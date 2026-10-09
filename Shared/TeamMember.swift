import Foundation

/// Tenant identity and personal registrations are deliberately separate types.
/// Independent devices and AI agents will have their own directory models.
struct TeamMember: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String
    let number: String?
    let personalDeviceCount: Int
    let personalDevices: [PersonalDevice]
    var availability: PersonalAvailability? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, email, availability
        case number = "extension"
        case personalDeviceCount = "personal_device_count"
        case personalDevices = "personal_devices"
    }

    struct PersonalDevice: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    var initials: String {
        if name == email { return String(email.prefix(1)).uppercased() }
        return name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        let fields = [name, email, number ?? ""]
        return words.allSatisfy { word in
            fields.contains { $0.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil }
        }
    }

    /// Calls always target the person's extension. A personal registration is never dialed directly.
    func callContact(tenantID: String) -> Contact? {
        guard let number, (2...6).contains(number.count), number.first != "0",
              number.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Contact(id: "team:\(tenantID):\(id)", name: name, role: "Team", number: number)
    }
}

struct TeamContext: Hashable, Sendable {
    let tenantID: String
    let accountID: String
    let sessionID: UUID
}

struct TeamSnapshot: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let tenantID: String
    let tenantName: String
    let revision: Int
    let selfUserID: String
    let members: [TeamMember]

    enum CodingKeys: String, CodingKey {
        case revision, members
        case schemaVersion = "schema_version"
        case tenantID = "tenant_id"
        case tenantName = "tenant_name"
        case selfUserID = "self_user_id"
    }

    func validated(for context: TeamContext) throws -> TeamSnapshot {
        guard schemaVersion == 1, tenantID == context.tenantID, selfUserID == context.accountID,
              revision > 0, !tenantName.isEmpty,
              Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && !$0.email.isEmpty &&
                  $0.personalDeviceCount >= $0.personalDevices.count &&
                  ($0.id == selfUserID || $0.personalDevices.isEmpty) &&
                  ($0.number == nil || $0.callContact(tenantID: tenantID) != nil) }) else {
            throw TeamDirectoryError.invalidResponse
        }
        return self
    }

    func resolvedContact(number: String) -> Contact? {
        let matches = members.filter { $0.number == number }
        guard matches.count == 1 else { return nil }
        return matches[0].callContact(tenantID: tenantID)
    }
}

enum TeamDirectoryError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "Das Team konnte nicht sicher geladen werden. Bitte erneut aktualisieren." }
}

/// Telephone activity comes from the PBX, independently of a personal status.
struct TeamPresenceSnapshot: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let tenantID, selfUserID: String
    let collectorAvailable: Bool
    let observedAt, expiresAt: Double?
    let members: [CallPresence]
    enum CodingKeys: String, CodingKey {
        case members
        case schemaVersion = "schema_version", tenantID = "tenant_id", selfUserID = "self_user_id"
        case collectorAvailable = "collector_available", observedAt = "observed_at", expiresAt = "expires_at"
    }
    func validated(for context: TeamContext) throws -> Self {
        let ids = Set(members.map(\.userID))
        guard schemaVersion == 1, tenantID == context.tenantID, selfUserID == context.accountID,
              ids.count == members.count, ids.contains(selfUserID), members.count <= 1000,
              members.allSatisfy({ !$0.userID.isEmpty && $0.valid &&
                  ($0.peerUserID == nil || ids.contains($0.peerUserID!)) }),
              observedAt == nil || observedAt!.isFinite,
              expiresAt == nil || expiresAt!.isFinite,
              !collectorAvailable || (observedAt != nil && expiresAt != nil &&
                  expiresAt! >= observedAt! && expiresAt! - observedAt! <= 15 &&
                  observedAt! <= Date().timeIntervalSince1970 + 30),
              collectorAvailable || members.allSatisfy({ $0.state == "unknown" }) else {
            throw TeamDirectoryError.invalidResponse
        }
        return self
    }
    func presence(for userID: String, at date: Date = Date()) -> CallPresence {
        guard collectorAvailable, let expiresAt, date.timeIntervalSince1970 < expiresAt else { return .unknown(userID) }
        return members.first { $0.userID == userID } ?? .unknown(userID)
    }
}

