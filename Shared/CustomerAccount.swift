import SwiftUI
import Security
import AVFoundation
import CryptoKit
import Combine
import Contacts

private struct CustomerSummary: Decodable {
    let id: String
    let email: String
    let company: String
    let status: String
    let revision: Int
    let password_configured: Bool?
    let password_managed: Bool?
}

/// Stored only in the device's Keychain, never UserDefaults or an iCloud keychain.
struct RememberedCustomerSession: Codable {
    let token, refresh_token, device_id, user_id, email: String
    let expires_at, device_expires_at: Int
    var pending_request_id: String?
    func validated(deviceID: String, userID: String? = nil) throws -> Self {
        guard device_id == deviceID, UUID(uuidString: device_id) != nil,
              userID == nil || user_id == userID,
              (32...128).contains(token.count), (32...128).contains(refresh_token.count),
              !user_id.isEmpty, !email.isEmpty, expires_at <= device_expires_at else {
            throw PhoneError.message("Ungültige Geräteanmeldung vom Kontodienst.")
        }
        return self
    }
}
private struct CustomerConfiguration: Decodable {
    let revision: Int
    let configuration: Configuration
    struct Configuration: Decodable {
        let server, domain, username, authentication_name, password: String
        let port: Int
        let transport, stun_server, turn_server, turn_username, turn_password, turn_transport: String
        let stun_port, turn_port: Int
        let ice_enabled, turn_enabled, force_turn: Bool
        let media_encryption: String?
        let media_encryption_mandatory: Bool?
        func account() throws -> SIPAccount {
            var a = SIPAccount()
            a.server = server; a.domain = domain; a.username = username
            a.authenticationName = authentication_name; a.port = port
            guard let sipTransport = SIPTransport(rawValue: transport), let turnTransport = SIPTransport(rawValue: turn_transport) else {
                throw PhoneError.message("Die Konfiguration enthält einen unbekannten Transport.")
            }
            a.transport = sipTransport
            if let encryption = media_encryption {
                guard let media = SIPMediaEncryption(rawValue: encryption) else {
                    throw PhoneError.message("Unbekannte Medienverschlüsselung in der Konfiguration.")
                }
                a.mediaEncryption = media
            }
            if media_encryption_mandatory == true && a.mediaEncryption != .srtp {
                throw PhoneError.message("Diese Telefonie-Konfiguration erfordert SRTP.")
            }
            a.nat.iceEnabled = ice_enabled; a.nat.stunServer = stun_server; a.nat.stunPort = stun_port
            a.nat.turnEnabled = turn_enabled; a.nat.turnServer = turn_server; a.nat.turnPort = turn_port
            a.nat.turnUsername = turn_username; a.nat.turnTransport = turnTransport
            a.compatibility.forceTURN = force_turn
            return try a.validated()
        }
    }
}
private struct CloudDeviceConfiguration: Decodable {
    let status, tenant_id, device_id: String
    let schema_version: Int?
    let backend: String?
    let revision: Int?
    let configuration: CustomerConfiguration.Configuration?

    func validated(tenantID: String, deviceID: String) throws -> CustomerConfiguration.Configuration? {
        guard tenant_id == tenantID, device_id == deviceID else {
            throw PhoneError.message("Die Antwort gehört nicht zu deiner Firma oder diesem Gerät.")
        }
        if status == "provisioning" { return nil }
        guard status == "ready", schema_version == 1, backend == "asterisk",
              let revision, revision > 0, let configuration,
              configuration.transport == "TLS", configuration.port == 5061,
              configuration.server == configuration.domain,
              configuration.media_encryption == "SRTP", configuration.media_encryption_mandatory == true else {
            throw PhoneError.message("Die Cloud-Konfiguration konnte nicht sicher übernommen werden.")
        }
        _ = try configuration.account()
        return configuration
    }
}
struct CloudMembership: Decodable, Identifiable {
    let id, name, role: String
    let number: String?
    let trial: Trial
    enum CodingKeys: String, CodingKey { case id, name, role, trial; case number = "extension" }
    struct Trial: Decodable {
        let expires_at: Int?
        let expired: Bool
        let telephony_status: String
    }
}
struct CallForwardingSettings: Decodable {
    let tenant_id: String
    let `extension`: String?
    let mode, target, status: String
    let revision: Int
    let external_available: Bool
}
private struct CloudSummary: Decodable {
    let tenants: [CloudMembership]
    let user: User?
    struct User: Decodable { let id: String }
}

/// Pure selection policy: never infer another person's account or silently pick a company.
enum CloudSetupDecision: Equatable {
    case waiting, chooseCompany, configure(String), keep(String)
}
enum CloudAutoSetup {
    static func decision(_ memberships: [CloudMembership], accountID: String,
                         selection: [String: String]?, endpoint: String, hasCredentials: Bool) -> CloudSetupDecision {
        guard !accountID.isEmpty else { return .waiting }
        let chosen: CloudMembership?
        if selection?["account_id"] == accountID,
           let previous = memberships.first(where: { $0.id == selection?["tenant_id"] }) {
            chosen = previous
        } else if memberships.count == 1 {
            chosen = memberships.first
        } else {
            return memberships.isEmpty ? .waiting : .chooseCompany
        }
        guard let chosen, let number = chosen.number, !number.isEmpty,
              !chosen.trial.expired, chosen.trial.telephony_status == "internal_ready" else { return .waiting }
        if selection?["account_id"] == accountID, selection?["tenant_id"] == chosen.id,
           selection?["extension"] == number, selection?["endpoint_id"] == endpoint,
           !endpoint.isEmpty, hasCredentials { return .keep(chosen.id) }
        return .configure(chosen.id)
    }
}


