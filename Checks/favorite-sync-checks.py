#!/usr/bin/env python3
"""Exercise the real favorites methods and sync worker with isolated files/accounts."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
if not (root / 'Shared').is_dir(): root = root.parent
sources = root / 'Shared' if (root / 'Shared').is_dir() else root / 'ios/Fonoo' 
phone = (sources / 'PhoneStore.swift').read_text()
methods = phone[phone.index('    /// Capture the pre-upgrade account'):].rsplit('}', 1)[0]
customer = (sources / 'CustomerAccount.swift').read_text()
worker = customer[customer.index('@MainActor\nprivate final class CloudFavoritesSync'):customer.index('/// Shared by the iPhone and Mac targets through CustomerAccount.swift.')]
stub = r'''
import Foundation
import Combine
@MainActor final class NoticeManager { var notice = ""; func show(_ value: String) { notice = value } }
@MainActor final class PhoneStore {
    var favoriteLibrary: FavoriteLibrary = .empty
    var favoriteSyncStatus = ""
    let objectWillChange = ObservableObjectPublisher()
    var favoriteSyncEnabled = false
    var favoriteConflict = false
    var favoriteEditingError: String?
    var canImportLegacyFavorites: Bool {
        favoriteOwner != nil && favoritesDefaults.string(forKey: "fonoo.favorites.legacyOwner") == ""
            && FileManager.default.fileExists(atPath: legacyFavoritesStore.url.path)
    }
    var favorites: [Contact] { favoriteLibrary.contacts }
    var favoriteGroups: [FavoriteGroup] { favoriteLibrary.groups }
    var onFavoritesChanged: (() -> Void)?
    var onFavoritesRefresh: (() -> Void)?
    private var favoriteState = FavoriteLibraryState(owner: "local")
    private var favoriteOwner: String?
    private var favoriteStore: FavoriteLibraryStore?
    private var favoritePersistence: FavoriteLibraryStore
    private var legacyFavoritesStore: FavoritesStore
    private var favoritesDefaults: UserDefaults
    let manager = NoticeManager()
    init(_ directory: URL, defaults: UserDefaults) {
        favoritePersistence = FavoriteLibraryStore(directory: directory.appendingPathComponent("groups"))
        legacyFavoritesStore = FavoritesStore(url: directory.appendingPathComponent("favorites.json"))
        favoritesDefaults = defaults
        captureLegacyFavoritesOwner()
    }
'''
checks = r'''
private extension CloudFavoritesSync {
    func selectForChecks(_ owner: String?) { setContext(owner); scheduled?.cancel(); polling?.cancel() }
    func runForChecks() async { await refresh(); scheduled?.cancel() }
}
@MainActor final class Backend {
    var snapshots: [String: CloudFavoriteSnapshot] = [:]
    var offline = false, pauseRead = false, pauseWrite = false
    var readWait: CheckedContinuation<CloudFavoriteSnapshot, Error>?
    var writeWait: CheckedContinuation<CloudFavoriteSnapshot, Error>?
    var writes = 0
    var racingWrites = 0
    func read(_ owner: String) async throws -> CloudFavoriteSnapshot {
        if offline { throw URLError(.notConnectedToInternet) }
        if pauseRead { return try await withCheckedThrowingContinuation { readWait = $0 } }
        return snapshots[owner] ?? CloudFavoriteSnapshot(schema_version: 1, user_id: owner, revision: 0, library: .empty)
    }
    func write(_ owner: String, _ revision: Int64, _ library: FavoriteLibrary) async throws -> CloudFavoriteSnapshot {
        let current = try await read(owner)
        if racingWrites > 0 {
            racingWrites -= 1
            var library = current.library; try library.addGroup("Race " + String(current.revision))
            snapshots[owner] = CloudFavoriteSnapshot(schema_version: 1, user_id: owner, revision: current.revision + 1, library: library)
            throw FavoriteError.serverConflict
        }
        precondition(current.revision == revision)
        writes += 1
        let saved = CloudFavoriteSnapshot(schema_version: 1, user_id: owner, revision: revision + 1, library: library)
        snapshots[owner] = saved
        if pauseWrite { return try await withCheckedThrowingContinuation { writeWait = $0 } }
        return saved
    }
}
@main struct FavoriteSyncChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "fonoo.favorite.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = root.appendingPathComponent("one"), second = root.appendingPathComponent("two")
        let legacy = FavoritesStore(url: first.appendingPathComponent("favorites.json"))
        let contact = Contact(id: "example", name: "Example", role: "work", number: "101")
        try legacy.save([contact])
        let before = try Data(contentsOf: legacy.url)
        defaults.set(["account_id": "user-a"], forKey: "fonoo.cloud.selected.v2")
        defaults.set(false, forKey: "fonoo.favorites.sync.user-a")
        let phone = PhoneStore(first, defaults: defaults), backend = Backend()
        phone.selectFavoriteOwner("user-a", importLegacy: true)
        assert(phone.favoriteSyncEnabled)
        assert(phone.favorites == [contact])
        phone.createFavoriteGroup("Work")
        let worker = CloudFavoritesSync(phone: phone, read: backend.read, write: backend.write)
        worker.selectForChecks("user-a"); phone.onFavoritesChanged = nil
        await worker.runForChecks()
        assert(phone.favoriteSyncStatus == "Mit deinem fonu-Konto synchronisiert")
        let intact = try Data(contentsOf: legacy.url); assert(before == intact)
        print("PASS: legacy favorites adopted once for confirmed owner, original file preserved and cloud synced")

        phone.selectFavoriteOwner("user-b", importLegacy: true)
        assert(phone.favorites.isEmpty && phone.favoriteGroups.count == 1)
        phone.clearFavoriteContext(); assert(phone.favorites.isEmpty)
        phone.createFavoriteGroup("Blocked"); assert(phone.favoriteGroups.count == 1)
        phone.selectFavoriteOwner("user-a")
        assert(phone.favorites == [contact] && phone.favoriteGroups[1].name == "Work")
        print("PASS: another user cannot inherit legacy favorites; logout hides library and blocks writes")

        backend.offline = true
        phone.createFavoriteGroup("Family")
        await worker.runForChecks()
        assert(phone.favoriteSyncStatus.contains("fehlgeschlagen") && phone.favoriteGroups.count == 3)
        let reopened = PhoneStore(first, defaults: defaults); reopened.selectFavoriteOwner("user-a")
        assert(reopened.favoriteLibrary == phone.favoriteLibrary)
        backend.offline = false; await worker.runForChecks()
        let other = PhoneStore(second, defaults: defaults); other.selectFavoriteOwner("user-a")
        let otherWorker = CloudFavoritesSync(phone: other, read: backend.read, write: backend.write)
        otherWorker.selectForChecks("user-a"); other.onFavoritesChanged = nil
        await otherWorker.runForChecks()
        assert(other.favoriteLibrary == phone.favoriteLibrary)
        print("PASS: offline edits survive restart and become visible on the second device")

        other.createFavoriteGroup("Other device"); await otherWorker.runForChecks()
        phone.renameFavoriteGroup(phone.favoriteGroups[1].id, name: "Office")
        let writes = backend.writes; await worker.runForChecks()
        assert(!phone.favoriteConflict && backend.writes == writes + 1 && phone.favoriteGroups[1].name == "Office")
        await otherWorker.runForChecks()
        assert(!phone.favoriteConflict && phone.favoriteLibrary == other.favoriteLibrary)
        assert(phone.favoriteGroups.contains { $0.name == "Other device" })
        print("PASS: simultaneous device changes converge automatically without a synchronization toggle or merge button")

        phone.createFavoriteGroup("Race edit"); backend.racingWrites = 2
        await worker.runForChecks(); await otherWorker.runForChecks()
        assert(backend.racingWrites == 0 && phone.favoriteLibrary == other.favoriteLibrary)
        phone.createFavoriteGroup("Pending race"); backend.racingWrites = 4
        await worker.runForChecks()
        assert(backend.racingWrites == 1 && phone.favoriteSyncStatus.contains("ausstehend"))
        backend.racingWrites = 0; await worker.runForChecks(); await otherWorker.runForChecks()
        assert(phone.favoriteLibrary == other.favoriteLibrary)
        print("PASS: CAS races retry automatically with a strict bound and recover on the next poll")

        phone.createFavoriteGroup("Before upload")
        backend.pauseWrite = true
        let upload = Task { @MainActor in await worker.runForChecks() }
        for _ in 0..<200 where backend.writeWait == nil { await Task.yield() }
        assert(backend.writeWait != nil)
        phone.createFavoriteGroup("During upload")
        let accepted = backend.snapshots["user-a"]!
        backend.pauseWrite = false; backend.writeWait?.resume(returning: accepted); backend.writeWait = nil
        await upload.value
        assert(phone.favoriteGroups.contains { $0.name == "During upload" })
        await worker.runForChecks(); await otherWorker.runForChecks()
        assert(other.favoriteGroups.contains { $0.name == "During upload" })
        print("PASS: edits arriving during an upload remain queued and are uploaded next")

        let transient = Contact(id: "transient", name: "Transient", role: "work", number: "105")
        phone.toggleFavorite(transient); backend.pauseWrite = true
        let uncertain = Task { @MainActor in await worker.runForChecks() }
        for _ in 0..<200 where backend.writeWait == nil { await Task.yield() }
        assert(backend.writeWait != nil)
        phone.toggleFavorite(transient)
        var newer = backend.snapshots["user-a"]!.library; try newer.addGroup("After lost reply")
        backend.snapshots["user-a"] = CloudFavoriteSnapshot(schema_version: 1, user_id: "user-a",
            revision: backend.snapshots["user-a"]!.revision + 1, library: newer)
        backend.pauseWrite = false; backend.writeWait?.resume(throwing: URLError(.networkConnectionLost)); backend.writeWait = nil
        await uncertain.value; await worker.runForChecks(); await otherWorker.runForChecks()
        assert(!phone.favorites.contains { $0.id == transient.id } && phone.favoriteLibrary == other.favoriteLibrary)
        assert(phone.favoriteGroups.contains { $0.name == "After lost reply" })
        print("PASS: deletion after a lost upload response cannot resurrect a newly created favorite")

        backend.pauseRead = true
        let old = Task { @MainActor in await worker.runForChecks() }
        for _ in 0..<200 where backend.readWait == nil { await Task.yield() }
        assert(backend.readWait != nil)
        let obsolete = backend.snapshots["user-a"]!
        phone.clearFavoriteContext(); phone.selectFavoriteOwner("user-b"); worker.selectForChecks("user-b")
        backend.pauseRead = false; backend.readWait?.resume(returning: obsolete); backend.readWait = nil
        await old.value
        assert(phone.favorites.isEmpty && phone.favoriteGroups.count == 1)
        assert(phone.favoriteSyncEnabled)
        await worker.runForChecks()
        assert(phone.favoriteGroups.count == 1)
        print("PASS: late old-account callbacks cannot replace a new account's library")

        let store = FavoriteLibraryStore(directory: first.appendingPathComponent("groups"))
        let corrupt = Data("invalid".utf8); try corrupt.write(to: store.url(owner: "user-b"))
        let broken = PhoneStore(first, defaults: defaults); broken.selectFavoriteOwner("user-b")
        broken.createFavoriteGroup("Do not overwrite")
        let retained = try Data(contentsOf: store.url(owner: "user-b")); assert(retained == corrupt)
        print("PASS: corrupted local archive stays read-only and intact")
        let unknownSuite = suite + ".unknown", unknownDefaults = UserDefaults(suiteName: unknownSuite)!
        defer { unknownDefaults.removePersistentDomain(forName: unknownSuite) }
        let unknownFolder = root.appendingPathComponent("unknown")
        try FavoritesStore(url: unknownFolder.appendingPathComponent("favorites.json")).save([contact])
        let unknown = PhoneStore(unknownFolder, defaults: unknownDefaults)
        unknownDefaults.set(["account_id": "user-new"], forKey: "fonoo.cloud.selected.v2")
        unknown.selectFavoriteOwner("user-new", importLegacy: true)
        assert(unknown.favorites.isEmpty)
        unknown.importLegacyFavorites()
        assert(unknown.favorites == [contact])
        unknown.clearFavoriteContext(); unknown.selectFavoriteOwner("another-user", importLegacy: true)
        assert(unknown.favorites.isEmpty)
        print("PASS: unknown legacy owner never migrates after a later login; explicit adoption stays personal")
        worker.selectForChecks(nil); otherWorker.selectForChecks(nil)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='fonoo-favorite-checks-') as directory:
    temp = Path(directory)
    source = temp / 'Checks.swift'
    source.write_text(stub + methods + '}\n' + worker + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(temp / 'modules'),
                    str(sources / 'CallSession.swift'), str(sources / 'FavoriteGroups.swift'),
                    str(source), '-o', str(temp / 'Checks')], check=True)
    subprocess.run([str(temp / 'Checks'), str(temp / 'cache')], check=True)
