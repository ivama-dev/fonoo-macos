import SwiftUI

private enum TeamStyle {
    static var accent: Color {
        #if os(iOS)
        FonooStyle.accent
        #else
        MacStyle.accent
        #endif
    }
    static var background: Color {
        #if os(iOS)
        FonooStyle.background
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

private struct TeamRoute: Hashable {
    let context: TeamContext
    let memberID: String
}

struct TeamView: View {
    @EnvironmentObject private var customer: CustomerAccount
    var body: some View { TeamContent(directory: customer.teamDirectory) }
}

private struct TeamContent: View {
    @EnvironmentObject private var customer: CustomerAccount
    @EnvironmentObject private var phone: PhoneStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var directory: TeamDirectory
    @State private var query = ""
    @State private var selection: TeamRoute?
    @State private var visible = false
    @State private var showAvailability = false

    private struct LoadRequest: Equatable {
        let context: TeamContext?
        let active: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            companyHeader
            #if os(macOS)
            // The outer app owns the sidebar. Bound Team to its detail column so
            // an inner split view or a long search prompt cannot widen the window.
            GeometryReader { geometry in
                if geometry.size.width >= 640 {
                    HStack(spacing: 0) {
                        teamList.frame(width: min(340, geometry.size.width * 0.44))
                        Divider()
                        memberDetails.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let selection {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { self.selection = nil } label: {
                            Label("Zurück zum Team", systemImage: "chevron.left")
                        }.buttonStyle(.plain).padding(16)
                        TeamDetailView(directory: directory, route: selection)
                    }
                } else {
                    teamList
                }
            }
            #else
            teamList
                .navigationDestination(for: TeamRoute.self) { route in
                    TeamDetailView(directory: directory, route: route)
                }
            #endif
        }
        .background(TeamStyle.background)
        #if os(iOS)
        .searchable(text: $query, prompt: "Name, E-Mail oder interne Nummer")
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button { Task { await customer.refreshTeam() } } label: { Label("Team aktualisieren", systemImage: "arrow.clockwise") }
                    .disabled(directory.context == nil || directory.isLoading || directory.isSavingName)
            }
            #endif
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: LoadRequest(context: customer.teamContext, active: visible && scenePhase == .active)) {
            if visible && scenePhase == .active { await customer.refreshTeam() }
        }
        .onChange(of: customer.teamContext) { _, _ in selection = nil; query = "" }
        .sheet(isPresented: $showAvailability) { AvailabilityView() }
    }

    #if os(macOS)
    private var memberDetails: some View {
        Group {
            if let selection { TeamDetailView(directory: directory, route: selection) }
            else {
                ContentUnavailableView("Dein Team", systemImage: "person.2",
                    description: Text("Wähle einen Mitarbeiter, um Kontaktdaten und die interne Nummer zu sehen."))
            }
        }
    }
    #endif

