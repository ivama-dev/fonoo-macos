#if DEBUG
import Foundation

/// Explicit, isolated UI preview. No account restore, network, microphone or persisted contacts.
enum TeamPreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--preview-team-ui") }
    static let snapshot = TeamSnapshot(schemaVersion: 1, tenantID: "preview-company", tenantName: "Beispiel GmbH",
        revision: 1, selfUserID: "preview-self", members: [
            TeamMember(id: "preview-self", name: "Alex Berger", email: "alex@example.invalid", number: "100",
                personalDeviceCount: 2, personalDevices: [.init(id: "preview-iphone", name: "Persönliches Gerät 1"),
                                                       .init(id: "preview-mac", name: "Persönliches Gerät 2")]),
            TeamMember(id: "preview-anna", name: "Anna Müller", email: "anna@example.invalid", number: "101",
                personalDeviceCount: 2, personalDevices: []),
            TeamMember(id: "preview-lukas", name: "Lukas Novak", email: "lukas@example.invalid", number: "102",
                personalDeviceCount: 1, personalDevices: []),
            TeamMember(id: "preview-no-number", name: "Samira Huber", email: "samira@example.invalid", number: nil,
                personalDeviceCount: 0, personalDevices: [])
        ])
    static var membership: CloudMembership {
        CloudMembership(id: snapshot.tenantID, name: snapshot.tenantName, role: "member", number: "100",
            trial: .init(expires_at: nil, expired: false, telephony_status: "internal_ready"))
    }
    static var presence: TeamPresenceSnapshot {
        let now = Date().timeIntervalSince1970
        return TeamPresenceSnapshot(schemaVersion:1,tenantID:snapshot.tenantID,selfUserID:snapshot.selfUserID,
            collectorAvailable:true,observedAt:now,expiresAt:now+15,members:snapshot.members.map { member in
                if member.id == "preview-anna" {
                    return CallPresence(userID:member.id,state:"busy",callCount:1,peerNumber:"102",peerUserID:"preview-lukas",direction:"incoming")
                }
                if member.id == "preview-lukas" {
                    return CallPresence(userID:member.id,state:"busy",callCount:1,peerNumber:"101",peerUserID:"preview-anna",direction:"outgoing")
                }
                return CallPresence(userID:member.id,state:"idle",callCount:0,peerNumber:nil,peerUserID:nil,direction:nil)
            })
    }
}

@MainActor
final class TeamPreviewCore: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    func setSIPTracing(_ enabled: Bool) {}
    func register(account: SIPAccount, password: String, turnPassword: String) throws {}
    func unregister() throws {}
    func invite(number: String, id: UUID) throws { throw PhoneError.message("Vorschau: Anrufe sind deaktiviert.") }
    func answer(id: UUID) throws {}
    func end(id: UUID) throws {}
    func setMuted(_ muted: Bool, id: UUID) throws {}
    func setHeld(_ held: Bool, id: UUID) throws {}
    func sendDTMF(_ digit: String, id: UUID) throws {}
    func selectAudioDevice(id: String) throws {}
    func refreshAudioDevices() {}
    func setNetworkAvailable(_ available: Bool) {}
    func refreshRegistration() {}
}
#endif
