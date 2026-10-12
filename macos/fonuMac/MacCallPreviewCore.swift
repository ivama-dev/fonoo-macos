#if DEBUG
import Foundation

/// UI-only fixture. Never constructs an SDK core, uses a microphone or sends SIP.
@MainActor
final class MacCallPreviewCore: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    private let id = UUID()
    private var muted = false
    func start() {
        onEvent?(.registration(.registered))
        emit(.incoming)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-call-incoming") { return }
        emit(arguments.contains("--preview-call-ringing") ? .ringing : .active)
    }
    private func emit(_ state: SIPCallState) {
        onEvent?(.call(SIPCallEvent(id: id, number: "500", displayName: "Testgespräch", state: state)))
    }
    func callAudioLevels(id: UUID) -> CallAudioLevels {
        let phase = ProcessInfo.processInfo.systemUptime
        return CallAudioLevels(microphone: muted ? nil : Float(-34 + 11 * sin(phase * 2.2)),
            playback: Float(-38 + 12 * sin(phase * 1.6)))
    }
    func setSIPTracing(_ enabled: Bool) {}
    func register(account: SIPAccount, password: String, turnPassword: String) throws {}
    func unregister() throws {}
    func invite(number: String, id: UUID) throws {}
    func answer(id: UUID) throws { emit(.active) }
    func end(id: UUID) throws { emit(.ended) }
    func setMuted(_ muted: Bool, id: UUID) throws { self.muted = muted }
    func setHeld(_ held: Bool, id: UUID) throws { emit(held ? .held : .active) }
    func sendDTMF(_ digit: String, id: UUID) throws {}
    func selectAudioDevice(id: String) throws {}
    func refreshAudioDevices() {}
    func setNetworkAvailable(_ available: Bool) {}
    func refreshRegistration() {}
}
#endif
