import Foundation

struct Contact: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let role: String
    let number: String
    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    static let examples = [
        Contact(id: "201", name: "Anna Berger", role: "Empfang", number: "201"),
        Contact(id: "204", name: "Lukas Weber", role: "Vertrieb", number: "204"),
        Contact(id: "208", name: "Sarah Hofer", role: "Buchhaltung", number: "208"),
        Contact(id: "212", name: "Thomas Gruber", role: "Technik", number: "212")
    ]
}

enum CallPhase: Equatable { case incoming, connecting, ringing, active, ending }

struct CallSession: Identifiable, Equatable {
    let id: UUID
    var original: Contact
    var startedAt = Date()
    var incoming = false
    var phase: CallPhase = .connecting
    var isMuted = false
    var isHeld = false
    var isRemoteHeld = false
    var holdPending = false
    var connectedAt: Date?
    var tones = ""
    var declined = false
    var displayedContact: Contact { original }
}

struct RecentCall: Identifiable, Codable {
    var id = UUID()
    let contact: Contact
    let date: Date
    let detail: String
    var missed = false
    var incoming: Bool? = nil
    var duration: TimeInterval? = nil
}

/// The same account history contract is consumed by iOS, macOS and Windows.
struct CloudHistoryPayload: Codable, Sendable {
    let schema_version: Int
    let tenant_id, self_user_id: String
    let revision: Int64
    let not_modified: Bool
    let collector_available: Bool
    let last_collected_at: Int64
    let entries: [Entry]
    struct Entry: Codable, Sendable {
        let id, number: String
        let incoming: Bool
        let started_at: Int64
        let duration_seconds: Int
        let outcome: String
    }
    func validated(tenant: String, user: String) throws -> [RecentCall] {
        guard schema_version == 1, tenant_id == tenant, self_user_id == user, revision >= 0,
              entries.count <= 500, !not_modified || entries.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var ids = Set<UUID>()
        return try entries.map { entry in
            guard let id = UUID(uuidString: entry.id), ids.insert(id).inserted,
                  entry.number == "anonymous" || entry.number.range(of: #"^\+?[0-9*#]{1,64}$"#, options: .regularExpression) != nil,
                  entry.started_at > 0, entry.started_at <= Int64(Date().timeIntervalSince1970) + 60,
                  (0...604800).contains(entry.duration_seconds), ["completed","missed","failed"].contains(entry.outcome),
                  entry.outcome != "missed" || entry.incoming,
                  entry.outcome == "completed" || entry.duration_seconds == 0 else { throw CocoaError(.fileReadCorruptFile) }
            let title = entry.number == "anonymous" ? "Unbekannte Rufnummer" : entry.number
            let detail = entry.outcome == "missed" ? "Verpasst" : entry.outcome == "failed" ? "Fehlgeschlagen" : entry.incoming ? "Eingehend" : "Ausgehend"
            return RecentCall(id: id, contact: Contact(id: entry.id, name: title, role: "Anruf", number: entry.number),
                              date: Date(timeIntervalSince1970: TimeInterval(entry.started_at)), detail: detail,
                              missed: entry.outcome == "missed", incoming: entry.incoming, duration: TimeInterval(entry.duration_seconds))
        }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }
}

/// Bounded local history; atomic writes keep the previous file intact on failure.
struct CallHistoryStore {
    let url: URL
    static var local: CallHistoryStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CallHistoryStore(url: directory.appendingPathComponent("Fonoo", isDirectory: true).appendingPathComponent("call-history.json"))
    }
    private struct Archive: Codable {
        let version: Int
        let calls: [RecentCall]
    }
    func load() throws -> [RecentCall] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return Array(archive.calls.prefix(100))
    }
    func save(_ calls: [RecentCall]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Archive(version: 1, calls: Array(calls.prefix(100))))
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

/// Favorites are independent of SIP credentials and survive app restarts.
struct FavoritesStore {
    let url: URL
    static var local: FavoritesStore {
        FavoritesStore(url: CallHistoryStore.local.url.deletingLastPathComponent().appendingPathComponent("favorites.json"))
    }
    func load() throws -> [Contact] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Contact].self, from: Data(contentsOf: url))
    }
    func save(_ contacts: [Contact]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(contacts)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

struct RecentCallGroup: Identifiable {
    var calls: [RecentCall]
    var id: UUID { calls[0].id }
    var latest: RecentCall { calls[0] }
    static func grouped(_ calls: [RecentCall], calendar: Calendar = .current) -> [RecentCallGroup] {
        var groups: [RecentCallGroup] = []
        for call in calls.sorted(by: { $0.date > $1.date }) {
            if call.missed, let last = groups.last, last.latest.missed,
               last.latest.contact.number == call.contact.number,
               calendar.isDate(last.latest.date, inSameDayAs: call.date) {
                groups[groups.count - 1].calls.append(call)
            } else { groups.append(RecentCallGroup(calls: [call])) }
        }
        return groups
    }
}

struct RecentCallDay: Identifiable {
    let id: Date
    var groups: [RecentCallGroup]
    static func sections(_ calls: [RecentCall], missedOnly: Bool, calendar: Calendar = .current) -> [RecentCallDay] {
        var days: [RecentCallDay] = []
        // Group before filtering so an answered call still separates missed-call groups.
        for group in RecentCallGroup.grouped(calls, calendar: calendar) {
            guard !missedOnly || group.latest.missed else { continue }
            let day = calendar.startOfDay(for: group.latest.date)
            if days.last?.id == day { days[days.count - 1].groups.append(group) }
            else { days.append(RecentCallDay(id: day, groups: [group])) }
        }
        return days
    }
}
