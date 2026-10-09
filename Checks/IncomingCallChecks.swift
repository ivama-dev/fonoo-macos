import Foundation

@MainActor
final class FakeIncomingReporter: IncomingCallReporting {
    var reports: [UUID] = []
    var ends: [UUID] = []
    var updated: [UUID] = []
    var connections: [UUID] = []
    var reportedContacts: [Contact?] = []
    var updatedContacts: [Contact] = []
    var automatic = true
    var completions: [(Bool) -> Void] = []
    func report(id: UUID, contact: Contact?, completion: @escaping (Bool) -> Void) {
        reports.append(id)
        reportedContacts.append(contact)
        if automatic { completion(true) } else { completions.append(completion) }
    }
    func update(id: UUID, contact: Contact) { updated.append(id); updatedContacts.append(contact) }
    func connected(id: UUID) { connections.append(id) }
    func end(id: UUID, reason: SystemCallEnd) { ends.append(id) }
    func requestAnswer(id: UUID) {}
    func requestEnd(id: UUID) {}
    func requestMute(id: UUID, muted: Bool) {}
}

@MainActor
final class IncomingFixture {
    let reporter = FakeIncomingReporter()
    var clock = Date(timeIntervalSince1970: 1000)
    lazy var coordinator = IncomingCallCoordinator(reporter: reporter, clock: { [unowned self] in self.clock })
    let uuid = UUID(), sipID = UUID()
    var forwarded: [SIPCallEvent] = []
    var accepted: [UUID] = []
    var terminated: [UUID] = []
    var restored = 0
    var completedPush = 0
    init() {
        coordinator.canReceive = { true }
        coordinator.restoreConnection = { [unowned self] in self.restored += 1 }
        coordinator.forwardSIP = { [unowned self] in self.forwarded.append($0) }
        coordinator.acceptSIP = { [unowned self] id, done in self.accepted.append(id); done(true) }
        coordinator.endSIP = { [unowned self] in self.terminated.append($0) }
    }
    var payload: [AnyHashable: Any] {
        ["fonoo": ["version": 1, "type": "incoming_call", "event_id": "event-1",
                   "call_id": "call-1", "call_uuid": uuid.uuidString, "expires_at": 1060] as [String: Any]]
    }
    func cloudPayload(number: Any? = nil, expires: Int = 1060) -> [AnyHashable: Any] {
        var data: [String: Any] = ["version":2, "type":"incoming_call", "event_id":"event-1",
            "call_id":String(repeating:"c",count:32), "call_uuid":uuid.uuidString,
            "expires_at":expires, "wake_token":String(repeating:"t",count:43),
            "tenant_id":"tenant", "device_id":"iphone", "endpoint_id":"d"+String(repeating:"a",count:32)]
        if let number { data["caller_number"] = number }
        return ["fonoo":data]
    }
    func push() { coordinator.receivePush(payload) { [unowned self] in self.completedPush += 1 } }
    @discardableResult
    func sip(_ state: SIPCallState, callID: String = "call-1", id: UUID? = nil) -> Bool {
        coordinator.receiveSIP(SIPCallEvent(id: id ?? sipID, number: "500", displayName: "Test",
                                          state: state, signalingID: callID))
    }
}

