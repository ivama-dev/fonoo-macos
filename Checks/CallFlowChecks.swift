import Foundation

@MainActor
final class FakeSIPCore: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    var lastID: UUID?
    var invited: [String] = []
    var answered: [UUID] = []
    var ended: [UUID] = []
    var directTransfers: [(UUID, String)] = []
    var attendedTransfers: [(UUID, UUID)] = []
    func transfer(id: UUID, number: String) throws { directTransfers.append((id, number)) }
    func transfer(id: UUID, destinationID: UUID) throws { attendedTransfers.append((id, destinationID)) }
    var tones: [String] = []
    var holds: [Bool] = []
    var muted = false
    var systemAudio = false
    var audioActivations: [Bool] = []
    func setSystemCallAudio(_ enabled: Bool) { systemAudio = enabled }
    func systemAudioActivated(_ active: Bool) { audioActivations.append(active) }
    var throwOnInvite = false
    var throwOnAnswer = false
    var throwOnHold = false
    var throwOnRegister = false
    var silentRegister = false
    var receivedTURNPassword = ""
    func setSIPTracing(_ enabled: Bool) {}
    func register(account: SIPAccount, password: String, turnPassword: String) throws {
        if throwOnRegister { throw PhoneError.message("Local registration failure") }
        receivedTURNPassword = turnPassword
        if !silentRegister { onEvent?(.registration(.registering)) }
    }
    func unregister() throws { onEvent?(.registration(.offline)) }
    func invite(number: String, id: UUID) throws {
        lastID = id; invited.append(number)
        if throwOnInvite { throw PhoneError.message("Test failure") }
    }
    func answer(id: UUID) throws {
        if throwOnAnswer { throw PhoneError.message("Answer test failure") }
        answered.append(id)
    }
    func end(id: UUID) throws { ended.append(id) }
    func setMuted(_ value: Bool, id: UUID) throws { muted = value }
    func setHeld(_ held: Bool, id: UUID) throws {
        if throwOnHold { throw PhoneError.message("Hold test failure") }
        holds.append(held)
    }
    func sendDTMF(_ digit: String, id: UUID) throws { tones.append(digit) }
    func selectAudioDevice(id: String) throws {}
    func refreshAudioDevices() {}
    func setNetworkAvailable(_ available: Bool) {}
    func refreshRegistration() {}
    func emit(_ id: UUID, _ state: SIPCallState) {
        onEvent?(.call(SIPCallEvent(id: id, number: "500", displayName: "Test", state: state)))
    }
}

@MainActor
final class FakeAudio: CallAudio {
    var permitted = true
    var waitForPermission = false
    var continuation: CheckedContinuation<Bool, Never>?
    var managed = false
    var releasedWhileManaged: [Bool] = []
    func setSystemManaged(_ enabled: Bool) { managed = enabled }
    var prepared = 0
    var released = 0
    func requestPermission() async -> Bool {
        if waitForPermission { return await withCheckedContinuation { continuation = $0 } }
        return permitted
    }
    func prepare() throws { prepared += 1 }
    func release() { released += 1; releasedWhileManaged.append(managed) }
}

@MainActor
final class FakeOutgoingReporter: OutgoingCallReporting {
    var requests: [UUID] = []
    var connections: [UUID] = []
    var ends: [UUID] = []
    var failure: (() -> Void)?
    func startOutgoing(id: UUID, contact: Contact, failed: @escaping () -> Void) { requests.append(id); failure = failed }
    func outgoingConnected(id: UUID) { connections.append(id) }
    func endOutgoing(id: UUID, failed: Bool) { ends.append(id) }
}