struct CallPresence: Decodable, Equatable, Sendable {
    let userID, state: String
    let callCount: Int
    let peerNumber, peerUserID, direction: String?
    enum CodingKeys: String, CodingKey {
        case state, direction
        case userID = "user_id", callCount = "call_count", peerNumber = "peer_number", peerUserID = "peer_user_id"
    }
    static func unknown(_ userID: String) -> Self {
        Self(userID:userID, state:"unknown", callCount:0, peerNumber:nil, peerUserID:nil, direction:nil)
    }
    var valid: Bool {
        guard ["idle","busy","ringing","dialing","unknown"].contains(state), (0...1000).contains(callCount),
              peerNumber == nil || Self.validNumber(peerNumber!),
              peerUserID == nil || peerNumber != nil else { return false }
        if state != "busy" { return callCount == 0 && peerNumber == nil && peerUserID == nil && direction == nil }
        if callCount == 1 { return direction == "incoming" || direction == "outgoing" }
        return callCount > 1 && peerNumber == nil && peerUserID == nil && direction == nil
    }
    static func validNumber(_ number: String) -> Bool {
        let digits = number.hasPrefix("+") ? number.dropFirst() : Substring(number)
        return (2...32).contains(digits.count) && digits.utf8.allSatisfy({ (48...57).contains($0) })
    }
    var label: String {
        switch state {
        case "idle": "Frei"
        case "busy": "Telefoniert"
        case "ringing": "Klingelt"
        case "dialing": "Ruft an"
        default: "Telefonstatus unbekannt"
        }
    }
}

