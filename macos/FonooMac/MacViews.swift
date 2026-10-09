import AppKit
import Combine
import SwiftUI

enum MacStyle {
    static let accent = Color(red: 0.43, green: 0.29, blue: 0.85)
}

enum MacDestination: String, CaseIterable, Identifiable {
    case conversation = "Gespräch", dial = "Wählen", favorites = "Favoriten", recents = "Anrufliste", contacts = "Kontakte", team = "Team", account = "Konto", diagnostics = "Diagnose"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .conversation: "phone.fill"
        case .dial: "circle.grid.3x3.fill"
        case .favorites: "star"
        case .recents: "clock"
        case .contacts: "person.crop.rectangle"
        case .team: "person.2.fill"
        case .account: "person.crop.circle"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct MacRootView: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var customer: CustomerAccount
    @State private var destination: MacDestination? = .dial
    @State private var destinationBeforeCall: MacDestination = .dial
    @State private var dialNumber = ""
    @State private var audioPresented = false
    @State private var availabilityPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previousColumnVisibility: NavigationSplitViewVisibility = .all
    var isPreview = false
    var isTeamPreview = false
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("fonoo").font(.system(size: 32, weight: .heavy)).tracking(-1.5)
                    Circle().fill(MacStyle.accent).frame(width: 8, height: 8)
                }.padding(.horizontal, 16).padding(.top, 20)
                List(selection: $destination) {
                    if phone.call != nil {
                        Label("Gespräch", systemImage: "phone.fill").tag(MacDestination.conversation)
                    }
                    ForEach(MacDestination.allCases.filter { $0 != .conversation }) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label(phone.registration == .registered ? "Verbunden" : phone.registration.label,
                          systemImage: phone.registration == .registered ? "circle.fill" : "circle")
                        .font(.caption).foregroundStyle(phone.registration == .registered ? .green : .secondary)
                    Text("Liblinphone").font(.caption).foregroundStyle(.secondary)
                    if let membership = customer.activeCloudMembership {
                        Text(membership.name).font(.caption)
                        Text("Nebenstelle " + (membership.number ?? "–")).font(.caption).foregroundStyle(.secondary)
                    }
                    if customer.teamContext != nil {
                        Button("Profile verwalten") { availabilityPresented = true }
                    } else { Toggle("Nicht stören", isOn: $phone.doNotDisturb).toggleStyle(.checkbox) }
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if phone.call != nil && destination != .conversation {
                    MacCallReturnBar { destination = .conversation }
                }
                if phone.call != nil && destination == .conversation {
                    MacCallView()
                } else if destination == .diagnostics {
                    MacDiagnosticsView(diagnostics: phone.diagnostics)
                } else if customer.needsPasswordSetup {
                    MacAccountView()
                } else if destination == .team && customer.signedIn {
                    TeamView()
                } else if (isPreview || customer.signedIn && phone.hasSavedPassword) && destination != .account {
                    switch destination ?? .dial {
                    case .conversation, .dial: MacDialView(number: $dialNumber)
                    case .favorites: MacFavoritesView()
                    case .recents: MacRecentsView()
                    case .contacts: MacContactsView()
                    case .team: TeamView()
                    case .account: MacAccountView()
                    case .diagnostics: MacDiagnosticsView(diagnostics: phone.diagnostics)
                    }
                } else { MacAccountView() }
                if let notice = phone.notice {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(notice).textSelection(.enabled)
                        Spacer()
                        Button { phone.clearNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding().background(.quaternary)
                }
            }
            .navigationTitle(phone.call != nil && destination == .conversation ? "Gespräch" :
                (customer.needsPasswordSetup ? "Konto einrichten" : isPreview || customer.signedIn ? (destination?.rawValue ?? "fonoo") : "Anmelden"))
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ToolbarItemGroup { AvailabilityProfileMenu(); MacAudioMenu(isPresented: $audioPresented) } }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $audioPresented) {
            MacAudioSettingsView { audioPresented = false }
                .frame(maxHeight: .infinity, alignment: .top)
                .inspectorColumnWidth(min: 360, ideal: 360, max: 400)
        }
        .onAppear { if isTeamPreview { destination = .team } }
        .sheet(isPresented:$availabilityPresented) { AvailabilityView() }
        .onChange(of: audioPresented) { _, presented in
            if presented {
                previousColumnVisibility = columnVisibility
                columnVisibility = .detailOnly
            } else { columnVisibility = previousColumnVisibility }
        }
        .onChange(of: phone.call?.id, initial: true) { _, id in
            if id != nil {
                if let destination, destination != .conversation { destinationBeforeCall = destination }
                destination = .conversation
            } else if destination == .conversation || destination == nil {
                destination = destinationBeforeCall
            }
        }
    }
}

