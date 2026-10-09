import Foundation

enum SIPTransport: String, Codable, CaseIterable { case tls = "TLS", tcp = "TCP", udp = "UDP" }
enum SIPMediaEncryption: String, Codable, CaseIterable { case none = "RTP", srtp = "SRTP" }
enum SIPDTMF: String, Codable, CaseIterable { case rfc2833 = "RTP / RFC 4733", info = "SIP INFO" }

struct SIPAccount: Codable, Equatable {
    var server = ""
    var domain = ""
    var username = ""
    var authenticationName = ""
    var port = 5061
    var transport: SIPTransport = .tls
    var mediaEncryption: SIPMediaEncryption = .none
    var dtmf: SIPDTMF = .rfc2833

    // Retain the field for decoding old saved profiles; Cloud uses SIP digest.
    private var tlsClientCertificateEnabled: Bool?
    var usesTLSClientCertificate: Bool {
        get { tlsClientCertificateEnabled ?? false }
        set { tlsClientCertificateEnabled = newValue }
    }

    // Optional backing storage preserves decoding of accounts saved before ICE support.
    private var natSettings: SIPNATSettings?
    var nat: SIPNATSettings {
        get { natSettings ?? SIPNATSettings() }
        set { natSettings = newValue }
    }

    private var compatibilitySettings: SIPCompatibilitySettings?
    var compatibility: SIPCompatibilitySettings {
        get { compatibilitySettings ?? SIPCompatibilitySettings() }
        set { compatibilitySettings = newValue }
    }

    var effectiveDomain: String { domain.isEmpty ? server : domain }
    var effectiveAuthName: String { authenticationName.isEmpty ? username : authenticationName }

    func validated() throws -> SIPAccount {
        var value = self
        value.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        value.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.authenticationName = authenticationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        func validHost(_ host: String) -> Bool {
            !host.isEmpty && host.count <= 253 && host.unicodeScalars.allSatisfy(hostCharacters.contains)
                && !host.hasPrefix(".") && !host.hasSuffix(".")
        }
        guard validHost(value.server), validHost(value.effectiveDomain), (1...65535).contains(value.port) else {
            throw PhoneError.message("Bitte Registrar und SIP-Domain als Hostname oder IPv4-Adresse ohne https://, Pfad oder Port eingeben. Port: 1–65535.")
        }
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()+")
        guard !value.username.isEmpty, value.username.count <= 128,
              value.username.unicodeScalars.allSatisfy(userCharacters.contains),
              value.effectiveAuthName.count <= 256,
              !value.effectiveAuthName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PhoneError.message("Bitte einen SIP-Benutzernamen ohne @ oder Leerzeichen angeben. Einen abweichenden Authentifizierungsnamen separat eintragen.")
        }
        value.nat = try nat.validated()
        guard !compatibility.forceTURN || value.nat.usesTURN else {
            throw PhoneError.message("Für „TURN-Verbindung erzwingen“ müssen ICE und TURN aktiviert sein.")
        }
        return value
    }

    static func normalizedNumber(_ input: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "0123456789+*# ()-./")
        guard input.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PhoneError.message("Bitte eine Rufnummer eingeben.")
        }
        let number = input.filter { "0123456789+*#".contains($0) }
        guard !number.isEmpty, number.count <= 64, number != "+",
              !number.dropFirst().contains("+") else { throw PhoneError.message("Ungültige Rufnummer.") }
        return number
    }
}

enum PhoneError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

/// Passwords are deliberately excluded from this observable, Codable configuration.
struct SIPNATSettings: Codable, Equatable {
    var iceEnabled = false
    var stunServer = ""
    var stunPort = 3478
    var turnEnabled = false
    var turnServer = ""
    var turnPort = 443
    var turnTransport: SIPTransport = .tcp
    var turnUsername = "cloud_turn"

    var usesTURN: Bool { iceEnabled && turnEnabled }
    // liblinphone uses one endpoint per policy; TURN supersedes standalone STUN.
    var effectiveEndpoint: String? {
        guard iceEnabled else { return nil }
        return turnEnabled ? "\(turnServer):\(turnPort)" : "\(stunServer):\(stunPort)"
    }
    func canReuseTURNPassword(from saved: SIPNATSettings) -> Bool {
        turnServer.lowercased() == saved.turnServer.lowercased() && turnPort == saved.turnPort
            && turnTransport == saved.turnTransport && turnUsername == saved.turnUsername
    }
    func validated() throws -> SIPNATSettings {
        var value = self
        value.stunServer = stunServer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value.turnServer = turnServer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value.turnUsername = turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        func validHost(_ host: String) -> Bool {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
            return !host.isEmpty && host.count <= 253 && host.unicodeScalars.allSatisfy(allowed.contains)
                && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                }
        }
        if iceEnabled {
            let host = turnEnabled ? value.turnServer : value.stunServer
            let port = turnEnabled ? turnPort : stunPort
            guard validHost(host), (1...65535).contains(port) else {
                throw PhoneError.message("STUN/TURN: Bitte einen Hostnamen oder eine IPv4-Adresse ohne Präfix, Port oder Zusatz eingeben. Port separat: 1–65535.")
            }
        }
        if usesTURN {
            guard !value.turnUsername.isEmpty, value.turnUsername.count <= 256,
                  !value.turnUsername.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PhoneError.message("Bitte einen gültigen TURN-Benutzer eingeben.")
            }
        }
        return value
    }
}

/// Opt-in interoperability settings; legacy accounts retain the SDK codec selection.
struct SIPCompatibilitySettings: Codable, Equatable {
    var g711Only = false
    var forceTURN = false
    func allowsCodec(mime: String, rate: Int) -> Bool {
        !g711Only || (rate == 8000 && ["PCMA", "PCMU"].contains(mime.uppercased()))
    }
}

// A legacy directly configured PBX account must never register after a Cloud-only update.
extension SIPAccount {
    func isSelectedCloudProfile(endpointID: String?) -> Bool {
        guard let endpointID, !endpointID.isEmpty, endpointID == username else { return false }
        return transport == .tls && port == 5061 && mediaEncryption == .srtp
            && server == effectiveDomain && !usesTLSClientCertificate
    }
}