@MainActor
final class FakeSystemControls: SystemCallControlling {
    var ended: [UUID] = []
    var held: [(UUID, Bool)] = []
    var tones: [(UUID, String)] = []
    var muted: [(UUID, Bool)] = []
    func requestEnd(id: UUID) { ended.append(id) }
    func requestHold(id: UUID, held: Bool) { self.held.append((id, held)) }
    func requestTones(id: UUID, digits: String) { tones.append((id, digits)) }
    func requestMute(id: UUID, muted: Bool) { self.muted.append((id, muted)) }
}

@main
struct CallFlowChecks {
    @MainActor
    static func settle() async { for _ in 0..<12 { await Task.yield() } }
    @MainActor
    static func checkTransfers() async {
        let core = FakeSIPCore(), audio = FakeAudio()
        let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
        core.onEvent?(.registration(.registered))
        manager.dial("500"); await settle()
        let first = manager.call!.id
        core.emit(first, .active)
        manager.beginConsultation("510")
        precondition(manager.consultation == nil && manager.consultationPending)
        precondition(core.invited == ["500"], "Consultation must wait for confirmed hold")
        manager.beginConsultation("520")
        core.emit(first, .held)
        let second = manager.consultation!.id
        precondition(core.invited == ["500", "510"])
        manager.completeConsultation()
        precondition(core.attendedTransfers.isEmpty, "Cannot connect a ringing consultation")
        core.emit(second, .active)
        manager.completeConsultation(); manager.completeConsultation()
        precondition(core.attendedTransfers.count == 1 && manager.transferPending)
        core.onEvent?(.transfer(first, .failed(403)))
        precondition(!manager.transferPending && manager.call != nil && manager.consultation != nil)
        manager.returnToOriginal()
        core.emit(second, .active)
        precondition(manager.consultation?.phase == .ending, "Late media must not undo hangup")
        core.emit(second, .ended)
        precondition(manager.consultation == nil && core.holds.last == false && audio.released == 0)
        core.emit(first, .active)
        manager.transferDirect("bad uri")
        precondition(core.directTransfers.isEmpty)
        manager.transferDirect("520"); manager.transferDirect("530")
        precondition(core.directTransfers.count == 1 && core.ended == [second])
        core.onEvent?(.transfer(UUID(), .succeeded))
        precondition(manager.call?.phase == .active)
        core.onEvent?(.transfer(first, .succeeded))
        precondition(manager.call?.phase == .ending && core.ended.last == first)
        core.emit(first, .ended)
        precondition(manager.call == nil && !manager.transferPending && audio.released == 1)

        manager.dial("500"); await settle()
        let original = manager.call!.id
        core.emit(original, .active); manager.beginConsultation("510"); core.emit(original, .held)
        let consultation = manager.consultation!.id
        core.emit(original, .ended)
        precondition(manager.busy && core.ended.contains(consultation), "No orphaned second call")
        core.emit(consultation, .ended)
        precondition(!manager.busy && manager.consultation == nil)

        manager.dial("500"); await settle()
        let transferSource = manager.call!.id
        core.emit(transferSource, .active)
        manager.beginConsultation("510")
        manager.returnToOriginal()
        core.emit(transferSource, .held)
        precondition(manager.consultation == nil && core.holds.last == false)
        core.emit(transferSource, .active)
        manager.beginConsultation("510"); core.emit(transferSource, .held)
        let destination = manager.consultation!.id
        core.emit(destination, .active); manager.completeConsultation()
        core.onEvent?(.transfer(transferSource, .succeeded))
        precondition(core.ended.contains(destination) && core.ended.contains(transferSource))
        core.emit(destination, .ended); core.emit(transferSource, .ended)
        precondition(!manager.busy)

        let incoming = UUID()
        manager.resolveContact = { number in Contact(id: "local", name: "Lokaler Kontakt", role: "Mobil", number: number) }
        core.emit(incoming, .incoming); await settle()
        precondition(manager.call?.original.name == "Lokaler Kontakt")
        core.emit(incoming, .ended)
        precondition(manager.recents.first?.contact.name == "Lokaler Kontakt")
        print("PASS: consultation hold gate, answer gate, transfer failure/success, duplicate/stale events, return, orphan cleanup and caller name")
    }
    @MainActor
    static func checkNativeControls() async {
        let core = FakeSIPCore(), audio = FakeAudio(), reporter = FakeOutgoingReporter(), controls = FakeSystemControls()
        let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
        manager.outgoingReporter = reporter; manager.systemControls = controls
        core.onEvent?(.registration(.registered))
        manager.dial("101"); await settle()
        let id = reporter.requests[0]
        precondition(core.invited.isEmpty, "Normal app dialing must wait for native authorization")
        precondition(manager.beginSystemOutgoing(id: id))
        core.emit(id, .active)
        manager.toggleMute(); manager.toggleHold(); manager.sendTone("5")
        precondition(!core.muted && core.holds.isEmpty && core.tones.isEmpty)
        precondition(controls.muted[0].0 == id && controls.held[0].0 == id && controls.tones[0].0 == id)
        core.throwOnHold = true
        var failedHold: [Bool] = []
        manager.setSystemHeld(id: id, held: true) { failedHold.append($0) }
        precondition(failedHold == [false] && !manager.call!.holdPending && core.holds.isEmpty)
        core.throwOnHold = false
        var results: [Bool] = []
        manager.setSystemHeld(id: UUID(), held: true) { results.append($0) }
        precondition(results == [false] && core.holds.isEmpty)
        results = []
        manager.setSystemHeld(id: id, held: true) { results.append($0) }
        precondition(results.isEmpty && manager.call!.holdPending && core.holds == [true])
        precondition(!manager.sendSystemTones(id: id, digits: "2"))
        var duplicate: [Bool] = []
        manager.setSystemHeld(id: id, held: true) { duplicate.append($0) }
        precondition(duplicate == [false] && core.holds == [true])
        core.emit(id, .held); core.emit(id, .held)
        precondition(results == [true] && manager.call!.isHeld)
        precondition(!manager.sendSystemTones(id: id, digits: "3"))
        manager.setSystemHeld(id: id, held: false) { results.append($0) }
        precondition(results == [true] && core.holds == [true, false])
        core.emit(id, .active)
        precondition(results == [true, true] && !manager.call!.isHeld)
        for digits in ["", "1x", "1,2", String(repeating: "1", count: 33)] {
            precondition(!manager.sendSystemTones(id: id, digits: digits))
        }
        precondition(!manager.sendSystemTones(id: UUID(), digits: "4"))
        precondition(manager.sendSystemTones(id: id, digits: "12*#") && core.tones == ["1", "2", "*", "#"])
        manager.setSystemHeld(id: id, held: true) { results.append($0) }
        manager.cancelSystemHold(id: id)
        precondition(results == [true, true, false])
        core.emit(id, .held)
        precondition(results.count == 3, "Late SIP confirmation must not fulfill an expired action")
        manager.setSystemHeld(id: id, held: false) { results.append($0) }
        manager.end()
        precondition(controls.ended == [id] && core.ended.isEmpty)
        precondition(manager.endSystemOutgoing(id: id))
        core.emit(id, .ended)
        precondition(results == [true, true, false, false] && !manager.busy)
        precondition(!manager.sendSystemTones(id: id, digits: "5"))
        print("PASS: in-app native dialing, shared controls, hold acknowledgement, duplicate/stale actions, cancellation, end during hold and validated DTMF")
    }

