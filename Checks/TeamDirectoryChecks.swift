import Foundation

@main
struct TeamDirectoryChecks {
    @MainActor
    static func main() async throws {
        let context = TeamContext(tenantID: "alpha", accountID: "owner", sessionID: UUID())
        let json = #"{"schema_version":1,"tenant_id":"alpha","tenant_name":"Alpha GmbH","revision":3,"self_user_id":"owner","members":[{"id":"anna","name":"Anna Müller","email":"anna@example.at","extension":"101","personal_device_count":2,"personal_devices":[]},{"id":"owner","name":"owner@example.at","email":"owner@example.at","extension":null,"personal_device_count":0,"personal_devices":[]}]}"#
        let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: Data(json.utf8)).validated(for: context)
        let anna = snapshot.members[0]
        precondition(anna.matches("MULLER"))
        precondition(anna.matches("  Anna 101 "))
        precondition(anna.matches("EXAMPLE.AT"))
        precondition(anna.matches(" "))
        precondition(!anna.matches("Anna 999"))
        precondition(anna.callContact(tenantID: "alpha")?.number == "101")
        precondition(anna.callContact(tenantID: "alpha")?.id != anna.callContact(tenantID: "beta")?.id)
        precondition(snapshot.members[1].callContact(tenantID: "alpha") == nil)
        precondition(snapshot.resolvedContact(number: "101")?.name == "Anna Müller")
        precondition(snapshot.resolvedContact(number: "1") == nil)
        precondition(snapshot.resolvedContact(number: "+43101") == nil)
        precondition(snapshot.members.count == 2) // Two personal devices are never two extra people.
        for malformed in [
            json.replacingOccurrences(of: "\"alpha\"", with: "\"beta\""),
            json.replacingOccurrences(of: "\"self_user_id\":\"owner\"", with: "\"self_user_id\":\"other\""),
            json.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2"),
            json.replacingOccurrences(of: "\"extension\":\"101\"", with: "\"extension\":\"sip:secret@host\""),
            json.replacingOccurrences(of: "\"extension\":\"101\"", with: "\"extension\":\"0101\""),
            json.replacingOccurrences(of: "\"id\":\"anna\"", with: "\"id\":\"owner\""),
            json.replacingOccurrences(of: "\"personal_devices\":[]", with: "\"personal_devices\":[{\"id\":\"private\",\"name\":\"Mac\"}]")
        ] {
            do {
                _ = try JSONDecoder().decode(TeamSnapshot.self, from: Data(malformed.utf8)).validated(for: context)
                preconditionFailure("Unsafe response accepted")
            } catch { }
        }
        let directory = TeamDirectory()
        directory.setContext(context)
        await directory.refresh { snapshot }
        precondition(directory.members(matching: "101").map(\.id) == ["anna"])
        precondition(!directory.isLoading && directory.errorMessage == nil)

        // A different tenant/login invalidates rows synchronously, including delayed old responses.
        var reply: CheckedContinuation<TeamSnapshot, Error>?
        let oldRequest = Task { @MainActor in
            await directory.refresh { try await withCheckedThrowingContinuation { reply = $0 } }
        }
        while reply == nil { await Task.yield() }
        directory.setContext(TeamContext(tenantID: "beta", accountID: "owner", sessionID: UUID()))
        precondition(directory.snapshot == nil && !directory.isLoading)
        reply?.resume(returning: snapshot)
        await oldRequest.value
        precondition(directory.snapshot == nil)

        directory.setContext(context)
        reply = nil
        let firstRefresh = Task { @MainActor in
            await directory.refresh { try await withCheckedThrowingContinuation { reply = $0 } }
        }
        while reply == nil { await Task.yield() }
        await directory.refresh { snapshot }
        reply?.resume(throwing: TeamDirectoryError.invalidResponse)
        await firstRefresh.value
        precondition(directory.snapshot == snapshot && directory.errorMessage == nil)

        await directory.refresh { throw TeamDirectoryError.invalidResponse }
        precondition(directory.snapshot == nil && directory.errorMessage != nil && !directory.isLoading)
        await directory.refresh { throw CancellationError() }
        precondition(!directory.isLoading)
        await directory.refresh { snapshot }
        var writes = 0
        await directory.saveName { writes += 1; throw TeamDirectoryError.invalidResponse }
        precondition(writes == 1 && directory.nameError != nil && !directory.isSavingName)
        directory.setContext(nil)
        precondition(directory.snapshot == nil && directory.nameError == nil)
        await directory.refresh { preconditionFailure("Signed-out request") }
        print("PASS: shared Team decoding/search, user-owned devices, extension calls, tenant/login isolation, response races, cancellation and name errors")
    }
}