@MainActor
final class CustomerAccount: ObservableObject {
    @Published var email = ""
    @Published var code = ""
    @Published var password = ""
    @Published var passwordConfirmation = ""
    @Published private(set) var passwordConfigured = false
    @Published private(set) var passwordManaged = false
    @Published private(set) var accountLoaded = false
    @Published private(set) var rememberedDevice = false
    var needsPasswordSetup: Bool { signedIn && accountLoaded && !passwordConfigured && !passwordManaged }
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var signedIn = false
    @Published private(set) var status = ""
    @Published private(set) var company = ""
    @Published private(set) var cloudMemberships: [CloudMembership] = []
    let teamDirectory = TeamDirectory()
    @Published private(set) var teamContext: TeamContext?
    @Published private(set) var availability: AvailabilitySnapshot?
    @Published private(set) var availabilityMessage = ""
    @Published private(set) var availabilitySaving = false
    @Published private(set) var teamPresence: TeamPresenceSnapshot?
    @Published private(set) var presenceContactNames: [String:String] = [:]
    private var presenceForeground = false
    private var presencePolling: Task<Void,Never>?
    private var presenceExpiry: Task<Void,Never>?
    private var presenceGeneration = UUID()
    private let presenceContacts = ContactsDirectory()
    private var presenceContactsLoaded = false
    private var presenceContactChanges: AnyCancellable?
    private var teamTenantChoice: String?
    private var teamSessionID = UUID()
    @Published private(set) var cloudMessage = ""
    @Published private(set) var configuringTenantID: String?
    private var deferredCloudSetup = false
    private var phoneObservation: AnyCancellable?
    private var availabilityPolling: Task<Void,Never>?
    @Published private(set) var challenge = ""
    @Published private(set) var pushStatus = "VoIP-Gerätetoken ausstehend · Hintergrundanrufe noch nicht aktiv"
    private var token = ""
    private var rememberedSession: RememberedCustomerSession?
    private var loginGeneration = UUID()
    private var renewalTask: Task<Void, Error>?
    private var accountID = ""
    private var revision = 0
    private weak var phone: PhoneStore?
    private var historySync: CloudCallHistorySync?
    private var historyMemberships: Set<String>?
    private let cloudSelectionKey = "fonoo.cloud.selected.v2"
    private var cloudEnrollmentInFlight = false
    private var pushToken: Data?
    private let deviceID: String = {
        let key = "fonoo.push.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()
    private let endpoint = URL(string: "https://push.dev.fonoo.app/v1/account/")!
    private var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    private var keychain: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Fonoo") + ".customer",
         kSecAttrAccount as String: "session"]
    }
    #if DEBUG
    private var testCredentialSink: ((Data) throws -> Void)?
    init(authenticationTests session: URLSession, credentialSink: @escaping (Data) throws -> Void) {
        self.session = session; testCredentialSink = credentialSink
    }
    private var teamPreviewSnapshot: TeamSnapshot?
    init(teamPreview: Bool) {
        precondition(teamPreview)
        teamPreviewSnapshot = TeamPreview.snapshot
        signedIn = true; email = "alex@example.invalid"; accountID = TeamPreview.snapshot.selfUserID
        accountLoaded = true
        cloudMemberships = [TeamPreview.membership]
        updateTeamContext()
    }
    #endif
    init() {
        var q = keychain; q[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            if let saved = try? JSONDecoder().decode(RememberedCustomerSession.self, from: data).validated(deviceID: deviceID) {
                rememberedSession = saved; token = saved.token; email = saved.email
                rememberedDevice = true; signedIn = true
            } else if let saved = String(data: data, encoding: .utf8), (32...128).contains(saved.count) {
                token = saved; signedIn = true
            }
        }
    }
    func attach(phone: PhoneStore) {
        self.phone = phone
        presenceContactChanges = NotificationCenter.default.publisher(for:.CNContactStoreDidChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presenceContactsLoaded = false; self.presenceContacts.clear(); self.presenceContactNames = [:]
            }
        }
        attachHistorySync(phone: phone)
        phone.resolveTeamContact = { [weak self] number in
            guard let self, self.teamContext?.tenantID == self.activeCloudMembership?.id else { return nil }
            return self.teamDirectory.snapshot?.resolvedContact(number: number)
        }
        phoneObservation = phone.objectWillChange.sink { [weak self] in
            guard self?.deferredCloudSetup == true else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.busy, !phone.busy, !phone.connectionRestarting else { return }
                self.deferredCloudSetup = false
                await self.refresh()
            }
        }
        phone.onVoIPTokenChanged = { [weak self] value in self?.pushTokenChanged(value) }
        phone.onPushPreferenceChanged = { [weak self] in Task { await self?.enrollDeviceIfReady() } }
        phone.startVoIPTokenRegistration()
        availabilityPolling?.cancel()
        availabilityPolling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(15)) } catch { return }
                if let self, self.signedIn, self.accountLoaded, !self.availabilitySaving {
                    await self.refreshAvailability()
                    await self.syncActivePhoneAvailability()
                }
            }
        }
        if signedIn { Task { await refresh() } }
    }
    private func pushTokenChanged(_ value: Data?) {
        pushToken = value
        if value == nil {
            pushStatus = "VoIP-Gerätetoken ungültig · Hintergrundanrufe noch nicht aktiv"
            if signedIn { Task { await removeCloudPush() } }
        } else {
            Task { await enrollDeviceIfReady() }
        }
    }
    private func storeCredential(_ data: Data) throws {
        #if DEBUG
        if let testCredentialSink { try testCredentialSink(data); return }
        #endif
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var result = SecItemUpdate(keychain as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(keychain.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw PhoneError.message("Anmeldung konnte nicht im Schlüsselbund gespeichert werden.") }
    }
    private func beginLogin(_ value: String) {
        phone?.cancelCloudRegistrationIntent()
        loginGeneration = UUID(); renewalTask?.cancel(); renewalTask = nil
        clearPresence()
        teamDirectory.setContext(nil)
        teamContext = nil; availability = nil; availabilityMessage = ""; teamTenantChoice = nil; teamSessionID = UUID()
        token = value; signedIn = true
        accountLoaded = false
    }
    private func saveToken(_ value: String) throws {
        try storeCredential(Data(value.utf8))
        rememberedSession = nil; rememberedDevice = false
        beginLogin(value)
    }
    private func saveDevice(_ value: RememberedCustomerSession, newLogin: Bool) throws {
        let checked = try value.validated(deviceID: deviceID, userID: newLogin ? nil : rememberedSession?.user_id)
        try storeCredential(JSONEncoder().encode(checked))
        rememberedSession = checked; rememberedDevice = true
        if newLogin { beginLogin(checked.token) } else { token = checked.token }
        email = checked.email
    }
    private func renewDevice() async throws {
        if let renewalTask { try await renewalTask.value; return }
        guard var saved = rememberedSession else { throw PhoneError.message("Bitte erneut anmelden.") }
        let generation = loginGeneration
        if saved.pending_request_id == nil { saved.pending_request_id = UUID().uuidString.lowercased() }
        // Persist the request ID before sending: a lost response can be retried safely.
        try saveDevice(saved, newLogin: false)
        let task = Task { @MainActor in
            var request = URLRequest(url: self.endpoint.appendingPathComponent("device/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode([
                "device_id": saved.device_id, "refresh_token": saved.refresh_token,
                "request_id": saved.pending_request_id!])
            let (data, response) = try await self.session.data(for: request)
            guard self.loginGeneration == generation else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw PhoneError.message("Keine Antwort vom Kontodienst.") }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { self.clearSession(); try? self.phone?.unregister() }
                throw PhoneError.message((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Kontodienst vorübergehend nicht erreichbar.")
            }
            let result = try JSONDecoder().decode(RememberedCustomerSession.self, from: data)
            try self.saveDevice(result, newLogin: false)
        }
        renewalTask = task
        defer { if loginGeneration == generation { renewalTask = nil } }
        try await task.value
    }
    private struct Failure: Decodable { let error: String }
    private func request<T: Decodable>(_ path: String, body: [String: String]? = nil) async throws -> T {
        try await requestData(path, bodyData: body.map { try JSONEncoder().encode($0) })
    }
    private func requestData<T: Decodable>(_ path: String, bodyData: Data? = nil, cloud: Bool = false, retry: Bool = true) async throws -> T {
        let base = cloud ? URL(string: "https://push.dev.fonoo.app/v1/cloud/")! : endpoint
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let bodyData {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        let generation = loginGeneration
        let (data, response) = try await session.data(for: request)
        // A delayed reply from an old login must neither overwrite nor sign out a new login.
        guard loginGeneration == generation else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw PhoneError.message("Keine Antwort vom Kontodienst.") }
        guard (200..<300).contains(http.statusCode) else {
            let authenticated = cloud || !["verify", "device/verify", "password", "code"].contains(path)
            if http.statusCode == 401 && authenticated {
                if retry && rememberedSession != nil {
                    try await renewDevice()
                    guard loginGeneration == generation else { throw CancellationError() }
                    return try await requestData(path, bodyData: bodyData, cloud: cloud, retry: false)
                }
                clearSession(); try? phone?.unregister()
            }
            let text = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Kontodienst vorübergehend nicht erreichbar."
            throw PhoneError.message(text)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; message = ""
        defer { busy = false }
        do { try await work() }
        catch is CancellationError { return }
        catch { message = error.localizedDescription }
    }
    func sendCode() async {
        await perform {
            struct Result: Decodable { let challenge: String }
            let result: Result = try await request("code", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)])
            challenge = result.challenge; code = ""
            message = "Wir haben dir einen Code geschickt. Er gilt zehn Minuten."
        }
    }
    func verify() async {
        await perform {
            #if os(macOS)
            let result: RememberedCustomerSession = try await request("device/verify", body: [
                "challenge": challenge, "code": code, "device_id": deviceID,
                "device_name": String(ProcessInfo.processInfo.hostName.prefix(80))])
            try saveDevice(result, newLogin: true)
            #else
            struct Result: Decodable { let token: String }
            let result: Result = try await request("verify", body: ["challenge": challenge, "code": code])
            try saveToken(result.token)
            #endif
            challenge = ""; code = ""
            try await loadSummary()
        }
    }
    func setOwnPassword() async {
        await perform {
            defer { password = ""; passwordConfirmation = "" }
            guard password == passwordConfirmation else { throw PhoneError.message("Die Kennwörter stimmen nicht überein.") }
            let result: CustomerSummary = try await request("password/set", body: ["password": password])
            passwordConfigured = result.password_configured == true
            message = "Dein Kennwort ist hinterlegt. Dieser Rechner bleibt angemeldet."
        }
    }
    func signInWithPassword() async {
        await perform {
            defer { password = "" }
            struct Result: Decodable { let token: String }
            let result: Result = try await request("password", body: [
                "email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
            try saveToken(result.token); challenge = ""; code = ""
            try await loadSummary()
        }
    }
    private func loadSummary() async throws {
        defer { updateHistoryContext() }
        let result: CustomerSummary = try await request("me")
        email = result.email; company = result.company; status = result.status
        accountID = result.id; revision = result.revision
        passwordConfigured = result.password_configured == true
        passwordManaged = result.password_managed == true
        accountLoaded = true
        cloudMessage = ""
        do {
            let cloud: CloudSummary = try await requestData("me", cloud: true)
            cloudMemberships = cloud.tenants
            historyMemberships = Set(cloud.tenants.map(\.id))
            updateTeamContext()
            await synchronizeCloud()
            updateTeamContext()
            await refreshAvailability()
        } catch is CancellationError {
            return
        } catch {
            cloudMemberships = []
            updateTeamContext()
            cloudMessage = "Cloud-Kundenbereich konnte nicht geladen werden. Bitte erneut aktualisieren."
        }
    }
    func refresh() async {
        #if DEBUG
        if teamPreviewSnapshot != nil { await refreshTeam(); return }
        #endif
        guard signedIn else { return }
        await perform { try await loadSummary() }
    }
    private func enrollDeviceIfReady() async {
        #if os(macOS)
        pushStatus = "Erreichbar, solange fonoo läuft und dein Mac wach ist."
        return
        #else
        guard signedIn, !token.isEmpty else { return }
        if let phone, let selection = UserDefaults.standard.dictionary(forKey: cloudSelectionKey) as? [String: String],
           selection["endpoint_id"] == phone.account.username {
            await enrollCloudPush(selection, phone: phone)
        } else {
            pushStatus = "Bitte zuerst deine fonoo-Cloud-Nebenstelle einrichten."
        }
        #endif
    }
    private func enrollCloudPush(_ selection: [String: String], phone: PhoneStore) async {
        guard !cloudEnrollmentInFlight, let pushToken, let tenant = selection["tenant_id"],
              let endpoint = selection["endpoint_id"], selection["account_id"] == accountID else { return }
        let enrollmentLogin = token
        cloudEnrollmentInFlight = true
        defer {
            cloudEnrollmentInFlight = false
            if signedIn, cloudSelection != selection {
                Task { await self.enrollDeviceIfReady() }
            }
        }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        struct Enrollment: Encodable {
            let tenant_id, device_id, endpoint_id, push_token, environment: String
            let capability = "fonoo.cloud.push.v2"
            let enabled: Bool
        }
        struct Result: Decodable { let status: String; let enabled: Bool }
        do {
            let data = try JSONEncoder().encode(Enrollment(tenant_id: tenant, device_id: deviceID,
                endpoint_id: endpoint, push_token: pushToken.map { String(format: "%02x", $0) }.joined(),
                environment: environment, enabled: !phone.doNotDisturb && phone.cloudAutomaticRegistration))
            let result: Result = try await requestData("push/device", bodyData: data, cloud: true)
            guard signedIn, token == enrollmentLogin, result.status == "registered",
                  cloudSelection?["tenant_id"] == tenant, cloudSelection?["endpoint_id"] == endpoint,
                  phone.account.username == endpoint else { return }
            try phone.enableCloudPush(tenantID: tenant, deviceID: deviceID, endpointID: endpoint)
            pushStatus = result.enabled ? "Cloud-Push angemeldet · Erreichbarkeit im Pilot testen" : "Cloud-Push vorbereitet · Versand noch nicht aktiv"
        } catch {
            guard signedIn, token == enrollmentLogin else { return }
            pushStatus = "Cloud-Push noch nicht bereit: \(error.localizedDescription)"
        }
    }
    private func removeCloudPush() async {
        phone?.disableCloudPush()
        guard signedIn else { return }
        struct Result: Decodable { let status: String }
        _ = try? await requestData("push/remove", bodyData: JSONEncoder().encode(["device_id": deviceID]), cloud: true) as Result
    }
    private var cloudSelection: [String: String]? {
        UserDefaults.standard.dictionary(forKey: cloudSelectionKey) as? [String: String]
    }
    var activeCloudMembership: CloudMembership? {
        guard let phone, signedIn else { return nil }
        return cloudMemberships.first { isCloudConfigured($0, phone: phone) }
    }
    func selectTeamTenant(_ id: String?) {
        guard id == nil || cloudMemberships.contains(where: { $0.id == id }) else { return }
        teamTenantChoice = id
        updateTeamContext()
    }
    private func updateTeamContext() {
        let chosen = teamTenantChoice.flatMap { choice in cloudMemberships.first { $0.id == choice } }
            ?? activeCloudMembership
            ?? (cloudMemberships.count == 1 ? cloudMemberships.first : nil)
        let context = signedIn && !accountID.isEmpty ? chosen.map {
            TeamContext(tenantID: $0.id, accountID: accountID, sessionID: teamSessionID)
        } : nil
        teamDirectory.setContext(context)
        if teamContext != context { availability = nil; availabilityMessage = ""; clearPresence() }
        teamContext = context
    }

    func setPresenceForeground(_ active: Bool) {
        guard presenceForeground != active else { return }
        presenceForeground = active
        presencePolling?.cancel(); presencePolling = nil
        clearPresence()
        guard active else { return }
        presencePolling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, self.signedIn, self.accountLoaded, self.presenceForeground {
                    if self.teamDirectory.snapshot == nil && !self.teamDirectory.isLoading { await self.refreshTeam() }
                    await self.refreshPresence()
                }
                do { try await Task.sleep(for:.seconds(3)) } catch { return }
            }
        }
    }

    private func clearPresence() {
        presenceGeneration = UUID(); presenceExpiry?.cancel(); presenceExpiry = nil
        teamPresence = nil; presenceContactNames = [:]
        presenceContactsLoaded = false; presenceContacts.clear()
    }

    func telephonePresence(for userID: String) -> CallPresence {
        guard let context = teamContext, teamPresence?.tenantID == context.tenantID,
              teamPresence?.selfUserID == context.accountID else { return .unknown(userID) }
        return teamPresence?.presence(for:userID) ?? .unknown(userID)
    }

    func presenceMember(for contact: Contact) -> TeamMember? {
        guard teamContext?.tenantID == activeCloudMembership?.id,
              teamDirectory.snapshot?.tenantID == teamContext?.tenantID else { return nil }
        return teamDirectory.snapshot?.presenceMember(for:contact)
    }

    func presencePeerName(_ presence: CallPresence) -> String? {
        guard let number = presence.peerNumber else { return nil }
        if let id = presence.peerUserID, let member = teamDirectory.snapshot?.members.first(where:{$0.id == id}) {
            return member.name
        }
        return presenceContactNames[number] ?? number
    }

    private func refreshPresence() async {
        guard presenceForeground, let context = teamContext else { return }
        let generation = presenceGeneration
        #if DEBUG
        if teamPreviewSnapshot != nil { teamPresence = TeamPreview.presence; return }
        #endif
        do {
            let result: TeamPresenceSnapshot = try await requestData("team/presence",
                bodyData:JSONEncoder().encode(["tenant_id":context.tenantID]), cloud:true)
            let validated = try result.validated(for:context)
            guard !Task.isCancelled, presenceForeground, teamContext == context, presenceGeneration == generation else { return }
            if let old = teamPresence?.observedAt, let fresh = validated.observedAt, fresh < old { return }
            teamPresence = validated
            presenceExpiry?.cancel()
            if let expiry = validated.expiresAt {
                presenceExpiry = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for:.seconds(max(0,expiry-Date().timeIntervalSince1970))) } catch { return }
                    guard let self, self.teamContext == context, self.presenceGeneration == generation,
                          self.teamPresence?.observedAt == validated.observedAt else { return }
                    self.teamPresence = nil; self.presenceContactNames = [:]
                }
            }
            let numbers = Set(validated.members.compactMap(\.peerNumber))
            if presenceContacts.access != ContactsDirectory.currentAccess() {
                presenceContactsLoaded = false; presenceContacts.clear(); presenceContactNames = [:]
            }
            if !numbers.isEmpty && !presenceContactsLoaded {
                await presenceContacts.refresh() // Existing permission only; no prompt or upload.
                guard !Task.isCancelled, presenceForeground, teamContext == context, presenceGeneration == generation else { return }
                presenceContactsLoaded = true
            }
            var names: [String:String] = [:]
            for number in numbers {
                if let match = DeviceContact.resolvedContact(in:presenceContacts.contacts, number:number) {
                    names[number] = match.name
                } else if let favorites = phone?.favorites {
                    let matches = favorites.filter { DeviceContact(id:$0.id,name:$0.name,numbers:[.init(id:$0.id,label:$0.role,value:$0.number)]).containsPhoneNumber(number) }
                    if matches.count == 1 { names[number] = matches[0].name }
                }
            }
            guard teamPresence?.observedAt == validated.observedAt,
                  validated.expiresAt.map({Date().timeIntervalSince1970 < $0}) ?? false else { return }
            presenceContactNames = names
        } catch {
            guard !Task.isCancelled, teamContext == context, presenceGeneration == generation else { return }
            teamPresence = nil; presenceContactNames = [:]
        }
    }
    func refreshTeam() async {
        #if DEBUG
        if let teamPreviewSnapshot {
            await teamDirectory.refresh { teamPreviewSnapshot }
            return
        }
        #endif
        updateTeamContext()
        guard let context = teamContext else { return }
        await teamDirectory.refresh {
            let result: TeamSnapshot = try await requestData("team/read",
                bodyData: JSONEncoder().encode(["tenant_id": context.tenantID]), cloud: true)
            guard teamContext == context else { throw CancellationError() }
            return result
        }
        await refreshAvailability()
    }

    func refreshAvailability() async {
        guard let context = teamContext else { availability = nil; return }
        do {
            let result: AvailabilitySnapshot = try await requestData("availability/read",
                bodyData: JSONEncoder().encode(["tenant_id":context.tenantID]), cloud:true)
            guard teamContext == context else { return }
            guard result.schemaVersion == 1, result.tenantID == context.tenantID,
                  result.userID == context.accountID, result.selfUserID == context.accountID, result.profilesValid else { throw TeamDirectoryError.invalidResponse }
            availability = result; availabilityMessage = ""
            applyPhoneAvailability(result)
        } catch {
            guard teamContext == context else { return }
            availabilityMessage = error.localizedDescription
        }
    }

    private func applyPhoneAvailability(_ result: AvailabilitySnapshot) {
        guard result.company.routingEnabled, activeCloudMembership?.id == result.tenantID,
              result.schemaVersion == 1, result.userID == accountID, result.selfUserID == accountID else { return }
        let dnd = result.effective.presence?.state == "do_not_disturb"
        if phone?.doNotDisturb != dnd { phone?.doNotDisturb = dnd }
    }

    private func syncActivePhoneAvailability() async {
        guard let active = activeCloudMembership, active.id != teamContext?.tenantID else { return }
        let session = teamSessionID, account = accountID
        do {
            let result: AvailabilitySnapshot = try await requestData("availability/read",
                bodyData: JSONEncoder().encode(["tenant_id":active.id]), cloud:true)
            guard signedIn, teamSessionID == session, accountID == account,
                  activeCloudMembership?.id == active.id, result.tenantID == active.id else { return }
            applyPhoneAvailability(result)
        } catch { /* Preserve the last confirmed phone preference during network failures. */ }
    }

    @discardableResult
    func saveAvailability(_ changes: [String:Any], expectedRevision: Int? = nil) async -> Bool {
        guard let context = teamContext, let current = availability, !availabilitySaving else { return false }
        availabilitySaving = true
        defer { availabilitySaving = false }
        do {
            struct Result: Decodable { let revision: Int }
            let body = try JSONSerialization.data(withJSONObject:["tenant_id":context.tenantID,"expected_revision":expectedRevision ?? current.revision,"changes":changes])
            let _: Result = try await requestData("availability/user",bodyData:body,cloud:true)
            guard teamContext == context else { return false }
            await refreshAvailability()
            await refreshTeam()
            return true
        } catch {
            guard teamContext == context else { return false }
            availabilityMessage = error.localizedDescription
            return false
        }
    }

    func pauseCallTeam(_ team: AvailabilitySnapshot.CallTeam, until: Date?) async {
        guard let context = teamContext, let current = availability, !availabilitySaving,
              let member = team.members.first(where: { $0.targetType == "user" && $0.targetID == current.selfUserID }) else { return }
        availabilitySaving = true
        defer { availabilitySaving = false }
        do {
            struct Result: Decodable { let revision: Int }
            let body = try JSONSerialization.data(withJSONObject:["tenant_id":context.tenantID,"team_id":team.id,
                "expected_revision":member.revision,"until":until.map { Int($0.timeIntervalSince1970) } as Any? ?? NSNull()])
            let _: Result = try await requestData("availability/pause",bodyData:body,cloud:true)
            guard teamContext == context else { return }
            await refreshAvailability()
        } catch {
            guard teamContext == context else { return }
            availabilityMessage = error.localizedDescription
        }
    }
    func saveTeamName(_ name: String) async {
        guard let context = teamContext, let snapshot = teamDirectory.snapshot else { return }
        #if DEBUG
        if let preview = teamPreviewSnapshot {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let members = preview.members.map { member in
                member.id == preview.selfUserID ? TeamMember(id: member.id, name: name, email: member.email,
                    number: member.number, personalDeviceCount: member.personalDeviceCount, personalDevices: member.personalDevices) : member
            }
            let updated = TeamSnapshot(schemaVersion: 1, tenantID: preview.tenantID, tenantName: preview.tenantName,
                revision: preview.revision + 1, selfUserID: preview.selfUserID, members: members)
            await teamDirectory.saveName { updated }
            teamPreviewSnapshot = updated
            return
        }
        #endif
        struct Change: Encodable {
            let tenant_id, name: String
            let expected_revision: Int
        }
        await teamDirectory.saveName {
            let result: TeamSnapshot = try await requestData("team/name", bodyData: JSONEncoder().encode(
                Change(tenant_id: context.tenantID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                       expected_revision: snapshot.revision)), cloud: true)
            guard teamContext == context else { throw CancellationError() }
            return result
        }
    }
    func canCallTeamMember(_ member: TeamMember) -> Bool {
        guard let context = teamContext, activeCloudMembership?.id == context.tenantID,
              teamDirectory.snapshot?.members.contains(member) == true,
              member.id != context.accountID, member.callContact(tenantID: context.tenantID) != nil,
              !teamDirectory.isLoading, teamDirectory.errorMessage == nil,
              configuringTenantID == nil, let phone else { return false }
        return !phone.busy && phone.registration == .registered
    }
    func callTeamMember(_ member: TeamMember) {
        guard canCallTeamMember(member), let tenantID = teamContext?.tenantID,
              let contact = member.callContact(tenantID: tenantID) else { return }
        phone?.start(contact)
    }

    func forwardingSettings(tenantID: String) async throws -> CallForwardingSettings {
        let result: CallForwardingSettings = try await requestData("call-forwarding/read",
            bodyData: JSONEncoder().encode(["tenant_id": tenantID]), cloud: true)
        guard activeCloudMembership?.id == tenantID, result.tenant_id == tenantID,
              result.extension == activeCloudMembership?.number else { throw CancellationError() }
        return result
    }
    func saveForwarding(tenantID: String, mode: String, target: String, revision: Int) async throws -> CallForwardingSettings {
        guard activeCloudMembership?.id == tenantID else { throw CancellationError() }
        struct Change: Encodable {
            let tenant_id, mode, target: String
            let expected_revision: Int
        }
        let result: CallForwardingSettings = try await requestData("call-forwarding",
            bodyData: JSONEncoder().encode(Change(tenant_id: tenantID, mode: mode, target: target, expected_revision: revision)), cloud: true)
        guard activeCloudMembership?.id == tenantID, result.tenant_id == tenantID,
              result.extension == activeCloudMembership?.number else { throw CancellationError() }
        return result
    }
    func isCloudConfigured(_ membership: CloudMembership, phone: PhoneStore) -> Bool {
        signedIn && cloudSelection?["account_id"] == accountID &&
        cloudSelection?["tenant_id"] == membership.id && cloudSelection?["extension"] == membership.number &&
        cloudSelection?["endpoint_id"] == phone.account.username && phone.hasSavedPassword
    }
    private func synchronizeCloud() async {
        guard let phone, signedIn else { return }
        switch CloudAutoSetup.decision(cloudMemberships, accountID: accountID, selection: cloudSelection,
                                       endpoint: phone.account.username, hasCredentials: phone.hasSavedPassword) {
        case .configure(let tenant):
            guard let membership = cloudMemberships.first(where: { $0.id == tenant }) else { return }
            if phone.busy {
                deferredCloudSetup = true
                cloudMessage = "Deine Nebenstelle wird nach dem laufenden Gespräch eingerichtet."
                return
            }
            do { try await configureCloud(membership, phone: phone) }
            catch is CancellationError { return }
            catch { cloudMessage = error.localizedDescription }
        case .keep:
            // Foreground recovery owns SIP reconnection; refreshing the account never resets it.
            await enrollDeviceIfReady()
        case .chooseCompany:
            cloudMessage = "Wähle einmal, mit welcher Firma du auf diesem Gerät telefonieren möchtest."
        case .waiting:
            break
        }
    }
    func applyCloud(_ membership: CloudMembership, to phone: PhoneStore) async {
        await perform {
            cloudMessage = ""
            try await phone.prepareExplicitCloudReconnect()
            try await configureCloud(membership, phone: phone)
        }
    }
    private func configureCloud(_ membership: CloudMembership, phone: PhoneStore) async throws {
        guard signedIn, !accountID.isEmpty,
              cloudMemberships.contains(where: { $0.id == membership.id && $0.number == membership.number }),
              !membership.trial.expired, let number = membership.number, !number.isEmpty,
              membership.trial.telephony_status == "internal_ready" else {
            throw PhoneError.message("Deine Firma und Nebenstelle müssen zuerst freigeschaltet sein.")
        }
        guard !phone.busy else { throw PhoneError.message("Bitte zuerst das Gespräch beenden.") }
        let owner = accountID, login = token
        configuringTenantID = membership.id
        defer { configuringTenantID = nil }
        struct Request: Encodable {
            let tenant_id, device_id: String
            let capabilities = ["fonoo.cloud.v1", "srtp.required"]
            #if os(macOS)
            let device_name = "Fonoo auf dem Mac"
            let device_type = "desktop_app"
            #else
            let device_name = "Fonoo auf dem iPhone"
            let device_type = "mobile_app"
            #endif
        }
        let body = try JSONEncoder().encode(Request(tenant_id: membership.id, device_id: deviceID))
        for attempt in 0..<10 {
            try Task.checkCancellation()
            guard signedIn, accountID == owner, token == login else { throw CancellationError() }
            let result: CloudDeviceConfiguration = try await requestData("device-configuration", bodyData: body, cloud: true)
            guard signedIn, accountID == owner, token == login else { throw CancellationError() }
            if let configuration = try result.validated(tenantID: membership.id, deviceID: deviceID) {
                guard !phone.busy else {
                    deferredCloudSetup = true
                    throw PhoneError.message("Deine Nebenstelle wird nach dem laufenden Gespräch eingerichtet.")
                }
                var cloudAccount = try configuration.account()
                cloudAccount.usesTLSClientCertificate = false
                guard !phone.busy, !phone.connectionRestarting else {
                    deferredCloudSetup = true
                    throw PhoneError.message("Deine Nebenstelle wird nach dem laufenden Gespräch eingerichtet.")
                }
                try phone.saveAndRegister(cloudAccount, password: configuration.password, turnPassword: configuration.turn_password)
                pushStatus = "Hintergrundanrufe werden eingerichtet …"
                UserDefaults.standard.set(["tenant_id": membership.id, "endpoint_id": configuration.username,
                                           "account_id": owner, "extension": number], forKey: cloudSelectionKey)
                updateHistoryContext()
                deferredCloudSetup = false
                // Company changes invalidate every old row/detail before another call can start.
                teamTenantChoice = membership.id
                updateTeamContext()
                await enrollDeviceIfReady()
                guard signedIn, accountID == owner, token == login else { throw CancellationError() }
                cloudMessage = ""
                message = "Nebenstelle \(number) eingerichtet."
                return
            }
            cloudMessage = "Deine Nebenstelle wird eingerichtet …"
            if attempt < 9 { try await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        throw PhoneError.message("Die Einrichtung dauert noch etwas. Bitte erneut versuchen.")
    }
    private func clearSession() {
        phone?.cancelCloudRegistrationIntent()
        historySync?.setContext(nil)
        historyMemberships = nil
        loginGeneration = UUID(); renewalTask?.cancel(); renewalTask = nil
        rememberedSession = nil; rememberedDevice = false; accountLoaded = false
        passwordConfigured = false; passwordManaged = false; password = ""; passwordConfirmation = ""
        clearPresence()
        teamDirectory.setContext(nil)
        teamContext = nil; availability = nil; availabilityMessage = ""; teamTenantChoice = nil; teamSessionID = UUID()
        deferredCloudSetup = false
        configuringTenantID = nil
        phone?.disableCloudPush()
        #if DEBUG
        if testCredentialSink == nil {
            UserDefaults.standard.removeObject(forKey: cloudSelectionKey)
            SecItemDelete(keychain as CFDictionary)
        }
        #else
        UserDefaults.standard.removeObject(forKey: cloudSelectionKey)
        SecItemDelete(keychain as CFDictionary)
        #endif
        token = ""; signedIn = false; status = ""; company = ""; challenge = ""; code = ""
        accountID = ""; revision = 0
        cloudMemberships = []; cloudMessage = ""
        pushStatus = "VoIP-Gerätetoken ausstehend · Hintergrundanrufe noch nicht aktiv"
    }
    func signOut() async {
        await perform {
            defer { try? phone?.unregister(); clearSession() }
            let _: [String: String] = try await request("logout", body: ["device_id": deviceID])
        }
    }
}

#if os(iOS)
struct CustomerEntryView: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var customer: CustomerAccount
    var body: some View {
        if phone.hasSavedPassword || customer.signedIn && !customer.cloudMemberships.isEmpty { RootView() }
        else { NavigationStack { CustomerAccountView() } }
    }
}

