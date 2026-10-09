import Foundation

@MainActor
private final class MeterCore: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    var power: Float? = -20
    var levelReads = 0
    var playback: Float? = -30
    var audioReads = 0
    func callAudioLevels(id: UUID) -> CallAudioLevels {
        audioReads += 1
        return CallAudioLevels(microphone: power, playback: playback)
    }
    func microphoneLevel(id: UUID) -> Float? { levelReads += 1; return power }
    func setSIPTracing(_ enabled: Bool) {}
    func register(account: SIPAccount, password: String, turnPassword: String) throws {}
    func unregister() throws {}
    func invite(number: String, id: UUID) throws {}
    func answer(id: UUID) throws {}
    func end(id: UUID) throws {}
    func setMuted(_ muted: Bool, id: UUID) throws {}
    func setHeld(_ held: Bool, id: UUID) throws {}
    func sendDTMF(_ digit: String, id: UUID) throws {}
    func selectAudioDevice(id: String) throws {}
    func refreshAudioDevices() {}
    func setNetworkAvailable(_ available: Bool) {}
    func refreshRegistration() {}
    func emit(_ id: UUID, _ state: SIPCallState) {
        onEvent?(.call(SIPCallEvent(id: id, number: "500", displayName: "Local fixture", state: state)))
    }
}
@MainActor
private final class MeterAudio: CallAudio {
    func requestPermission() async -> Bool { false }
    func prepare() throws {}
    func release() {}
}