    private var companyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if customer.cloudMemberships.count > 1 {
                Picker("Firma", selection: Binding<String?>(get: { customer.teamContext?.tenantID }, set: { customer.selectTeamTenant($0) })) {
                    Text("Firma auswählen").tag(String?.none)
                    ForEach(customer.cloudMemberships) { Text($0.name).tag(Optional($0.id)) }
                }
            } else if let membership = customer.cloudMemberships.first {
                Text(membership.name).font(.headline)
            }
            Text("Internes Firmenadressbuch").font(.subheadline).foregroundStyle(.secondary)
            Button { showAvailability = true } label: {
                Label("Anrufprofile & Rufteams", systemImage: "person.crop.circle.badge.clock")
            }
            #if os(macOS)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Team durchsuchen", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Name, E-Mail oder interne Nummer")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Suche löschen")
                }
            }.padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            #endif
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var teamList: some View {
        List {
            Section("Benutzer") {
                if directory.context == nil {
                    ContentUnavailableView(customer.cloudMemberships.isEmpty ? "Noch kein Team" : "Firma auswählen",
                        systemImage: "person.2", description: Text(customer.cloudMemberships.isEmpty
                            ? "Dein Team erscheint, sobald du im Kundenbereich einer Firma angehörst."
                            : "Wähle oben die Firma, deren Team du sehen möchtest."))
                } else if let error = directory.errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Team konnte nicht geladen werden").font(.headline)
                        Text(error).foregroundStyle(.secondary)
                        Button("Erneut versuchen") { Task { await customer.refreshTeam() } }
                    }.padding(.vertical, 8)
                } else {
                    if directory.isLoading { ProgressView("Team laden …") }
                    if directory.snapshot != nil {
                        let members = directory.members(matching: query)
                        if members.isEmpty {
                            ContentUnavailableView(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Noch keine Mitarbeiter" : "Kein Mitarbeiter gefunden",
                                systemImage: "person.crop.circle.badge.questionmark",
                                description: Text("Suche nach Name, E-Mail oder interner Nummer."))
                        }
                        ForEach(members) { member in
                            if let context = directory.context {
                                let route = TeamRoute(context: context, memberID: member.id)
                                #if os(macOS)
                                HStack(spacing: 8) {
                                    Button { selection = route } label: {
                                        TeamMemberRow(member: member, isSelf: member.id == context.accountID)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if member.id != context.accountID, let number = member.number {
                                        Button { customer.callTeamMember(member) } label: {
                                            Image(systemName: "phone.fill").padding(5)
                                        }.buttonStyle(.bordered).tint(TeamStyle.accent)
                                            .help("\(member.name) anrufen · \(number)")
                                            .accessibilityLabel("\(member.name) anrufen, Nebenstelle \(number)")
                                            .disabled(!customer.canCallTeamMember(member))
                                    }
                                }.padding(6)
                                    .background(selection == route ? TeamStyle.accent.opacity(0.10) : .clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                #else
                                NavigationLink(value: route) { TeamMemberRow(member: member, isSelf: member.id == context.accountID) }
                                #endif
                            }
                        }
                    }
                }
            }
            Section("Endgeräte") {
                if let availability = customer.availability, !availability.standaloneDevices.isEmpty {
                    ForEach(availability.standaloneDevices) { device in
                        Label(device.name, systemImage: "phone").padding(.vertical,4)
                    }
                } else {
                    Text("Noch keine eigenständigen Geräte eingerichtet. Persönliche Geräte bleiben beim Benutzer.").foregroundStyle(.secondary)
                }
            }
            Section("KI-Assistenten") {
                TeamPlannedArea(symbol: "sparkles", description: "Hier findest du später die KI-Assistenten deiner Firma.")
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await customer.refreshTeam() }
    }
}

