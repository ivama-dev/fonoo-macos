import AVFoundation
import Intents
import Combine
import Foundation

/// UI facade keeps contacts/settings separate from the SIP call state machine.
@MainActor
final class PhoneStore: ObservableObject {
    @Published private(set) var sipTracing = false
    var supportsSIPTracing: Bool { connection?.supportsSIPTracing == true }
    func setSIPTracing(_ enabled: Bool) {
        sipTracing = enabled && supportsSIPTracing
        manager.setSIPTracing(sipTracing)
    }
    @Published private(set) var favoriteLibrary: FavoriteLibrary = .empty
    @Published private(set) var favoriteSyncStatus = ""
    @Published private(set) var favoriteSyncEnabled = false
    var canSynchronizeFavorites: Bool { favoriteOwner != nil }
    var canImportLegacyFavorites: Bool {
        favoriteOwner != nil && favoritesDefaults.string(forKey: "fonoo.favorites.legacyOwner") == ""
            && FileManager.default.fileExists(atPath: legacyFavoritesStore.url.path)
    }
    @Published private(set) var favoriteConflict = false
    @Published private(set) var favoriteEditingError: String?
    var favorites: [Contact] { favoriteLibrary.contacts }
    var favoriteGroups: [FavoriteGroup] { favoriteLibrary.groups }
    var onFavoritesChanged: (() -> Void)?
    var onFavoritesRefresh: (() -> Void)?
    private var favoriteState = FavoriteLibraryState(owner: "local")
    private var favoriteOwner: String?
    private var favoriteStore: FavoriteLibraryStore? = .local
    private var favoritePersistence: FavoriteLibraryStore = .local
    private var legacyFavoritesStore: FavoritesStore = .local
    private var favoritesDefaults: UserDefaults = .standard
    @Published var doNotDisturb = false { didSet { manager.doNotDisturb = doNotDisturb; onPushPreferenceChanged() } }
    @Published private(set) var account = SIPAccount()
    @Published private(set) var hasSavedPassword = false
    @Published private(set) var hasSavedTURNPassword = false
    @Published private(set) var presentedSheets: Set<String> = []
    let manager: CallManager
    let diagnostics: Diagnostics
    let connection: SIPConnectionCoordinator?
    var sdkVersion: String { connection?.sdkVersion ?? "Vorschau" }
    var connectionFailure: String? { connection?.failure }
    var connectionRestarting: Bool { connection?.restarting == true }
    var canRestartConnection: Bool { connection?.canRestart == true }
    func cancelCloudRegistrationIntent() { connection?.cancelRegistrationIntent() }
    /// Re-provision after an explicit account reconnect; do not replay the old profile.
    func prepareExplicitCloudReconnect() async throws {
        guard let connection, connection.failure != nil else { return }
        connection.cancelRegistrationIntent()
        try await connection.restart()
        diagnostics.recordRegistration("— Telefonieverbindung ausdrücklich neu gestartet —")
    }
    func restartConnection() async {
        guard let connection else { return }
        do {
            try await connection.restart()
            diagnostics.media = nil
            manager.refreshAudioDevices()
        } catch { manager.show(error.localizedDescription) }
    }
    #if os(iOS)
    private var systemCalls: SystemIncomingCalls?
    #endif
    var onPushPreferenceChanged: () -> Void = {}
    var resolveTeamContact: (String) -> Contact? = { _ in nil }
    private let cloudPushKey = "fonoo.cloud.push.binding.v2"
    private var wakeTask: Task<Void, Never>?
    private var wakePush: IncomingPush?
    var cloudPushBinding: [String: String]? { UserDefaults.standard.dictionary(forKey: cloudPushKey) as? [String: String] }
    var cloudAutomaticRegistration: Bool { recovery.enabled }
    var cloudPushActive: Bool { cloudPushBinding?["endpoint_id"] == account.username && recovery.enabled }
    func enableCloudPush(tenantID: String, deviceID: String, endpointID: String) throws {
        guard account.username == endpointID else { throw PhoneError.message("Cloud-Profil wurde gewechselt.") }
        try accountStore.allowCloudBackgroundAccess()
        UserDefaults.standard.set(["tenant_id": tenantID, "device_id": deviceID, "endpoint_id": endpointID], forKey: cloudPushKey)
    }
    func disableCloudPush() {
        UserDefaults.standard.removeObject(forKey: cloudPushKey)
        #if os(iOS)
        systemCalls?.coordinator.suppressWaitingCall()
        #endif
    }
    var onVoIPTokenChanged: (Data?) -> Void = { _ in }
    private let accountStore = AccountStore()
    private let audio: AudioManager
    private let network = NetworkMonitor()
    private let recovery = ForegroundRegistrationRecovery()
    private let autoRegistrationKey = "fonoo.sip.automaticallyRegisters"
    private var observations: Set<AnyCancellable> = []

