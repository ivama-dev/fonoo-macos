#!/usr/bin/env python3
"""Exercise the actual shared sync controller with isolated caches and a fake API."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Shared/CustomerAccount.swift').read_text()
controller = source[source.index('@MainActor\nprivate final class CloudCallHistorySync'):]
stub = r'''
import Foundation
import CryptoKit
@MainActor final class CallManager {
    var recents: [RecentCall] = []
    var historyStatus = ""
    var notice: String?
    var onHistoryRefresh: (() -> Void)?
    var onHistoryDelete: ((Set<UUID>) -> Void)?
    func setCloudHistoryContext(_ enabled: Bool) { recents = []; historyStatus = enabled ? "Loading" : "" }
    func applyCloudHistory(_ entries: [RecentCall], status: String) { recents = entries; historyStatus = status }
    func setCloudHistoryStatus(_ status: String) { historyStatus = status }
    func show(_ message: String) { notice = message }
}
'''
checks = r'''
private extension CloudCallHistorySync {
    func selectForChecks(_ value: Context?) { setContext(value); polling?.cancel(); polling = nil }
    func refreshForChecks() async { await refresh() }
    func removeForChecks(_ ids: Set<UUID>) async { await remove(ids) }
    func pathForChecks(_ value: Context) -> URL { cacheURL(value) }
}
@MainActor private final class Backend {
    var response: CloudHistoryPayload!
    var offline = false
    var suspend = false
    var waiting: CheckedContinuation<CloudHistoryPayload, Error>?
    var deleted: Set<UUID> = []
    func read(_ tenant: String, _ revision: Int64?) async throws -> CloudHistoryPayload {
        if offline { throw URLError(.notConnectedToInternet) }
        if suspend { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return response
    }
    func delete(_ tenant: String, _ ids: Set<UUID>) async throws -> CloudHistoryPayload {
        if offline { throw URLError(.notConnectedToInternet) }
        deleted = ids
        response = CloudHistoryPayload(schema_version: 1, tenant_id: tenant, self_user_id: response.self_user_id,
            revision: response.revision + 1, not_modified: false, collector_available: true,
            last_collected_at: response.last_collected_at, entries: response.entries.filter { !ids.contains(UUID(uuidString: $0.id)!) })
        return response
    }
}
@main struct HistorySyncChecks {
    @MainActor static func main() async throws {
        let cache = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let backend = Backend(), manager = CallManager(), otherDevice = CallManager()
        let a = CloudCallHistorySync.Context(user: "own-user", tenant: "company-a")
        let b = CloudCallHistorySync.Context(user: "own-user", tenant: "company-b")
        let id = UUID(), now = Int64(Date().timeIntervalSince1970) - 30
        func payload(_ context: CloudCallHistorySync.Context, revision: Int64 = 2, unchanged: Bool = false,
                     available: Bool = true) -> CloudHistoryPayload {
            CloudHistoryPayload(schema_version: 1, tenant_id: context.tenant, self_user_id: context.user,
                revision: revision, not_modified: unchanged, collector_available: available, last_collected_at: now,
                entries: unchanged ? [] : [.init(id: id.uuidString, number: "505", incoming: true,
                    started_at: now, duration_seconds: 12, outcome: "completed")])
        }
        let sync = CloudCallHistorySync(manager: manager, cacheDirectory: cache,
            read: backend.read, delete: backend.delete)
        backend.response = payload(a)
        sync.selectForChecks(a)
        await sync.refreshForChecks()
        precondition(manager.recents.count == 1 && manager.recents[0].id == id)
        let attributes = try FileManager.default.attributesOfItem(atPath: sync.pathForChecks(a).path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        backend.response = payload(a, unchanged: true)
        await sync.refreshForChecks()
        precondition(manager.recents.count == 1)
        backend.offline = true
        await sync.refreshForChecks()
        precondition(manager.recents.count == 1 && manager.historyStatus.contains("gespeicherter Stand"))
        let second = CloudCallHistorySync(manager: otherDevice, cacheDirectory: cache,
            read: backend.read, delete: backend.delete)
        second.selectForChecks(a)
        precondition(otherDevice.recents.count == 1 && otherDevice.recents[0].id == id)
        await sync.removeForChecks([id])
        precondition(manager.recents.count == 1 && manager.notice != nil)
        backend.offline = false
        backend.response = payload(a)
        await sync.removeForChecks([id])
        precondition(manager.recents.isEmpty && backend.deleted == [id])
        await second.refreshForChecks()
        precondition(otherDevice.recents.isEmpty)
        backend.response = payload(a, revision: 1)
        await sync.refreshForChecks()
        precondition(manager.recents.isEmpty, "Older response resurrected a deleted call")
        backend.suspend = true
        let pending = Task { await sync.refreshForChecks() }
        while backend.waiting == nil { await Task.yield() }
        sync.selectForChecks(b)
        backend.waiting!.resume(returning: payload(a))
        backend.waiting = nil
        await pending.value
        precondition(manager.recents.isEmpty, "Old-company response leaked into new context")
        backend.suspend = false
        backend.response = payload(a)
        await sync.refreshForChecks()
        precondition(manager.recents.isEmpty, "Foreign-company payload accepted")
        backend.response = payload(b)
        await sync.refreshForChecks()
        precondition(manager.recents.count == 1 && sync.pathForChecks(a) != sync.pathForChecks(b))
        sync.selectForChecks(nil)
        precondition(manager.recents.isEmpty && manager.historyStatus.isEmpty)
        print("PASS: shared IDs, protected offline cache, unchanged revisions, deletion across clients, stale response/account isolation and logout")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='fonoo-history-sync-') as directory:
    folder = Path(directory)
    harness = folder / 'HistorySyncChecks.swift'
    harness.write_text(stub + controller + checks)
    binary = folder / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'module-cache'),
        str(root / 'Shared/CallSession.swift'), str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'cache')], check=True, timeout=15)