private struct TeamPlannedArea: View {
    let symbol: String
    let description: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(TeamStyle.accent)
                .frame(width: 42, height: 42)
                .background(TeamStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Geplant").font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

private struct TeamMemberRow: View {
    let member: TeamMember
    let isSelf: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TeamAvatar(member: member)
            VStack(alignment: .leading, spacing: 5) {
                Text(member.name).font(.headline).foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon).lineLimit(1).truncationMode(.tail)
                PresenceStatusView(userID:member.id)
                if let availability = member.availability {
                    if availability.state != "available" { Text("Status: " + availability.label).font(.caption).foregroundStyle(.secondary) }
                    if !availability.description.isEmpty { Text(availability.description).font(.caption).foregroundStyle(.secondary) }
                }
                if member.name != member.email {
                    Text(member.email).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text((member.number.map { "Intern \($0)" } ?? "Keine interne Nummer") + (isSelf ? " · Du" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

/// Shared telephone-presence presentation for Team and both apps' favorites.
struct PresenceStatusView: View {
    @EnvironmentObject private var customer: CustomerAccount
    let userID: String
    private var presence: CallPresence { customer.telephonePresence(for:userID) }
    private var tint: Color {
        switch presence.state {
        case "idle": .green
        case "busy": .red
        case "ringing", "dialing": .orange
        default: .secondary
        }
    }
    private var counterpart: String? {
        guard presence.state == "busy" else { return nil }
        if presence.callCount > 1 { return "\(presence.callCount) Gespräche" }
        return customer.presencePeerName(presence).map { "Mit " + $0 } ?? "Rufnummer nicht verfügbar"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            HStack(spacing:6) {
                Circle().fill(tint).frame(width:7,height:7).accessibilityHidden(true)
                Text(presence.label).foregroundStyle(tint).lineLimit(1)
            }
            if let counterpart { Text(counterpart).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
        }.font(.caption)
        .accessibilityElement(children:.combine)
    }
}

private struct TeamAvatar: View {
    let member: TeamMember
    var large = false
    var body: some View {
        Text(member.initials).font(large ? .largeTitle : .headline)
            .foregroundStyle(TeamStyle.accent)
            .frame(width: large ? 88 : 42, height: large ? 88 : 42)
            .background(TeamStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: large ? 29 : 14))
            .accessibilityHidden(true)
    }
}

private struct TeamDetailView: View {
    @EnvironmentObject private var customer: CustomerAccount
    @EnvironmentObject private var phone: PhoneStore
    @ObservedObject var directory: TeamDirectory
    let route: TeamRoute
    @State private var draftName = ""
    @State private var editingName = false

    private var member: TeamMember? {
        guard directory.context == route.context else { return nil }
        return directory.snapshot?.members.first { $0.id == route.memberID }
    }

    var body: some View {
        Group {
            if let member {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(spacing: 12) {
                            TeamAvatar(member: member, large: true)
                            Text(member.name).font(.title2.bold()).multilineTextAlignment(.center)
                            if member.id == route.context.accountID { Text("Du").font(.subheadline).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 16) {
                            detail("E-Mail", value: member.email)
                            PresenceStatusView(userID:member.id)
                            if let peer = customer.telephonePresence(for:member.id).peerNumber,
                               customer.presencePeerName(customer.telephonePresence(for:member.id)) != peer {
                                detail("Gesprächspartner",value:peer)
                            }
                            if let availability = member.availability {
                                if availability.state != "available" { detail("Persönlicher Status", value:availability.label) }
                                if !availability.description.isEmpty { detail("Statustext",value:availability.description) }
                                if let until = availability.validUntil { detail("Gültig bis",value:Date(timeIntervalSince1970:until).formatted(date:.abbreviated,time:.shortened)) }
                            }
                            detail("Interne Nummer", value: member.number ?? "Noch nicht zugewiesen")
                        }
                        if member.id != route.context.accountID {
                            Button { customer.callTeamMember(member) } label: {
                                Label("Anrufen", systemImage: "phone.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!customer.canCallTeamMember(member))
                            if let reason = callUnavailableReason(member) {
                                Text(reason).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let contact = member.callContact(tenantID:route.context.tenantID),
                               customer.activeCloudMembership?.id == route.context.tenantID {
                                Button { phone.toggleFavorite(contact) } label: {
                                    Label(phone.favorites.contains(where:{$0.id == contact.id}) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                                          systemImage:phone.favorites.contains(where:{$0.id == contact.id}) ? "star.fill" : "star")
                                }.buttonStyle(.bordered)
                            }
                        }
                        if member.personalDeviceCount > 0 {
                            DisclosureGroup("Persönliche Geräte (\(member.personalDeviceCount))") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(member.personalDevices) { device in Label(device.name, systemImage: "phone") }
                                    Text("Diese Geräte gehören zur Person. Anrufe gehen an die interne Nummer.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                            }
                        }
                        if member.id == route.context.accountID {
                            if member.name == member.email {
                                Text("Ergänze deinen Namen, damit dein Team dich leichter findet.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("Deinen Namen bearbeiten", isExpanded: $editingName) {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextField("Vor- und Nachname", text: $draftName).textFieldStyle(.roundedBorder)
                                    Button("Namen speichern") { Task { await customer.saveTeamName(draftName) } }
                                        .disabled(directory.isSavingName || directory.isLoading ||
                                            draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftName.count > 120)
                                    if directory.isSavingName { ProgressView("Speichern …") }
                                    if let error = directory.nameError {
                                        Text(error).font(.footnote).foregroundStyle(.secondary)
                                        Button("Team aktualisieren") { Task { await customer.refreshTeam() } }
                                            .disabled(directory.isLoading)
                                    }
                                }.padding(.top, 10)
                            }
                            .onChange(of: editingName) { _, open in if open { draftName = member.name == member.email ? "" : member.name } }
                        }
                    }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
                }
            } else if directory.isLoading {
                ProgressView("Team laden …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("Mitarbeiter nicht verfügbar", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Der Team-Stand hat sich geändert. Bitte öffne den Mitarbeiter erneut aus der Liste."))
                    Button("Team aktualisieren") { Task { await customer.refreshTeam() } }
                        .disabled(directory.context == nil)
                }
            }
        }
        .background(TeamStyle.background)
        #if os(iOS)
        .navigationTitle("Mitarbeiter").navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func callUnavailableReason(_ member: TeamMember) -> String? {
        if member.number == nil { return "Für diesen Mitarbeiter ist noch keine interne Nummer hinterlegt." }
        if customer.activeCloudMembership?.id != route.context.tenantID {
            return "Wähle diese Firma in deinem Konto zum Telefonieren aus."
        }
        if phone.busy { return "Bitte beende zuerst das laufende Gespräch." }
        if phone.registration != .registered { return "Verbinde deine Telefonie, um einen Anruf zu starten." }
        return nil
    }
}

struct AvailabilityProfileMenu: View {
    @EnvironmentObject private var customer: CustomerAccount
    @State private var presented = false
    var body: some View {
        if let snapshot = customer.availability {
            Menu {
                ForEach(snapshot.settings.profiles) { profile in
                    Button {
                        Task { await customer.saveAvailability(["active_profile_id":profile.id]) }
                    } label: {
                        Label(profile.name,systemImage:profile.id == snapshot.settings.activeProfile.id ? "checkmark.circle.fill" : "circle")
                    }
                }
                Divider()
                Button("Profile verwalten") { presented = true }
            } label: {
                Label(snapshot.settings.activeProfile.name,systemImage:"rectangle.stack")
                    .lineLimit(1).truncationMode(.tail)
            }
            .disabled(customer.availabilitySaving)
            .accessibilityLabel("Anrufprofil: " + snapshot.settings.activeProfile.name)
            .accessibilityHint("Geräte für eingehende Anrufe auswählen")
            .sheet(isPresented:$presented) { AvailabilityView() }
        }
    }
}

struct AvailabilityView: View {
    @EnvironmentObject private var customer: CustomerAccount
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ProfileEditContext?
    @State private var state = "available"
    @State private var description = ""
    @State private var expiration = 3600
    private let statuses = ["available","busy","away","off_duty","vacation","do_not_disturb"]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if let snapshot = customer.availability {
                        VStack(alignment:.leading,spacing:8) {
                            Label("Deine Anrufprofile",systemImage:"rectangle.stack.fill").font(.title2.bold())
                            Text("Wähle, auf welchen Geräten eingehende Anrufe klingeln. Dein Profil gilt auf allen Geräten dieser Firma.")
                                .foregroundStyle(.secondary)
                        }
                        if snapshot.profilesAvailable != true {
                            Label("Der Telefonieserver hat die Profilsteuerung noch nicht bestätigt.",systemImage:"info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        VStack(spacing:12) {
                            ForEach(snapshot.settings.profiles) { profile in
                                profileRow(profile,snapshot:snapshot)
                            }
                        }
                        Button {
                            editor = ProfileEditContext(snapshot:snapshot,profile:.init(id:"p"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),name:"",deviceIDs:snapshot.ownDevices.map(\.id)),isNew:true)
                        } label: { Label("Profil anlegen",systemImage:"plus.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(TeamStyle.accent)
                        .disabled(snapshot.settings.profiles.count >= 20)
                        DisclosureGroup("Status, Arbeitszeiten und Rufteams") {
                            advanced(snapshot).padding(.top,12)
                        }
                        .font(.subheadline)
                    } else { ProgressView("Profile laden …") }
                    if !customer.availabilityMessage.isEmpty {
                        Text(customer.availabilityMessage).foregroundStyle(.red).font(.callout)
                    }
                }.padding(24).frame(maxWidth:640,alignment:.leading).frame(maxWidth:.infinity)
            }
            .background(TeamStyle.background)
            .disabled(customer.availabilitySaving)
            .navigationTitle("Anrufprofile")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Fertig") { dismiss() } } }
            .task(id:customer.teamContext) { await customer.refreshAvailability() }
            .sheet(item:$editor) { ProfileEditorView(context:$0) }
        }
        #if os(macOS)
        .frame(minWidth:540,idealWidth:600,minHeight:540)
        #endif
    }
    private func profileRow(_ profile:AvailabilitySnapshot.DeviceProfile,snapshot:AvailabilitySnapshot)->some View {
        let active = snapshot.settings.activeProfile.id == profile.id
        let devices = snapshot.ownDevices.filter { profile.deviceIDs?.contains($0.id) ?? true }
        return VStack(alignment:.leading,spacing:10) {
            HStack(spacing:12) {
                Button { Task { await customer.saveAvailability(["active_profile_id":profile.id]) } } label: {
                    HStack(spacing:12) {
                        Image(systemName:active ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(TeamStyle.accent)
                        VStack(alignment:.leading,spacing:4) {
                            Text(profile.name).font(.headline).foregroundStyle(.primary)
                            Text(profile.isStandard ? "Alle Geräte · auch neue Geräte" : "\(devices.count) Geräte ausgewählt")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(profile.name + (active ? ", aktiv" : ", aktivieren"))
                if !profile.isStandard {
                    Button("Bearbeiten") { editor = ProfileEditContext(snapshot:snapshot,profile:profile,isNew:false) }
                        .buttonStyle(.borderless)
                }
            }
            if !devices.isEmpty {
                Text(devices.map(\.name).joined(separator:" · ")).font(.callout).foregroundStyle(.secondary)
            } else { Text("Keine Geräte ausgewählt – eingehende Anrufe klingeln hier nicht.").font(.callout).foregroundStyle(.secondary) }
            if profile.isStandard {
                Text("Deaktivierte oder abgemeldete Geräte bleiben ausgeschlossen.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.background,in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(active ? TeamStyle.accent.opacity(0.6) : Color.secondary.opacity(0.15),lineWidth:active ? 2 : 1))
    }
    @ViewBuilder private func advanced(_ snapshot:AvailabilitySnapshot)->some View {
        VStack(alignment:.leading,spacing:16) {
            if !snapshot.company.routingEnabled {
                Text("Status, Zeitpläne und Rufteams sind vorbereitet und benötigen die Freigabe eurer Administration. Deine Anrufprofile funktionieren unabhängig davon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Mein Status") {
                VStack(alignment:.leading,spacing:12) {
                    Text(PersonalAvailability.statusNames[snapshot.effective.presence?.state ?? "available"] ?? "Verfügbar").font(.headline)
                    Picker("Status",selection:$state) { ForEach(statuses,id:\.self) { Text(PersonalAvailability.statusNames[$0] ?? $0).tag($0) } }
                    TextField("Statustext",text:$description)
                    Picker("Gültig",selection:$expiration) {
                        Text("30 Minuten").tag(1800); Text("1 Stunde").tag(3600)
                        Text("Bis morgen").tag(86400); Text("Bis zur nächsten Änderung").tag(0)
                    }
                    Button("Status übernehmen") {
                        let until:Any = expiration == 0 ? NSNull() : Int(Date().addingTimeInterval(Double(expiration)).timeIntervalSince1970)
                        Task { await customer.saveAvailability(["presence":["state":state,"description":description,"valid_until":until],"override_schedule_until":state == "available" ? until : NSNull()]) }
                    }
                    Button("Automatisch nach Zeitplan") { Task { await customer.saveAvailability(["presence":NSNull(),"override_schedule_until":NSNull()]) } }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            if let schedule = snapshot.schedules.first(where: { $0.id == snapshot.settings.scheduleID }) {
                Label(schedule.name + " · " + schedule.definition.timezone,systemImage:"calendar")
            }
            ForEach(snapshot.callTeams) { team in
                if let member = team.members.first(where:{ $0.targetType == "user" && $0.targetID == snapshot.selfUserID }) {
                    GroupBox(team.name) {
                        VStack(alignment:.leading,spacing:8) {
                            Text(member.effective.reasonText)
                            if team.allowSelfPause {
                                Button("Für eine Stunde pausieren") { Task { await customer.pauseCallTeam(team,until:Date().addingTimeInterval(3600)) } }
                                Button("Pause beenden") { Task { await customer.pauseCallTeam(team,until:nil) } }
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                    }
                }
            }
            Link("Zeitpläne und Rufteams im Kundenbereich",destination:URL(string:"https://dev.fonoo.app/kunden/?tenant_id="+snapshot.tenantID+"&section=availability")!)
        }.onAppear { if let presence = snapshot.settings.presence { state=presence.state; description=presence.description } }
    }
}

private struct ProfileEditContext: Identifiable {
    let snapshot:AvailabilitySnapshot
    let profile:AvailabilitySnapshot.DeviceProfile
    let isNew:Bool
    var id:String { snapshot.tenantID + profile.id }
}
private struct ProfileEditorView:View {
    let context:ProfileEditContext
    @EnvironmentObject private var customer:CustomerAccount
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var selected:Set<String>
    @State private var deleting = false
    init(context:ProfileEditContext) {
        self.context=context
        _name=State(initialValue:context.profile.name)
        _selected=State(initialValue:Set(context.profile.deviceIDs ?? []))
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text("Profilname").font(.headline)
                    TextField("Zum Beispiel Büro oder Unterwegs",text:$name)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    Text("Hier sollen Anrufe klingeln").font(.headline).padding(.top,8)
                    ForEach(context.snapshot.ownDevices) { device in
                        Toggle(device.name + (device.enabled == false ? " · Deaktiviert" : ""),isOn:Binding(get:{selected.contains(device.id)},set:{enabled in
                            if enabled { selected.insert(device.id) } else { selected.remove(device.id) }
                        }))
                    }
                    Text("Ein neues Gerät wird automatisch im Profil Standard aktiviert. In diesem Profil wählst du es bei Bedarf dazu.")
                        .font(.caption).foregroundStyle(.secondary)
                    if selected.isEmpty { Text("Ohne ausgewählte Geräte klingeln keine eingehenden Anrufe.").font(.caption) }
                    if !context.isNew { Divider(); Button("Profil löschen",role:.destructive) { deleting=true } }
                    if !customer.availabilityMessage.isEmpty { Text(customer.availabilityMessage).foregroundStyle(.red) }
                }.padding(24).frame(maxWidth:540,alignment:.leading).frame(maxWidth:.infinity)
            }
            .navigationTitle(context.isNew ? "Neues Profil" : "Profil bearbeiten")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Speichern") { Task { await save(delete:false) } }
                    .disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || name.count > 50 || customer.availabilitySaving) }
            }
            .confirmationDialog("Profil „\(context.profile.name)“ löschen?",isPresented:$deleting,titleVisibility:.visible) {
                Button("Profil löschen",role:.destructive) { Task { await save(delete:true) } }
            } message: { Text("Ist dieses Profil aktiv, wird auf Standard mit allen Geräten umgeschaltet.") }
            .disabled(customer.availabilitySaving)
            .onChange(of:customer.teamContext) { _, _ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth:500,idealWidth:540,minHeight:400)
        #endif
    }
    private func save(delete:Bool) async {
        guard customer.teamContext?.tenantID == context.snapshot.tenantID,
              customer.teamContext?.accountID == context.snapshot.userID else { return }
        var profiles=context.snapshot.settings.profiles.filter { $0.id != context.profile.id }
        if !delete { profiles.append(.init(id:context.profile.id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),deviceIDs:selected.sorted())) }
        let active = delete && context.snapshot.settings.activeProfile.id == context.profile.id ? "standard" : context.snapshot.settings.activeProfile.id
        if await customer.saveAvailability(["device_profiles":profiles.map(\.requestValue),"active_profile_id":active],expectedRevision:context.snapshot.revision) { dismiss() }
    }
}