struct MacAccountView: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var customer: CustomerAccount
    @State private var usePassword = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupBox { SIPConnectionStatusView().frame(maxWidth: .infinity, alignment: .leading) }
                Text(customer.signedIn ? "Dein fonoo-Konto" : "Willkommen auf deinem Mac")
                    .font(.largeTitle.bold())
                Text(customer.signedIn ? customer.email : "Melde dich an. Deine Firma und Nebenstelle werden automatisch eingerichtet.")
                    .foregroundStyle(.secondary)
                if !customer.signedIn {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("E-Mail-Adresse", text: $customer.email).textContentType(.emailAddress)
                        Picker("Anmelden mit", selection: $usePassword) {
                            Text("Passwort").tag(true)
                            Text("E-Mail-Code").tag(false)
                        }.pickerStyle(.segmented)
                        if usePassword {
                            SecureField("Passwort", text: $customer.password)
                                .onSubmit { login() }
                            Button("Anmelden", action: login)
                                .buttonStyle(.borderedProminent)
                                .disabled(customer.email.isEmpty || customer.password.isEmpty)
                        } else if customer.challenge.isEmpty {
                            Button("Anmeldecode senden") { Task { await customer.sendCode() } }
                                .disabled(customer.email.isEmpty)
                        } else {
                            TextField("Sechsstelliger Code", text: $customer.code)
                                .onSubmit { Task { await customer.verify() } }
                            Button("Code bestätigen") { Task { await customer.verify() } }
                                .buttonStyle(.borderedProminent).disabled(customer.code.count != 6)
                            Button("Neuen Code senden") { Task { await customer.sendCode() } }
                        }
                    }.textFieldStyle(.roundedBorder).controlSize(.large).frame(maxWidth: 380)
                } else {
                    if !customer.passwordManaged && (!customer.rememberedDevice || customer.needsPasswordSetup) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 14) {
                                if !customer.rememberedDevice || !customer.challenge.isEmpty {
                                    Text("Diesen Mac merken").font(.title2.bold())
                                    Text("Bestätige diesen Mac einmal mit dem E-Mail-Code. Danach bleibt fonoo hier automatisch angemeldet.")
                                    if customer.challenge.isEmpty {
                                        Button("E-Mail-Code senden") { Task { await customer.sendCode() } }
                                    } else {
                                        TextField("Sechsstelliger Code", text: $customer.code).textContentType(.oneTimeCode)
                                        Button("Mac bestätigen") { Task { await customer.verify() } }
                                            .buttonStyle(.borderedProminent).disabled(customer.code.count != 6)
                                    }
                                } else if customer.needsPasswordSetup {
                                    Text("Dein Kennwort festlegen").font(.title2.bold())
                                    Text("Mindestens 15 Zeichen. Verwende eine längere Wortfolge oder einen Passwortmanager.")
                                    SecureField("Neues Kennwort", text: $customer.password).textContentType(.newPassword)
                                    SecureField("Kennwort wiederholen", text: $customer.passwordConfirmation).textContentType(.newPassword)
                                        .onSubmit { Task { await customer.setOwnPassword() } }
                                    Button("Kennwort speichern") { Task { await customer.setOwnPassword() } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(customer.password.count < 15 || customer.password != customer.passwordConfirmation)
                                    Button("E-Mail erneut bestätigen") { Task { await customer.sendCode() } }
                                }
                            }.textFieldStyle(.roundedBorder).frame(maxWidth: 400, alignment: .leading).padding(8)
                        }
                    } else if customer.rememberedDevice {
                        Label("Dieser Mac bleibt angemeldet", systemImage: "checkmark.shield")
                    }
                    ForEach(customer.cloudMemberships) { membership in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(membership.name).font(.headline)
                                Text(membership.number.map { "Nebenstelle \($0)" } ?? "Noch keine Nebenstelle zugewiesen")
                                if customer.configuringTenantID == membership.id {
                                    ProgressView("Nebenstelle wird eingerichtet …")
                                } else if customer.isCloudConfigured(membership, phone: phone) {
                                    Text(phone.registration.label).foregroundStyle(.secondary)
                                    if phone.registration != .registered {
                                        Button("Erneut verbinden") {
                                            Task {
                                                do {
                                                    try await phone.prepareExplicitCloudReconnect()
                                                    try phone.reregisterSavedAccount()
                                                } catch { phone.manager.show(error.localizedDescription) }
                                            }
                                        }.disabled(phone.busy)
                                    }
                                } else if membership.trial.expired {
                                    Text("Die Testzeit ist beendet.")
                                } else if membership.number == nil || membership.trial.telephony_status != "internal_ready" {
                                    Text("Deine Telefonie wird noch vorbereitet.")
                                } else {
                                    Button("Mit dieser Firma telefonieren") {
                                        Task { await customer.applyCloud(membership, to: phone) }
                                    }.disabled(phone.busy)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    if customer.cloudMemberships.isEmpty {
                        Text("Noch keine Firma zugeordnet. Verwende dasselbe Konto wie auf deinem iPhone.")
                    }
                    Text("Für eingehende Anrufe muss fonoo laufen und dein Mac wach sein. Du kannst das Fenster schließen; fonoo bleibt in der Menüleiste geöffnet. Gleichzeitiges Klingeln auf iPhone und Mac ist in dieser Testversion noch nicht verfügbar.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Status aktualisieren") { Task { await customer.refresh() } }
                        Link("Kundenbereich öffnen", destination: URL(string: "https://dev.fonoo.app/kunden/")!)
                    }
                    Button("Abmelden") { Task { await customer.signOut() } }.disabled(phone.busy)
                }
                if customer.busy { ProgressView("Bitte warten …") }
                if !customer.message.isEmpty { Text(customer.message).textSelection(.enabled) }
                if !customer.cloudMessage.isEmpty { Text(customer.cloudMessage).foregroundStyle(.secondary) }
            }.frame(maxWidth: 580, alignment: .leading).padding(36).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(customer.busy)
        .onDisappear { customer.password = ""; customer.passwordConfirmation = "" }
    }
    private func login() { Task { await customer.signInWithPassword() } }
}

