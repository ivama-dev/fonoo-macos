import Foundation
import CoreFoundation

/// Cloud v2 may contain a presentation-allowed number for the first native report.
/// No caller name, SIP credentials or address-book data are included in pushes.
struct IncomingPush {
    let callID: String
    let uuid: UUID
    let expiresAt: Date
    let cloud: CloudWake?
    let callerNumber: String?
    struct CloudWake { let token, tenantID, deviceID, endpointID: String }

    init?(_ payload: [AnyHashable: Any], now: Date) {
        guard let data = payload["fonoo"] as? [String: Any],
              let version = data["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), [1.0, 2.0].contains(version.doubleValue),
              data["type"] as? String == "incoming_call",
              let event = data["event_id"] as? String, !event.isEmpty, event.utf8.count <= 128,
              let callID = data["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 512,
              !callID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let rawUUID = data["call_uuid"] as? String, let uuid = UUID(uuidString: rawUUID),
              let expires = data["expires_at"] as? NSNumber,
              CFGetTypeID(expires) != CFBooleanGetTypeID(), expires.doubleValue.isFinite,
              expires.doubleValue <= now.timeIntervalSince1970 + 65 else { return nil }
        if version.intValue == 2 {
            guard let token = data["wake_token"] as? String, token.range(of: "^[A-Za-z0-9_-]{40,128}$", options: .regularExpression) != nil,
                  let tenant = data["tenant_id"] as? String, let device = data["device_id"] as? String,
                  let endpoint = data["endpoint_id"] as? String,
                  endpoint.range(of: "^d[0-9a-f]{32}$", options: .regularExpression) != nil,
                  callID.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
            cloud = CloudWake(token: token, tenantID: tenant, deviceID: device, endpointID: endpoint)
            if let number = data["caller_number"] as? String,
               let match = number.range(of: "^\\+?[0-9]{2,32}$", options: .regularExpression),
               match == number.startIndex..<number.endIndex {
                callerNumber = number
            } else { callerNumber = nil }
        } else { cloud = nil; callerNumber = nil }
        self.callID = callID; self.uuid = uuid
        expiresAt = Date(timeIntervalSince1970: expires.doubleValue)
    }
    var callerContact: Contact? {
        callerNumber.map { Contact(id: $0, name: $0, role: "Eingehend", number: $0) }
    }
}

enum SystemCallEnd { case remote, unanswered, failed, declined }

@MainActor
protocol IncomingCallReporting: AnyObject {
    func report(id: UUID, contact: Contact?, completion: @escaping (Bool) -> Void)
    func update(id: UUID, contact: Contact)
    func connected(id: UUID)
    func end(id: UUID, reason: SystemCallEnd)
    func requestAnswer(id: UUID)
    func requestEnd(id: UUID)
    func requestMute(id: UUID, muted: Bool)
}

extension IncomingCallReporting {
    func connected(id: UUID) {} // CallKit tracks incoming connection via its answer action.
}

/// One incoming call, serialized with SIP and the native system UI on the main actor.
/// Transport/CallKit adapters are injected so races can be checked without an iPhone.
@MainActor
final class IncomingCallCoordinator {
    private struct Pending {
        let uuid: UUID
        let callID: String
        var expiresAt: Date
        var sipID: UUID?
        var contact: Contact?
        var reported = false
        var connected = false
        var accepting = false
        var answer: ((Bool) -> Void)?
    }
    private let reporter: IncomingCallReporting
    private let clock: () -> Date
    private var pending: Pending?
    private var tombstones: [String: Date] = [:]
    private var reporting: Set<UUID> = []
    private var deferredEnds: [UUID: SystemCallEnd] = [:]
    var authorizePush: (IncomingPush) -> Bool = { _ in true }
    var handlesSIP: () -> Bool = { true }
    var pushStarted: (IncomingPush) -> Void = { _ in }
    var callFinished: (String) -> Void = { _ in }
    var canReceive: () -> Bool = { false }
    var restoreConnection: () throws -> Void = {}
    var forwardSIP: (SIPCallEvent) -> Void = { _ in }
    var acceptSIP: (UUID, @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
    var endSIP: (UUID) -> Void = { _ in }
    var changed: () -> Void = {}
    var trace: (String) -> Void = { _ in }

    init(reporter: IncomingCallReporting, clock: @escaping () -> Date = Date.init) {
        self.reporter = reporter; self.clock = clock
    }
    var busy: Bool { pending != nil }
    var sipID: UUID? { pending?.sipID }
    var systemID: UUID? { pending?.uuid }
    func owns(_ sipID: UUID) -> Bool { pending?.sipID == sipID }

    /// Every VoIP delivery is reported immediately, including malformed/expired pushes.
    /// Completion is tied to CallKit reporting, never to registration or INVITE arrival.
    func receivePush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        expire()
        guard let push = IncomingPush(payload, now: clock()) else {
            trace("VoIP-Push: ungültiger Inhalt; Systemanruf wird sofort beendet.")
            reportTransient(UUID(), reason: .failed, completion: completion)
            return
        }
        if let current = pending, current.callID == push.callID {
            // A retry must not extend the deadline, replace identity or abort the real call.
            reporter.report(id: current.uuid, contact: current.contact) { _ in completion() }
            trace("VoIP-Push: doppeltes Anrufereignis zugeordnet.")
            return
        }
        let authorized = authorizePush(push)
        let contact = authorized ? push.callerContact : nil
        guard push.expiresAt > clock(), tombstones[push.callID] == nil, pending == nil,
              canReceive(), authorized else {
            remember(push.callID)
            reportTransient(push.uuid == pending?.uuid ? UUID() : push.uuid, contact: contact,
                            reason: .unanswered, completion: completion)
            return
        }
        pending = Pending(uuid: push.uuid, callID: push.callID, expiresAt: push.expiresAt, contact: contact)
        changed()
        reportCurrent(completion: completion)
        // A synchronous report rejection may already have removed the call.
        guard pending?.uuid == push.uuid else { return }
        trace("VoIP-Push: beim System gemeldet; SIP-Verbindung wird wiederhergestellt.")
        // Establish the wake lifecycle first so a synchronous restore failure can
        // cancel the server-side waiting call as well as the CallKit presentation.
        pushStarted(push)
        do { try restoreConnection() }
        catch {
            trace("Push-Wiederanmeldung fehlgeschlagen: \(error.localizedDescription)")
            finish(reason: .failed, terminateSIP: true)
        }
    }

    /// Returns true only for incoming calls owned/rejected by this coordinator.
    func receiveSIP(_ event: SIPCallEvent) -> Bool {
        guard handlesSIP() || pending != nil else { return false }
        expire()
        if case .incoming = event.state {
            guard let callID = event.signalingID, !callID.isEmpty else {
                endSIP(event.id); trace("Eingehender Anruf ohne SIP-Call-ID abgelehnt."); return true
            }
            if tombstones[callID] != nil { endSIP(event.id); return true }
            if let current = pending {
                guard current.callID == callID,
                      current.sipID == nil || current.sipID == event.id else { endSIP(event.id); return true }
                if current.sipID == event.id { return true }
                pending?.sipID = event.id
            } else {
                guard canReceive() else { endSIP(event.id); return true }
                pending = Pending(uuid: event.id, callID: callID,
                                  expiresAt: clock().addingTimeInterval(60), sipID: event.id)
                changed()
            }
            forwardSIP(event)
            guard let current = pending else { return true }
            let contact = Contact(id: event.number, name: event.displayName.isEmpty ? event.number : event.displayName,
                                  role: "Eingehend", number: event.number)
            pending?.contact = contact
            reporter.update(id: current.uuid, contact: contact)
            if !current.reported && !reporting.contains(current.uuid) { reportCurrent(contact: contact, completion: {}) }
            acceptIfReady()
            return true
        }
        guard pending?.sipID == event.id else { return false }
        forwardSIP(event)
        switch event.state {
        case .active:
            if let current = pending, !current.connected {
                pending?.connected = true
                reporter.connected(id: current.uuid)
            }
        case .ended: finish(reason: .remote, terminateSIP: false)
        case .failed: finish(reason: .failed, terminateSIP: false)
        default: break
        }
        return true
    }

    func requestAnswer() { if let id = systemID { reporter.requestAnswer(id: id) } }
    func requestEnd() { if let id = systemID { reporter.requestEnd(id: id) } }
    func requestMute(_ muted: Bool) { if let id = systemID { reporter.requestMute(id: id, muted: muted) } }

    func answer(id: UUID, completion: @escaping (Bool) -> Void) {
        expire()
        guard pending?.uuid == id, pending?.answer == nil, pending?.accepting == false,
              pending?.connected == false else { completion(false); return }
        pending?.answer = completion
        acceptIfReady()
    }
    func end(id: UUID) -> Bool {
        guard pending?.uuid == id else { return false }
        finish(reason: .declined, terminateSIP: true)
        return true
    }
    func remoteEnded(callID: String) {
        if pending?.callID == callID { finish(reason: .remote, terminateSIP: true) }
    }
    func reset() { finish(reason: .failed, terminateSIP: true) }
    func suppressWaitingCall() {
        if pending?.connected == false { finish(reason: .declined, terminateSIP: true) }
    }
    func expire() {
        tombstones = tombstones.filter { $0.value > clock() }
        if let current = pending, !current.connected, current.expiresAt <= clock() {
            trace("Eingehender Anruf: Zeitfenster abgelaufen.")
            finish(reason: .unanswered, terminateSIP: true)
        }
    }

    private func reportCurrent(contact: Contact? = nil, completion: @escaping () -> Void) {
        guard let current = pending else { completion(); return }
        reporting.insert(current.uuid)
        reporter.report(id: current.uuid, contact: contact ?? current.contact) { [weak self] success in
            guard let self else { completion(); return }
            reporting.remove(current.uuid)
            if let reason = deferredEnds.removeValue(forKey: current.uuid) {
                if success { reporter.end(id: current.uuid, reason: reason) }
            } else if pending?.uuid == current.uuid {
                if success { pending?.reported = true; acceptIfReady() }
                else { finish(reason: .failed, terminateSIP: true) }
            }
            completion()
        }
    }
    private func reportTransient(_ uuid: UUID, contact: Contact? = nil, reason: SystemCallEnd, completion: @escaping () -> Void) {
        reporter.report(id: uuid, contact: contact) { [weak self] success in
            if success { self?.reporter.end(id: uuid, reason: reason) }
            completion()
        }
    }
    private func acceptIfReady() {
        guard let current = pending, current.reported, let sipID = current.sipID,
              current.answer != nil, !current.accepting else { return }
        pending?.accepting = true
        acceptSIP(sipID) { [weak self] success in
            guard let self, pending?.uuid == current.uuid else { return }
            let completion = pending?.answer
            pending?.answer = nil
            completion?(success)
            if !success { finish(reason: .failed, terminateSIP: true) }
        }
    }
    private func finish(reason: SystemCallEnd, terminateSIP: Bool) {
        guard let current = pending else { return }
        pending = nil
        callFinished(current.callID)
        remember(current.callID)
        current.answer?(false)
        if reporting.contains(current.uuid) { deferredEnds[current.uuid] = reason }
        else if current.reported { reporter.end(id: current.uuid, reason: reason) }
        if terminateSIP, let sipID = current.sipID { endSIP(sipID) }
        changed()
    }
    private func remember(_ callID: String) {
        tombstones[callID] = clock().addingTimeInterval(600)
        if tombstones.count > 128, let oldest = tombstones.min(by: { $0.value < $1.value })?.key {
            tombstones.removeValue(forKey: oldest)
        }
    }
}

/// Shared native controls for incoming and outgoing calls.
@MainActor
protocol SystemCallControlling: AnyObject {
    func requestEnd(id: UUID)
    func requestMute(id: UUID, muted: Bool)
    func requestHold(id: UUID, held: Bool)
    func requestTones(id: UUID, digits: String)
}

/// Native outgoing calls use the same SIP state machine as incoming calls.
@MainActor
protocol OutgoingCallReporting: AnyObject {
    func startOutgoing(id: UUID, contact: Contact, failed: @escaping () -> Void)
    func outgoingConnected(id: UUID)
    func endOutgoing(id: UUID, failed: Bool)
}
