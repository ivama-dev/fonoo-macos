import Foundation
@main struct CallHistoryChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CallHistoryStore(url: folder.appendingPathComponent("history.json"))
        let empty = try store.load(); assert(empty.isEmpty)
        let contact = Contact(id: "500", name: "Test", role: "Intern", number: "+431234")
        let base = Date(timeIntervalSince1970: 1_790_250_000)
        let missed1 = RecentCall(contact: contact, date: base, detail: "Verpasst", missed: true)
        let missed2 = RecentCall(contact: contact, date: base.addingTimeInterval(-30), detail: "Verpasst", missed: true)
        let answered = RecentCall(contact: contact, date: base.addingTimeInterval(-60), detail: "Eingehend")
        let missed3 = RecentCall(contact: contact, date: base.addingTimeInterval(-90), detail: "Verpasst", missed: true)
        let yesterday = RecentCall(contact: contact, date: base.addingTimeInterval(-86400), detail: "Verpasst", missed: true)
        let grouped = RecentCallGroup.grouped([missed1, missed2, answered, missed3, yesterday])
        assert(grouped.count == 4 && grouped[0].calls.count == 2)
        assert(grouped.flatMap(\.calls).count == 5)
        let sections = RecentCallDay.sections([missed1, missed2, answered, missed3, yesterday], missedOnly: true)
        assert(sections.count == 2 && sections[0].groups.count == 2)
        assert(sections[0].groups[0].calls.count == 2 && sections[0].groups[1].calls.count == 1)
        assert(RecentCallDay.sections([], missedOnly: false).isEmpty)
        let calls = (0..<105).map { RecentCall(contact: contact, date: Date(timeIntervalSince1970: Double(1000-$0)), detail: "Verpasst", missed: true) }
        try store.save(calls)
        let restored = try CallHistoryStore(url: store.url).load()
        assert(restored.count == 100 && restored[0].id == calls[0].id)
        assert(restored[0].contact == contact && restored[0].missed)
        assert(restored[99].date == calls[99].date)
        // Archives created before duration/direction were added must remain readable.
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        var rows = legacy["calls"] as! [[String: Any]]
        rows[0].removeValue(forKey: "incoming"); rows[0].removeValue(forKey: "duration")
        legacy["calls"] = rows
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        let old = try store.load()
        assert(old[0].incoming == nil && old[0].duration == nil)
        let completed = RecentCall(contact: contact, date: Date(), detail: "Ausgehend", incoming: false, duration: 125)
        try store.save([completed])
        let withDuration = try store.load()
        assert(withDuration[0].duration == 125 && withDuration[0].incoming == false)
        let favorites = FavoritesStore(url: folder.appendingPathComponent("favorites.json"))
        try favorites.save([contact])
        let savedFavorites = try FavoritesStore(url: favorites.url).load()
        assert(savedFavorites == [contact])
        try favorites.save([])
        let removedFavorites = try favorites.load(); assert(removedFavorites.isEmpty)
        try store.save([])
        let cleared = try store.load(); assert(cleared.isEmpty)
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: store.url)
        do { _ = try store.load(); fatalError("Corrupt history accepted") } catch {}
        let preserved = try Data(contentsOf: store.url); assert(preserved == corrupt)
        print("History checks passed: restart, stable IDs, metadata, cap, legacy archives, duration, favorites, empty and corrupt archive")
    }
}
