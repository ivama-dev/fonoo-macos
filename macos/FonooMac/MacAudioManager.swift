import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The active SIP engine owns Core Audio; microphone permission remains explicit.
@MainActor
final class AudioManager: CallAudio {
    var onRouteChange: (() -> Void)?
    var onInterruption: ((Bool) -> Void)?
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    func prepare() throws { MacMicrophoneMeter.shared.suspendLocalCapture() }
    func release() {}
}

/// Match the SDK's opaque suffix against real Core Audio UIDs. Parentheses that
/// are part of a product name remain intact; device identity never uses its label.
struct MacAudioHardware {
    struct Device { let uid: String; let name: String }
    let devices: [Device]
    let defaultInputUID: String?
    let defaultOutputUID: String?

    init() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var found: [Device] = []
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
           size >= MemoryLayout<AudioDeviceID>.size {
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            let status = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
            }
            if status == noErr {
                found = ids.compactMap { id in
                    guard let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                          let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
                    return Device(uid: uid, name: name)
                }
            }
        }
        devices = found
        defaultInputUID = Self.defaultUID(kAudioHardwarePropertyDefaultInputDevice)
        defaultOutputUID = Self.defaultUID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func isSystemDefault(_ option: AudioDeviceOption) -> Bool {
        ["default capture", "default playback", "default"].contains(
            option.name.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased())
    }
    func uid(for option: AudioDeviceOption) -> String? {
        if Self.isSystemDefault(option) {
            return option.id.hasPrefix("input:") ? defaultInputUID : defaultOutputUID
        }
        return devices.first { option.name.hasSuffix(" (" + $0.uid + ")") }?.uid
    }
    func name(for option: AudioDeviceOption) -> String {
        if Self.isSystemDefault(option) { return "Systemeinstellung" }
        return uid(for: option).flatMap { uid in devices.first { $0.uid == uid }?.name } ?? option.name
    }
    func systemName(for option: AudioDeviceOption) -> String? {
        guard Self.isSystemDefault(option), let uid = uid(for: option) else { return nil }
        return devices.first { $0.uid == uid }?.name
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    // Deterministic fixture for presentation checks, independent of host devices.
    init(devices: [Device], defaultInputUID: String?, defaultOutputUID: String?) {
        self.devices = devices; self.defaultInputUID = defaultInputUID; self.defaultOutputUID = defaultOutputUID
    }
}

/// A local input-only preview. Session work and sample callbacks share one queue;
/// no samples leave this object, and no file, speaker output or network is used.
private final class MacMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.fonoo.microphone-preview")
    private var session: AVCaptureSession?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var lastReport = -Double.infinity

    func start(uid: String, onLevel: @escaping @Sendable (Float) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopOnQueue()
                guard let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    continuation.resume(returning: false); return
                }
                let session = AVCaptureSession()
                let output = AVCaptureAudioDataOutput()
                output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsNonInterleaved: false]
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    continuation.resume(returning: false); return
                }
                session.beginConfiguration()
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                session.commitConfiguration()
                self.onLevel = onLevel
                self.session = session
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
    }
    /// Wait for capture to stop before the telephony engine takes the microphone.
    func stop() { queue.sync { stopOnQueue() } }
    var isRunning: Bool { queue.sync { session?.isRunning == true } }
    private func stopOnQueue() {
        onLevel = nil
        session?.stopRunning()
        session = nil
        lastReport = -.infinity
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 0.08 else { return }
        lastReport = now
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mFormatID == kAudioFormatLinearPCM,
              format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.pointee.mBitsPerChannel == 32 else { return }
        var list = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))
        var retainedBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBuffer) == noErr,
            list.mNumberBuffers == 1, let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        var squareSum: Double = 0
        for index in 0..<count {
            let value = Double(samples[index])
            guard value.isFinite else { return }
            squareSum += value * value
        }
        // Some virtual capture connections report constant channel power. Measure
        // actual PCM samples instead; retain their block until the scan completes.
        let power = Float(10 * log10(max(squareSum / Double(count), 1e-12)))
        withExtendedLifetime(retainedBuffer) { onLevel?(power) }
    }
}