@main
struct AudioDeviceChecks {
    @MainActor
    static func main() async {
        let hardware = MacAudioHardware(devices: [
            .init(uid: "BuiltInMicrophoneDevice", name: "MacBook Air-Mikrofon"),
            .init(uid: "usb-one", name: "Headset (USB)"),
            .init(uid: "usb-two", name: "Headset (USB)"),
            .init(uid: "BuiltInSpeakerDevice", name: "MacBook Air-Lautsprecher")
        ], defaultInputUID: "BuiltInMicrophoneDevice", defaultOutputUID: "BuiltInSpeakerDevice")
        let builtIn = AudioDeviceOption(id: "input:opaque-sdk-id", name: "MacBook Air-Mikrofon (BuiltInMicrophoneDevice)")
        precondition(hardware.name(for: builtIn) == "MacBook Air-Mikrofon")
        precondition(hardware.uid(for: builtIn) == "BuiltInMicrophoneDevice")
        let defaultInput = AudioDeviceOption(id: "input:default", name: "Default Capture")
        let defaultOutput = AudioDeviceOption(id: "output:default", name: "Default Playback")
        precondition(hardware.name(for: defaultInput) == "Systemeinstellung")
        precondition(hardware.uid(for: defaultInput) == "BuiltInMicrophoneDevice")
        precondition(hardware.uid(for: defaultOutput) == "BuiltInSpeakerDevice")
        precondition(hardware.systemName(for: defaultOutput) == "MacBook Air-Lautsprecher")
        let headset = AudioDeviceOption(id: "input:usb-one", name: "Headset (USB) (usb-one)")
        let otherHeadset = AudioDeviceOption(id: "input:usb-two", name: "Headset (USB) (usb-two)")
        precondition(hardware.name(for: headset) == "Headset (USB)")
        precondition(hardware.uid(for: headset) != hardware.uid(for: otherHeadset))
        let disconnected = AudioDeviceOption(id: "input:gone", name: "Disconnected (gone)")
        precondition(hardware.uid(for: disconnected) == nil) // Never test a different microphone.
        precondition(hardware.name(for: .init(id: "input:unknown", name: "Headset (USB)")) == "Headset (USB)")
        print("PASS: friendly names, independent defaults, duplicate names and disconnected-device identity")

        precondition(MacMicrophoneMeter.normalizedLevel(-120) == 0)
        precondition(MacMicrophoneMeter.normalizedLevel(-55) == 0)
        precondition(MacMicrophoneMeter.normalizedLevel(-30) > 0)
        precondition(MacMicrophoneMeter.normalizedLevel(4) == 1)
        precondition(MacMicrophoneMeter.normalizedLevel(.nan) == 0)
        precondition(MacMicrophoneMeter.normalizedLevel(.infinity) == 0)
        print("PASS: silence, speech activity, loud levels and invalid level values")

        precondition(MacSpeechEnvelope.normalizedLevel(-120) == 0)
        precondition(MacSpeechEnvelope.normalizedLevel(.nan) == 0)
        precondition(MacSpeechEnvelope.normalizedLevel(.infinity) == 0)
        precondition(MacSpeechEnvelope.normalizedLevel(-10) < MacSpeechEnvelope.normalizedLevel(0))
        precondition(MacSpeechEnvelope.normalizedLevel(6) == 1)
        var envelope = MacSpeechEnvelope()
        let speech = CallAudioLevels(microphone: -12, playback: -120)
        envelope.sample(speech, at: 100)
        precondition(envelope.bars.last! > 0 && envelope.bars.dropLast().allSatisfy { $0 == 0 })
        let firstBars = envelope.bars
        for _ in 0..<20 { envelope.sample(speech, at: 100.001) }
        precondition(envelope.bars == firstBars) // Metadata events don't manufacture audio samples.
        envelope.sample(.init(microphone: -120, playback: -120), at: 100.04)
        precondition(envelope.bars[3] == firstBars[4] && envelope.bars[4] < firstBars[4])
        for step in 2...20 {
            envelope.sample(.init(microphone: -120, playback: -120), at: 100 + Double(step) * 0.04)
        }
        precondition(envelope.level == 0 && envelope.bars.allSatisfy { $0 == 0 })
        for step in 1...8 { envelope.sample(speech, at: 101 + Double(step) * 0.04) }
        precondition(Set(envelope.bars).count == 1) // Constant sound stays constant, without fake pulsing.
        envelope.sample(.init(microphone: -12, playback: -35), at: 102)
        envelope.sample(.init(microphone: nil, playback: -35), at: 102.04)
        precondition(envelope.level > 0 && envelope.bars.allSatisfy { $0 < MacSpeechEnvelope.normalizedLevel(-12) })
        envelope.sample(.init(microphone: nil, playback: nil), at: 102.041)
        precondition(envelope.level == 0 && envelope.bars.allSatisfy { $0 == 0 })
        envelope.sample(.init(microphone: .nan, playback: .infinity), at: 102.08)
        precondition(envelope.bars.allSatisfy { $0 == 0 })
        print("PASS: real temporal speech history, fast response, quiet pauses, headroom, mute direction and sampling cadence")

        let core = MeterCore()
        let manager = CallManager(core: core, audio: MeterAudio(), diagnostics: Diagnostics())
        let meter = MacMicrophoneMeter()
        let id = UUID()
        core.emit(id, .incoming)
        await meter.monitor(input: builtIn, hardware: hardware, manager: manager)
        precondition(meter.status == .waiting && meter.level == 0 && core.levelReads == 0)
        core.emit(id, .active)
        await meter.monitor(input: builtIn, hardware: hardware, manager: manager)
        precondition(meter.status == .listening && meter.level > 0 && core.levelReads == 1)
        manager.toggleMute()
        await meter.monitor(input: builtIn, hardware: hardware, manager: manager)
        precondition(meter.status == .muted && meter.level == 0 && core.levelReads == 1)
        manager.toggleMute()
        core.emit(id, .held)
        await meter.monitor(input: builtIn, hardware: hardware, manager: manager)
        precondition(meter.status == .held && meter.level == 0 && core.levelReads == 1)
        core.emit(id, .active)
        core.power = nil
        await meter.monitor(input: builtIn, hardware: hardware, manager: manager)
        precondition(meter.status == .waiting && meter.level == 0)
        meter.stop()
        precondition(meter.status == .idle && meter.level == 0)
        print("PASS: call meter reuses call levels, honors mute/hold, waits for media and resets on close")

        let activityCore = MeterCore()
        let activityManager = CallManager(core: activityCore, audio: MeterAudio(), diagnostics: Diagnostics())
        let activity = MacCallActivity(manager: activityManager)
        precondition(!activity.snapshot.hasCall && !activity.isSampling)
        let activeID = UUID()
        activityCore.emit(activeID, .incoming)
        activity.sampleNow()
        precondition(activity.snapshot.callID == activeID && activity.snapshot.state == .incoming && activity.isSampling && activityCore.audioReads == 0)
        activityCore.emit(activeID, .active)
        activity.sampleNow()
        precondition(activity.snapshot.state == .active && activity.snapshot.level > 0 && activity.snapshot.waveform.last! > 0 && activityCore.audioReads == 1)
        activityManager.toggleMute()
        precondition(activityManager.callAudioLevels().microphone == nil)
        activity.sampleNow()
        precondition(activity.snapshot.state == .muted && activity.snapshot.level > 0) // Peer remains audible.
        activityCore.emit(activeID, .held)
        let readsBeforeHold = activityCore.audioReads
        activity.sampleNow()
        precondition(activity.snapshot.state == .held && activity.snapshot.level == 0
            && activity.snapshot.waveform.allSatisfy { $0 == 0 } && activityCore.audioReads == readsBeforeHold)
        activityCore.emit(activeID, .active)
        activityCore.emit(activeID, .remoteHeld)
        activity.sampleNow()
        precondition(activity.snapshot.state == .held && activity.snapshot.level == 0)
        activityCore.emit(activeID, .active)
        activityCore.power = .nan; activityCore.playback = .infinity
        activity.sampleNow()
        precondition(activity.snapshot.level == 0)
        activityCore.emit(activeID, .ended)
        activity.sampleNow()
        precondition(!activity.snapshot.hasCall && activity.snapshot.callID == nil && !activity.isSampling && activity.snapshot.elapsed.isEmpty)
        let nextID = UUID()
        activityCore.power = -120; activityCore.playback = -120
        activityCore.emit(nextID, .incoming); activityCore.emit(nextID, .active)
        activity.sampleNow()
        precondition(activity.snapshot.callID == nextID && activity.snapshot.state == .active && activity.snapshot.level == 0)
        activity.stop()
        activity.sampleNow() // Queued callbacks after stopping must not restart the timer.
        precondition(!activity.isSampling && !activity.snapshot.hasCall)
        print("PASS: app-owned call activity, both audio directions, mute, local/remote hold, end, restart and invalid levels")
        let start = Date(timeIntervalSince1970: 1_000)
        precondition(MacCallActivity.duration(since: start, now: start.addingTimeInterval(65)) == "1:05")
        precondition(MacCallActivity.duration(since: start, now: start.addingTimeInterval(3601)) == "1:00:01")
        precondition(MacCallActivity.duration(since: start, now: start.addingTimeInterval(-5)) == "0:00")
        print("PASS: compact duration, long conversations and clock corrections")
    }
}