@main
struct IncomingCallChecks {
    @MainActor
    static func main() {
        do {
            let f = IncomingFixture()
            let payload = f.cloudPayload(number: "+43720700100")
            f.coordinator.receivePush(payload) { f.completedPush += 1 }
            precondition(f.reporter.reportedContacts.first??.number == "+43720700100",
                         "Initial native report must contain the number before any SIP INVITE")
            f.coordinator.remoteEnded(callID: String(repeating:"c",count:32))
            precondition(f.reporter.ends == [f.uuid] && f.forwarded.isEmpty && f.completedPush == 1,
                         "Caller hangs up before SIP: retain identity in the native missed-call entry")
        }
        do {
            for expired in [false, true] {
                let f = IncomingFixture()
                f.coordinator.canReceive = { false }
                let payload = f.cloudPayload(number:"505", expires:expired ? 990 : 1060)
                f.coordinator.receivePush(payload) { f.completedPush += 1 }
                precondition(f.reporter.reportedContacts.first??.number == "505")
                precondition(f.reporter.ends == [f.uuid] && f.restored == 0 && f.completedPush == 1,
                             "Late or unavailable call is reported with identity without reviving it")
            }
            let f = IncomingFixture()
            f.coordinator.authorizePush = { _ in false }
            f.coordinator.receivePush(f.cloudPayload(number:"505")) {}
            precondition(f.reporter.reportedContacts[0] == nil, "Foreign account cannot display caller hint")
        }
        do {
            let f = IncomingFixture()
            let payload = f.cloudPayload(number:"100")
            f.coordinator.receivePush(payload) {}
            f.sip(.incoming, callID:String(repeating:"c",count:32))
            f.coordinator.receivePush(payload) {}
            precondition(f.reporter.reportedContacts.last??.number == "500",
                         "Duplicate push must retain the later authoritative SIP identity")
        }
        do {
            let f = IncomingFixture()
            for number: Any in ["anonymous", "+43\n", "sip:505@pbx", "1", String(repeating:"1",count:33), true] {
                let push = IncomingPush(f.cloudPayload(number:number), now:f.clock)
                precondition(push != nil && push?.callerNumber == nil,
                             "Invalid optional identity cannot prevent mandatory VoIP reporting")
            }
            precondition(IncomingPush(f.cloudPayload(), now:f.clock)?.callerNumber == nil,
                         "Existing v2 pushes remain compatible")
        }
        do {
            let f = IncomingFixture()
            let cid = String(repeating: "c", count: 32)
            var data = f.payload["fonoo"] as! [String: Any]
            data["version"] = 2; data["call_id"] = cid
            data["wake_token"] = String(repeating: "t", count: 43)
            data["tenant_id"] = "tenant"; data["device_id"] = "iphone"
            data["endpoint_id"] = "d" + String(repeating: "a", count: 32)
            var wakes = 0; var finishes = 0
            f.coordinator.authorizePush = { $0.cloud?.tenantID == "tenant" }
            f.coordinator.pushStarted = { _ in wakes += 1 }
            f.coordinator.callFinished = { _ in finishes += 1 }
            f.coordinator.receivePush(["fonoo": data]) {}
            precondition(wakes == 1 && f.coordinator.busy)
            f.coordinator.receivePush(["fonoo": data]) {}
            precondition(wakes == 1)
            f.coordinator.remoteEnded(callID: "another")
            precondition(f.coordinator.busy)
            f.coordinator.remoteEnded(callID: cid)
            precondition(!f.coordinator.busy && finishes == 1)
            f.sip(.incoming, callID: cid)
            precondition(f.terminated == [f.sipID])
            data["wake_token"] = "bad"
            precondition(IncomingPush(["fonoo": data], now: f.clock) == nil)
            let other = IncomingFixture()
            other.coordinator.authorizePush = { _ in false }
            other.push()
            precondition(other.restored == 0 && !other.coordinator.busy)
            other.coordinator.handlesSIP = { false }
            precondition(!other.sip(.incoming))
        }
        do {
            let f = IncomingFixture()
            f.push()
            precondition(f.completedPush == 1 && f.restored == 1 && f.coordinator.busy)
            var answers: [Bool] = []
            f.coordinator.answer(id: f.uuid) { answers.append($0) }
            precondition(f.accepted.isEmpty && answers.isEmpty, "Answer waits for matching INVITE")
            f.sip(.incoming)
            precondition(f.accepted == [f.sipID] && answers == [true])
            precondition(f.reporter.connections.isEmpty, "Accepting SIP is not a confirmed connection")
            f.sip(.active)
            f.sip(.active)
            precondition(f.reporter.connections == [f.uuid], "Report connection once using the push UUID, not the SIP UUID")
            f.clock += 120; f.coordinator.expire()
            precondition(f.coordinator.busy, "Connected call is not subject to ringing timeout")
            f.sip(.ended)
            precondition(!f.coordinator.busy && f.reporter.ends == [f.uuid])
        }
        do {
            let f = IncomingFixture()
            f.sip(.incoming)
            precondition(f.coordinator.systemID == f.sipID)
            f.push()
            precondition(f.reporter.reports == [f.sipID, f.sipID] && f.restored == 0,
                         "SIP-first + push must retain one native identity and transport")
            precondition(f.forwarded.count == 1)
            f.sip(.incoming)
            precondition(f.forwarded.count == 1, "Duplicate incoming callback cannot reset call")
            f.clock += 61; f.coordinator.expire()
            precondition(!f.coordinator.busy)
        }
        do {
            let f = IncomingFixture()
            f.push()
            var results: [Bool] = []
            f.coordinator.answer(id: f.uuid) { results.append($0) }
            f.clock += 61; f.coordinator.expire()
            precondition(results == [false] && !f.coordinator.busy)
            f.sip(.incoming)
            precondition(f.accepted.isEmpty && f.terminated == [f.sipID] && f.forwarded.isEmpty,
                         "Late INVITE after timeout must be declined, never resurrected")
            f.push()
            precondition(!f.coordinator.busy && f.completedPush == 2)
        }
        do {
            let f = IncomingFixture()
            f.push()
            let other = UUID()
            f.sip(.incoming, callID: "different-call", id: other)
            precondition(f.terminated == [other] && f.coordinator.sipID == nil,
                         "Caller number cannot be used to correlate calls")
            precondition(f.coordinator.end(id: f.uuid))
            f.sip(.incoming)
            precondition(f.accepted.isEmpty && f.forwarded.isEmpty)
        }
        do {
            let f = IncomingFixture()
            f.reporter.automatic = false
            f.push()
            precondition(f.completedPush == 0 && f.reporter.reports.count == 1)
            precondition(f.coordinator.end(id: f.uuid))
            f.reporter.completions.removeFirst()(true)
            precondition(f.reporter.ends == [f.uuid] && f.completedPush == 1,
                         "Hangup while report is pending must end after report completion")
        }
        do {
            let f = IncomingFixture()
            f.reporter.automatic = false
            f.push(); f.sip(.incoming)
            var results: [Bool] = []
            f.coordinator.answer(id: f.uuid) { results.append($0) }
            precondition(f.accepted.isEmpty, "No answer until CallKit accepts the call")
            f.reporter.completions.removeFirst()(false)
            precondition(results == [false] && f.terminated == [f.sipID] && f.completedPush == 1)
        }
        do {
            let f = IncomingFixture()
            f.coordinator.canReceive = { false }
            f.push()
            precondition(f.restored == 0 && f.reporter.ends == [f.uuid] && !f.coordinator.busy)
            f.coordinator.canReceive = { true }
            f.sip(.incoming)
            precondition(f.terminated == [f.sipID], "Blocked push cannot become a late incoming call")
        }
        do {
            let f = IncomingFixture()
            f.clock += 61; f.push()
            precondition(f.completedPush == 1 && f.restored == 0 && f.reporter.ends.count == 1)
            var completions = 0
            for payload: [AnyHashable: Any] in [[:], ["fonoo": "wrong"], ["fonoo": ["version": true]]] {
                f.coordinator.receivePush(payload) { completions += 1 }
            }
            precondition(completions == 3 && f.reporter.reports.count == 4 && !f.coordinator.busy)
        }
        do {
            let f = IncomingFixture()
            var wakeLifecycle: [String] = []
            f.coordinator.pushStarted = { _ in wakeLifecycle.append("start") }
            f.coordinator.callFinished = { _ in wakeLifecycle.append("finish") }
            f.coordinator.restoreConnection = { throw PhoneError.message("fixture") }
            f.push()
            precondition(!f.coordinator.busy && f.reporter.ends == [f.uuid])
            precondition(wakeLifecycle == ["start", "finish"], "Restore failure must release the server wake ticket")
        }
        do {
            let f = IncomingFixture()
            f.push()
            f.reporter.automatic = false
            f.push(); f.reporter.completions.removeFirst()(false)
            precondition(f.coordinator.busy && f.reporter.ends.isEmpty && f.completedPush == 2,
                         "Rejected duplicate report must not terminate the original call")
            f.clock += 61; f.coordinator.expire()
            precondition(!f.coordinator.busy, "Duplicate push must not extend ringing")
        }
        do {
            let f = IncomingFixture()
            f.push(); f.sip(.incoming)
            var delayed: ((Bool) -> Void)?
            f.coordinator.acceptSIP = { _, done in delayed = done }
            var results: [Bool] = []
            f.coordinator.answer(id: f.uuid) { results.append($0) }
            f.coordinator.reset(); delayed?(true)
            precondition(results == [false] && !f.coordinator.busy,
                         "Late accept callback after reset must not fulfill answer twice")
            precondition(!f.sip(.active, callID: "outgoing", id: UUID()), "Outgoing events stay with CallManager")
        }
        do {
            let f = IncomingFixture()
            var base = f.payload["fonoo"] as! [String: Any]
            for (key, value): (String, Any) in [("version", true), ("version", 2), ("call_id", "x\nInjected"),
                                               ("call_uuid", "wrong"), ("expires_at", true), ("expires_at", 9000)] {
                var bad = base; bad[key] = value
                precondition(IncomingPush(["fonoo": bad], now: f.clock) == nil)
            }
            base["expires_at"] = 999
            precondition(IncomingPush(["fonoo": base], now: f.clock) != nil, "Expired payload still has a native identity to report/end")
        }
        print("PASS: push/SIP ordering, early answer, exact Call-ID matching, duplicate delivery, deadlines, late INVITE, report/answer races, reset, DND/sign-out gate and malformed payloads")
    }
}
