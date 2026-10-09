import Foundation

@MainActor
private final class EngineFixture: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    var startFails = false, stopFails = false, suspendStop = false, registerFails = false
    var starts = 0, stops = 0, registrations = 0
    var network = true, tracing = false
    var stopContinuation: CheckedContinuation<Void, Never>?
    var sdkVersion: String { "test fixture" }
    var supportsSIPTracing: Bool { true }
    func start() throws { starts += 1; if startFails { throw PhoneError.message("start fixture failure") } }
    func shutdown() async throws {
        stops += 1
        if suspendStop { await withCheckedContinuation { stopContinuation = $0 } }
        onEvent = nil
        if stopFails { stopFails = false; throw PhoneError.message("stop fixture failure") }
    }
    func setSIPTracing(_ enabled: Bool) { tracing = enabled }
    func register(account: SIPAccount, password: String, turnPassword: String) throws {
        registrations += 1
        if registerFails { throw PhoneError.message("registration fixture failure 32") }
    }
    func unregister() throws {}
    func invite(number: String, id: UUID) throws {}
    func answer(id: UUID) throws {}
    func end(id: UUID) throws {}
    func setMuted(_ muted: Bool, id: UUID) throws {}
    func setHeld(_ held: Bool, id: UUID) throws {}
    func sendDTMF(_ digit: String, id: UUID) throws {}
    func selectAudioDevice(id: String) throws {}
    func refreshAudioDevices() {}
    func setNetworkAvailable(_ available: Bool) { network = available }
    func refreshRegistration() {}
}

