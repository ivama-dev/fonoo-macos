import SwiftUI

/// Native Mac presentation of the same sanitized diagnostics and engine coordinator.
/// Opening this view never starts a microphone test or changes the call's audio route.
struct MacDiagnosticsView: View {
    @EnvironmentObject private var phone: PhoneStore
    @ObservedObject var diagnostics: Diagnostics

    var body: some View {
        TabView {
            overview.tabItem { Label("Verbindung & Audio", systemImage: "waveform.path.ecg") }
            MacDiagnosticConsole(title: "Registrierungsprotokoll", messages: diagnostics.registrationEntries.map {
                .init(id: $0.id, date: $0.date, text: $0.message)
            }, emptyMessage: "Noch kein Registrierungsversuch in diesem App-Lauf protokolliert.")
                .tabItem { Label("Registrierung", systemImage: "network") }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("SIP-Mitschnitt aktiv", isOn: Binding(get: { phone.sipTracing }, set: { phone.setSIPTracing($0) }))
                    .disabled(!phone.supportsSIPTracing)
                Text(phone.supportsSIPTracing
                    ? "Vor dem Registrieren oder Wählen aktivieren. Gefilterte SIP-Adressen und Rufnummern; Authentifizierung, Schlüssel und nicht freigegebene Inhalte sind ausgeblendet. Maximal 150 Meldungen im Arbeitsspeicher."
                    : "Die aktive Engine stellt keinen SIP-Paketmitschnitt bereit.")
                    .font(.caption).foregroundStyle(.secondary)
                MacDiagnosticConsole(title: "SIP-Meldungen", messages: diagnostics.sipPackets.map {
                    .init(id: $0.id, date: $0.date, text: $0.direction + "\n" + $0.text)
                }, emptyMessage: phone.sipTracing ? "Warte auf SIP-Meldungen …" : "Mitschnitt ausgeschaltet.")
                Button("SIP-Meldungen löschen") { diagnostics.clearSIP() }
                    .disabled(diagnostics.sipPackets.isEmpty)
            }.padding()
                .tabItem { Label("SIP-Meldungen", systemImage: "text.alignleft") }
            MacDiagnosticConsole(title: "Ereignisse", messages: diagnostics.entries.reversed().map {
                .init(id: $0.id, date: $0.date, text: $0.message)
            }, emptyMessage: "Noch keine Ereignisse in diesem App-Lauf.")
                .tabItem { Label("Ereignisse", systemImage: "list.bullet") }
        }.padding(18)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("App") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Version", value: appVersion)
                        Text("Lokaler macOS-Entwicklungsbuild für Apple Silicon.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox { SIPConnectionStatusView().frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                GroupBox("Verbindung") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Registrierung", value: phone.registration.label)
                        LabeledContent("Netzwerk", value: phone.networkLabel)
                        LabeledContent("Gespräch", value: callStatus)
                        if !phone.account.server.isEmpty {
                            LabeledContent("Registrar / Proxy", value: phone.account.server)
                            LabeledContent("Transport / Port", value: "\(phone.account.transport.rawValue) · \(phone.account.port)")
                            LabeledContent("Medienverschlüsselung", value: phone.account.mediaEncryption.rawValue)
                            LabeledContent("Codec-Angebot", value: phone.account.compatibility.g711Only ? "G.711 PCMA/PCMU" : "SDK-Standard (Opus bevorzugt)")
                        }
                        Button("Verbindung erneut herstellen") {
                            Task {
                                do {
                                    try await phone.prepareExplicitCloudReconnect()
                                    try phone.reregisterSavedAccount()
                                } catch { phone.manager.show(error.localizedDescription) }
                            }
                        }.disabled(phone.busy || !phone.registration.canReconnect || !phone.hasSavedPassword)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Aktuelles Audio") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let media = diagnostics.media {
                            LabeledContent("Ausgehandelter Codec", value: media.codec)
                            LabeledContent("ICE / Medienweg", value: media.iceStatus)
                            LabeledContent("Audio-Richtung", value: media.audioDirection)
                            LabeledContent("Mikrofoneingang", value: media.inputDevice)
                            LabeledContent("Audioausgang", value: media.outputDevice)
                            LabeledContent("Empfang", value: String(format: "%.1f kbit/s", media.downloadKbps))
                            LabeledContent("Senden", value: String(format: "%.1f kbit/s", media.uploadKbps))
                            LabeledContent(media.jitterLabel, value: String(format: "%.1f ms", media.jitterMs))
                            LabeledContent("Paketverlust Empfang", value: String(format: "%.1f %%", media.lossPercent))
                        } else {
                            Text(phone.call == nil ? "Kein laufendes Gespräch." : "Noch keine Audiomesswerte der Engine.")
                        }
                        Text("Der tatsächliche Codec wird mit PBX und Gegenstelle ausgehandelt. Messwerte erscheinen während des Gesprächs; sie ersetzen keinen Hörtest.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.textSelection(.enabled).padding(12).frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
    private var callStatus: String {
        if phone.manager.transferPending { return "Vermittlung läuft" }
        if phone.manager.consultation != nil || phone.manager.consultationPending { return "Rückfrage" }
        guard let call = phone.call else { return phone.busy ? "Anruf wird vorbereitet" : "Kein laufendes Gespräch" }
        if call.isHeld { return "Gehalten" }
        if call.isRemoteHeld { return "Von der Gegenstelle gehalten" }
        switch call.phase {
        case .incoming: return "Eingehender Anruf"
        case .connecting: return "Verbindung wird aufgebaut"
        case .ringing: return "Gegenstelle klingelt"
        case .active: return "Verbunden"
        case .ending: return "Gespräch wird beendet"
        }
    }
}

private struct MacDiagnosticConsole: View {
    struct Message: Identifiable {
        let id: UUID
        let date: Date
        let text: String
    }
    let title: String
    let messages: [Message]
    let emptyMessage: String
    @State private var followLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Neueste Meldung verfolgen", isOn: $followLatest)
                Spacer()
                ShareLink(item: exportText) { Label("Protokoll teilen", systemImage: "square.and.arrow.up") }
                    .disabled(messages.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if messages.isEmpty { Text(emptyMessage).foregroundStyle(.secondary) }
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                    .foregroundStyle(.secondary)
                                Text(message.text).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding()
                }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onAppear { if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: messages.last?.id) { _, _ in
                        if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onChange(of: followLatest) { _, enabled in
                        if enabled { proxy.scrollTo("latest", anchor: .bottom) }
                    }
            }
            Text("Nur dieser App-Lauf. Teilen überträgt ausschließlich die angezeigten, bereits gefilterten Einträge.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
    private var exportText: String {
        title + "\n" + messages.map { "\($0.date.formatted(.iso8601)) \($0.text)" }.joined(separator: "\n\n")
    }
}