@MainActor
final class MacMicrophoneMeter: ObservableObject {
    static let shared = MacMicrophoneMeter()
    enum Status { case idle, starting, listening, needsPermission, denied, unavailable, waiting, muted, held }
    @Published private(set) var level: Double = 0
    @Published private(set) var status: Status = .idle
    private let capture = MacMicrophoneCapture()
    private var timer: Timer?
    private var generation = UUID()
    private var lastSampleAt: TimeInterval?
    private var startedAt: TimeInterval = 0
    #if DEBUG
    private(set) var previewSampleCount = 0
    private(set) var previewPowerRange: ClosedRange<Float>?
    var isPreviewRunning: Bool { capture.isRunning }
    #endif

    static func normalizedLevel(_ decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        // A readable activity meter, not a calibrated loudness measurement.
        return min(1, max(0, Double(decibels + 55) / 45))
    }
    var message: String {
        switch status {
        case .idle: "Mikrofonanzeige pausiert."
        case .starting: "Mikrofon wird vorbereitet …"
        case .listening: level > 0.12 ? "Ton kommt an." : "Sprich kurz – hier siehst du deinen Mikrofonpegel."
        case .needsPermission: "Gib das Mikrofon frei, um es hier zu testen."
        case .denied: "Der Mikrofonzugriff ist in den Mac-Einstellungen gesperrt."
        case .unavailable: "Dieses Mikrofon ist gerade nicht verfügbar. Wähle ein anderes Gerät."
        case .waiting: "Die Anzeige startet, sobald das Gespräch verbunden ist."
        case .muted: "Dein Mikrofon ist stummgeschaltet."
        case .held: "Das Gespräch wird gehalten."
        }
    }
    func monitor(input: AudioDeviceOption?, hardware: MacAudioHardware, manager: CallManager, requestPermission: Bool = false) async {
        stop()
        let current = generation
        if manager.busy {
            status = .waiting
            pollCall(manager)
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak manager] _ in
                MainActor.assumeIsolated {
                    if let manager { self?.pollCall(manager) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return
        }
        var permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined && requestPermission {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            permission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard current == generation, !Task.isCancelled, !manager.busy else { return }
        guard permission == .authorized else {
            status = permission == .notDetermined ? .needsPermission : .denied
            return
        }
        guard let input, let uid = hardware.uid(for: input) else { status = .unavailable; return }
        status = .starting
        startedAt = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        previewSampleCount = 0
        previewPowerRange = nil
        #endif
        let running = await capture.start(uid: uid) { [weak self] power in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.lastSampleAt = ProcessInfo.processInfo.systemUptime
                self.level = max(Self.normalizedLevel(power), self.level * 0.65)
                self.status = .listening
                #if DEBUG
                self.previewSampleCount += 1
                let range = self.previewPowerRange
                self.previewPowerRange = min(range?.lowerBound ?? power, power)...max(range?.upperBound ?? power, power)
                #endif
            }
        }
        guard current == generation, !Task.isCancelled, !manager.busy else { return }
        guard running else { capture.stop(); status = .unavailable; return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - (self.lastSampleAt ?? self.startedAt) > 3 {
                    self.level = 0; self.status = .unavailable
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func pollCall(_ manager: CallManager) {
        guard let call = manager.controlledCall else { level = 0; status = .waiting; return }
        if call.isMuted { level = 0; status = .muted }
        else if call.isHeld { level = 0; status = .held }
        else if let power = manager.microphoneLevel() {
            level = max(Self.normalizedLevel(power), level * 0.65); status = .listening
        } else { level = 0; status = .waiting }
    }
    func suspendLocalCapture() {
        generation = UUID()
        capture.stop()
        level = 0
    }
    func stop() {
        suspendLocalCapture()
        timer?.invalidate(); timer = nil
        lastSampleAt = nil
        status = .idle
    }
}
