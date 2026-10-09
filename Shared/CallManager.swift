import Combine
import Foundation

@MainActor
final class CallManager: ObservableObject {
    @Published private(set) var consultation: CallSession?
    @Published private(set) var transferPending = false
    @Published private(set) var consultationPending = false
    private var consultationTarget: Contact?
    private var originalEnded = false
    private var originalFailed = false
    private var resumeWhenHeld = false
    private var holdTimeout: Task<Void, Never>?
    private var transferTimeout: Task<Void, Never>?
    var controlledCall: CallSession? { consultation ?? call }
    var canTransfer: Bool { call?.phase == .active && call?.holdPending == false && call?.isRemoteHeld == false && !transferPending && !consultationPending && consultation == nil }
    @Published private(set) var call: CallSession?
    @Published private(set) var registration: RegistrationStatus = .offline
    @Published private(set) var recents: [RecentCall] = []
    @Published private(set) var historyStatus = ""
    private var cloudHistoryManaged = false
    var onHistoryRefresh: (() -> Void)?
    var onHistoryDelete: ((Set<UUID>) -> Void)?
    @Published private(set) var notice: String?
    @Published private(set) var audioDevices: [AudioDeviceOption] = []
    @Published private(set) var selectedAudioID: String?
    @Published private(set) var networkLabel = "Netzwerk wird geprüft"
    @Published private(set) var preparingCall = false
    @Published private(set) var acceptingCall = false
    var resolveContact: ((String) async -> Contact?)?
    private var lookupTask: Task<Void, Never>?
    private var answerTimeout: Task<Void, Never>?
    var doNotDisturb = false { didSet { if doNotDisturb { incomingCalls?.suppressWaitingCall() } } }
    let diagnostics: Diagnostics
    var outgoingReporter: OutgoingCallReporting?
    var systemControls: SystemCallControlling?
    private var systemHold: (id: UUID, held: Bool, done: (Bool) -> Void)?
    private var systemHoldTimeout: Task<Void, Never>?
    private var nativeCallID: UUID? {
        if let systemOutgoingID { return systemOutgoingID }
        guard let call, incomingCalls?.owns(call.id) == true else { return nil }
        return incomingCalls?.systemID
    }
    private var systemOutgoingID: UUID?
    private var systemOutgoingStarted = false
    private var systemStartCompletion: ((Bool) -> Void)?
    private var systemStartTimeout: Task<Void, Never>?
    private var systemAudioOwned = false
    private var incomingCalls: IncomingCallCoordinator?
    private var history: CallHistoryStore?
    private let core: SIPCore
    private let audio: CallAudio
    private var operation: UUID?
    private var pendingTask: Task<Void, Never>?
    private var endingTimeout: Task<Void, Never>?

    init(core: SIPCore, audio: CallAudio, diagnostics: Diagnostics, history: CallHistoryStore? = nil) {
        self.core = core; self.audio = audio; self.diagnostics = diagnostics
        self.history = history
        if let history {
            do { recents = try history.load() }
            catch {
                // Preserve unreadable or future-format data instead of overwriting it.
                self.history = nil
                notice = "Gespeicherte Anrufliste konnte nicht geladen werden."
                diagnostics.record("Lokale Anrufliste konnte nicht geladen werden; Datei bleibt erhalten")
            }
        }
        core.onEvent = { [weak self] event in self?.receive(event) }
    }
    var busy: Bool { call != nil || preparingCall || incomingCalls?.busy == true }
    var audioName: String { audioDevices.first { $0.id == selectedAudioID }?.name ?? "Audioausgabe" }

