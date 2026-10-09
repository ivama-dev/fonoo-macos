import Foundation

/// One recovery attempt per foreground session, delayed until a network is available.
/// Brief inactive phases (permission sheets, Control Center) do not recreate the account.
@MainActor
final class ForegroundRegistrationRecovery {
    var enabled = true
    var isBusy: () -> Bool = { false }
    var restore: () -> Void = {}
    private var active = false
    private var networkAvailable = false
    private var pending = true

    func becameActive() {
        active = true
        attemptIfNeeded()
    }

    func becameInactive(background: Bool) {
        active = false
        if background { pending = true }
    }

    func networkChanged(available: Bool) {
        networkAvailable = available
        attemptIfNeeded()
    }

    func manualRegistrationStarted() { pending = false }

    private func attemptIfNeeded() {
        guard active, networkAvailable, pending, enabled else { return }
        // Preserve the live call's account and transport for this foreground session.
        guard !isBusy() else { pending = false; return }
        // Consume before restoring: synchronous SDK events must not start another attempt.
        pending = false
        restore()
    }
}

enum RegistrationStatus: Equatable {
    case offline, registering, registered, unregistering, failed(Int)
    var canReconnect: Bool {
        switch self { case .offline, .failed: true; default: false }
    }
    var label: String {
        switch self {
        case .offline: "Nicht registriert"
        case .registering: "Registrierung läuft …"
        case .registered: "Registriert"
        case .unregistering: "Abmeldung läuft …"
        case .failed(let code): code == 0 ? "Registrierung fehlgeschlagen" : "Registrierung fehlgeschlagen (\(code))"
        }
    }
}

enum SIPCallState { case incoming, connecting, ringing, active, holding, held, resuming, remoteHeld, ended, failed(Int) }
struct SIPCallEvent {
    let id: UUID
    let number: String
    let displayName: String
    let state: SIPCallState
    var signalingID: String? = nil
}
struct AudioDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
    var symbol: String = "speaker.wave.2"
    var isSelected: Bool = false
}
struct CallAudioLevels {
    var microphone: Float?
    var playback: Float?
}
struct MediaSnapshot {
    let codec: String
    let downloadKbps: Float
    let uploadKbps: Float
    let jitterMs: Float
    let lossPercent: Float
    var iceStatus: String = "Nicht verfügbar"
    var audioDirection: String = "Nicht verfügbar"
    var inputDevice: String = "Nicht verfügbar"
    var outputDevice: String = "Nicht verfügbar"
    var jitterLabel: String = "Jitterpuffer"
}
enum TransferState { case progressing, succeeded, failed(Int) }
enum SIPEvent {
    case operationError(String)
    case engineStopped(String)
    case transfer(UUID, TransferState)
    case sipPacket(SIPTracePacket)
    // Application-defined text only; never SDK messages or SIP packet contents.
    case registrationTrace(String)
    case callTrace(String)
    case registration(RegistrationStatus)
    case call(SIPCallEvent)
    case audioDevices([AudioDeviceOption], selectedID: String?)
    case media(MediaSnapshot)
}

/// The app depends on this interface; PBX and SDK details remain in the adapter.
/// Every command and event is serialized on the main actor.
@MainActor
protocol SIPCore: AnyObject {
    var onEvent: ((SIPEvent) -> Void)? { get set }
    var sdkVersion: String { get }
    var limitations: [String] { get }
    var supportsSIPTracing: Bool { get }
    /// Initialize without credentials. Shutdown returns only after callbacks,
    /// audio, timers and transports have stopped, even when deregistration fails.
    func start() throws
    func shutdown() async throws
    func setSIPTracing(_ enabled: Bool)
    func register(account: SIPAccount, password: String, turnPassword: String) throws
    func unregister() throws
    func invite(number: String, id: UUID) throws
    func transfer(id: UUID, number: String) throws
    func transfer(id: UUID, destinationID: UUID) throws
    func answer(id: UUID) throws
    func end(id: UUID) throws
    func setMuted(_ muted: Bool, id: UUID) throws
    func setHeld(_ held: Bool, id: UUID) throws
    func sendDTMF(_ digit: String, id: UUID) throws
    func selectAudioDevice(id: String) throws
    func refreshAudioDevices()
    func reloadAudioDevices()
    /// Read-only level from the existing call capture path, in SDK decibels.
    func microphoneLevel(id: UUID) -> Float?
    func callAudioLevels(id: UUID) -> CallAudioLevels
    func setNetworkAvailable(_ available: Bool)
    func refreshRegistration()
    func setSystemCallAudio(_ enabled: Bool)
    func systemAudioActivated(_ active: Bool)
}

@MainActor
protocol CallAudio: AnyObject {
    func requestPermission() async -> Bool
    func prepare() throws
    func release()
    func setSystemManaged(_ enabled: Bool)
}

// Non-iOS test doubles and other adapters may retain manual audio ownership.
extension SIPCore {
    var sdkVersion: String { "Nicht verfügbar" }
    var limitations: [String] { [] }
    var supportsSIPTracing: Bool { false }
    func start() throws {}
    func shutdown() async throws { try unregister(); onEvent = nil }
    func reloadAudioDevices() { refreshAudioDevices() }
    func microphoneLevel(id: UUID) -> Float? { nil }
    func callAudioLevels(id: UUID) -> CallAudioLevels { CallAudioLevels(microphone: microphoneLevel(id: id), playback: nil) }
    func transfer(id: UUID, number: String) throws { throw PhoneError.message("Vermittlung wird nicht unterstützt.") }
    func transfer(id: UUID, destinationID: UUID) throws { throw PhoneError.message("Rückfragevermittlung wird nicht unterstützt.") }
    func setSystemCallAudio(_ enabled: Bool) {}
    func systemAudioActivated(_ active: Bool) {}
}
extension CallAudio {
    func setSystemManaged(_ enabled: Bool) {}
}