    @MainActor
    static func checkNativeOutgoing() async {
        let contact = Contact(id: "101", name: "Test", role: "", number: "101")
        do {
            let core = FakeSIPCore(), audio = FakeAudio(), reporter = FakeOutgoingReporter()
            let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
            manager.outgoingReporter = reporter
            core.onEvent?(.registration(.registered))
            var results: [Bool] = []
            manager.startSystemCall(contact) { results.append($0) }; await settle()
            let id = reporter.requests[0]
            precondition(manager.busy && core.invited.isEmpty && audio.managed && core.systemAudio)
            manager.dial("102"); await settle()
            precondition(core.invited.isEmpty, "No competing call before OS authorizes start")
            precondition(manager.beginSystemOutgoing(id: id))
            precondition(!manager.beginSystemOutgoing(id: id), "Duplicate Start cannot invite twice")
            precondition(results == [true] && core.invited == ["101"])
            core.emit(id, .active); core.emit(id, .active)
            precondition(reporter.connections == [id])
            precondition(manager.endSystemOutgoing(id: id))
            precondition(audio.managed && manager.call != nil, "Audio remains system-owned until SDK ends")
            core.emit(id, .ended)
            precondition(reporter.ends == [id] && !manager.busy && !audio.managed && !core.systemAudio)
            precondition(results == [true], "Start completion runs once")
        }
        do {
            let core = FakeSIPCore(), audio = FakeAudio(), reporter = FakeOutgoingReporter()
            let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
            manager.outgoingReporter = reporter; core.onEvent?(.registration(.registered))
            var results: [Bool] = []
            manager.startSystemCall(contact) { results.append($0) }; await settle()
            let id = reporter.requests[0]
            manager.end()
            precondition(results == [false] && !manager.busy && !audio.managed)
            precondition(!manager.beginSystemOutgoing(id: id) && core.invited.isEmpty, "Cancelled native start stays cancelled")
            reporter.failure?()
            precondition(results == [false], "Late OS failure cannot complete twice")
        }
        for failInvite in [false, true] {
            let core = FakeSIPCore(), audio = FakeAudio(), reporter = FakeOutgoingReporter()
            let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
            manager.outgoingReporter = reporter; core.onEvent?(.registration(.registered))
            var results: [Bool] = []
            manager.startSystemCall(contact) { results.append($0) }; await settle()
            if failInvite { core.throwOnInvite = true; precondition(!manager.beginSystemOutgoing(id: reporter.requests[0])) }
            else { reporter.failure?() }
            precondition(results == [false] && !manager.busy && !audio.managed)
        }
        print("PASS: native outgoing authorization, duplicate/stale actions, early cancel, request/invite failure, audio ownership and one-shot completion")
    }
    @MainActor
    static func main() async throws {
        do {
            let core = FakeSIPCore(), manager = CallManager(core: core, audio: FakeAudio(), diagnostics: Diagnostics())
            var account = SIPAccount(); account.server = "127.0.0.1"; account.domain = "127.0.0.1"; account.username = "fixture"
            core.silentRegister = true
            core.onEvent?(.registration(.registered))
            try manager.restoreIncomingConnection(account: account, password: "fixture", turnPassword: "")
            precondition(manager.registration == .registering, "Push readiness must not inherit a previous registration before the SDK callback")
            core.onEvent?(.registration(.registered))
            precondition(manager.registration == .registered)
            core.throwOnRegister = true
            do { try manager.restoreIncomingConnection(account: account, password: "fixture", turnPassword: ""); preconditionFailure("Expected local failure") } catch {}
            precondition(manager.registration == .failed(0), "Failed push restore must not announce ready")
        }
        await checkNativeOutgoing()
        await checkNativeControls()
        await checkTransfers()
        checkForegroundRegistrationRecovery()
        await checkSystemIncomingIntegration()
        let core = FakeSIPCore(), audio = FakeAudio()
        let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
        let person = Contact(id: "500", name: "Test", role: "", number: "500")
        manager.start(person)
        await settle()
        precondition(core.invited.isEmpty, "Unregistered calls must not reach the engine")
        core.onEvent?(.registration(.registered))
        audio.permitted = false
        manager.start(person); await settle()
        precondition(core.invited.isEmpty && manager.call == nil, "Microphone refusal must prevent outgoing calls")
        audio.permitted = true
        manager.dial("+43 (123) 45"); await settle()
        let first = manager.call!.id
        precondition(core.invited == ["+4312345"] && manager.call?.phase == .connecting)
        manager.sendTone("1")
        precondition(core.tones.isEmpty, "No DTMF before answer")
        core.emit(UUID(), .active)
        precondition(manager.call?.phase == .connecting, "Stale call events cannot connect current call")
        core.emit(first, .ringing)
        precondition(manager.call?.phase == .ringing)
        core.emit(first, .active)
        manager.toggleMute()
        precondition(core.muted && manager.call!.isMuted)
        manager.toggleHold(); manager.toggleHold()
        precondition(core.holds == [true] && !manager.call!.isHeld, "Hold must await SDK acknowledgement and coalesce taps")
        core.emit(first, .held)
        manager.sendTone("5")
        precondition(core.tones.isEmpty, "Held call cannot send DTMF")
        manager.toggleHold()
        precondition(core.holds == [true, false])
        core.emit(first, .active)
        manager.sendTone("#"); manager.sendTone("x"); manager.sendTone("12")
        precondition(core.tones == ["#"])
        manager.end(); manager.end()
        precondition(core.ended == [first] && manager.call?.phase == .ending)
        core.emit(first, .active)
        precondition(manager.call?.phase == .ending, "Late connection event cannot undo hangup")
        core.emit(first, .ended); core.emit(first, .ended)
        precondition(manager.call == nil && manager.recents.count == 1 && audio.released == 1)

        precondition(manager.recents.first!.incoming == false && manager.recents.first!.duration != nil)
        let missed = UUID()
        core.emit(missed, .incoming); core.emit(missed, .ended)
        precondition(manager.recents.first!.missed && manager.recents.count == 2)
        let declined = UUID()
        core.emit(declined, .incoming); manager.end(); core.emit(declined, .ended)
        precondition(!manager.recents.first!.missed && manager.recents.first!.detail == "Abgelehnt")
        manager.doNotDisturb = true
        let rejected = UUID()
        core.emit(rejected, .incoming)
        precondition(core.ended.contains(rejected) && manager.call == nil)
        manager.doNotDisturb = false

        audio.waitForPermission = true
        let cancelled = UUID()
        core.emit(cancelled, .incoming); manager.answer(); await settle()
        precondition(audio.continuation != nil)
        core.emit(cancelled, .ended)
        audio.continuation?.resume(returning: true); audio.continuation = nil
        await settle()
        precondition(core.answered.isEmpty && manager.call == nil && !manager.preparingCall,
                     "CANCEL while permission is pending must never answer a dead call")
        audio.waitForPermission = false
        let incoming = UUID()
        core.emit(incoming, .incoming); manager.answer(); await settle()
        precondition(core.answered == [incoming] && manager.acceptingCall)
        manager.answer(); await settle()
        precondition(core.answered == [incoming], "Accept must not be submitted again while ICE is pending")
        core.emit(incoming, .incoming)
        precondition(!core.ended.contains(incoming), "Early media/repeated incoming notifications cannot decline the current call")
        core.emit(incoming, .active)
        precondition(!manager.acceptingCall)
        core.emit(incoming, .ended)
        let answerFailure = UUID()
        core.throwOnAnswer = true
        core.emit(answerFailure, .incoming); manager.answer(); await settle()
        precondition(!manager.acceptingCall && !manager.preparingCall && manager.notice == "Answer test failure")
        core.throwOnAnswer = false
        manager.answer(); await settle()
        precondition(manager.acceptingCall && core.answered.last == answerFailure)
        manager.end(); core.emit(answerFailure, .ended)
        precondition(!manager.acceptingCall)
        precondition(manager.recents.contains { $0.detail == "Eingehend" })

        audio.waitForPermission = true
        manager.start(person); await settle()
        let wins = UUID()
        core.emit(wins, .incoming)
        audio.continuation?.resume(returning: true); audio.continuation = nil
        await settle()
        precondition(manager.call?.id == wins && core.invited.count == 1,
                     "Incoming call takes precedence over outbound microphone request")
        core.emit(wins, .ended)
        audio.waitForPermission = false
        core.throwOnInvite = true
        manager.start(person); await settle()
        precondition(manager.call == nil && manager.recents.first!.detail == "Fehlgeschlagen")

        var account = SIPAccount()
        account.server = "pbx.example.com"; account.username = "500"
        _ = try account.validated()
        try manager.register(account: account, password: "test-sip-secret", turnPassword: "test-turn-secret")
        precondition(core.receivedTURNPassword == "test-turn-secret")
        precondition(!manager.diagnostics.registrationEntries.contains { $0.message.contains("test-turn-secret") })
        account.server = "https://pbx.example.com/path"
        do { _ = try account.validated(); preconditionFailure("Reject web URLs") } catch {}
        account.server = "pbx.example.com"; account.username = "500@domain"
        do { _ = try account.validated(); preconditionFailure("Reject injected identity domain") } catch {}
        for invalid in ["sip:500@evil.example", "1\r\nHeader: x", "+", "1+2", ""] {
            do { _ = try SIPAccount.normalizedNumber(invalid); preconditionFailure("Reject invalid dial string") } catch {}
        }
        precondition(MediaTrace.sanitized("ice: Recv TURN allocate success response: secret-address") == "TURN: Relay-Zuweisung vom Server bestätigt.")
        precondition(MediaTrace.sanitized("password=private-turn-secret") == nil)
        precondition(MediaTrace.sanitized("ice: Gathering timeout for checklist secret")?.contains("secret") == false)
        let log = Diagnostics()
        for index in 0..<305 { log.recordRegistration("Step \(index)") }
        precondition(log.registrationEntries.count == 300)
        precondition(log.registrationEntries.first?.message == "Step 5")
        precondition(log.registrationEntries.last?.message == "Step 304")
        core.onEvent?(.registrationTrace("Engine ready"))
        precondition(manager.diagnostics.registrationEntries.last?.message == "Engine ready")
        core.onEvent?(.registration(.failed(403)))
        precondition(manager.diagnostics.registrationEntries.last?.message.contains("403") == true)
        let outgoing = "channel [test]: message sent to [UDP://pbx.example.com:5060], size: [400] bytes\nREGISTER sip:user:secret@pbx.example.com SIP/2.0\r\nVia: SIP/2.0/UDP 192.0.2.1:5060\r\nCSeq: 2 REGISTER\r\nAuthorization: Digest username=hidden,\r\n response=supersecret\r\nProxy-Authorization: token-secret\r\nX-API-Key: api-secret\r\nContent-Length: 0\r\n\r\n"
        let packet = SIPTracePacket.sanitized(outgoing)!
        precondition(packet.direction == "GESENDET" && packet.text.contains("CSeq: 2 REGISTER"))
        for secret in ["secret", "hidden", "supersecret", "token-secret", "api-secret"] {
            precondition(!packet.text.contains(secret), "Credentials must be removed before storage")
        }
        let incomingDump = "channel [test]: received [200] new bytes from [UDP://pbx.example.com:5060]:\nSIP/2.0 401 Unauthorized\nWWW-Authenticate: Digest nonce=private-nonce\nCSeq: 1 REGISTER\nContent-Length: 0\n\n"
        let response = SIPTracePacket.sanitized(incomingDump)!
        precondition(response.direction == "EMPFANGEN" && response.text.contains("401 Unauthorized"))
        precondition(!response.text.contains("private-nonce"))
        let sdp = "channel [test]: message sent to [UDP://pbx.example.com:5060]\nINVITE sip:500@pbx.example.com SIP/2.0\nContent-Type: application/sdp\n\nv=0\nm=audio 7078 RTP/SAVP 0\na=rtpmap:0 PCMU/8000\na=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:private-key\na=ice-pwd:private-ice\na=candidate:1 1 UDP 123 203.0.113.1 45000 typ relay ufrag private-ufrag\n"
        let mediaDump = SIPTracePacket.sanitized(sdp)!.text
        precondition(mediaDump.contains("PCMU/8000") && !mediaDump.contains("private-key") && !mediaDump.contains("private-ice"))
        precondition(mediaDump.contains("203.0.113.1 45000 typ relay") && !mediaDump.contains("private-ufrag"))
        let info = "channel [test]: message sent to [UDP://pbx.example.com:5060]\nINFO sip:500@pbx.example.com SIP/2.0\nContent-Type: application/dtmf-relay\n\nSignal=7\nDuration=160\n"
        precondition(!SIPTracePacket.sanitized(info)!.text.contains("Signal=7"))
        precondition(SIPTracePacket.sanitized("Authentication password=secret") == nil)
        precondition(SIPTracePacket.sanitized(String(repeating: "x", count: 65_537)) == nil)
        for _ in 0..<155 { log.recordSIP(packet) }
        precondition(log.sipPackets.count == 150)
        log.clearSIP(); precondition(log.sipPackets.isEmpty)
        print("PASS: SIP dump direction, folded authentication headers, URI passwords, SDP keys, DTMF bodies, size limit and retention")
        let toDelete = manager.recents[0].id
        manager.deleteRecents(ids: [toDelete])
        precondition(!manager.recents.contains { $0.id == toDelete })
        manager.deleteRecents(ids: Set(manager.recents.map(\.id)))
        precondition(manager.recents.isEmpty)
        print("PASS: registration and microphone gates, SDK-driven call state, stale events, hold acknowledgement, DTMF, mute, hangup races, history, DND, incoming cancellation, call collision and input validation")
    }

