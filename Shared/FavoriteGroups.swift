import Foundation
import CryptoKit

struct FavoriteGroup: Identifiable, Codable, Equatable {
    static let generalID = "ungrouped"
    var id: String
    var name: String
    var contacts: [Contact]
    var isGeneral: Bool { id == Self.generalID }
}

enum FavoriteError: LocalizedError {
    case invalid, duplicateName, unavailable, serverConflict
    var errorDescription: String? {
        switch self {
        case .invalid: "Ungültige Favoriten. Gruppennamen dürfen höchstens 80 Zeichen enthalten; maximal 50 Gruppen und 500 Favoriten."
        case .duplicateName: "Eine Gruppe mit diesem Namen gibt es bereits."
        case .unavailable: "Favoriten sind wegen eines Lesefehlers vorübergehend schreibgeschützt. Die gespeicherte Datei bleibt erhalten."
        case .serverConflict: "Favoriten werden mit dem aktuellen Kontostand abgeglichen."
        }
    }
}

struct FavoriteLibrary: Codable, Equatable {
    var groups: [FavoriteGroup]
    static let empty = Self(groups: [.init(id: FavoriteGroup.generalID, name: "Allgemein", contacts: [])])
    var contacts: [Contact] { groups.flatMap(\.contacts) }
    func checked() throws -> Self {
        guard !groups.isEmpty, groups.count <= 50,
              groups.filter(\.isGeneral).count == 1, contacts.count <= 500 else { throw FavoriteError.invalid }
        var ids = Set<String>(), names = Set<String>(), contactIDs = Set<String>()
        func safe(_ text: String, maximum: Int, empty: Bool = false) -> Bool {
            (empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && text.count <= maximum
                && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        for group in groups {
            guard group.isGeneral || UUID(uuidString: group.id) != nil, ids.insert(group.id).inserted,
                  safe(group.name, maximum: 80), group.name == Self.cleanName(group.name) else { throw FavoriteError.invalid }
            guard names.insert(group.name.lowercased()).inserted else { throw FavoriteError.duplicateName }
            for contact in group.contacts {
                guard safe(contact.id, maximum: 256), contactIDs.insert(contact.id).inserted,
                      safe(contact.name, maximum: 256), safe(contact.role, maximum: 128, empty: true),
                      safe(contact.number, maximum: 128) else { throw FavoriteError.invalid }
            }
        }
        guard try JSONEncoder().encode(self).count <= 60_000 else { throw FavoriteError.invalid }
        return self
    }
    static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    mutating func addGroup(_ name: String) throws {
        groups.append(.init(id: UUID().uuidString.lowercased(), name: Self.cleanName(name), contacts: []))
        _ = try checked()
    }
    mutating func renameGroup(_ id: String, name: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }), !groups[index].isGeneral else { throw FavoriteError.invalid }
        groups[index].name = Self.cleanName(name); _ = try checked()
    }
    mutating func deleteGroup(_ id: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }), !groups[index].isGeneral else { throw FavoriteError.invalid }
        let moved = groups.remove(at: index).contacts
        groups[groups.firstIndex(where: \.isGeneral)!].contacts.append(contentsOf: moved)
    }
    mutating func assign(_ contactID: String, to groupID: String) throws {
        guard groups.contains(where: { $0.id == groupID }), let contact = contacts.first(where: { $0.id == contactID }) else { throw FavoriteError.invalid }
        if groups.first(where: { $0.id == groupID })?.contacts.contains(where: { $0.id == contactID }) == true { return }
        for index in groups.indices { groups[index].contacts.removeAll { $0.id == contactID } }
        groups[groups.firstIndex(where: { $0.id == groupID })!].contacts.append(contact)
    }
    mutating func toggle(_ contact: Contact) {
        if contacts.contains(where: { $0.id == contact.id }) {
            for index in groups.indices { groups[index].contacts.removeAll { $0.id == contact.id } }
        } else { groups[groups.firstIndex(where: \.isGeneral)!].contacts.append(contact) }
    }
    mutating func moveGroups(from offsets: IndexSet, to destination: Int) throws {
        groups = try Self.reordered(groups, from: offsets, to: destination)
    }
    mutating func moveContacts(in groupID: String, from offsets: IndexSet, to destination: Int) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { throw FavoriteError.invalid }
        groups[index].contacts = try Self.reordered(groups[index].contacts, from: offsets, to: destination)
    }
    private static func reordered<T>(_ values: [T], from offsets: IndexSet, to destination: Int) throws -> [T] {
        guard (0...values.count).contains(destination), offsets.allSatisfy({ values.indices.contains($0) }) else { throw FavoriteError.invalid }
        var result = values
        let moving = offsets.sorted().map { values[$0] }
        for index in offsets.sorted(by: >) { result.remove(at: index) }
        result.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        return result
    }
    /// Three-way merge against the last confirmed account snapshot. Unchanged
    /// local fields follow the server; pending local edits win a same-field race.
    /// Deletions in either branch win over stale copies, without deleting contacts
    /// when only their group was removed.
    func merging(_ remote: Self, base: Self? = nil, deletedContacts: Set<String> = [], deletedGroups: Set<String> = []) throws -> Self {
        _ = try checked(); _ = try remote.checked()
        let ancestor = try (base ?? .empty).checked()
        let b = Dictionary(uniqueKeysWithValues: ancestor.groups.map { ($0.id, $0) })
        let l = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: remote.groups.map { ($0.id, $0) })
        let removedGroups = Set(b.keys.filter { $0 != FavoriteGroup.generalID && (l[$0] == nil || r[$0] == nil) })
            .union(deletedGroups).subtracting([FavoriteGroup.generalID])
        let groupIDs = Set(l.keys).union(r.keys).subtracting(removedGroups)
        let groupOrder = Self.mergedOrder(base: ancestor.groups.map(\.id), local: groups.map(\.id),
            remote: remote.groups.map(\.id), surviving: groupIDs)
        var result = Self(groups: []), aliases: [String: String] = [:], named: [String: String] = [:]
        for id in groupOrder {
            let name = l[id].map { local in
                b[id]?.name != local.name ? local.name : r[id]?.name ?? local.name
            } ?? r[id]!.name
            // Independently created equal-name groups become one group; entries survive.
            if let same = named[name.lowercased()] { aliases[id] = same; continue }
            named[name.lowercased()] = id; aliases[id] = id
            result.groups.append(.init(id: id, name: name, contacts: []))
        }
        func entries(_ library: Self) -> [String: (Contact, String)] {
            Dictionary(uniqueKeysWithValues: library.groups.flatMap { group in group.contacts.map { ($0.id, ($0, group.id)) } })
        }
        let bc = entries(ancestor), lc = entries(self), rc = entries(remote)
        let removedContacts = Set(bc.keys.filter { lc[$0] == nil || rc[$0] == nil }).union(deletedContacts)
        let contactIDs = Set(lc.keys).union(rc.keys).subtracting(removedContacts)
        var merged: [String: Contact] = [:], membership: [String: String] = [:]
        for id in contactIDs {
            let local = lc[id], other = rc[id], old = bc[id]
            let chosen = local?.0 ?? other!.0
            func field(_ local: String, _ other: String?, _ old: String?) -> String { local != old ? local : other ?? local }
            merged[id] = Contact(id: id,
                name: field(chosen.name, other?.0.name, old?.0.name),
                role: field(chosen.role, other?.0.role, old?.0.role),
                number: field(chosen.number, other?.0.number, old?.0.number))
            let parent = local.map { old?.1 != $0.1 ? $0.1 : other?.1 ?? $0.1 } ?? other!.1
            membership[id] = aliases[parent] ?? FavoriteGroup.generalID
        }
        for index in result.groups.indices {
            let id = result.groups[index].id
            let members = Set(contactIDs.filter { membership[$0] == id })
            let order = Self.mergedOrder(base: ancestor.contacts.map(\.id), local: contacts.map(\.id),
                remote: remote.contacts.map(\.id), surviving: members)
            result.groups[index].contacts = order.compactMap { merged[$0] }
        }
        return try result.checked()
    }
    private static func mergedOrder(base: [String], local: [String], remote: [String], surviving: Set<String>) -> [String] {
        let common = Set(base).intersection(local).intersection(surviving)
        let reordered = local.filter { common.contains($0) } != base.filter { common.contains($0) }
        let primary = reordered ? local : remote, secondary = reordered ? remote : local
        var result = primary.filter { surviving.contains($0) }
        for (offset, id) in secondary.enumerated() where surviving.contains(id) && !result.contains(id) {
            if let previous = secondary[..<offset].last(where: { result.contains($0) }), let index = result.firstIndex(of: previous) {
                result.insert(id, at: index + 1)
            } else if let next = secondary.dropFirst(offset + 1).first(where: { result.contains($0) }), let index = result.firstIndex(of: next) {
                result.insert(id, at: index)
            } else { result.append(id) }
        }
        return result
    }
}

