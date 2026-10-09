import Combine
import Foundation

@MainActor
final class Diagnostics: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let message: String
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var registrationEntries: [Entry] = []
    func recordRegistration(_ message: String) {
        registrationEntries.append(Entry(message: message))
        if registrationEntries.count > 300 { registrationEntries.removeFirst(registrationEntries.count - 300) }
    }
    @Published private(set) var sipPackets: [SIPTracePacket] = []
    func recordSIP(_ packet: SIPTracePacket) {
        sipPackets.append(packet)
        if sipPackets.count > 150 { sipPackets.removeFirst(sipPackets.count - 150) }
    }
    func clearSIP() { sipPackets.removeAll() }
    @Published var media: MediaSnapshot?
    // Only application-defined state descriptions belong here. Never raw SIP messages,
    // remote display names, addresses, credentials or dialed DTMF sequences.
    func record(_ message: String) {
        entries.insert(Entry(message: message), at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
    }
}

/// Converts complete SDK packet dumps to a deliberately restricted diagnostic view.
/// Raw text never crosses into the observable store or an async task.
struct SIPTracePacket: Identifiable, Sendable {
    let id = UUID()
    let date = Date()
    let direction: String
    let text: String

    static func sanitized(_ raw: String) -> SIPTracePacket? {
        guard raw.utf8.count <= 65_536 else { return nil }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let methods = ["REGISTER", "INVITE", "ACK", "BYE", "CANCEL", "OPTIONS", "INFO", "UPDATE", "PRACK", "SUBSCRIBE", "NOTIFY", "REFER", "MESSAGE", "PUBLISH"]
        guard let start = lines.firstIndex(where: { line in
            line.hasPrefix("SIP/2.0 ") || (methods.contains(String(line.split(separator: " ").first ?? "")) && line.hasSuffix(" SIP/2.0"))
        }) else { return nil }
        let prefix = lines[..<start].joined(separator: " ").lowercased()
        // Only actual channel send/receive dumps, not incidental parser/auth logs.
        guard prefix.contains("channel"), prefix.contains("received") || prefix.contains("sent") else { return nil }
        let direction = prefix.contains("received") ? "EMPFANGEN" : "GESENDET"
        let allowed: Set<String> = ["via", "v", "from", "f", "to", "t", "contact", "m", "call-id", "i", "cseq", "max-forwards", "expires", "min-expires", "route", "record-route", "allow", "supported", "k", "require", "unsupported", "user-agent", "server", "content-type", "c", "content-length", "l", "accept", "retry-after", "date", "allow-events", "event", "subscription-state", "refer-to", "referred-by", "replaces", "session-expires", "min-se"]
        func hideURISecrets(_ value: String) -> String {
            value.replacingOccurrences(of: "(?i)(sips?:[^\\s<>:@]+):[^\\s<>@]*@", with: "$1:[ausgeblendet]@", options: .regularExpression)
                .replacingOccurrences(of: "(?i)(sips?:[^\\s<>?]+)\\?[^\\s<>]*", with: "$1?[ausgeblendet]", options: .regularExpression)
        }
        var output = [hideURISecrets(lines[start])]
        var headers: [(String, String)] = []
        var bodyStart = lines.count
        for index in (start + 1)..<lines.count {
            let line = lines[index]
            if line.isEmpty { bodyStart = index + 1; break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !headers.isEmpty { headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces) }
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        var sdp = false
        for (name, value) in headers {
            let key = name.lowercased()
            if key == "content-type" || key == "c" { sdp = value.lowercased().hasPrefix("application/sdp") }
            // Authentication challenges are shown only as header names: no nonce/digest/token.
            output.append(allowed.contains(key) ? "\(name): \(hideURISecrets(value))" : "\(name): [ausgeblendet]")
        }
        if bodyStart < lines.count, lines[bodyStart...].contains(where: { !$0.isEmpty }) {
            output.append("")
            if sdp {
                for line in lines[bodyStart...] where !line.isEmpty {
                    let safe = ["v=", "o=", "s=", "c=", "t=", "m=", "a=rtpmap:", "a=fmtp:", "a=rtcp:", "a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive", "a=ptime:", "a=maxptime:"].contains(where: line.hasPrefix)
                    if line.hasPrefix("a=candidate:") {
                        // Only the mandatory candidate fields; extensions can contain ICE usernames.
                        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                        if fields.count >= 8, fields[6] == "typ",
                           ["host", "srflx", "prflx", "relay"].contains(String(fields[7])),
                           UInt(fields[1]) != nil, UInt(fields[3]) != nil, UInt16(fields[5]) != nil {
                            output.append(fields.prefix(8).joined(separator: " "))
                        } else { output.append("[ICE-Kandidat ausgeblendet]") }
                    } else {
                        output.append(safe ? hideURISecrets(line) : "[SDP-Zeile ausgeblendet]")
                    }
                }
            } else { output.append("[Nachrichteninhalt ausgeblendet]") }
        }
        return SIPTracePacket(direction: direction, text: output.joined(separator: "\n"))
    }
}

/// Recognize only known engine events. Never retain raw SDK text or TURN credentials.
enum MediaTrace {
    static func sanitized(_ raw: String) -> String? {
        guard raw.utf8.count <= 65_536 else { return nil }
        let events = [
            ("ice: Recv TURN allocate success response:", "TURN: Relay-Zuweisung vom Server bestätigt."),
            ("ice: Recv TURN create permission success response:", "TURN: Freigabe für die Gegenstelle bestätigt."),
            ("ice: Recv TURN channel bind success response:", "TURN: Kanalbindung bestätigt."),
            ("ice: Finished candidates gathering for check list", "ICE: Ermittlung der Verbindungskandidaten abgeschlossen."),
            ("ice: Gathering timeout for checklist", "ICE: Zeitüberschreitung bei der Kandidatenermittlung."),
            ("No auth info found for STUN auth request", "STUN/TURN: Engine findet keine passenden Zugangsdaten."),
            ("Failed to resolve STUN server for ICE gathering", "STUN/TURN: Serverauflösung fehlgeschlagen."),
            ("ICE mismatch for checklist", "ICE: Gegenstelle und angebotene Medienadresse passen nicht zusammen."),
            ("There are no selected valid remote candidates for RTP.", "ICE: Kein gültiger RTP-Kandidat der Gegenstelle ausgewählt.")
        ]
        return events.first(where: { raw.contains($0.0) })?.1
    }
}
