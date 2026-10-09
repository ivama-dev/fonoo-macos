import AppKit
import Combine
import SwiftUI

/// App-owned, read-only sampling. It stays alive when the call view disappears,
/// the window is minimized, or another app has focus. No second capture session.
@MainActor
final class MacCallActivity: ObservableObject {
    enum State { case idle, incoming, connecting, ringing, active, muted, held, ending }
    struct Snapshot: Equatable {
        var callID: UUID?
        var state: State = .idle
        var contact = ""
        var elapsed = ""
        var level: Double = 0
        var levelsAvailable = false
        var waveform = Array(repeating: 0.0, count: MacSpeechEnvelope.barCount)
        var hasCall: Bool { state != .idle }
        var label: String {
            switch state {
            case .idle: "fonoo"
            case .incoming: "Eingehender Anruf"
            case .connecting: "Verbindung wird aufgebaut"
            case .ringing: "Klingelt …"
            case .active: "Im Gespräch"
            case .muted: "Mikrofon stumm"
            case .held: "Gehalten"
            case .ending: "Gespräch wird beendet"
            }
        }
        var symbol: String {
            switch state {
            case .idle: "phone.bubble"
            case .incoming, .ringing: "phone.arrow.up.right"
            case .connecting: "phone"
            case .active: "phone.fill"
            case .muted: "mic.slash.fill"
            case .held: "pause.fill"
            case .ending: "phone.down"
            }
        }
        var isSpeaking: Bool { state == .active || state == .muted }
        var tint: NSColor { state == .held || state == .ending ? .secondaryLabelColor : .systemGreen }
    }
    @Published private(set) var snapshot = Snapshot()
    private weak var manager: CallManager?
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var sampledCallID: UUID?
    private var envelope = MacSpeechEnvelope()
    private var stopped = false
    #if DEBUG
    var isSampling: Bool { timer?.isValid == true }
    #endif

    init(manager: CallManager) {
        self.manager = manager
        observation = manager.objectWillChange.sink { [weak self] _ in
            // @Published sends before assignment. Read the complete state after
            // the event, including consultation swaps and SDK-confirmed endings.
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
        sampleNow()
    }
    func sampleNow(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !stopped else { return }
        guard let manager, let call = manager.controlledCall else { reset(); return }
        if timer == nil {
            let timer = Timer(timeInterval: MacSpeechEnvelope.sampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleNow() }
            }
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        let state: State
        switch call.phase {
        case .incoming: state = .incoming
        case .connecting: state = .connecting
        case .ringing: state = .ringing
        case .ending: state = .ending
        case .active:
            state = call.isHeld || call.isRemoteHeld || call.holdPending ? .held : call.isMuted ? .muted : .active
        }
        if sampledCallID != call.id { envelope.reset() }
        let levels = manager.callAudioLevels()
        if state == .active || state == .muted {
            envelope.sample(levels, at: uptime)
        } else { envelope.reset() }
        let next = Snapshot(callID: call.id, state: state, contact: call.displayedContact.name,
            elapsed: (manager.call?.connectedAt ?? call.connectedAt).map { Self.duration(since: $0, now: now) } ?? "",
            level: envelope.level, levelsAvailable: levels.microphone != nil || levels.playback != nil, waveform: envelope.bars)
        sampledCallID = call.id
        if snapshot != next { snapshot = next }
    }
    static func duration(since start: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(start)
        guard interval.isFinite else { return "0:00" }
        let total = Int(min(max(0, interval), Double(Int32.max)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
    func stop() { stopped = true; observation?.cancel(); observation = nil; reset() }
    private func reset() {
        timer?.invalidate(); timer = nil; sampledCallID = nil
        envelope.reset()
        if snapshot != Snapshot() { snapshot = Snapshot() }
    }
    deinit { timer?.invalidate() }
}

/// Short amplitude history, not a frequency spectrum. Each bar is an actual
/// recent SDK level, with independent send/receive envelopes. No random motion.
struct MacSpeechEnvelope {
    static let barCount = 5
    static let sampleInterval: TimeInterval = 0.04
    private var microphone: Double = 0
    private var playback: Double = 0
    private var microphoneHistory = Array(repeating: 0.0, count: barCount)
    private var playbackHistory = Array(repeating: 0.0, count: barCount)
    private var sampledAt: TimeInterval?
    var level: Double { max(microphone, playback) }
    var bars: [Double] { zip(microphoneHistory, playbackHistory).map { max($0.0, $0.1) } }

    static func normalizedLevel(_ decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        // The call SDK reports dBm0, unlike local capture's dBFS. Allow
        // headroom above -10 so conversational peaks don't pin every bar.
        let normalized = min(1, max(0, (Double(decibels) + 55) / 61))
        return pow(normalized, 1.6)
    }
    mutating func sample(_ levels: CallAudioLevels, at time: TimeInterval) {
        let input = levels.microphone.flatMap { $0.isFinite ? Self.normalizedLevel($0) : nil }
        let output = levels.playback.flatMap { $0.isFinite ? Self.normalizedLevel($0) : nil }
        // Missing audio (including mute) immediately clears only that direction.
        // A muted microphone must never leave its old peaks in the peer's trace.
        if input == nil { microphone = 0; microphoneHistory = Array(repeating: 0, count: Self.barCount) }
        if output == nil { playback = 0; playbackHistory = Array(repeating: 0, count: Self.barCount) }
        guard input != nil || output != nil, time.isFinite else { reset(); return }
        let elapsed = sampledAt.map { max(0, time - $0) } ?? Self.sampleInterval
        // State/metadata notifications also trigger sampling. They must not
        // advance the history faster than the regular audio timer.
        guard sampledAt == nil || elapsed >= Self.sampleInterval * 0.8 else { return }
        sampledAt = time
        let decay = exp(-elapsed / 0.075)
        microphone = Self.release(input ?? 0, previous: microphone, decay: decay)
        playback = Self.release(output ?? 0, previous: playback, decay: decay)
        microphoneHistory.removeFirst(); microphoneHistory.append(microphone)
        playbackHistory.removeFirst(); playbackHistory.append(playback)
    }
    private static func release(_ target: Double, previous: Double, decay: Double) -> Double {
        let next = max(target, previous * decay)
        return next < 0.004 ? 0 : next
    }
    mutating func reset() { self = Self() }
}

/// Both call windows and the menu bar draw the same recent speech envelope.
struct MacCallWaveform: View {
    let snapshot: MacCallActivity.Snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(snapshot.waveform.enumerated()), id: \.offset) { _, level in
                Capsule().fill(snapshot.isSpeaking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 3, height: 3 + level * 15)
            }
        }.frame(width: 27, height: 20)
            .animation(reduceMotion ? nil : .linear(duration: MacSpeechEnvelope.sampleInterval), value: snapshot.waveform)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sprachpegel des Gesprächs")
            .accessibilityValue(snapshot.label + (snapshot.levelsAvailable ? ", \(Int(snapshot.level * 100)) Prozent" : ", Audiomesswerte nicht verfügbar"))
            .help(snapshot.levelsAvailable ? "Reagiert auf deine Stimme und auf die Gegenstelle" : "Keine Audiomesswerte verfügbar")
    }
}
