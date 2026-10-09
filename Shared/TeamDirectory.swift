import Combine
import Foundation

/// Shared iOS/macOS presentation state. Authentication and HTTP remain in CustomerAccount.
@MainActor
final class TeamDirectory: ObservableObject {
    @Published private(set) var context: TeamContext?
    @Published private(set) var snapshot: TeamSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSavingName = false
    @Published private(set) var nameError: String?
    private var generation = 0

    func setContext(_ value: TeamContext?) {
        guard context != value else { return }
        generation += 1
        context = value
        snapshot = nil
        isLoading = false
        errorMessage = nil
        isSavingName = false
        nameError = nil
    }

    func refresh(using load: () async throws -> TeamSnapshot) async {
        guard let context, !isSavingName else { return }
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let result = try await load().validated(for: context)
            try Task.checkCancellation()
            guard request == generation, self.context == context else { return }
            snapshot = result
        } catch is CancellationError {
            return
        } catch {
            guard request == generation, self.context == context else { return }
            // Never leave a removed colleague callable after a failed refresh.
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    func saveName(using save: () async throws -> TeamSnapshot) async {
        guard let context, !isSavingName, !isLoading else { return }
        generation += 1
        let request = generation
        isSavingName = true
        nameError = nil
        defer { if request == generation { isSavingName = false } }
        do {
            let result = try await save().validated(for: context)
            try Task.checkCancellation()
            guard request == generation, self.context == context else { return }
            snapshot = result
        } catch is CancellationError {
            return
        } catch {
            guard request == generation, self.context == context else { return }
            nameError = error.localizedDescription
        }
    }

    func members(matching query: String) -> [TeamMember] {
        (snapshot?.members ?? []).filter { $0.matches(query) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