    @MainActor
    static func checkSystemIncomingIntegration() async {
        let core = FakeSIPCore(), audio = FakeAudio(), reporter = IntegrationReporter()
        let manager = CallManager(core: core, audio: audio, diagnostics: Diagnostics())
        let incoming = IncomingCallCoordinator(reporter: reporter)
        manager.attachIncomingCalls(incoming)
        incoming.canReceive = { manager.canReceiveSystemCall }
        let systemID = UUID(), sipID = UUID()
        let payload: [AnyHashable: Any] = ["fonoo": ["version": 1, "type": "incoming_call", "event_id": "e1",
            "call_id": "dialog-1", "call_uuid": systemID.uuidString, "expires_at": Date().timeIntervalSince1970 + 60]]
        incoming.receivePush(payload) {}
        precondition(manager.busy && core.systemAudio && audio.managed)
        core.onEvent?(.registration(.registered))
        manager.dial("500"); await settle()
        precondition(core.invited.isEmpty, "Waiting system call blocks outgoing dial")
        var result: [Bool] = []
        incoming.answer(id: systemID) { result.append($0) }
        core.onEvent?(.call(SIPCallEvent(id: sipID, number: "500", displayName: "Test", state: .incoming, signalingID: "dialog-1")))
        await settle()
        precondition(core.answered == [sipID] && result == [true] && manager.call?.id == sipID)
        core.emit(sipID, .active)
        var holds: [Bool] = []
        manager.setSystemHeld(id: sipID, held: true) { holds.append($0) }
        precondition(holds == [false])
        manager.setSystemHeld(id: systemID, held: true) { holds.append($0) }
        core.emit(sipID, .held)
        manager.setSystemHeld(id: systemID, held: false) { holds.append($0) }
        core.emit(sipID, .active)
        precondition(holds == [false, true, true])
        precondition(manager.sendSystemTones(id: systemID, digits: "9"))
        precondition(!manager.sendSystemTones(id: sipID, digits: "9"))
        manager.systemAudioActivated(true)
        manager.toggleMute()
        precondition(reporter.mutes == [true] && !core.muted, "App controls request CallKit transactions")
        precondition(manager.setSystemMuted(true) && core.muted)
        manager.end()
        precondition(reporter.endsRequested == [systemID] && core.ended.isEmpty)
        precondition(incoming.end(id: systemID))
        precondition(core.ended == [sipID] && audio.managed, "Keep audio owned by CallKit until SDK confirms end")
        core.emit(sipID, .ended)
        precondition(manager.call == nil && !manager.busy && !audio.managed && !core.systemAudio)
        precondition(audio.releasedWhileManaged == [true] && core.audioActivations == [true, false])

        incoming.receivePush(["fonoo": ["version": 1, "type": "incoming_call", "event_id": "e2",
            "call_id": "dialog-2", "call_uuid": UUID().uuidString, "expires_at": Date().timeIntervalSince1970 + 60]]) {}
        manager.doNotDisturb = true
        precondition(!manager.busy && !incoming.busy, "DND cancels an unconnected waiting call")
        print("PASS: CallManager integration, early native answer, pending-call exclusion, CallKit control transactions, SDK-confirmed hangup and audio ownership")
    }