struct MacDialView: View {
    @EnvironmentObject private var phone: PhoneStore
    @Binding var number: String
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            Image(systemName: "phone.bubble").font(.system(size: 32)).foregroundStyle(MacStyle.accent)
            Text("Wen möchtest du anrufen?").font(.title2.bold())
            HStack {
                TextField("Nummer oder Nebenstelle", text: $number)
                    .textFieldStyle(.plain).font(.title2).onSubmit { dial() }
                if !number.isEmpty {
                    Button { number.removeLast() } label: { Image(systemName: "delete.left") }
                        .buttonStyle(.plain).help("Letzte Ziffer löschen")
                }
            }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        number += key
                        if !phone.busy { MacDialpadFeedback.shared.play(key) }
                    } label: {
                        Text(key).font(.title2).frame(maxWidth: .infinity, minHeight: 34)
                    }.controlSize(.large)
                }
            }
            Button(action: dial) {
                Label("Anrufen", systemImage: "phone.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty || phone.busy || phone.registration != .registered)
            Spacer(minLength: 10)
        }.frame(maxWidth: 340).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func dial() { phone.dial(number) }
}

struct MacContactRow: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var customer: CustomerAccount
    let contact: Contact
    var body: some View {
        HStack(spacing: 12) {
            Text(contact.initials).font(.headline).frame(width: 38, height: 38)
                .background(MacStyle.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.name).font(.headline)
                Text(contact.number).foregroundStyle(.secondary)
                if let member = customer.presenceMember(for:contact) { PresenceStatusView(userID:member.id) }
            }
            Spacer()
            Button { phone.toggleFavorite(contact) } label: {
                Image(systemName: phone.favorites.contains(where: { $0.id == contact.id }) ? "star.fill" : "star")
            }.buttonStyle(.borderless).help("Favorit umschalten")
            Button { phone.start(contact) } label: { Image(systemName: "phone.fill") }
                .disabled(phone.busy || phone.registration != .registered).help("Anrufen")
        }.padding(.vertical, 5)
    }
}