extension TeamSnapshot {
    /// A saved team favorite remains bound to its company, never just an extension.
    func presenceMember(for contact: Contact) -> TeamMember? {
        if contact.id.hasPrefix("team:") {
            return members.first { $0.callContact(tenantID:tenantID)?.id == contact.id }
        }
        let matches = members.filter { $0.number == contact.number }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct PersonalAvailability: Decodable, Equatable, Sendable {
    let state: String
    let description: String
    let workMode: String
    let validUntil: Double?
    let nextAvailableAt: String?
    enum CodingKeys: String, CodingKey {
        case state, description
        case workMode = "work_mode", validUntil = "valid_until", nextAvailableAt = "next_available_at"
    }
    static let statusNames = ["available":"Verfügbar", "busy":"Beschäftigt", "away":"Abwesend",
        "off_duty":"Nicht im Dienst", "vacation":"Urlaub", "do_not_disturb":"Nicht stören"]
    static let modeNames = ["office":"Büro", "home_office":"Homeoffice", "mobile":"Mobil", "custom":"Benutzerdefiniert"]
    var label: String { Self.statusNames[state] ?? state }
}

struct AvailabilitySnapshot: Decodable, Sendable {
    let schemaVersion: Int
    let tenantID, userID, selfUserID: String
    let revision: Int
    let settings: Settings
    let effective: Effective
    let callTeams: [CallTeam]
    let personalDevices: [Device]
    let standaloneDevices: [Device]
    let schedules: [Schedule]
    let company: Company
    let profilesAvailable: Bool?
    let deviceProfilesVersion: Int?
    enum CodingKeys: String, CodingKey {
        case revision, settings, effective, schedules, company
        case profilesAvailable = "profiles_available", deviceProfilesVersion = "device_profiles_version"
        case schemaVersion = "schema_version", tenantID = "tenant_id", userID = "user_id", selfUserID = "self_user_id"
        case callTeams = "call_teams", personalDevices = "personal_devices", standaloneDevices = "standalone_devices"
    }
    struct Company: Decodable, Sendable {
        let routingEnabled: Bool
        enum CodingKeys: String, CodingKey { case routingEnabled = "routing_enabled" }
    }
    struct Settings: Decodable, Sendable {
        let presence: Presence?
        let workMode: String
        let modeDevices: [String:[String]]
        let scheduleID: String?
        let deviceProfiles: [DeviceProfile]?
        let activeProfileID: String?
        var profiles: [DeviceProfile] { deviceProfiles ?? [.standard] }
        var activeProfile: DeviceProfile { profiles.first { $0.id == (activeProfileID ?? "standard") } ?? .standard }
        enum CodingKeys: String, CodingKey {
            case presence
            case workMode = "work_mode", modeDevices = "mode_devices", scheduleID = "schedule_id"
            case deviceProfiles = "device_profiles", activeProfileID = "active_profile_id"
        }
    }
    struct DeviceProfile: Codable, Identifiable, Equatable, Sendable {
        let id: String
        var name: String
        var deviceIDs: [String]?
        static let standard = DeviceProfile(id:"standard",name:"Standard",deviceIDs:nil)
        var isStandard: Bool { id == "standard" }
        enum CodingKeys: String, CodingKey { case id, name; case deviceIDs = "device_ids" }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy:CodingKeys.self)
            try container.encode(id,forKey:.id); try container.encode(name,forKey:.name)
            if let deviceIDs { try container.encode(deviceIDs,forKey:.deviceIDs) }
            else { try container.encodeNil(forKey:.deviceIDs) }
        }
        var requestValue: [String:Any] { ["id":id,"name":name,"device_ids":deviceIDs as Any? ?? NSNull()] }
    }
    var ownDevices: [Device] { personalDevices.filter { $0.userID == userID } }
    var profilesValid: Bool {
        let profiles = settings.profiles, ids = profiles.map(\.id), own = Set(ownDevices.map(\.id))
        return (deviceProfilesVersion == nil || deviceProfilesVersion == 1) && (1...20).contains(profiles.count)
            && Set(ids).count == ids.count && profiles.contains(.standard)
            && ids.contains(settings.activeProfileID ?? "standard")
            && profiles.allSatisfy { p in
                !p.name.isEmpty && p.name.count <= 50 && (p.isStandard ? p == .standard :
                    p.deviceIDs.map { Set($0).isSubset(of:own) && Set($0).count == $0.count } == true)
            }
    }
    struct Presence: Decodable, Sendable {
        let state, description: String
        let validUntil: Double?
        enum CodingKeys: String, CodingKey { case state, description; case validUntil = "valid_until" }
    }
    struct Effective: Decodable, Sendable {
        let eligible: Bool
        let reasonText: String
        let nextAvailableAt: String?
        let effectiveDevices: [Device]?
        let presence: Presence?
        enum CodingKeys: String, CodingKey {
            case eligible, presence
            case reasonText = "reason_text", nextAvailableAt = "next_available_at", effectiveDevices = "effective_devices"
        }
    }
    struct Device: Decodable, Identifiable, Sendable {
        let id, name: String
        let userID: String?
        let technicalStatus: String?
        let enabled: Bool?
        enum CodingKeys: String, CodingKey { case id, name, enabled; case userID = "user_id", technicalStatus = "technical_status" }
    }
    struct CallTeam: Decodable, Identifiable, Sendable {
        let id, name, `extension`: String
        let allowSelfPause: Bool
        let members: [Member]
        enum CodingKeys: String, CodingKey { case id, name, `extension`, members; case allowSelfPause = "allow_self_pause" }
    }
    struct Member: Decodable, Sendable {
        let targetType, targetID: String
        let revision: Int
        let temporaryPauseUntil: Double?
        let effective: Effective
        enum CodingKeys: String, CodingKey {
            case revision, effective
            case targetType = "target_type", targetID = "target_id", temporaryPauseUntil = "temporary_pause_until"
        }
    }
    struct Schedule: Decodable, Identifiable, Sendable {
        let id, name: String
        let definition: Definition
        struct Definition: Decodable, Sendable {
            let timezone: String
            let weeklyRules: [String:[[String]]]
            let exceptionRules: [String:[[String]]]
            let holidayRules: [String]
            enum CodingKeys: String, CodingKey { case timezone; case weeklyRules = "weekly_rules", exceptionRules = "exception_rules", holidayRules = "holiday_rules" }
        }
    }
}
