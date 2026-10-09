import Foundation

@main
struct NATChecks {
    static func main() throws {
        let legacy = Data(#"{"server":"pbx.example.org","domain":"example.org","username":"500","authenticationName":"","port":5061,"transport":"TLS","mediaEncryption":"RTP","dtmf":"RTP / RFC 4733"}"#.utf8)
        var account = try JSONDecoder().decode(SIPAccount.self, from: legacy)
        precondition(account.username == "500" && account.server == "pbx.example.org")
        precondition(!account.nat.iceEnabled && account.nat.effectiveEndpoint == nil)
        precondition(account.compatibility == SIPCompatibilitySettings())
        precondition(!account.usesTLSClientCertificate)
        precondition(!account.isSelectedCloudProfile(endpointID: "500"))
        var cloudAccount = account
        cloudAccount.usesTLSClientCertificate = false
        cloudAccount.mediaEncryption = .srtp
        let cloudReloaded = try JSONDecoder().decode(SIPAccount.self, from: JSONEncoder().encode(cloudAccount))
        precondition(!cloudReloaded.usesTLSClientCertificate)
        precondition(cloudReloaded.transport == .tls && cloudReloaded.mediaEncryption == .srtp)
        var forceWithoutTURN = account
        forceWithoutTURN.compatibility.forceTURN = true
        do { _ = try forceWithoutTURN.validated(); fatalError("Forced relay without TURN accepted") } catch {}
        account.compatibility.g711Only = true
        precondition(account.compatibility.allowsCodec(mime: "pcma", rate: 8000))
        precondition(account.compatibility.allowsCodec(mime: "PCMU", rate: 8000))
        precondition(!account.compatibility.allowsCodec(mime: "opus", rate: 48000))
        precondition(!account.compatibility.allowsCodec(mime: "PCMA", rate: 16000))
        precondition(account.transport == .tls && account.port == 5061)
        precondition(account.nat.stunServer.isEmpty && account.nat.turnServer.isEmpty)
        account.nat.stunServer = "stun.example.test"
        account.nat.turnServer = "turn.example.test"
        account.nat.iceEnabled = true
        precondition(account.nat.effectiveEndpoint == "stun.example.test:3478")
        account.nat.turnEnabled = true
        precondition(account.nat.effectiveEndpoint == "turn.example.test:443")
        account.nat.turnTransport = .tcp
        account.compatibility.forceTURN = true
        let checked = try account.validated()
        let decoded = try JSONDecoder().decode(SIPAccount.self, from: JSONEncoder().encode(checked))
        precondition(decoded == checked)
        precondition(decoded.compatibility.g711Only && decoded.compatibility.forceTURN)
        var restored = decoded
        restored.compatibility = SIPCompatibilitySettings()
        precondition(restored.compatibility.allowsCodec(mime: "opus", rate: 48000))
        precondition(restored.nat == decoded.nat && restored.transport == decoded.transport)
        let nat = checked.nat
        precondition(nat.canReuseTURNPassword(from: nat))
        for mutate: (inout SIPNATSettings) -> Void in [
            { $0.turnServer = "other.example.org" }, { $0.turnPort = 3478 },
            { $0.turnTransport = .tls }, { $0.turnUsername = "other" }
        ] {
            var changed = nat; mutate(&changed)
            precondition(!changed.canReuseTURNPassword(from: nat))
        }
        var disabled = nat; disabled.iceEnabled = false
        precondition(!disabled.usesTURN && disabled.effectiveEndpoint == nil)
        precondition(disabled.canReuseTURNPassword(from: nat))
        for invalid in ["https://turn.example.org", "host:443", "host?transport=tcp", "host\nname", "a..b", "-host"] {
            var bad = nat; bad.turnServer = invalid
            do { _ = try bad.validated(); fatalError("Invalid endpoint accepted") } catch { }
        }
        for port in [0, -1, 65536] {
            var bad = nat; bad.turnPort = port
            do { _ = try bad.validated(); fatalError("Invalid port accepted") } catch { }
        }
        var emptyUser = nat; emptyUser.turnUsername = " "
        do { _ = try emptyUser.validated(); fatalError("Empty TURN user accepted") } catch { }
        var selected = SIPAccount()
        selected.server = "pbx.example.test"; selected.domain = selected.server
        selected.username = "cloud-device"; selected.mediaEncryption = .srtp
        precondition(selected.isSelectedCloudProfile(endpointID: "cloud-device"))
        precondition(!selected.isSelectedCloudProfile(endpointID: nil))
        precondition(!selected.isSelectedCloudProfile(endpointID: "other"))
        selected.usesTLSClientCertificate = true
        precondition(!selected.isSelectedCloudProfile(endpointID: "cloud-device"))
        print("PASS: legacy account migration, NAT persistence, endpoint selection, credential scope, disabling ICE and input validation")
    }
}