struct MacFavoritesView: View {
    @EnvironmentObject private var phone: PhoneStore
    var body: some View {
        if phone.favorites.isEmpty {
            ContentUnavailableView("Deine Favoriten", systemImage: "star", description: Text("Markiere Kontakte mit einem Stern, um sie hier schnell anzurufen."))
        } else {
            List(phone.favorites) { MacContactRow(contact: $0) }
        }
    }
}

struct MacRecentsView: View {
    @EnvironmentObject private var phone: PhoneStore
    @State private var detailCall: RecentCall?
    @State private var deleteCandidate: RecentCall?
    @State private var deleteConfirmation = false
    var body: some View {
        Group {
            if phone.recents.isEmpty {
                ContentUnavailableView("Noch keine Anrufe", systemImage: "clock", description: Text(phone.manager.historyStatus.isEmpty ? "Deine Gespräche erscheinen hier." : phone.manager.historyStatus))
            } else {
                List(phone.recents) { recent in
                    VStack(alignment: .leading, spacing: 4) {
                        MacContactRow(contact: recent.contact)
                        HStack {
                            Text(recent.missed ? "Verpasst" : recent.detail).foregroundStyle(recent.missed ? .red : .secondary)
                            if let duration = recent.duration, duration > 0 {
                                Text("\(Int(duration) / 60) Min. \(Int(duration) % 60) Sek.")
                            }
                            Spacer()
                            Text(recent.date, format: .dateTime.day().month().hour().minute())
                            Menu {
                                actions(for: recent)
                            } label: {
                                Image(systemName: "ellipsis")
                            }.menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("Anrufaktionen")
                                .help("Details und Löschen")
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                        .contextMenu { actions(for: recent) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !phone.manager.historyStatus.isEmpty {
                Text(phone.manager.historyStatus).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .onAppear { phone.manager.onHistoryRefresh?() }
        .toolbar {
            ToolbarItem {
                Button { phone.manager.onHistoryRefresh?() } label: {
                    Label("Anrufliste aktualisieren", systemImage: "arrow.clockwise")
                }.disabled(phone.manager.onHistoryRefresh == nil)
            }
        }
        .sheet(item: $detailCall) { MacRecentCallDetails(recent: $0) }
        .alert("Anruf löschen?", isPresented: $deleteConfirmation, presenting: deleteCandidate) { recent in
            Button("Abbrechen", role: .cancel) { deleteCandidate = nil }
            Button("Löschen", role: .destructive) {
                phone.manager.deleteRecents(ids: [recent.id])
                deleteCandidate = nil
            }
        } message: { _ in
            Text(phone.manager.historyStatus.isEmpty
                 ? "Dieser Eintrag wird aus der Anrufliste auf diesem Mac gelöscht."
                 : "Dieser Eintrag wird für dein fonoo-Konto in dieser Firma auf allen Geräten gelöscht. Die Anruflisten anderer Teammitglieder bleiben erhalten.")
        }
    }
    @ViewBuilder private func actions(for recent: RecentCall) -> some View {
        Button("Anrufdetails", systemImage: "info.circle") { detailCall = recent }
        Divider()
        Button("Anruf löschen", systemImage: "trash", role: .destructive) {
            deleteCandidate = recent
            deleteConfirmation = true
        }
    }
}

private struct MacRecentCallDetails: View {
    @Environment(\.dismiss) private var dismiss
    let recent: RecentCall
    private var durationText: String {
        guard let duration = recent.duration else { return "Nicht erfasst" }
        let seconds = Int(duration)
        return "\(seconds / 60) Min. \(seconds % 60) Sek."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Anrufdetails").font(.title2.bold())
            Text(recent.contact.name).font(.headline)
            if recent.contact.number != "anonymous" {
                LabeledContent("Rufnummer", value: recent.contact.number).textSelection(.enabled)
            }
            LabeledContent("Zeitpunkt", value: recent.date.formatted(date: .abbreviated, time: .standard))
            LabeledContent("Ergebnis", value: recent.detail)
            if let incoming = recent.incoming {
                LabeledContent("Richtung", value: incoming ? "Eingehend" : "Ausgehend")
            }
            LabeledContent("Gesprächsdauer", value: durationText)
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
    }
}

struct MacContactsView: View {
    @StateObject private var directory = ContactsDirectory()
    @State private var query = ""
    var body: some View {
        VStack {
            if directory.canRead {
                List(directory.contacts.filter { query.isEmpty || $0.matches(query) }) { contact in
                    ForEach(contact.numbers) { number in MacContactRow(contact: contact.callContact(for: number)) }
                }.searchable(text: $query, prompt: "Name oder Telefonnummer")
            } else {
                ContentUnavailableView {
                    Label("Kontakte auf deinem Mac", systemImage: "person.crop.rectangle")
                } description: {
                    Text("Namen und Telefonnummern bleiben auf deinem Gerät.")
                } actions: {
                    if directory.access == .notRequested {
                        Button("Kontakte freigeben") { Task { await directory.requestAccess() } }
                    } else {
                        Link("Datenschutzeinstellungen öffnen", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
                    }
                }
            }
            if directory.isLoading { ProgressView() }
            if let error = directory.errorMessage { Text(error).padding() }
        }.task { await directory.refresh() }
    }
}

struct MacAudioMenu: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented.toggle() } label: { Label("Audio", systemImage: "headphones") }
            .accessibilityLabel("Audioeinstellungen")
            .help("Mikrofon und Lautsprecher auswählen")
    }
}

private struct MacAudioSettingsView: View {
    @EnvironmentObject private var phone: PhoneStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MacDialpadFeedback.preferenceKey) private var dialpadSounds = true
    @ObservedObject private var meter = MacMicrophoneMeter.shared
    @State private var hardware = MacAudioHardware()
    @State private var permissionRequest = 0
    @State private var routeSelection = 0
    @State private var detectedDeviceUIDs: [String] = []
    let dismiss: () -> Void
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var inputs: [AudioDeviceOption] { devices(prefix: "input:") }
    private var outputs: [AudioDeviceOption] { devices(prefix: "output:") }
    private var selectedInput: AudioDeviceOption? { inputs.first(where: \.isSelected) }
    private var selectedOutput: AudioDeviceOption? { outputs.first(where: \.isSelected) }
    private struct MonitorRequest: Hashable {
        let inputID: String?
        let uid: String?
        let busy: Bool
        let active: Bool
        let permission: Int
        let selection: Int
    }
    private var monitorRequest: MonitorRequest {
        MonitorRequest(inputID: selectedInput?.id, uid: selectedInput.flatMap { hardware.uid(for: $0) },
            busy: phone.busy, active: scenePhase == .active, permission: permissionRequest, selection: routeSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Dein Audio").font(.title3.bold())
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Audioeinstellungen schließen")
                    .help("Schließen")
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Mikrofon", systemImage: "mic").font(.headline)
                devicePicker("Mikrofon", options: inputs, selected: selectedInput)
                if let input = selectedInput, let name = hardware.systemName(for: input) {
                    Text("Aktuell: " + name).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Mikrofonpegel").font(.caption.weight(.medium))
                        Spacer()
                        if meter.status == .listening {
                            Text("Live").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    MacMicrophoneLevelView(level: meter.level, muted: meter.status == .muted)
                    Text(meter.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if meter.status == .needsPermission {
                        Button("Mikrofon testen") { permissionRequest += 1 }
                            .buttonStyle(.borderedProminent)
                    } else if meter.status == .denied {
                        Link("Mikrofon freigeben", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MacStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Lautsprecher", systemImage: "speaker.wave.2").font(.headline)
                devicePicker("Lautsprecher oder Kopfhörer", options: outputs, selected: selectedOutput)
                if let output = selectedOutput, let name = hardware.systemName(for: output) {
                    Text("Aktuell: " + name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(phone.busy ? "Die Anzeige zeigt den Mikrofonpegel deines Gesprächs." : "Der Mikrofontest läuft nur in diesem Fenster. Es wird nichts aufgenommen.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Tastentöne beim Wählen", isOn: $dialpadSounds)
        }.padding(22).frame(width: 360)
        .onAppear { refreshHardware() }
        .onReceive(refresh) { _ in refreshHardware() }
        .task(id: monitorRequest) {
            if monitorRequest.active {
                await meter.monitor(input: selectedInput, hardware: hardware, manager: phone.manager, requestPermission: permissionRequest > 0)
            } else { meter.stop() }
        }
        .onDisappear { meter.stop() }
    }
    private func devicePicker(_ title: String, options: [AudioDeviceOption], selected: AudioDeviceOption?) -> some View {
        Picker(title, selection: Binding(get: { selected?.id ?? "" }, set: { id in
            guard !id.isEmpty, selected?.id != id else { return }
            meter.suspendLocalCapture()
            phone.setAudio(id)
            routeSelection += 1
        })) {
            if selected == nil { Text(options.isEmpty ? "Kein Gerät verfügbar" : "Bitte auswählen").tag("") }
            ForEach(options) { device in Text(hardware.name(for: device)).tag(device.id) }
        }.labelsHidden().pickerStyle(.menu).controlSize(.large).frame(maxWidth: .infinity)
            .disabled(options.isEmpty)
            .accessibilityLabel(title)
    }
    private func devices(prefix: String) -> [AudioDeviceOption] {
        phone.audioDevices.filter { $0.id.hasPrefix(prefix) }.sorted { lhs, rhs in
            let leftDefault = MacAudioHardware.isSystemDefault(lhs)
            let rightDefault = MacAudioHardware.isSystemDefault(rhs)
            if leftDefault != rightDefault { return leftDefault }
            return hardware.name(for: lhs).localizedStandardCompare(hardware.name(for: rhs)) == .orderedAscending
        }
    }
    private func refreshHardware() {
        let current = MacAudioHardware()
        let uids = current.devices.map(\.uid).sorted()
        if !phone.busy, detectedDeviceUIDs != uids {
            phone.manager.reloadAudioDevices()
            detectedDeviceUIDs = uids
        } else { phone.manager.refreshAudioDevices() }
        hardware = current
    }
}

private struct MacMicrophoneLevelView: View {
    let level: Double
    let muted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<20, id: \.self) { index in
                Capsule().fill(level > Double(index) / 20 && !muted ? MacStyle.accent : Color.secondary.opacity(0.15))
                    .frame(maxWidth: .infinity).frame(height: 14)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mikrofonpegel")
        .accessibilityValue(muted ? "Stummgeschaltet" : "\(Int(level * 100)) Prozent")
    }
}

/// Keeps a call reachable while looking up contacts or recent calls.
private struct MacCallReturnBar: View {
    @EnvironmentObject private var activity: MacCallActivity
    let returnToCall: () -> Void
    var body: some View {
        Button(action: returnToCall) {
            HStack(spacing: 12) {
                MacCallWaveform(snapshot: activity.snapshot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.snapshot.contact).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(activity.snapshot.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !activity.snapshot.elapsed.isEmpty {
                    Text(activity.snapshot.elapsed).monospacedDigit().foregroundStyle(.secondary)
                }
                Text("Zum Gespräch").font(.callout.weight(.medium))
                Image(systemName: "chevron.right").font(.caption)
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).background(MacStyle.accent.opacity(0.07))
            .accessibilityLabel("Zum Gespräch mit " + activity.snapshot.contact)
    }
}

struct MacCallView: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var activity: MacCallActivity
    @State private var transferNumber = ""
    @State private var showTransfer = false
    @State private var showTones = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
    var body: some View {
        if let original = phone.call, let call = phone.manager.controlledCall {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            if phone.manager.consultation != nil {
                                Text("Rückfrage").font(.callout).foregroundStyle(.secondary)
                            }
                            Text(call.displayedContact.name)
                                .font(.system(size: 28, weight: .semibold))
                                .multilineTextAlignment(.center).textSelection(.enabled)
                            if call.displayedContact.number != call.displayedContact.name {
                                Text(call.displayedContact.number).font(.title3).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        HStack(spacing: 10) {
                            MacCallWaveform(snapshot: activity.snapshot)
                            Text(activity.snapshot.label)
                            if !activity.snapshot.elapsed.isEmpty {
                                Text("·").foregroundStyle(.tertiary)
                                Text(activity.snapshot.elapsed).monospacedDigit()
                            }
                        }.font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5), in: Capsule())

                        if original.phase == .incoming {
                            HStack(spacing: 16) {
                                endButton(incoming: true)
                                Button("Annehmen", systemImage: "phone.fill") { phone.answer() }
                                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                                    .disabled(phone.manager.acceptingCall)
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                Button { phone.toggleMute() } label: {
                                    controlLabel(call.isMuted ? "Mikrofon an" : "Stumm", symbol: call.isMuted ? "mic.slash.fill" : "mic.fill")
                                }.buttonStyle(MacCallControlStyle(selected: call.isMuted))
                                    .disabled(call.phase != .active)
                                    .help(call.isMuted ? "Mikrofon einschalten" : "Mikrofon stummschalten")
                                Button { showTones.toggle() } label: {
                                    controlLabel("Ziffern", symbol: "circle.grid.3x3.fill")
                                }.buttonStyle(MacCallControlStyle(selected: showTones))
                                    .disabled(!canSendTones(call))
                                    .popover(isPresented: $showTones, arrowEdge: .bottom) { tonePad(call: call) }

                                if phone.manager.consultation == nil {
                                    Button { phone.toggleHold() } label: {
                                        controlLabel(call.isHeld ? "Fortsetzen" : "Halten", symbol: call.isHeld ? "play.fill" : "pause.fill")
                                    }.buttonStyle(MacCallControlStyle(selected: call.isHeld))
                                        .disabled(call.phase != .active || call.holdPending || call.isRemoteHeld || phone.manager.consultationPending || phone.manager.transferPending)
                                    Button { showTransfer.toggle() } label: {
                                        controlLabel("Vermitteln", symbol: "arrow.triangle.branch")
                                    }.buttonStyle(MacCallControlStyle(selected: showTransfer))
                                        .disabled(!phone.manager.canTransfer)
                                        .popover(isPresented: $showTransfer, arrowEdge: .bottom) { transferPanel }
                                } else {
                                    Button { phone.manager.returnToOriginal() } label: {
                                        controlLabel("Zurück", symbol: "arrow.uturn.backward")
                                    }.buttonStyle(MacCallControlStyle())
                                        .disabled(phone.manager.transferPending)
                                        .help("Zum ursprünglichen Gespräch zurückkehren")
                                    Button { phone.manager.completeConsultation() } label: {
                                        controlLabel("Verbinden", symbol: "arrow.triangle.branch")
                                    }.buttonStyle(MacCallControlStyle())
                                        .disabled(call.phase != .active || phone.manager.transferPending)
                                }
                            }
                            if phone.manager.consultationPending {
                                Button("Rückfrage abbrechen") { phone.manager.returnToOriginal() }
                            } else if let consultation = phone.manager.consultation {
                                Text("\(original.displayedContact.name) wartet")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel("Ursprüngliches Gespräch mit \(original.displayedContact.name) wartet. Rückfrage bei \(consultation.displayedContact.name).")
                            }
                            endButton(incoming: false).disabled(original.phase == .ending)
                        }
                    }.frame(maxWidth: 400).padding(28)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height)
                }
            }
            .onChange(of: canSendTones(call)) { _, enabled in if !enabled { showTones = false } }
            .onChange(of: phone.manager.canTransfer) { _, enabled in if !enabled { showTransfer = false } }
        }
    }
    private func controlLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium))
            Text(title).font(.callout.weight(.medium))
        }.frame(maxWidth: .infinity, minHeight: 78)
    }
    private func endButton(incoming: Bool) -> some View {
        Button { phone.end() } label: {
            Label(incoming ? "Ablehnen" : "Auflegen", systemImage: "phone.down.fill")
                .frame(minWidth: 112)
        }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
    }
    private func canSendTones(_ call: CallSession) -> Bool {
        call.phase == .active && !call.isHeld && !call.isRemoteHeld && !call.holdPending
    }
    private func tonePad(call: CallSession) -> some View {
        VStack(spacing: 12) {
            Text("Ziffern senden").font(.headline)
            if !call.tones.isEmpty {
                Text(call.tones).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(.secondary).accessibilityLabel("Gesendete Ziffern: " + call.tones)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(Array("123456789*0#"), id: \.self) { digit in
                    Button { phone.sendTone(String(digit)) } label: {
                        Text(String(digit)).font(.title3).frame(maxWidth: .infinity, minHeight: 30)
                    }.controlSize(.large).disabled(!canSendTones(call))
                }
            }
        }.padding(18).frame(width: 232)
    }
    private var transferPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gespräch vermitteln").font(.headline)
            TextField("Nummer oder Nebenstelle", text: $transferNumber)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .onSubmit { beginConsultation() }
            Button { beginConsultation() } label: {
                Text("Rückfrage starten").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!phone.manager.canTransfer || transferNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                phone.manager.transferDirect(transferNumber.trimmingCharacters(in: .whitespacesAndNewlines))
                showTransfer = false
            } label: {
                Text("Direkt vermitteln").frame(maxWidth: .infinity)
            }.controlSize(.large)
                .disabled(!phone.manager.canTransfer || transferNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(20).frame(width: 300)
    }
    private func beginConsultation() {
        let number = transferNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.manager.canTransfer, !number.isEmpty else { return }
        phone.manager.beginConsultation(number)
        showTransfer = false
    }
}

private struct MacCallControlStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? AnyShapeStyle(MacStyle.accent) : AnyShapeStyle(.primary))
            .background(selected ? MacStyle.accent.opacity(0.13) : Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045),
                in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? MacStyle.accent.opacity(0.28) : Color.primary.opacity(0.07))
            }
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
