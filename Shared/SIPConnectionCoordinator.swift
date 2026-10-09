import Foundation

/// Stable SIPCore identity for CallManager, PushKit and native system controls.
/// MainActor serializes SDK restarts and commands; generation fences queued SDK events.
@MainActor
final class SIPConnectionCoordinator: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    var onChange: (() -> Void)?
    var isBusy: () -> Bool = { false }
    private(set) var running = false
    private(set) var restarting = false
    private(set) var failure: String?
    var sdkVersion: String { adapter?.sdkVersion ?? "Nicht gestartet" }
    var limitations: [String] { adapter?.limitations ?? [] }
    private var adapter: SIPCore?
    private var generation = UUID()
    private var liveCalls: Set<UUID> = []
    private var transfers: Set<UUID> = []
    private var tracing = false
    private var networkAvailable = true
    private var systemManaged = false
    private var audioActive = false
    private var registrationRejected = false
    private let factory: () throws -> SIPCore
    private var registration: (account: SIPAccount, password: String, turnPassword: String)?

    init(factory: @escaping () throws -> SIPCore) { self.factory = factory }

    func start() throws {
        guard !restarting else { throw unavailable() }
        if adapter != nil { return }
        do { try install() }
        catch { failure = error.localizedDescription; onChange?(); throw error }
    }

    private func install() throws {
        let candidate = try factory()
        // Retain a failed candidate for shutdown before an explicit retry.
        adapter = candidate
        let token = UUID(); generation = token
        candidate.onEvent = { [weak self] event in
            guard let self, self.generation == token else { return }
            // Cleanup after a synchronous REGISTER rejection can queue an
            // "offline" event. Preserve the visible failure until explicit recovery.
            if self.failure != nil, case .registration = event { return }
            if case .call(let call) = event {
                switch call.state {
                case .ended, .failed: self.liveCalls.remove(call.id); self.transfers.remove(call.id)
                default: self.liveCalls.insert(call.id)
                }
            }
            if case .transfer(let id, let state) = event {
                switch state {
                case .progressing: self.transfers.insert(id)
                case .succeeded, .failed: self.transfers.remove(id)
                }
            }
            if case .engineStopped(let reason) = event {
                self.running = false; self.failure = reason; self.registrationRejected = false
                self.onChange?()
            }
            self.onEvent?(event)
        }
        try candidate.start()
        candidate.setSIPTracing(tracing && candidate.supportsSIPTracing)
        candidate.setNetworkAvailable(networkAvailable)
        candidate.setSystemCallAudio(systemManaged)
        candidate.systemAudioActivated(audioActive)
        running = true; failure = nil; registrationRejected = false
    }

    var canRestart: Bool { !restarting && !isBusy() && liveCalls.isEmpty && transfers.isEmpty }

    func restart() async throws {
        guard canRestart else { throw PhoneError.message("Die Verbindung kann erst nach allen Gesprächen und Vermittlungen neu gestartet werden.") }
        restarting = true; failure = nil; onChange?()
        defer { restarting = false; onChange?() }
        generation = UUID() // Invalidate before the first suspension.
        let previous = adapter
        previous?.onEvent = nil
        running = false
        do {
            if let previous { try await previous.shutdown() }
            adapter = nil
            onEvent?(.registration(.offline))
            try install()
            if let registration {
                try adapter!.register(account: registration.account, password: registration.password,
                                      turnPassword: registration.turnPassword)
            }
        } catch {
            generation = UUID()
            adapter?.onEvent = nil
            // Cleanup is mandatory before returning; never initialize another engine automatically.
            if let adapter { try? await adapter.shutdown() }
            adapter = nil; running = false
            failure = error.localizedDescription
            onEvent?(.registration(.failed(0)))
            throw error
        }
    }

    func shutdown() async throws {
        guard canRestart else { throw PhoneError.message("Bitte zuerst alle Gespräche beenden.") }
        restarting = true; generation = UUID()
        defer { restarting = false; onChange?() }
        let old = adapter; adapter = nil; running = false; old?.onEvent = nil
        try await old?.shutdown()
    }

    private func unavailable() -> PhoneError { .message("Telefonieverbindung nicht bereit. Bitte erneut verbinden.") }
    private func ready() throws -> SIPCore {
        guard !restarting, failure == nil else { throw unavailable() }
        if adapter == nil { try start() }
        guard running, let adapter else { throw unavailable() }
        return adapter
    }
    func register(account: SIPAccount, password: String, turnPassword: String) throws {
        guard !restarting, liveCalls.isEmpty else { throw unavailable() }
        // Retain the current requested profile even if the adapter rejects a
        // capability; an explicit reconnect must use that profile.
        registration = (account, password, turnPassword)
        // A failed profile request does not mean the native loop has stopped.
        // Only an explicit new profile request (foreground/push/manual) may
        // retry that same live adapter. Calls stay blocked until it succeeds;
        // genuine startup/loop failures still require an explicit restart.
        if registrationRejected, running, adapter != nil {
            registrationRejected = false; failure = nil
        }
        let core = try ready()
        do { try core.register(account: account, password: password, turnPassword: turnPassword) }
        catch {
            // A synchronous registration error must permit an explicit restart
            // of this same engine. Calls remain blocked until an explicit reconnect succeeds.
            failure = error.localizedDescription
            registrationRejected = running
            onChange?()
            throw error
        }
        onChange?()
    }
    func unregister() throws {
        guard !restarting else { throw unavailable() }
        try adapter?.unregister(); registration = nil
    }
    /// Logout can arrive during shutdown; prevent replaying that user's credentials.
    func cancelRegistrationIntent() { registration = nil }
    var supportsSIPTracing: Bool { !restarting && adapter?.supportsSIPTracing == true }
    func setSIPTracing(_ enabled: Bool) { tracing = enabled; if !restarting { adapter?.setSIPTracing(enabled && supportsSIPTracing) } }
    func invite(number: String, id: UUID) throws { try ready().invite(number: number, id: id) }
    func answer(id: UUID) throws { try ready().answer(id: id) }
    func end(id: UUID) throws { try ready().end(id: id) }
    func transfer(id: UUID, number: String) throws {
        transfers.insert(id)
        do { try ready().transfer(id: id, number: number) } catch { transfers.remove(id); throw error }
    }
    func transfer(id: UUID, destinationID: UUID) throws {
        transfers.insert(id)
        do { try ready().transfer(id: id, destinationID: destinationID) } catch { transfers.remove(id); throw error }
    }
    func setMuted(_ muted: Bool, id: UUID) throws { try ready().setMuted(muted, id: id) }
    func setHeld(_ held: Bool, id: UUID) throws { try ready().setHeld(held, id: id) }
    func sendDTMF(_ digit: String, id: UUID) throws { try ready().sendDTMF(digit, id: id) }
    func selectAudioDevice(id: String) throws { try ready().selectAudioDevice(id: id) }
    func refreshAudioDevices() { if !restarting { adapter?.refreshAudioDevices() } }
    func reloadAudioDevices() { if !restarting { adapter?.reloadAudioDevices() } }
    func microphoneLevel(id: UUID) -> Float? { restarting ? nil : adapter?.microphoneLevel(id: id) }
    func callAudioLevels(id: UUID) -> CallAudioLevels { restarting ? CallAudioLevels() : adapter?.callAudioLevels(id: id) ?? CallAudioLevels() }
    func setNetworkAvailable(_ available: Bool) { networkAvailable = available; if !restarting { adapter?.setNetworkAvailable(available) } }
    func refreshRegistration() { if !restarting { adapter?.refreshRegistration() } }
    func setSystemCallAudio(_ enabled: Bool) { systemManaged = enabled; if !restarting { adapter?.setSystemCallAudio(enabled) } }
    func systemAudioActivated(_ active: Bool) { audioActive = active; if !restarting { adapter?.systemAudioActivated(active) } }
}