    func attachIncomingCalls(_ coordinator: IncomingCallCoordinator) {
        incomingCalls = coordinator
        coordinator.forwardSIP = { [weak self] event in self?.receiveCall(event, systemRouted: true) }
        coordinator.acceptSIP = { [weak self] id, done in
            guard let self, self.call?.id == id else { done(false); return }
            self.answerDirect(completion: done)
        }
        coordinator.endSIP = { [weak self] id in
            guard let self else { return }
            if self.call?.id == id { self.endDirect() }
            else { try? self.core.end(id: id) }
        }
        coordinator.changed = { [weak self] in
            guard let self else { return }
            self.updateSystemAudioOwnership()
            self.objectWillChange.send()
        }
        coordinator.trace = { [weak self] in self?.diagnostics.record($0) }
    }
    private func updateSystemAudioOwnership() {
        let managed = systemOutgoingID != nil || incomingCalls?.busy == true || (systemAudioOwned && call != nil)
        if systemAudioOwned && !managed { core.systemAudioActivated(false) }
        systemAudioOwned = managed
        audio.setSystemManaged(managed)
        core.setSystemCallAudio(managed)
    }
    var canReceiveSystemCall: Bool { call == nil && !preparingCall && !doNotDisturb }
    func restoreIncomingConnection(account: SIPAccount, password: String, turnPassword: String) throws {
        guard call == nil, !preparingCall, !doNotDisturb else {
            throw PhoneError.message("Ein anderer Anruf ist bereits aktiv.")
        }
        // Invalidate yesterday's/foreground registration before the wake Task
        // can announce "ready". Only the fresh registrar response may do that.
        registration = .registering
        do { try core.register(account: account.validated(), password: password, turnPassword: turnPassword) }
        catch { registration = .failed(0); throw error }
    }
    func systemAudioActivated(_ active: Bool) { core.systemAudioActivated(active) }
    func setSystemMuted(_ muted: Bool) -> Bool {
        guard let call, call.phase == .active else { return false }
        do { try core.setMuted(muted, id: call.id); self.call?.isMuted = muted; return true }
        catch { return false }
    }

    func setSIPTracing(_ enabled: Bool) { core.setSIPTracing(enabled) }

