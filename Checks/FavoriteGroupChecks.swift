import Foundation

@main
struct FavoriteGroupChecks {
    static func main() throws {
        struct MergeCase: Decodable {
            let name: String, base: FavoriteLibrary, local: FavoriteLibrary, remote: FavoriteLibrary, expected: FavoriteLibrary
            let deleted_contact_ids: Set<String>?
        }
        let cases = try JSONDecoder().decode([MergeCase].self, from: Data(contentsOf: URL(fileURLWithPath: "Checks/favorite-merge-cases.json")))
        for vector in cases {
            let actual = try vector.local.merging(vector.remote, base: vector.base, deletedContacts: vector.deleted_contact_ids ?? [])
            assert(actual == vector.expected, vector.name)
        }
        print("PASS: shared cross-platform merge fixtures (names, fields, deletion, grouping and order)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = Contact(id: "a", name: "Alice", role: "work", number: "101")
        let b = Contact(id: "b", name: "Bob", role: "mobile", number: "102")
        var library = FavoriteLibrary.empty
        library.toggle(a); library.toggle(b)
        try library.addGroup(" Arbeit "); try library.addGroup("Familie")
        let work = library.groups[1].id, family = library.groups[2].id
        try library.assign(a.id, to: work)
        try library.moveGroups(from: [2], to: 0)
        assert(library.groups.map(\.id) == [family, FavoriteGroup.generalID, work])
        try library.deleteGroup(work)
        assert(library.contacts.count == 2 && library.groups.first(where: \.isGeneral)!.contacts == [b, a])
        try library.moveContacts(in: FavoriteGroup.generalID, from: [0], to: 2)
        assert(library.groups.first(where: \.isGeneral)!.contacts == [a, b])
        print("PASS: group order, assignment, contact order and group deletion preserve favorites")

        func rejected(_ work: () throws -> Void) {
            do { try work(); assertionFailure("Invalid data accepted") } catch {}
        }
        rejected { var bad = library; try bad.addGroup("allgemein") }
        rejected { var bad = library; try bad.addGroup("bad\nname") }
        rejected { var bad = library; try bad.moveGroups(from: [99], to: 0) }
        rejected { var bad = library; try bad.moveGroups(from: [0], to: -1) }
        rejected { var bad = library; try bad.deleteGroup(FavoriteGroup.generalID) }
        rejected { var bad = library; bad.groups[0].contacts = [a]; _ = try bad.checked() }
        print("PASS: duplicate names, invalid moves, reserved group and duplicate favorites rejected")

        let store = FavoriteLibraryStore(directory: directory)
        var state = FavoriteLibraryState(owner: "user-a", library: library, dirty: true)
        try store.save(state)
        let savedA = try store.load(owner: "user-a"), savedB = try store.load(owner: "user-b")
        assert(savedA == state); assert(savedB == nil)
        assert(store.url(owner: "../escape").deletingLastPathComponent().path == directory.path)
        rejected { _ = try CloudFavoriteSnapshot(schema_version: 1, user_id: "user-b", revision: 1, library: library).checked(owner: "user-a") }
        print("PASS: durable account caches and wrong-account responses isolated")

        try state.observe(.init(schema_version: 1, user_id: "user-a", revision: 0, library: .empty))
        assert(state.dirty && state.revision == 0 && state.library == library && state.conflict == nil)
        let sent = state.library; state.attempt = sent
        state.library.toggle(Contact(id: "c", name: "Charlie", role: "", number: "103"))
        let acknowledged = CloudFavoriteSnapshot(schema_version: 1, user_id: "user-a", revision: 1, library: sent)
        try state.acknowledged(acknowledged, sent: sent)
        assert(state.dirty && state.library.contacts.count == 3 && state.base == sent)
        print("PASS: migration to empty cloud and edits during upload retained")

        state.attempt = state.library
        let received = CloudFavoriteSnapshot(schema_version: 1, user_id: "user-a", revision: 2, library: state.library)
        try state.observe(received)
        assert(!state.dirty && state.attempt == nil && state.revision == 2)
        state.library.toggle(a); state.dirty = true
        var remote = received.library; try remote.addGroup("Remote"); remote.toggle(Contact(id: "d", name: "Dora", role: "", number: "104"))
        try state.observe(.init(schema_version: 1, user_id: "user-a", revision: 3, library: remote))
        assert(state.conflict == nil && state.dirty && state.revision == 3)
        assert(state.library.contacts.contains(where: { $0.id == "d" }))
        assert(!state.library.contacts.contains(where: { $0.id == a.id }))
        rejected { try state.observe(.init(schema_version: 1, user_id: "user-a", revision: 2, library: remote)) }
        print("PASS: lost response recovery and automatic three-way merge preserve deletions and independent changes")

        let data = Data("corrupt archive".utf8)
        try data.write(to: store.url(owner: "user-a"))
        rejected { _ = try store.load(owner: "user-a") }
        let intact = try Data(contentsOf: store.url(owner: "user-a")); assert(intact == data)
        print("PASS: corrupt cache remains intact")
    }
}