struct CustomerAccountView: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var customer: CustomerAccount
    @Environment(\.scenePhase) private var scenePhase
    @State private var passwordSignIn = false
    var body: some View {
        Form {
            Section {
                FonooWordmark(size: 38)
                Text(customer.signedIn ? "Dein Konto" : "Willkommen bei fonoo").font(.title2.bold())
                Text(customer.signedIn ? customer.email : "Erstelle dein Konto oder melde dich mit deiner E-Mail-Adresse an.").foregroundStyle(.secondary)
            }
            if !customer.signedIn {
                Section("E-Mail-Adresse") {
                    TextField("name@firma.at", text: $customer.email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(customer.challenge.isEmpty ? "Bestätigungscode senden" : "Neuen Code senden") { Task { await customer.sendCode() } }.disabled(customer.email.isEmpty)
                }
                if !customer.challenge.isEmpty {
                    Section("E-Mail bestätigen") {
                        TextField("Sechsstelliger Code", text: $customer.code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Bestätigen und anmelden") { Task { await customer.verify() } }.disabled(customer.code.count != 6)
                    }
                }
                Section {
                    DisclosureGroup("Mit Zugangsdaten anmelden", isExpanded: $passwordSignIn) {
                        SecureField("Passwort", text: $customer.password).textContentType(.password)
                        Button("Mit Passwort anmelden") { Task { await customer.signInWithPassword() } }
                            .disabled(customer.email.isEmpty || customer.password.isEmpty)
                        Text("Für Konten, zu denen du ein Passwort erhalten hast.").font(.footnote)
                    }
                }
            } else {
                Section("Cloud-Kundenbereich") {
                    ForEach(customer.cloudMemberships) { membership in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(membership.name).font(.headline)
                            Text(membership.number.map { "Deine Nebenstelle: \($0)" } ?? "Noch keine Nebenstelle zugewiesen")
                            if customer.configuringTenantID == membership.id {
                                ProgressView("Nebenstelle wird eingerichtet …")
                            } else if customer.isCloudConfigured(membership, phone: phone) {
                                Label(phone.registration == .registered ? "Verbunden" : phone.registration.label,
                                      systemImage: phone.registration == .registered ? "checkmark.circle.fill" : "phone.connection")
                                    .foregroundStyle(phone.registration == .registered ? .green : .secondary)
                                if phone.registration.canReconnect {
                                    Button("Verbindung erneut herstellen") { Task { await customer.applyCloud(membership, to: phone) } }
                                        .disabled(phone.busy || phone.connectionRestarting)
                                } else if !phone.cloudAutomaticRegistration {
                                    Button("Telefonie verbinden") { Task { await customer.applyCloud(membership, to: phone) } }
                                        .disabled(phone.busy)
                                }
                            } else if membership.trial.expired {
                                Text("Deine Testzeit ist beendet.").foregroundStyle(.secondary)
                            } else if membership.number == nil {
                                Text("Dein Team-Admin muss dir noch eine Nebenstelle zuweisen.").foregroundStyle(.secondary)
                            } else if membership.trial.telephony_status != "internal_ready" {
                                Text("Telefonie wird vorbereitet. Die Einrichtung erfolgt automatisch, sobald alles bereit ist.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if customer.cloudMemberships.count > 1 {
                                Button("Mit dieser Firma telefonieren") { Task { await customer.applyCloud(membership, to: phone) } }
                                    .disabled(phone.busy)
                            } else if !customer.cloudMessage.isEmpty || !customer.message.isEmpty {
                                Button("Einrichtung erneut versuchen") { Task { await customer.applyCloud(membership, to: phone) } }
                                    .disabled(phone.busy)
                            } else {
                                Text("Deine Nebenstelle wird automatisch eingerichtet.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                    if customer.cloudMemberships.isEmpty {
                        Text("Lege deine Firma im Kundenbereich an oder nimm dort eine Einladung an. Verwende dieselbe E-Mail-Adresse wie hier.")
                    }
                    if !customer.cloudMessage.isEmpty { Text(customer.cloudMessage).font(.footnote) }
                    Link("Firma und Benutzer verwalten", destination: URL(string: "https://dev.fonoo.app/kunden/")!)
                    Button("Status aktualisieren") { Task { await customer.refresh() } }
                }
                Section("Erreichbarkeit") { Text(customer.pushStatus).font(.subheadline) }
                Section("Verbindung") {
                    NavigationLink("Diagnose und SIP-Protokolle") { DiagnosticsView(diagnostics: phone.diagnostics) }
                }
                Section {
                    Button("Vom fonoo-Konto abmelden") { Task { await customer.signOut() } }
                } footer: { Text("Die Telefonie wird auf diesem iPhone abgemeldet. Deine Firma und Benutzer bleiben bestehen.") }
            }
            if customer.busy { ProgressView("Bitte warten …") }
            if !customer.message.isEmpty { Section { Text(customer.message).font(.callout).accessibilityLabel(customer.message) } }
        }
        .disabled(customer.busy)
        .scrollContentBackground(.hidden).background(FonooStyle.background)
        .navigationTitle("fonoo-Konto").navigationBarTitleDisplayMode(.inline)
        .task { await customer.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await customer.refresh() } } }
        .onDisappear { customer.password = "" }
    }
}

#endif

#if DEBUG && os(macOS)
/// Real URLSession requests against an in-process transport; no production API or Keychain access.
private final class CustomerAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var respond: ((URLRequest) -> (Int, Data, TimeInterval, Error?))?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.respond!(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + result.2) { [self] in
            lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
            if let error = result.3 { client?.urlProtocol(self, didFailWithError: error); return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

extension CustomerAccount {
    static func runAuthenticationChecks() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw PhoneError.message("FAIL: " + label) }
            print("PASS: " + label)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CustomerAuthFixtureProtocol.self]
        let testSession = URLSession(configuration: config)
        defer { testSession.invalidateAndCancel(); CustomerAuthFixtureProtocol.respond = nil }
        var stored: [Data] = []
        let account = CustomerAccount(authenticationTests: testSession) { stored.append($0) }
        let first = RememberedCustomerSession(token: String(repeating: "a", count: 43), refresh_token: String(repeating: "b", count: 64),
            device_id: account.deviceID, user_id: "fixture-user", email: "test@example.invalid",
            expires_at: 100, device_expires_at: Int(Date().timeIntervalSince1970) + 10000)
        let renewed = RememberedCustomerSession(token: String(repeating: "c", count: 43), refresh_token: String(repeating: "d", count: 64),
            device_id: first.device_id, user_id: first.user_id, email: first.email,
            expires_at: Int(Date().timeIntervalSince1970) + 1000, device_expires_at: first.device_expires_at)
        try account.saveDevice(first, newLogin: true)
        let decoded = try JSONDecoder().decode(RememberedCustomerSession.self, from: stored.last!)
        try check(decoded.refresh_token == first.refresh_token, "device credential survives encoded storage")
        do { _ = try decoded.validated(deviceID: UUID().uuidString); throw PhoneError.message("Cross-device credential accepted") }
        catch { try check(error.localizedDescription.contains("Ungültige"), "cross-device credential rejected") }
        let fixtureLock = NSLock()
        var refreshes = 0
        let ok = Data("{\"ok\":true}".utf8), rejected = Data("{\"error\":\"expired\"}".utf8)
        CustomerAuthFixtureProtocol.respond = { request in
            if request.url!.path.hasSuffix("/device/refresh") {
                fixtureLock.lock(); refreshes += 1; fixtureLock.unlock()
                return (200, try! JSONEncoder().encode(renewed), 0.1, nil)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer " + renewed.token
                ? (200, ok, 0, nil) : (401, rejected, 0, nil)
        }
        async let a: [String:Bool] = account.requestData("me")
        async let b: [String:Bool] = account.requestData("me")
        let results = try await (a,b)
        try check(results.0["ok"] == true && results.1["ok"] == true && refreshes == 1,
                  "parallel expired access requests renew once and both retry")
        try check(account.signedIn && account.token == renewed.token, "successful renewal preserves login")
        let pendingStored = try JSONDecoder().decode(RememberedCustomerSession.self, from: stored[stored.count-2])
        try check(pendingStored.pending_request_id != nil,
                  "retry request ID is saved before renewal")

        try account.saveDevice(first, newLogin: true)
        CustomerAuthFixtureProtocol.respond = { request in
            request.url!.path.hasSuffix("/device/refresh") ? (0, Data(), 0, URLError(.notConnectedToInternet)) : (401, rejected, 0, nil)
        }
        do { let _: [String:Bool] = try await account.requestData("me"); throw PhoneError.message("Offline refresh succeeded") }
        catch { try check(account.signedIn && account.rememberedSession?.pending_request_id != nil, "offline renewal keeps credential and pending retry") }
        let pending = account.rememberedSession!.pending_request_id!
        CustomerAuthFixtureProtocol.respond = { request in
            if request.url!.path.hasSuffix("/device/refresh") {
                // URLProtocol may put the HTTP body in a stream rather than httpBody.
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
                }
                let payload = try! JSONSerialization.jsonObject(with: body) as! [String:String]
                guard payload["request_id"] == pending && payload["refresh_token"] == first.refresh_token else { return (401, rejected, 0, nil) }
                return (200, try! JSONEncoder().encode(renewed), 0, nil)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer " + renewed.token ? (200, ok, 0, nil) : (401, rejected, 0, nil)
        }
        let recovered: [String:Bool] = try await account.requestData("me")
        try check(recovered["ok"] == true, "interrupted renewal retries the same persisted request")

        try account.saveDevice(first, newLogin: true)
        CustomerAuthFixtureProtocol.respond = { _ in (401, rejected, 0, nil) }
        do { let _: [String:Bool] = try await account.requestData("me"); throw PhoneError.message("Revoked refresh succeeded") }
        catch { try check(!account.signedIn && account.rememberedSession == nil, "confirmed revocation removes login") }

        try account.saveDevice(first, newLogin: true)
        CustomerAuthFixtureProtocol.respond = { request in
            request.url!.path.hasSuffix("/device/refresh") ? (200, try! JSONEncoder().encode(renewed), 0.2, nil) : (401, rejected, 0, nil)
        }
        let pendingRequest = Task { let _: [String:Bool] = try await account.requestData("me") }
        try await Task.sleep(for: .milliseconds(40))
        account.clearSession()
        _ = try? await pendingRequest.value
        try check(!account.signedIn && account.rememberedSession == nil, "late renewal cannot restore a logged-out account")
        print("Authentication checks passed; no production requests or credentials used.")
    }
}
#endif

private extension CustomerAccount {
    func attachHistorySync(phone: PhoneStore) {
        historySync?.setContext(nil)
        historySync = CloudCallHistorySync(manager: phone.manager, read: { [weak self] tenant, revision in
            guard let self, self.signedIn else { throw CancellationError() }
            var body: [String: Any] = ["tenant_id": tenant]
            if let revision { body["revision"] = revision }
            return try await self.requestData("call-history/read", bodyData: JSONSerialization.data(withJSONObject: body), cloud: true)
        }, delete: { [weak self] tenant, ids in
            guard let self, self.signedIn else { throw CancellationError() }
            return try await self.requestData("call-history/delete", bodyData: JSONSerialization.data(withJSONObject:
                ["tenant_id": tenant, "ids": ids.map { $0.uuidString.lowercased() }]), cloud: true)
        })
        updateHistoryContext()
    }
    func updateHistoryContext() {
        guard signedIn, !accountID.isEmpty,
              let selection = UserDefaults.standard.dictionary(forKey: cloudSelectionKey) as? [String: String],
              selection["account_id"] == accountID, selection["endpoint_id"] == phone?.account.username,
              let tenant = selection["tenant_id"], historyMemberships?.contains(tenant) == true else {
            historySync?.setContext(nil); return
        }
        historySync?.setContext(.init(user: accountID, tenant: tenant))
    }
}

/// Shared by the iPhone and Mac targets through CustomerAccount.swift.
@MainActor
private final class CloudCallHistorySync {
    struct Context: Equatable { let user, tenant: String }
    private weak var manager: CallManager?
    private let read: (String, Int64?) async throws -> CloudHistoryPayload
    private let delete: (String, Set<UUID>) async throws -> CloudHistoryPayload
    private let cacheDirectory: URL
    private var context: Context?
    private var generation = UUID()
    private var snapshot: CloudHistoryPayload?
    private var working = false
    private var polling: Task<Void, Never>?
    init(manager: CallManager, cacheDirectory: URL? = nil,
         read: @escaping (String, Int64?) async throws -> CloudHistoryPayload,
         delete: @escaping (String, Set<UUID>) async throws -> CloudHistoryPayload) {
        self.manager = manager; self.read = read; self.delete = delete
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fonoo", isDirectory: true).appendingPathComponent("cloud-history-v1", isDirectory: true)
        manager.onHistoryRefresh = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let generation = self.generation
                try? await Task.sleep(for: .seconds(2))
                if self.generation == generation { await self.refresh() }
            }
        }
        manager.onHistoryDelete = { [weak self] ids in Task { await self?.remove(ids) } }
    }
    deinit { polling?.cancel() }
    private func cacheURL(_ context: Context) -> URL {
        let key = SHA256.hash(data: Data((context.user + "\n" + context.tenant).utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(key).json")
    }
    func setContext(_ next: Context?) {
        guard context != next else { return }
        generation = UUID(); polling?.cancel(); polling = nil
        context = next; snapshot = nil
        manager?.setCloudHistoryContext(next != nil)
        guard let next else { return }
        if let cached = try? JSONDecoder().decode(CloudHistoryPayload.self, from: Data(contentsOf: cacheURL(next))),
           !cached.not_modified, let rows = try? cached.validated(tenant: next.tenant, user: next.user) {
            snapshot = cached
            manager?.applyCloudHistory(rows, status: "fonoo-Konto · gespeicherter Stand, wird aktualisiert")
        }
        let generation = self.generation
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.generation == generation else { return }
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    private func accept(_ response: CloudHistoryPayload, context: Context) throws {
        let rows = try response.validated(tenant: context.tenant, user: context.user)
        if let snapshot, response.revision < snapshot.revision { return }
        if !response.not_modified {
            let url = cacheURL(context)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(response)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #endif
            snapshot = response
            manager?.applyCloudHistory(rows, status: response.collector_available
                ? "Mit deinem fonoo-Konto synchronisiert" : "fonoo-Konto · Telefonieserver-Abgleich ausstehend")
        } else {
            guard snapshot?.revision == response.revision else { throw CocoaError(.fileReadCorruptFile) }
            manager?.setCloudHistoryStatus(response.collector_available
                ? "Mit deinem fonoo-Konto synchronisiert" : "fonoo-Konto · Telefonieserver-Abgleich ausstehend")
        }
    }
    private func refresh() async {
        guard !working, let context else { return }
        working = true; defer { working = false }
        let generation = self.generation
        do {
            let response = try await read(context.tenant, snapshot?.revision)
            guard !Task.isCancelled, self.generation == generation else { return }
            try accept(response, context: context)
        } catch {
            if self.generation == generation {
                manager?.setCloudHistoryStatus(snapshot == nil ? "Gemeinsame Anrufliste momentan nicht erreichbar"
                    : "fonoo-Konto · gespeicherter Stand, Verbindung wird wiederholt")
            }
        }
    }
    private func remove(_ ids: Set<UUID>) async {
        guard !working, let context, !ids.isEmpty else { manager?.show("Die Anrufliste wird gerade aktualisiert. Bitte kurz warten."); return }
        working = true; defer { working = false }
        let generation = self.generation
        do {
            let response = try await delete(context.tenant, ids)
            guard self.generation == generation else { return }
            guard !response.not_modified else { throw CocoaError(.fileReadCorruptFile) }
            try accept(response, context: context)
        } catch {
            if self.generation == generation { manager?.show("Die gemeinsame Anrufliste konnte nicht gelöscht werden. Bitte erneut versuchen.") }
        }
    }
}