    func register(account: SIPAccount, password: String, turnPassword: String = "") throws {
        guard !busy else { throw PhoneError.message("Bitte zuerst das Gespräch beenden.") }
        guard !password.isEmpty else { throw PhoneError.message("Bitte das SIP-Passwort eingeben.") }
        notice = nil
        do { try core.register(account: account.validated(), password: password, turnPassword: turnPassword) }
        catch {
            registration = .failed(0)
            diagnostics.recordRegistration("FEHLER: Registrierung konnte lokal nicht gestartet werden. Einstellungen und vorherigen Schritt prüfen.")
            throw error
        }
    }
    func unregister() throws {
        guard !busy else { throw PhoneError.message("Bitte zuerst das Gespräch beenden.") }
        try core.unregister()
    }
    func networkChanged(available: Bool, label: String) {
        networkLabel = label
        diagnostics.record("Netzwerk: \(label)")
        core.setNetworkAvailable(available)
        if !available { registration = .offline }
        else { core.refreshRegistration() }
    }
    func start(_ contact: Contact) { start(contact, native: outgoingReporter != nil, completion: { _ in }) }
    func startSystemCall(_ contact: Contact, completion: @escaping (Bool) -> Void) {
        guard outgoingReporter != nil else { completion(false); return }
        start(contact, native: true, completion: completion)
    }
    private func start(_ contact: Contact, native: Bool, completion: @escaping (Bool) -> Void) {
        guard !busy else { completion(false); return }
        guard registration == .registered else { show("Bitte zuerst unter Profil das SIP-Konto registrieren."); completion(false); return }
        let number: String
        do { number = try SIPAccount.normalizedNumber(contact.number) } catch { show(error.localizedDescription); completion(false); return }
        let id = UUID()
        operation = id
        preparingCall = true
        notice = nil
        pendingTask = Task { [weak self] in
            guard let self else { completion(false); return }
            let granted = await audio.requestPermission()
            guard !Task.isCancelled, operation == id else { completion(false); return }
            operation = nil; preparingCall = false
            guard granted else { show("Mikrofonzugriff fehlt. Bitte in den iPhone-Einstellungen für fonoo erlauben."); completion(false); return }
            guard call == nil, registration == .registered else { completion(false); return }
            do {
                if native {
                    systemOutgoingID = id
                    systemStartCompletion = completion
                    updateSystemAudioOwnership()
                }
                try audio.prepare()
                call = CallSession(id: id, original: Contact(id: contact.id, name: contact.name, role: contact.role, number: number))
                diagnostics.record("Ausgehender Anruf gestartet")
                if native {
                    systemStartTimeout = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard !Task.isCancelled, let self, systemOutgoingID == id, !systemOutgoingStarted else { return }
                        finish(failed: true)
                        show("Die System-Anrufsteuerung hat den Anruf nicht gestartet.")
                    }
                    outgoingReporter?.startOutgoing(id: id, contact: call!.original) { [weak self] in
                        guard let self, systemOutgoingID == id else { return }
                        if systemOutgoingStarted { endDirect() }
                        else { finish(failed: true) }
                    }
                } else {
                    try core.invite(number: number, id: id)
                    completion(true)
                }
            } catch {
                if call?.id == id { finish(failed: true) }
                else {
                    systemOutgoingID = nil; systemStartCompletion = nil
                    audio.release(); updateSystemAudioOwnership()
                    completion(false)
                }
                show(error.localizedDescription)
            }
        }
    }
    /// Called only after the OS authorizes its Start action. Duplicate or stale
    /// actions cannot place a second SIP call.
    func beginSystemOutgoing(id: UUID) -> Bool {
        guard systemOutgoingID == id, !systemOutgoingStarted,
              let call, call.id == id, call.phase == .connecting,
              registration == .registered else { return false }
        systemOutgoingStarted = true
        systemStartTimeout?.cancel()
        do {
            try core.invite(number: call.original.number, id: id)
            guard self.call?.id == id else { return false }
            let done = systemStartCompletion; systemStartCompletion = nil; done?(true)
            return true
        } catch { finish(failed: true); show(error.localizedDescription); return false }
    }
    func endSystemOutgoing(id: UUID) -> Bool {
        guard systemOutgoingID == id else { return false }
        endDirect()
        return true
    }
    func dial(_ input: String) {
        do {
            let number = try SIPAccount.normalizedNumber(input)
            start(Contact(id: number, name: number, role: "Rufnummer", number: number))
        } catch { show(error.localizedDescription) }
    }
    func answer() {
        if let incomingCalls, incomingCalls.busy {
            incomingCalls.requestAnswer()
        } else { answerDirect(completion: { _ in }) }
    }
    private func answerDirect(completion: @escaping (Bool) -> Void) {
        guard let session = call, session.phase == .incoming, !preparingCall, !acceptingCall else { completion(false); return }
        let id = session.id
        operation = id; preparingCall = true
        notice = nil
        diagnostics.record("Annehmen gedrückt; Mikrofonfreigabe wird geprüft.")
        pendingTask = Task { [weak self] in
            guard let self else { completion(false); return }
            let granted = await audio.requestPermission()
            guard !Task.isCancelled, operation == id, call?.id == id, call?.phase == .incoming else { completion(false); return }
            operation = nil; preparingCall = false
            guard granted else { show("Mikrofonzugriff fehlt. Bitte in den iPhone-Einstellungen erlauben."); completion(false); end(); return }
            diagnostics.record("Annahme: Mikrofon freigegeben.")
            do {
                try audio.prepare()
                diagnostics.record("Annahme: Audiositzung vorbereitet; Übergabe an die Telefonie-Engine.")
                acceptingCall = true
                try core.answer(id: id)
                if call?.id == id, call?.phase == .incoming, acceptingCall {
                    answerTimeout?.cancel()
                    answerTimeout = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard !Task.isCancelled, let self, self.call?.id == id, self.acceptingCall else { return }
                        self.diagnostics.record("Annahme: nach 10 Sekunden noch kein Verbindungsereignis der Engine.")
                        self.show("Die Anrufannahme wird noch nicht bestätigt. Bitte die Diagnose prüfen; ICE/TURN kann den Aufbau verzögern. Du kannst den Anruf beenden.")
                    }
                }
                completion(true)
            } catch {
                acceptingCall = false
                answerTimeout?.cancel()
                diagnostics.record("Annahme lokal fehlgeschlagen; Fehlermeldung im Anrufbildschirm.")
                audio.release(); show(error.localizedDescription); completion(false)
            }
        }
    }
    func beginConsultation(_ input: String) {
        guard canTransfer, let original = call else { return }
        do {
            let number = try SIPAccount.normalizedNumber(input)
            consultationTarget = Contact(id: number, name: number, role: "Rückfrage", number: number)
            consultationPending = true
            resumeWhenHeld = false
            holdTimeout?.cancel()
            holdTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, consultationPending, call?.id == original.id else { return }
                show("Halten wurde noch nicht bestätigt. Du kannst die Rückfrage abbrechen und zum Gespräch zurückkehren.")
            }
            notice = nil
            if original.isHeld { launchConsultation() }
            else { call?.holdPending = true; try core.setHeld(true, id: original.id) }
        } catch {
            consultationTarget = nil; consultationPending = false; call?.holdPending = false
            show(error.localizedDescription)
        }
    }
    private func launchConsultation() {
        guard let contact = consultationTarget, call?.isHeld == true else { return }
        consultationTarget = nil; consultationPending = false; holdTimeout?.cancel()
        let id = UUID()
        consultation = CallSession(id: id, original: contact)
        do { try audio.prepare(); try core.invite(number: contact.number, id: id) }
        catch { consultation = nil; resumeOriginal(); show(error.localizedDescription) }
    }
    func returnToOriginal() {
        guard !transferPending else { return }
        resumeWhenHeld = consultationPending && call?.isHeld != true
        holdTimeout?.cancel()
        consultationTarget = nil; consultationPending = false
        if let consult = consultation {
            consultation?.phase = .ending
            do { try core.end(id: consult.id) }
            catch { consultation?.phase = consult.phase; show(error.localizedDescription) }
        } else { resumeOriginal() }
    }
    private func resumeOriginal() {
        guard let original = call, !originalEnded, original.phase == .active, original.isHeld else { return }
        call?.holdPending = true
        do { try audio.prepare(); try core.setMuted(original.isMuted, id: original.id); try core.setHeld(false, id: original.id) }
        catch { call?.holdPending = false; show(error.localizedDescription) }
    }
    func transferDirect(_ number: String) {
        guard canTransfer, let original = call else { return }
        do {
            let target = try SIPAccount.normalizedNumber(number)
            transferPending = true; notice = "Vermittlung wird bestätigt …"
            try core.transfer(id: original.id, number: target)
            watchTransfer(original.id)
        } catch { transferPending = false; show(error.localizedDescription) }
    }
    func completeConsultation() {
        guard let original = call, original.isHeld, let consult = consultation,
              consult.phase == .active, !consult.isHeld, !consult.isRemoteHeld, !transferPending else { return }
        do {
            transferPending = true; notice = "Vermittlung wird bestätigt …"
            try core.transfer(id: original.id, destinationID: consult.id)
            watchTransfer(original.id)
        } catch { transferPending = false; show(error.localizedDescription) }
    }
    private func watchTransfer(_ id: UUID) {
        transferTimeout?.cancel()
        transferTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self, call?.id == id, transferPending else { return }
            show("Die Anlage hat die Vermittlung noch nicht bestätigt. Du kannst die Gespräche beenden; eine erneute Vermittlung ist währenddessen gesperrt.")
        }
    }
    private func receiveTransfer(_ id: UUID, state: TransferState) {
        guard call?.id == id, transferPending else { return }
        switch state {
        case .progressing: break
        case .failed(let code):
            transferTimeout?.cancel(); transferPending = false
            show("Vermittlung fehlgeschlagen (\(code)). Das Gespräch bleibt verfügbar.")
        case .succeeded:
            transferTimeout?.cancel()
            show("Vermittlung von der Gegenstelle bestätigt.")
            endDirect()
        }
    }
    private func receiveConsultation(_ event: SIPCallEvent) {
        guard consultation?.id == event.id else { return }
        if consultation?.phase == .ending {
            switch event.state { case .ended, .failed: break; default: return }
        }
        switch event.state {
        case .active:
            consultation?.phase = .active; consultation?.isHeld = false; consultation?.isRemoteHeld = false; consultation?.holdPending = false
            if consultation?.connectedAt == nil { consultation?.connectedAt = Date() }
        case .connecting: if consultation?.phase != .ending { consultation?.phase = .connecting }
        case .ringing: if consultation?.phase != .ending { consultation?.phase = .ringing }
        case .held: consultation?.isHeld = true; consultation?.holdPending = false
        case .remoteHeld: consultation?.isRemoteHeld = true
        case .holding, .resuming: consultation?.holdPending = true
        case .ended, .failed:
            if let consultation { archive(consultation, failed: { if case .failed = event.state { return true }; return false }()) }
            consultation = nil
            if originalEnded { finish(failed: false) }
            else if !transferPending && call?.phase != .ending { resumeOriginal() }
            if case .failed = event.state { show("Rückfrage fehlgeschlagen. Das ursprüngliche Gespräch wird fortgesetzt.") }
        case .incoming: break
        }
    }

    func end() {
        if consultation != nil { endDirect() }
        else if systemOutgoingStarted, let id = systemOutgoingID, let systemControls { systemControls.requestEnd(id: id) }
        else if let incomingCalls, incomingCalls.busy { incomingCalls.requestEnd() }
        else { endDirect() }
    }
    private func endDirect() {
        pendingTask?.cancel(); operation = nil; preparingCall = false
        answerTimeout?.cancel(); acceptingCall = false
        consultationTarget = nil; consultationPending = false
        guard let session = call else { return }
        if systemOutgoingID == session.id, !systemOutgoingStarted {
            finish(failed: false)
            return
        }
        // Mark the original first: synchronous consultation End must never resume it.
        call?.phase = .ending
        if let consult = consultation, consult.phase != .ending {
            consultation?.phase = .ending
            do { try core.end(id: consult.id) }
            catch { consultation?.phase = consult.phase; show(error.localizedDescription) }
        }
        guard call?.id == session.id, session.phase != .ending, !originalEnded else { return }
        if session.phase == .incoming { call?.declined = true }
        do {
            try core.end(id: session.id)
            if call?.id == session.id {
                endingTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled, self?.call?.id == session.id else { return }
                    self?.show("Beenden wird noch bestätigt. Bitte Netzwerk prüfen.")
                }
            }
        } catch { call?.phase = session.phase; show(error.localizedDescription) }
    }
    func toggleMute() {
        guard let session = controlledCall, session.phase == .active else { return }
        if consultation == nil, let id = nativeCallID, let systemControls { systemControls.requestMute(id: id, muted: !session.isMuted); return }
        if let incomingCalls, incomingCalls.owns(session.id) { incomingCalls.requestMute(!session.isMuted); return }
        do {
            try core.setMuted(!session.isMuted, id: session.id)
            if consultation?.id == session.id { consultation?.isMuted = !session.isMuted }
            else { call?.isMuted = !session.isMuted }
        }
        catch { show(error.localizedDescription) }
    }
    func toggleHold() {
        guard consultation == nil, !consultationPending, !transferPending else { return }
        guard let session = call, session.phase == .active, !session.holdPending, !session.isRemoteHeld else { return }
        if let id = nativeCallID, let systemControls { systemControls.requestHold(id: id, held: !session.isHeld); return }
        call?.holdPending = true
        do {
            if session.isHeld { try audio.prepare() }
            try core.setHeld(!session.isHeld, id: session.id)
        }
        catch { call?.holdPending = false; show(error.localizedDescription) }
    }
    func sendTone(_ digit: String) {
        guard let session = controlledCall, session.phase == .active, !session.isHeld, !session.isRemoteHeld,
              digit.count == 1, "0123456789*#".contains(digit) else { return }
        if consultation == nil, let id = nativeCallID, let systemControls { systemControls.requestTones(id: id, digits: digit); return }
        do {
            try core.sendDTMF(digit, id: session.id)
            if consultation?.id == session.id { consultation?.tones = String((session.tones + digit).suffix(64)) }
            else { call?.tones = String((session.tones + digit).suffix(64)) }
        }
        catch { show(error.localizedDescription) }
    }
    func setSystemHeld(id: UUID, held: Bool, completion: @escaping (Bool) -> Void) {
        guard nativeCallID == id, consultation == nil, !consultationPending, !transferPending,
              let session = call, session.phase == .active, !session.holdPending,
              !session.isRemoteHeld, systemHold == nil else { completion(false); return }
        guard session.isHeld != held else { completion(true); return }
        systemHold = (id, held, completion)
        call?.holdPending = true
        systemHoldTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, systemHold?.id == id else { return }
            completeSystemHold(false)
            show("Halten/Fortsetzen wurde von der Telefonanlage nicht bestätigt.")
        }
        do {
            if !held { try audio.prepare() }
            try core.setHeld(held, id: session.id)
        } catch { completeSystemHold(false); show(error.localizedDescription) }
    }
    private func completeSystemHold(_ success: Bool) {
        guard let pending = systemHold else { return }
        systemHold = nil; systemHoldTimeout?.cancel(); systemHoldTimeout = nil
        call?.holdPending = false
        pending.done(success)
    }
    func cancelSystemHold(id: UUID) {
        if systemHold?.id == id { completeSystemHold(false) }
    }
    func sendSystemTones(id: UUID, digits: String) -> Bool {
        guard nativeCallID == id, consultation == nil, let session = call,
              session.phase == .active, !session.isHeld, !session.isRemoteHeld, !session.holdPending,
              !digits.isEmpty, digits.count <= 32,
              digits.allSatisfy({ "0123456789*#".contains($0) }) else { return false }
        do {
            for digit in digits {
                try core.sendDTMF(String(digit), id: session.id)
                call?.tones = String(((call?.tones ?? "") + String(digit)).suffix(64))
            }
            return true
        } catch { show(error.localizedDescription); return false }
    }
    func setAudio(_ id: String) {
        guard id != selectedAudioID else { return }
        do { try core.selectAudioDevice(id: id) } catch { show(error.localizedDescription) }
    }
    func refreshAudioDevices() { core.refreshAudioDevices() }
    func reloadAudioDevices() { core.reloadAudioDevices() }
    func microphoneLevel() -> Float? {
        guard let call = controlledCall, call.phase == .active,
              !call.isMuted, !call.isHeld else { return nil }
        return core.microphoneLevel(id: call.id)
    }
    func callAudioLevels() -> CallAudioLevels {
        guard let call = controlledCall, call.phase == .active,
              !call.isHeld, !call.isRemoteHeld, !call.holdPending else {
            return CallAudioLevels(microphone: nil, playback: nil)
        }
        var levels = core.callAudioLevels(id: call.id)
        if call.isMuted { levels.microphone = nil }
        return levels
    }
    func interrupted(_ began: Bool) {
        guard call != nil else { return }
        diagnostics.record(began ? "Audio unterbrochen" : "Audio-Unterbrechung beendet")
        if began, !systemAudioOwned {
            if let session = call, session.phase == .active, !session.isHeld, !session.holdPending { toggleHold() }
            show("Audio wurde vom System unterbrochen. Danach das Gespräch manuell fortsetzen.")
        }
    }
    func show(_ message: String) { notice = message }
    func deleteRecents(ids: Set<UUID>) {
        if cloudHistoryManaged { onHistoryDelete?(ids); return }
        let remaining = recents.filter { !ids.contains($0.id) }
        guard remaining.count != recents.count else { return }
        do {
            try history?.save(remaining)
            recents = remaining
        } catch {
            notice = "Anrufliste konnte nicht gelöscht werden. Bitte erneut versuchen."
        }
    }

    func clearNotice() { notice = nil }

    private func receive(_ event: SIPEvent) {
        switch event {
        case .operationError(let message), .engineStopped(let message): show(message); diagnostics.record(message)
        case .transfer(let id, let state): receiveTransfer(id, state: state)
        case .sipPacket(let packet): diagnostics.recordSIP(packet)
        case .registrationTrace(let message): diagnostics.recordRegistration(message)
        case .callTrace(let message): diagnostics.record(message)
        case .registration(let status):
            registration = status
            diagnostics.record(status.label)
            diagnostics.recordRegistration("Status: \(status.label)")
        case .audioDevices(let devices, let selectedID):
            if audioDevices != devices { audioDevices = devices }
            if self.selectedAudioID != selectedID { self.selectedAudioID = selectedID }
        case .media(let snapshot): diagnostics.media = snapshot
        case .call(let event): receiveCall(event)
        }
    }
    private func receiveCall(_ event: SIPCallEvent, systemRouted: Bool = false) {
        if consultation?.id == event.id { receiveConsultation(event); return }
        if !systemRouted, incomingCalls?.receiveSIP(event) == true { return }

        if case .incoming = event.state {
            // Early media and repeated notifications belong to the same ringing call.
            if call?.id == event.id { return }
            guard call == nil, !doNotDisturb else {
                try? core.end(id: event.id)
                diagnostics.record("Eingehender Anruf abgelehnt: besetzt oder Nicht stören")
                return
            }
            pendingTask?.cancel(); operation = nil; preparingCall = false
            notice = nil
            let contact = Contact(id: event.number, name: event.displayName.isEmpty ? event.number : event.displayName, role: "Eingehend", number: event.number)
            call = CallSession(id: event.id, original: contact, incoming: true, phase: .incoming)
            lookupTask?.cancel()
            lookupTask = Task { [weak self] in
                guard let self, let found = await resolveContact?(event.number), !Task.isCancelled,
                      call?.id == event.id else { return }
                call?.original = Contact(id: found.id, name: found.name, role: found.role, number: event.number)
            }
            diagnostics.record("Eingehender Anruf")
            return
        }
        guard call?.id == event.id else { return }
        // End can race with Connected/StreamsRunning; an ending UI must remain ending.
        if call?.phase == .ending {
            switch event.state { case .ended, .failed: break; default: return }
        }
        switch event.state {
        case .incoming: break
        case .connecting: call?.phase = .connecting
        case .ringing: call?.phase = .ringing
        case .active:
            answerTimeout?.cancel()
            if acceptingCall { notice = nil }
            acceptingCall = false
            call?.phase = .active; call?.isHeld = false; call?.isRemoteHeld = false; call?.holdPending = false
            if let pending = systemHold { completeSystemHold(!pending.held) }
            if call?.connectedAt == nil {
                call?.connectedAt = Date(); diagnostics.record("Gespräch verbunden")
                if systemOutgoingID == event.id { outgoingReporter?.outgoingConnected(id: event.id) }
            }
        case .holding, .resuming: call?.holdPending = true
        case .held:
            call?.isHeld = true; call?.holdPending = false; diagnostics.record("Gespräch gehalten")
            if let pending = systemHold { completeSystemHold(pending.held) }
            if consultationPending { launchConsultation() }
            else if resumeWhenHeld { resumeWhenHeld = false; resumeOriginal() }
        case .remoteHeld:
            call?.isRemoteHeld = true; call?.holdPending = false
            completeSystemHold(false)
        case .ended: finish(failed: false)
        case .failed(let code):
            finish(failed: true)
            show(code == 0 ? "Anruf fehlgeschlagen. Bitte Verbindung und SIP-Konfiguration prüfen." : "Anruf fehlgeschlagen (SIP \(code)).")
        }
    }
    private func finish(failed: Bool) {
        guard let session = call else { return }
        completeSystemHold(false)
        if let consult = consultation {
            originalFailed = originalFailed || failed
            originalEnded = true; call?.phase = .ending
            do { try core.end(id: consult.id) } catch { show("Rückfrage noch aktiv. Bitte erneut auflegen.") }
            return
        }
        if systemOutgoingID == session.id {
            systemStartTimeout?.cancel()
            systemOutgoingID = nil; systemOutgoingStarted = false
            let done = systemStartCompletion; systemStartCompletion = nil; done?(false)
            outgoingReporter?.endOutgoing(id: session.id, failed: failed)
        }
        originalEnded = false; transferPending = false; consultationPending = false; consultationTarget = nil
        resumeWhenHeld = false; holdTimeout?.cancel()
        transferTimeout?.cancel()
        lookupTask?.cancel()
        pendingTask?.cancel(); endingTimeout?.cancel(); answerTimeout?.cancel()
        operation = nil; preparingCall = false; acceptingCall = false
        archive(session, failed: failed || originalFailed)
        originalFailed = false
        call = nil; diagnostics.media = nil; audio.release()
        updateSystemAudioOwnership()
        diagnostics.record(failed ? "Gespräch fehlgeschlagen" : "Gespräch beendet")
    }
    private func archive(_ session: CallSession, failed: Bool) {
        if cloudHistoryManaged { onHistoryRefresh?(); return }
        let missed = session.incoming && session.connectedAt == nil && !session.declined
        let detail = failed ? "Fehlgeschlagen" : session.declined ? "Abgelehnt" : missed ? "Verpasst" : session.incoming ? "Eingehend" : session.connectedAt == nil ? "Abgebrochen" : "Ausgehend"
        recents.insert(RecentCall(contact: session.original, date: session.startedAt, detail: detail, missed: missed, incoming: session.incoming, duration: session.connectedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0), at: 0)
        if recents.count > 100 { recents.removeLast() }
        do { try history?.save(recents) }
        catch {
            notice = "Anrufliste konnte nicht gespeichert werden."
            diagnostics.record("Lokale Anrufliste konnte nicht gespeichert werden")
        }
    }

}

extension CallManager {
    func setCloudHistoryContext(_ enabled: Bool) {
        if enabled || cloudHistoryManaged { recents = [] }
        cloudHistoryManaged = enabled
        historyStatus = enabled ? "fonoo-Konto · Anrufliste wird geladen" : ""
    }
    func applyCloudHistory(_ entries: [RecentCall], status: String) {
        guard cloudHistoryManaged else { return }
        recents = entries; historyStatus = status
    }
    func setCloudHistoryStatus(_ value: String) { if cloudHistoryManaged { historyStatus = value } }
}