    @MainActor
    static func checkForegroundRegistrationRecovery() {
        let recovery = ForegroundRegistrationRecovery()
        var attempts = 0
        var busy = false
        recovery.isBusy = { busy }
        recovery.restore = { attempts += 1; recovery.becameActive() }
        recovery.becameActive()
        precondition(attempts == 0, "Cold start must wait for network availability")
        recovery.networkChanged(available: true)
        precondition(attempts == 1, "Cold start restores once, including reentrant callbacks")
        recovery.becameActive(); recovery.networkChanged(available: true)
        recovery.becameInactive(background: false); recovery.becameActive()
        precondition(attempts == 1, "Duplicate events and temporary inactive phases must not replace the account")
        recovery.becameInactive(background: true)
        recovery.networkChanged(available: true)
        precondition(attempts == 1, "Never restore credentials while backgrounded")
        recovery.becameActive()
        precondition(attempts == 2, "Returning from background starts a fresh registration")
        recovery.becameInactive(background: true)
        recovery.networkChanged(available: false); recovery.becameActive()
        precondition(attempts == 2)
        recovery.networkChanged(available: true)
        precondition(attempts == 3, "An offline foreground entry resumes when connectivity returns")
        recovery.enabled = false
        recovery.becameInactive(background: true); recovery.becameActive()
        recovery.networkChanged(available: true)
        precondition(attempts == 3, "Explicit sign-out must suppress automatic registration")
        recovery.enabled = true
        recovery.manualRegistrationStarted(); recovery.networkChanged(available: true)
        precondition(attempts == 3, "Manual registration consumes the pending automatic attempt")
        busy = true
        recovery.becameInactive(background: true); recovery.becameActive()
        busy = false
        recovery.networkChanged(available: true)
        precondition(attempts == 3, "Returning during a call must preserve its account and transport")
        recovery.becameInactive(background: true); recovery.becameActive()
        precondition(attempts == 4, "Recovery resumes on the next foreground entry after a call")
        recovery.restore = {}
        print("PASS: foreground registration, cold start, offline recovery, background suppression, explicit sign-out, duplicate events and active-call protection")
    }
}

@MainActor
final class IntegrationReporter: IncomingCallReporting {
    var mutes: [Bool] = []
    var endsRequested: [UUID] = []
    func report(id: UUID, contact: Contact?, completion: @escaping (Bool) -> Void) { completion(true) }
    func update(id: UUID, contact: Contact) {}
    func end(id: UUID, reason: SystemCallEnd) {}
    func requestAnswer(id: UUID) {}
    func requestEnd(id: UUID) { endsRequested.append(id) }
    func requestMute(id: UUID, muted: Bool) { mutes.append(muted) }
}