@main
struct SIPConnectionChecks {
    @MainActor static func main() async throws {
        var created: [EngineFixture] = []
        var failStart = false
        let coordinator = SIPConnectionCoordinator {
            let core = EngineFixture(); core.startFails = failStart
            created.append(core); return core
        }
        var deliveries = 0
        coordinator.onEvent = { _ in deliveries += 1 }
        try coordinator.start()
        precondition(coordinator.running && created.count == 1)
        let first = created[0]
        let stale = first.onEvent!
        let id = UUID()
        for state in [SIPCallState.incoming, .connecting, .ringing, .active, .holding, .held, .resuming, .remoteHeld] {
            first.onEvent?(.call(SIPCallEvent(id: id, number: "", displayName: "", state: state)))
            do { try await coordinator.restart(); preconditionFailure("Switched during live call") } catch {}
            precondition(created.count == 1)
        }
        first.onEvent?(.call(SIPCallEvent(id: id, number: "", displayName: "", state: .ended)))
        first.onEvent?(.transfer(id, .progressing))
        precondition(!coordinator.canRestart)
        first.onEvent?(.transfer(id, .failed(500)))
        var managerBusy = true
        coordinator.isBusy = { managerBusy }
        do { try await coordinator.restart(); preconditionFailure("Switched during push/preparation") } catch {}
        managerBusy = false
        try coordinator.register(account: SIPAccount(), password: "memory-only-fixture", turnPassword: "")
        first.suspendStop = true
        let restarting = Task { try await coordinator.restart() }
        while first.stopContinuation == nil { await Task.yield() }
        precondition(coordinator.restarting && !coordinator.canRestart && created.count == 1)
        let deliveredBefore = deliveries
        stale(.registration(.registered))
        stale(.call(SIPCallEvent(id: UUID(), number: "", displayName: "", state: .incoming)))
        precondition(deliveries == deliveredBefore)
        do { try await coordinator.restart(); preconditionFailure("Concurrent switch") } catch {}
        do { try coordinator.invite(number: "123", id: UUID()); preconditionFailure("Command during shutdown") } catch {}
        coordinator.setNetworkAvailable(false); coordinator.setSIPTracing(true)
        first.stopContinuation?.resume(); first.stopContinuation = nil
        try await restarting.value
        precondition(first.stops == 1 && coordinator.running && created.count == 2)
        precondition(created[1].registrations == 1 && !created[1].network && created[1].tracing)
        try await coordinator.restart()
        precondition(coordinator.running && created[2].registrations == 1)
        failStart = true
        try await expectFailure { try await coordinator.restart() }
        precondition(!coordinator.running && coordinator.failure != nil && created.last!.stops == 1)
        let countAfterFailure = created.count
        do { try coordinator.invite(number: "123", id: UUID()); preconditionFailure("Implicit recovery") } catch {}
        precondition(created.count == countAfterFailure)
        failStart = false
        try await coordinator.restart()
        precondition(coordinator.running && coordinator.failure == nil)
        created.last!.stopFails = true
        let countBeforeStopFailure = created.count
        try await expectFailure { try await coordinator.restart() }
        precondition(created.count == countBeforeStopFailure && !coordinator.running)
        try await coordinator.restart()
        precondition(coordinator.running)
        created.last!.onEvent?(.engineStopped("native loop stopped"))
        precondition(!coordinator.running && coordinator.failure == "native loop stopped")
        do { try coordinator.invite(number: "123", id: UUID()); preconditionFailure("Restarted after native loop loss") } catch {}
        try await coordinator.restart()
        precondition(coordinator.running && coordinator.failure == nil)
        // A failed REGISTER outside a switch must not make same-engine retry a no-op.
        let failedRegistrationCore = created.last!
        failedRegistrationCore.registerFails = true
        do { try coordinator.register(account: SIPAccount(), password: "retry-test-secret", turnPassword: ""); preconditionFailure("REGISTER should fail") } catch {}
        precondition(coordinator.failure != nil && coordinator.canRestart)
        let deliveriesAfterRegisterFailure = deliveries
        failedRegistrationCore.onEvent?(.registration(.offline))
        failedRegistrationCore.onEvent?(.registration(.registered))
        precondition(deliveries == deliveriesAfterRegisterFailure)
        let countBeforeRegisterRetry = created.count
        do { try coordinator.invite(number: "123", id: UUID()); preconditionFailure("Call after failed REGISTER") } catch {}
        try await coordinator.restart()
        precondition(created.count == countBeforeRegisterRetry + 1 && failedRegistrationCore.stops == 1)
        precondition(created.last!.registrations == 1 && coordinator.failure == nil)
        // A push/foreground profile request may retry a rejected REGISTER on
        // the same live loop; a call must never trigger recovery itself.
        let retryCore = created.last!
        retryCore.registerFails = true
        do { try coordinator.register(account: SIPAccount(), password: "push-retry-fixture", turnPassword: ""); preconditionFailure("Expected rejection") } catch {}
        do { try coordinator.invite(number: "123", id: UUID()); preconditionFailure("Call bypassed failed registration") } catch {}
        retryCore.registerFails = false
        let adaptersBeforeRetry = created.count, stopsBeforeRetry = retryCore.stops
        try coordinator.register(account: SIPAccount(), password: "push-retry-fixture", turnPassword: "")
        precondition(coordinator.failure == nil && created.count == adaptersBeforeRetry && retryCore.stops == stopsBeforeRetry)
        retryCore.onEvent?(.engineStopped("loop actually stopped"))
        do { try coordinator.register(account: SIPAccount(), password: "push-retry-fixture", turnPassword: ""); preconditionFailure("Profile restarted a stopped loop") } catch {}
        try await coordinator.restart()
        // Logout during a suspended native stop cancels credential replay.
        try coordinator.register(account: SIPAccount(), password: "logout-test-secret", turnPassword: "")
        let beforeLogout = created.last!; beforeLogout.suspendStop = true
        let logoutSwitch = Task { try await coordinator.restart() }
        while beforeLogout.stopContinuation == nil { await Task.yield() }
        coordinator.cancelRegistrationIntent(); failStart = false
        beforeLogout.stopContinuation?.resume(); beforeLogout.stopContinuation = nil
        try await logoutSwitch.value
        precondition(created.last!.registrations == 0)
        print("PASS: single-SDK lifecycle, blocked recovery during calls, registration retry and logout during teardown")
        print("PASS: all live call states, push/preparation/transfer lock, serialized teardown, blocked commands, stale callbacks, failed start/stop, native loop loss, explicit recovery and credential privacy")
    }
    @MainActor private static func expectFailure(_ action: () async throws -> Void) async throws {
        do { try await action(); preconditionFailure("Expected failure") } catch {}
    }
}