struct CloudFavoriteSnapshot: Codable, Equatable {
    let schema_version: Int
    let user_id: String
    let revision: Int64
    let library: FavoriteLibrary
    func checked(owner: String) throws -> Self {
        guard schema_version == 1, user_id == owner, revision >= 0 else { throw FavoriteError.invalid }
        _ = try library.checked(); return self
    }
}

/// Durable local edits and their last acknowledged cloud base.
struct FavoriteLibraryState: Codable, Equatable {
    let version: Int
    let owner: String
    var library: FavoriteLibrary
    var revision: Int64?
    var base: FavoriteLibrary?
    var attempt: FavoriteLibrary?
    var dirty: Bool
    var conflict: CloudFavoriteSnapshot?
    // Keep explicit offline deletions even when an upload's success response was
    // lost before this device learned that a just-created entry reached the server.
    var deletedContactIDs: Set<String>?
    var deletedGroupIDs: Set<String>?
    init(owner: String, library: FavoriteLibrary = .empty, dirty: Bool = false) {
        self.version = 1; self.owner = owner; self.library = library; self.dirty = dirty
    }
    mutating func observe(_ snapshot: CloudFavoriteSnapshot) throws {
        let remote = try snapshot.checked(owner: owner)
        guard revision == nil || remote.revision >= revision! else { throw FavoriteError.invalid }
        if !dirty || library == remote.library {
            library = remote.library; dirty = false
        } else if base != remote.library, attempt != remote.library,
                  !(revision == nil && remote.library == .empty) {
            library = try library.merging(remote.library, base: base,
                deletedContacts: deletedContactIDs ?? [], deletedGroups: deletedGroupIDs ?? [])
            dirty = library != remote.library
        }
        revision = remote.revision; base = remote.library; attempt = nil; conflict = nil
        if !dirty { deletedContactIDs = nil; deletedGroupIDs = nil }
    }
    mutating func acknowledged(_ snapshot: CloudFavoriteSnapshot, sent: FavoriteLibrary) throws {
        let remote = try snapshot.checked(owner: owner)
        guard remote.library == sent else { throw FavoriteError.invalid }
        revision = remote.revision; base = remote.library; attempt = nil; conflict = nil
        dirty = library != remote.library
        if !dirty { deletedContactIDs = nil; deletedGroupIDs = nil }
    }
    mutating func mergeConflict() throws {
        guard let remote = conflict else { return }
        library = try library.merging(remote.library, base: base,
            deletedContacts: deletedContactIDs ?? [], deletedGroups: deletedGroupIDs ?? [])
        base = remote.library; revision = remote.revision; dirty = library != remote.library; attempt = nil; conflict = nil
    }
}

struct FavoriteLibraryStore {
    let directory: URL
    static var local: Self { Self(directory: CallHistoryStore.local.url.deletingLastPathComponent().appendingPathComponent("favorite-groups-v1", isDirectory: true)) }
    func url(owner: String) -> URL {
        let hash = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func load(owner: String) throws -> FavoriteLibraryState? {
        let file = url(owner: owner)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_000_000 else { throw FavoriteError.invalid }
        let state = try JSONDecoder().decode(FavoriteLibraryState.self, from: data)
        guard state.version == 1, state.owner == owner,
              state.revision == nil || state.revision! >= 0,
              (state.revision == nil) == (state.base == nil) else { throw FavoriteError.invalid }
        _ = try state.library.checked()
        if let base = state.base { _ = try base.checked() }
        if let attempt = state.attempt { _ = try attempt.checked() }
        if let conflict = state.conflict { _ = try conflict.checked(owner: owner) }
        return state
    }
    func save(_ state: FavoriteLibraryState) throws {
        _ = try state.library.checked()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 1_000_000 else { throw FavoriteError.invalid }
        #if os(iOS)
        try data.write(to: url(owner: state.owner), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(owner: state.owner), options: .atomic)
        #endif
    }
}