    #if DEBUG
    /// Isolated UI fixture: no saved account, registration, history or contacts.
    init(previewCore: SIPCore) {
        favoritePersistence = FavoriteLibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fonoo-preview-favorites-" + UUID().uuidString, isDirectory: true))
        favoriteStore = favoritePersistence
        favoriteState = FavoriteLibraryState(owner: "preview")
        connection = nil
        diagnostics = Diagnostics()
        audio = AudioManager()
        manager = CallManager(core: previewCore, audio: audio, diagnostics: diagnostics)
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    #endif

    init() {
        diagnostics = Diagnostics()
        audio = AudioManager()
        // Construct the single supported telephony SDK.
        let connection = SIPConnectionCoordinator { LinphoneSIPCore() }
        self.connection = connection
        manager = CallManager(core: connection, audio: audio, diagnostics: diagnostics, history: .local)
        connection.isBusy = { [weak self] in
            guard let self else { return true }
            return manager.busy || manager.consultation != nil || manager.transferPending || manager.consultationPending || manager.acceptingCall
        }
        connection.onChange = { [weak self] in self?.objectWillChange.send() }
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        audio.onRouteChange = { [weak self] in self?.manager.refreshAudioDevices() }
        audio.onInterruption = { [weak self] in self?.manager.interrupted($0) }
        recovery.enabled = UserDefaults.standard.object(forKey: autoRegistrationKey) as? Bool ?? true
        recovery.isBusy = { [weak self] in self?.busy ?? true }
        recovery.restore = { [weak self] in self?.restoreRegistrationOnOpen() }
        network.onChange = { [weak self] available, label in
            guard let self else { return }
            self.manager.networkChanged(available: available, label: label)
            self.recovery.networkChanged(available: available)
        }
        do {
            if let (saved, secret, turnSecret) = try accountStore.load(), isSelectedCloudAccount(saved) {
                account = saved
                hasSavedPassword = !secret.isEmpty
                hasSavedTURNPassword = !turnSecret.isEmpty
            }
        }
        catch { manager.show(error.localizedDescription) }
        captureLegacyFavoritesOwner()
        selectFavoriteOwner(nil)
        manager.resolveContact = { [weak self] number in
            guard let self else { return nil }
            if let match = self.resolveTeamContact(number) { return match }
            let directory = ContactsDirectory()
            await directory.refresh() // Uses existing permission only; never prompts during a call.
            if let match = DeviceContact.resolvedContact(in: directory.contacts, number: number) { return match }
            guard !Task.isCancelled else { return nil }
            return nil
        }
        do { try connection.start(); diagnostics.record("Liblinphone · \(sdkVersion)") }
        catch { manager.show(error.localizedDescription) }
        #if os(macOS)
        diagnostics.record("macOS: native fonu-Anrufansicht; erreichbar, solange die App läuft und der Mac wach ist.")
        #elseif targetEnvironment(simulator)
        // The simulator has no system in-call UI host. Its callservicesd ends
        // native outgoing calls immediately (disconnect reason 55). Keep SIP
        // and audio under the foreground app's control for simulator testing.
        diagnostics.record("Simulator: fonu-Anrufansicht aktiv; native Anrufe und VoIP-Push nur auf echten Geräten.")
        #else
        prepareSystemCalls()
        #endif
    }

    #if os(iOS)
    private func prepareSystemCalls() {
        let service = SystemIncomingCalls()
        systemCalls = service
        manager.outgoingReporter = service
        manager.systemControls = service
        service.onHold = { [weak self] id, held, done in
            guard let self else { done(false); return }
            self.manager.setSystemHeld(id: id, held: held, completion: done)
        }
        service.onTones = { [weak self] in self?.manager.sendSystemTones(id: $0, digits: $1) ?? false }
        service.onHoldTimeout = { [weak self] in self?.manager.cancelSystemHold(id: $0) }
        service.onOutgoingStart = { [weak self] in self?.manager.beginSystemOutgoing(id: $0) ?? false }
        service.onOutgoingEnd = { [weak self] in self?.manager.endSystemOutgoing(id: $0) ?? false }
        diagnostics.record("Native Anrufsteuerung: \(service.integrationName)")
        service.onTokenChanged = { [weak self] token in
            self?.diagnostics.record(token == nil ? "VoIP-Gerätetoken ungültig geworden." : "VoIP-Gerätetoken erhalten; Anrufweg noch nicht aktiv.")
            self?.onVoIPTokenChanged(token)
        }
        let coordinator = service.coordinator!
        manager.attachIncomingCalls(coordinator)
        coordinator.handlesSIP = { [weak self] in self?.cloudPushActive == true }
        coordinator.authorizePush = { [weak self] push in
            guard let self, let cloud = push.cloud, let binding = self.cloudPushBinding else { return false }
            return binding["tenant_id"] == cloud.tenantID && binding["device_id"] == cloud.deviceID
                && binding["endpoint_id"] == cloud.endpointID && self.account.username == cloud.endpointID
        }
        coordinator.pushStarted = { [weak self] push in self?.startCloudWake(push) }
        coordinator.callFinished = { [weak self] callID in self?.finishCloudWake(callID) }
        coordinator.canReceive = { [weak self] in
            guard let self else { return false }
            return self.cloudPushActive && !self.connectionRestarting && self.manager.canReceiveSystemCall
        }
        coordinator.restoreConnection = { [weak self] in
            guard let self, self.recovery.enabled,
                  let (account, password, turnPassword) = try self.accountStore.load(), !password.isEmpty, self.isSelectedCloudAccount(account) else {
                throw PhoneError.message("Kein angemeldetes SIP-Konto verfügbar.")
            }
            self.recovery.manualRegistrationStarted()
            // Also covers Cloud profiles saved by build 5 before this field existed.
            // This hook is only reached for an authenticated Cloud-push binding.
            var cloudAccount = account
            cloudAccount.usesTLSClientCertificate = false
            try self.manager.restoreIncomingConnection(account: cloudAccount, password: password, turnPassword: turnPassword)
        }
        service.onAudioActivation = { [weak self] in self?.manager.systemAudioActivated($0) }
        service.onMute = { [weak self] in self?.manager.setSystemMuted($0) ?? false }
    }
    private func wakeRequest(_ push: IncomingPush, action: String) async throws -> String {
        guard let cloud = push.cloud else { throw URLError(.badURL) }
        var request = URLRequest(url: URL(string: "https://push.dev.fonoo.app/v1/cloud/push/wake")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["call_id": push.callID, "wake_token": cloud.token, "action": action])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct State: Decodable { let state: String }
        return try JSONDecoder().decode(State.self, from: data).state
    }
    private func startCloudWake(_ push: IncomingPush) {
        wakeTask?.cancel()
        wakePush = push
        wakeTask = Task { [weak self] in
            guard let self else { return }
            var acknowledged = false
            while !Task.isCancelled && Date() < push.expiresAt {
                guard self.systemCalls?.coordinator.systemID == push.uuid else { return }
                // The fresh register initiated by this push must succeed before Asterisk dials.
                let action = !acknowledged && self.registration == .registered ? "ready" : "status"
                do {
                    let state = try await self.wakeRequest(push, action: action)
                    if action == "ready" { acknowledged = true }
                    if ["ended", "declined", "failed", "expired"].contains(state) {
                        self.systemCalls?.coordinator.remoteEnded(callID: push.callID)
                        return
                    }
                    // SIP now owns cancellation and the active conversation.
                    if self.systemCalls?.coordinator.sipID != nil { return }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
    private func finishCloudWake(_ callID: String) {
        guard let push = wakePush, push.callID == callID else { return }
        wakeTask?.cancel(); wakeTask = nil; wakePush = nil
        Task { [weak self] in _ = try? await self?.wakeRequest(push, action: "decline") }
    }
    private var nativeCallRequest: UUID?
    private var handledIntentRequests: Set<String> = []
    func startCarPlayCall(_ contact: Contact) async throws {
        try await startNativeCall(contact)
    }
    private func startNativeCall(_ contact: Contact) async throws {
        guard cloudPushActive, nativeCallRequest == nil, !busy else {
            throw PhoneError.message("Bitte eine Cloud-Nebenstelle am iPhone aktivieren oder das laufende Gespräch beenden.")
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw PhoneError.message("Bitte fonu am iPhone öffnen und den Mikrofonzugriff erlauben.")
        }
        let request = UUID(), endpoint = account.username
        nativeCallRequest = request
        defer { if nativeCallRequest == request { nativeCallRequest = nil } }
        if registration != .registered {
            recovery.manualRegistrationStarted()
            restoreRegistrationOnOpen()
            for _ in 0..<40 {
                if registration == .registered || busy || !cloudPushActive { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard cloudPushActive, account.username == endpoint, !busy, registration == .registered else {
            throw PhoneError.message("fonu ist gerade nicht verbunden. Bitte später erneut versuchen.")
        }
        let started = await withCheckedContinuation { continuation in
            manager.startSystemCall(contact) { continuation.resume(returning: $0) }
        }
        guard started else { throw PhoneError.message("Der Anruf konnte nicht gestartet werden.") }
    }
    @discardableResult
    func continueCallActivity(_ activity: NSUserActivity) -> Bool {
        guard let request = SystemCallActivity.request(from: activity) else { return false }
        continueCall(number: request.contact.number, name: request.contact.name, request: request.id)
        return true
    }
    private func continueCall(number: String, name: String, request: String) {
        guard !handledIntentRequests.contains(request), let normalized = try? SIPAccount.normalizedNumber(number) else { return }
        if handledIntentRequests.count >= 100 { handledIntentRequests.removeAll() }
        handledIntentRequests.insert(request)
        Task { [weak self] in
            guard let self else { return }
            do { try await startNativeCall(Contact(id: normalized, name: name, role: "Anrufliste", number: normalized)) }
            catch { manager.show(error.localizedDescription) }
        }
    }
    func startVoIPTokenRegistration() { systemCalls?.start(enrollmentReady: true) }
    #else
    func startVoIPTokenRegistration() {}
    #endif
    var call: CallSession? { manager.call }
    var notice: String? { manager.notice }
    var recents: [RecentCall] { manager.recents }
    var registration: RegistrationStatus { manager.registration }
    var busy: Bool { manager.busy }
    var audioDevices: [AudioDeviceOption] { manager.audioDevices }
    var audioName: String { manager.audioName }
    var selectedAudioID: String? { manager.selectedAudioID }
    var networkLabel: String { manager.networkLabel }
    func sheetOpened(_ id: String) { presentedSheets.insert(id) }
    func sheetClosed(_ id: String) { presentedSheets.remove(id) }
    func start(_ contact: Contact) { manager.start(contact) }
    func dial(_ input: String) { manager.dial(input) }
    func end() { manager.end() }
    func answer() { manager.answer() }
    func toggleMute() { manager.toggleMute() }
    func toggleHold() { manager.toggleHold() }
    func setAudio(_ id: String) { manager.setAudio(id) }
    func sendTone(_ digit: String) { manager.sendTone(digit) }
    func becameActive() {
        manager.refreshAudioDevices()
        recovery.becameActive()
    }
    func becameInactive(background: Bool) { recovery.becameInactive(background: background) }
    func clearNotice() { manager.clearNotice() }

    private func setAutomaticRegistration(_ enabled: Bool) {
        recovery.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoRegistrationKey)
    }

    private func isSelectedCloudAccount(_ candidate: SIPAccount) -> Bool {
        let selected = UserDefaults.standard.dictionary(forKey: "fonoo.cloud.selected.v2") as? [String: String]
        return candidate.isSelectedCloudProfile(endpointID: selected?["endpoint_id"])
    }

    private func restoreRegistrationOnOpen() {
        do {
            guard let (saved, secret, turnSecret) = try accountStore.load(), !secret.isEmpty, isSelectedCloudAccount(saved) else {
                hasSavedPassword = false
                return
            }
            account = saved
            hasSavedPassword = true
            hasSavedTURNPassword = !turnSecret.isEmpty
            diagnostics.recordRegistration("— App geöffnet: SIP-Anmeldung mit gespeicherten Zugangsdaten wird neu aufgebaut —")
            try manager.register(account: saved, password: secret, turnPassword: turnSecret)
        } catch {
            diagnostics.recordRegistration("FEHLER: Automatische Anmeldung beim Öffnen fehlgeschlagen. Konto und vorherigen Schritt prüfen.")
            manager.show(error.localizedDescription)
        }
    }

    func saveAndRegister(_ configuration: SIPAccount, password: String, turnPassword: String) throws {
        guard !busy else { throw PhoneError.message("Bitte zuerst das Gespräch beenden.") }
        let checked = try configuration.validated()
        guard checked.transport == .tls, checked.mediaEncryption == .srtp,
              !checked.usesTLSClientCertificate else {
            throw PhoneError.message("Bitte deine fonu-Cloud-Nebenstelle im fonu-Konto einrichten.")
        }
        // Blank means reuse the saved password only for the exact same account identity.
        let storedAccount = try accountStore.load()
        var secret = password
        if secret.isEmpty, let (saved, stored, _) = storedAccount,
           saved.server == checked.server, saved.effectiveDomain == checked.effectiveDomain,
           saved.username == checked.username, saved.effectiveAuthName == checked.effectiveAuthName { secret = stored }
        guard !secret.isEmpty else { throw PhoneError.message("Bitte das SIP-Passwort eingeben.") }
        var turnSecret = turnPassword
        if turnSecret.isEmpty, let (saved, _, storedTURN) = storedAccount,
           checked.nat.canReuseTURNPassword(from: saved.nat) { turnSecret = storedTURN }
        guard !checked.nat.usesTURN || !turnSecret.isEmpty else {
            throw PhoneError.message("Bitte das TURN-Passwort eingeben. Bei geändertem Server, Port, Transport oder Benutzer ist es erneut erforderlich.")
        }
        disableCloudPush()
        try accountStore.save(account: checked, password: secret, turnPassword: turnSecret)
        hasSavedTURNPassword = !turnSecret.isEmpty
        account = checked
        hasSavedPassword = true
        setAutomaticRegistration(true)
        recovery.manualRegistrationStarted()
        try manager.register(account: checked, password: secret, turnPassword: turnSecret)
    }
    func reregisterSavedAccount() throws {
        guard !busy else { throw PhoneError.message("Bitte zuerst das Gespräch beenden.") }
        guard registration != .registering && registration != .unregistering else {
            throw PhoneError.message("Bitte den laufenden Registrierungsvorgang abwarten.")
        }
        guard let (saved, secret, turnSecret) = try accountStore.load(), !secret.isEmpty, isSelectedCloudAccount(saved) else {
            hasSavedPassword = false
            throw PhoneError.message("Keine gespeicherten Zugangsdaten vorhanden. Bitte das SIP-Konto zuerst speichern.")
        }
        account = saved
        hasSavedPassword = true
        hasSavedTURNPassword = !turnSecret.isEmpty
        diagnostics.recordRegistration("— Erneute Registrierung mit Zugangsdaten aus dem Schlüsselbund —")
        setAutomaticRegistration(true)
        recovery.manualRegistrationStarted()
        try manager.register(account: saved, password: secret, turnPassword: turnSecret)
    }
    func unregister() throws {
        try manager.unregister()
        setAutomaticRegistration(false)
        onPushPreferenceChanged()
    }
    func forgetAccount() throws {
        try unregister()
        try accountStore.delete()
        account = SIPAccount()
        hasSavedPassword = false
        hasSavedTURNPassword = false
    }
    /// Capture the pre-upgrade account BEFORE a new login can replace its device selection.
    private func captureLegacyFavoritesOwner() {
        guard favoritesDefaults.object(forKey: "fonoo.favorites.legacyOwner") == nil else { return }
        let previous = (favoritesDefaults.dictionary(forKey: "fonoo.cloud.selected.v2") as? [String: String])?["account_id"]
        favoritesDefaults.set(previous ?? "", forKey: "fonoo.favorites.legacyOwner")
    }
    /// Only a confirmed account may adopt the legacy device list once. Its file is retained.
    func selectFavoriteOwner(_ owner: String?, importLegacy: Bool = false) {
        guard favoriteOwner != owner || favoriteLibrary == .empty else { return }
        favoriteOwner = owner; favoriteStore = favoritePersistence
        favoriteEditingError = nil
        // Personal favorites are always an account feature, regardless of a
        // previous per-device opt-out preference from the pilot version.
        favoriteSyncEnabled = owner != nil
        favoriteSyncStatus = favoriteSyncEnabled ? "Favoriten werden synchronisiert …" : "Auf diesem Gerät gespeichert"
        do {
            let key = owner ?? "local"
            var state = try favoriteStore!.load(owner: key) ?? FavoriteLibraryState(owner: key)
            let claimed = favoritesDefaults.string(forKey: "fonoo.favorites.legacyOwner")
            if state.library.contacts.isEmpty && state.library.groups.count == 1 && state.revision == nil,
               (owner == nil && claimed == nil || owner != nil && importLegacy && claimed == owner) {
                let legacy = try legacyFavoritesStore.load()
                var ids = Set<String>()
                state.library.groups[0].contacts = legacy.filter { ids.insert($0.id).inserted }
                state.dirty = owner != nil && !state.library.contacts.isEmpty
                try favoriteStore!.save(state)
                if let owner, importLegacy { favoritesDefaults.set(owner, forKey: "fonoo.favorites.legacyOwner") }
            }
            _ = try state.library.checked(); publishFavorites(state)
        } catch {
            favoriteStore = nil
            publishFavorites(FavoriteLibraryState(owner: owner ?? "local"))
            favoriteSyncStatus = FavoriteError.unavailable.localizedDescription
            manager.show(FavoriteError.unavailable.localizedDescription)
        }
    }
    func clearFavoriteContext() {
        favoriteOwner = nil; favoriteStore = nil; favoriteSyncEnabled = false; favoriteEditingError = nil
        publishFavorites(FavoriteLibraryState(owner: "signed-out")); favoriteSyncStatus = ""
    }
    private func publishFavorites(_ state: FavoriteLibraryState) {
        favoriteState = state; favoriteLibrary = state.library; favoriteConflict = state.conflict != nil
    }
    private func saveFavorites(_ state: FavoriteLibraryState) throws {
        guard let favoriteStore else { throw FavoriteError.unavailable }
        try favoriteStore.save(state); publishFavorites(state)
    }
    private func editFavorites(_ change: (inout FavoriteLibrary) throws -> Void) {
        favoriteEditingError = nil
        do {
            var state = favoriteState
            let before = state.library
            try change(&state.library); _ = try state.library.checked()
            guard state.library != favoriteLibrary else { return }
            let contacts = Set(state.library.contacts.map(\.id)), groups = Set(state.library.groups.map(\.id))
            state.deletedContactIDs = (state.deletedContactIDs ?? []).union(Set(before.contacts.map(\.id)).subtracting(contacts)).subtracting(contacts)
            state.deletedGroupIDs = (state.deletedGroupIDs ?? []).union(Set(before.groups.map(\.id)).subtracting(groups)).subtracting(groups)
            state.dirty = true
            try saveFavorites(state)
            favoriteSyncStatus = !favoriteSyncEnabled ? "Auf diesem Gerät gespeichert" : "Lokal gespeichert · Synchronisierung ausstehend"
            onFavoritesChanged?()
        } catch { favoriteEditingError = error.localizedDescription; manager.show(error.localizedDescription) }
    }
    func importLegacyFavorites() {
        guard canImportLegacyFavorites, let owner = favoriteOwner else { return }
        do {
            let legacy = try legacyFavoritesStore.load()
            editFavorites { library in
                var ids = Set(library.contacts.map(\.id))
                let additions = legacy.filter { ids.insert($0.id).inserted }
                library.groups[library.groups.firstIndex(where: \.isGeneral)!].contacts.append(contentsOf: additions)
            }
            if favoriteEditingError == nil {
                favoritesDefaults.set(owner, forKey: "fonoo.favorites.legacyOwner")
                objectWillChange.send()
            }
        } catch { favoriteEditingError = error.localizedDescription; manager.show(error.localizedDescription) }
    }
    func createFavoriteGroup(_ name: String) { editFavorites { try $0.addGroup(name) } }
    func renameFavoriteGroup(_ id: String, name: String) { editFavorites { try $0.renameGroup(id, name: name) } }
    func deleteFavoriteGroup(_ id: String) { editFavorites { try $0.deleteGroup(id) } }
    func moveFavoriteGroups(from offsets: IndexSet, to destination: Int) {
        editFavorites { try $0.moveGroups(from: offsets, to: destination) }
    }
    func moveFavorites(in groupID: String, from offsets: IndexSet, to destination: Int) {
        editFavorites { try $0.moveContacts(in: groupID, from: offsets, to: destination) }
    }
    func assignFavorite(_ contactID: String, to groupID: String) { editFavorites { try $0.assign(contactID, to: groupID) } }
    func toggleFavorite(_ contact: Contact) { editFavorites { $0.toggle(contact) } }
    func setFavoriteSyncStatus(_ status: String, owner: String) {
        guard favoriteOwner == owner, favoriteSyncEnabled else { return }; favoriteSyncStatus = status
    }
    func observeCloudFavorites(_ snapshot: CloudFavoriteSnapshot) throws {
        guard favoriteOwner == snapshot.user_id, favoriteSyncEnabled else { throw CancellationError() }
        var state = favoriteState; try state.observe(snapshot); try saveFavorites(state)
        favoriteSyncStatus = state.conflict != nil ? "Auf einem anderen Gerät geändert. Deine lokalen Änderungen bleiben erhalten."
            : state.dirty ? "Lokal gespeichert · Synchronisierung ausstehend" : "Mit deinem fonu-Konto synchronisiert"
    }
    func favoriteUpload(owner: String) throws -> (revision: Int64, library: FavoriteLibrary)? {
        guard favoriteOwner == owner, favoriteSyncEnabled, favoriteState.dirty, favoriteState.conflict == nil, let revision = favoriteState.revision else { return nil }
        var state = favoriteState; state.attempt = state.library; try saveFavorites(state)
        return (revision, state.library)
    }
    func acknowledgeFavorites(_ snapshot: CloudFavoriteSnapshot, sent: FavoriteLibrary) throws {
        guard favoriteOwner == snapshot.user_id, favoriteSyncEnabled else { throw CancellationError() }
        var state = favoriteState; try state.acknowledged(snapshot, sent: sent); try saveFavorites(state)
        favoriteSyncStatus = state.dirty ? "Lokal gespeichert · Synchronisierung ausstehend" : "Mit deinem fonu-Konto synchronisiert"
        if state.dirty { onFavoritesChanged?() }
    }
    func mergeFavoriteConflict() {
        do {
            var state = favoriteState; try state.mergeConflict(); try saveFavorites(state)
            favoriteSyncStatus = "Zusammengeführt · Synchronisierung ausstehend"; onFavoritesChanged?()
        } catch { manager.show(error.localizedDescription) }
    }
}
