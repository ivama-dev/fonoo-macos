import AppKit
import Combine
import SwiftUI

/// Retains a request until the main window exists, including after its red
/// close button was used. The menu bar never owns a second phone store.
@MainActor
final class MacWindowNavigation: ObservableObject {
    @Published var destination: MacDestination?
    @Published var profilesRequested = false
}

/// One native status item, replacing the static menu-bar extra. Its presence and
/// timer do not depend on any SwiftUI window or inspector lifecycle.
@MainActor
final class MacCallStatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem
    private let popover = NSPopover()
    private let phone: PhoneStore
    private let customer: CustomerAccount
    private let activity: MacCallActivity
    private let showWindow: () -> Void
    private let showDestination: (MacDestination) -> Void
    private let showProfiles: () -> Void
    private let miniCallWindow: MacMiniCallWindow
    private var observations: Set<AnyCancellable> = []

    init(phone: PhoneStore, customer: CustomerAccount, activity: MacCallActivity,
         miniCallWindow: MacMiniCallWindow, showWindow: @escaping () -> Void,
         showDestination: @escaping (MacDestination) -> Void, showProfiles: @escaping () -> Void) {
        MacMenuBarPlacement.prepare()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.phone = phone; self.customer = customer; self.activity = activity
        self.miniCallWindow = miniCallWindow; self.showWindow = showWindow
        self.showDestination = showDestination; self.showProfiles = showProfiles
        super.init()
        configureButton()
        popover.behavior = .transient
        popover.animates = true
        activity.$snapshot.sink { [weak self] in self?.update($0) }.store(in: &observations)
        // Registration and DND also change while no conversation is running.
        for publisher in [phone.objectWillChange.eraseToAnyPublisher(), customer.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.update(self.activity.snapshot)
                }
            }.store(in: &observations)
        }
        reportPlacementAfterLayout()
    }
    private func configureButton() {
        item.autosaveName = MacMenuBarPlacement.autosaveName
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageOnly
    }
    /// Explicit recovery, without restarting the app or its phone connection.
    func restoreVisiblePosition() {
        popover.performClose(nil)
        // Detach autosaving before removal, so removal cannot write the old
        // hidden position over the replacement's preference.
        item.autosaveName = nil
        NSStatusBar.system.removeStatusItem(item)
        MacMenuBarPlacement.restore()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureButton()
        item.isVisible = true
        update(activity.snapshot)
        reportPlacementAfterLayout()
    }
    private func reportPlacementAfterLayout() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let button = self.item.button, let window = button.window else { return }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let fits = self.item.isVisible && NSScreen.screens.contains {
                MacMenuBarPlacement.fits(frame, screen: $0.frame,
                    left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea)
            }
            self.phone.diagnostics.record("Menüleistensymbol: " + (fits ? "im sichtbaren Bildschirmbereich" : "durch die Menüleisten-Anordnung verdeckt")
                + ". Position x=\(Int(frame.minX)), Breite=\(Int(frame.width)).")
        }
    }
    private func preparePopover() {
        // A transient popover may be detached when its last call ends. A new
        // hosting controller reads current values instead of reusing a hidden
        // view tree, and tracks size changes between call controls and dialing.
        let controller = NSHostingController(rootView: MacMenuBarView(
            phone: phone, customer: customer, activity: activity,
            open: { [weak self] destination in
                self?.popover.performClose(nil)
                self?.showDestination(destination)
            }, profiles: { [weak self] in
                self?.popover.performClose(nil)
                self?.showProfiles()
            }, setDND: { [weak self] in self?.setDoNotDisturb($0) },
            close: { [weak self] in self?.popover.performClose(nil) },
            quit: { [weak self] in self?.quit() }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
    }
    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { togglePopover() }
    }
    func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            preparePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // The popover can accept keyboard input without restoring a
            // minimized main window. The application remains a normal Dock app.
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            if !MacAppDelegate.runningChecks {
                Task { await customer.refreshAvailability() }
            }
        }
    }
    private func update(_ snapshot: MacCallActivity.Snapshot) {
        guard let button = item.button else { return }
        // A growing duration/waveform pushed the status item towards the notch.
        // Keep its footprint constant; full call information remains in the popover.
        button.title = ""
        button.image = snapshot.hasCall ? Self.image(snapshot) : Self.brandImage
        button.toolTip = snapshot.hasCall ? "fonu · \(snapshot.label) · \(snapshot.contact)\(snapshot.elapsed.isEmpty ? "" : " · " + snapshot.elapsed)"
            : "fonu · \(phone.registration.label)\(phone.doNotDisturb ? " · Nicht stören" : "")"
        button.setAccessibilityLabel(snapshot.hasCall ? "fonu, \(snapshot.label), \(snapshot.elapsed)"
            : "fonu, \(phone.registration.label)\(phone.doNotDisturb ? ", Nicht stören" : "")")
        button.setAccessibilityHelp("Schnellzugriff öffnen. Rechtsklick für das Menü.")
    }
    private static let brandImage: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            ("f" as NSString).draw(at: NSPoint(x: 3, y: -3), withAttributes: [
                .font: NSFont.systemFont(ofSize: 21, weight: .heavy), .foregroundColor: NSColor.black])
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
    static func image(_ snapshot: MacCallActivity.Snapshot) -> NSImage? {
        guard snapshot.hasCall else { return brandImage }
        return NSImage(systemSymbolName: snapshot.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [snapshot.tint]))
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = activity.snapshot
        add(snapshot.hasCall ? snapshot.label + (snapshot.elapsed.isEmpty ? "" : " · " + snapshot.elapsed) : phone.registration.label,
            to: menu, action: nil)
        if snapshot.hasCall { add(snapshot.contact, to: menu, action: nil) }
        add(snapshot.hasCall ? "Zum Gespräch" : "fonu öffnen", to: menu, action: #selector(openWindow))
        if miniCallWindow.canShow {
            add("Kleines Gesprächsfenster anzeigen", to: menu, action: #selector(openMiniCall))
        }
        if phone.call?.phase == .incoming {
            add("Annehmen", to: menu, action: #selector(answer), enabled: !phone.manager.acceptingCall)
        } else if let call = phone.manager.controlledCall {
            add(call.isMuted ? "Mikrofon einschalten" : "Mikrofon stummschalten", to: menu,
                action: #selector(mute), enabled: call.phase == .active)
            add(call.isHeld ? "Gespräch fortsetzen" : "Gespräch halten", to: menu, action: #selector(hold),
                enabled: call.phase == .active && !call.holdPending && !call.isRemoteHeld
                    && phone.manager.consultation == nil && !phone.manager.consultationPending && !phone.manager.transferPending)
        }
        if phone.call != nil { add("Auflegen", to: menu, action: #selector(end)) }
        menu.addItem(.separator())
        let dnd = add("Nicht stören", to: menu, action: #selector(toggleDND), enabled: !customer.availabilitySaving)
        dnd.state = phone.doNotDisturb ? .on : .off
        add("Menüleistensymbol rechts einblenden", to: menu, action: #selector(restorePosition))
        add("fonu beenden", to: menu, action: #selector(quit))
    }
    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self; entry.isEnabled = action != nil && enabled
        menu.addItem(entry)
        return entry
    }
    @objc private func openWindow() { showWindow() }
    @objc private func openMiniCall() { miniCallWindow.show() }
    @objc private func answer() { phone.answer() }
    @objc private func mute() { phone.toggleMute() }
    @objc private func hold() { phone.toggleHold() }
    @objc private func end() { phone.end() }
    private func setDoNotDisturb(_ enabled: Bool) {
        guard !customer.availabilitySaving else { return }
        if let snapshot = customer.availability, snapshot.company.routingEnabled,
           snapshot.tenantID == customer.activeCloudMembership?.id {
            Task {
                await customer.saveAvailability(["presence": ["state": enabled ? "do_not_disturb" : "available",
                    "description": "", "valid_until": NSNull()], "override_schedule_until": NSNull()])
            }
        } else { phone.doNotDisturb = enabled }
    }
    @objc private func toggleDND() { setDoNotDisturb(!phone.doNotDisturb) }
    @objc private func restorePosition() { restoreVisiblePosition() }
    @objc private func quit() { popover.performClose(nil); NSApp.terminate(nil) }
    func remove() {
        popover.performClose(nil)
        popover.contentViewController = nil
        observations.removeAll()
        NSStatusBar.system.removeStatusItem(item)
    }
    #if DEBUG
    var buttonTitle: String { item.button?.title ?? "" }
    var buttonLabel: String { item.button?.accessibilityLabel() ?? "" }
    var isVisible: Bool { item.isVisible }
    #endif
}

/// Window-independent SwiftUI content backed by the app's existing account and
/// call manager. Opening/closing the popover cannot start or stop the SDK.
private struct MacMenuBarView: View {
    @ObservedObject var phone: PhoneStore
    @ObservedObject var customer: CustomerAccount
    @ObservedObject var activity: MacCallActivity
    let open: (MacDestination) -> Void
    let profiles: () -> Void
    let setDND: (Bool) -> Void
    let close: () -> Void
    let quit: () -> Void
    @State private var number = ""

    private var canDial: Bool {
        phone.registration == .registered && !phone.busy && !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("fonu").font(.system(size: 26, weight: .heavy)).tracking(-1)
                    Circle().fill(MacStyle.accent).frame(width: 6, height: 6)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Schnellzugriff schließen")
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(phone.registration == .registered ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(phone.registration.label).font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(phone.networkLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let membership = customer.activeCloudMembership {
                    HStack {
                        Text(membership.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("DW " + (membership.number ?? "–")).monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let snapshot = customer.availability,
                   snapshot.tenantID == customer.activeCloudMembership?.id {
                    Divider()
                    HStack {
                        Text("Anrufprofil").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(snapshot.settings.profiles) { profile in
                                Button {
                                    Task { await customer.saveAvailability(["active_profile_id": profile.id]) }
                                } label: {
                                    Label(profile.name, systemImage: profile.id == snapshot.settings.activeProfile.id ? "checkmark" : "rectangle.stack")
                                }
                            }
                            Divider()
                            Button("Profile verwalten", action: profiles)
                        } label: {
                            Label(snapshot.settings.activeProfile.name, systemImage: "rectangle.stack")
                                .lineLimit(1).truncationMode(.tail)
                        }.menuStyle(.borderlessButton).frame(maxWidth: 190, alignment: .trailing)
                            .disabled(customer.availabilitySaving)
                            .accessibilityLabel("Anrufprofil: " + snapshot.settings.activeProfile.name)
                    }
                }
            }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            if activity.snapshot.hasCall { callControls }
            else {
                HStack(spacing: 8) {
                    TextField("Rufnummer oder Nebenstelle", text: $number).textFieldStyle(.roundedBorder)
                        .onSubmit(dial).accessibilityLabel("Rufnummer für Direktwahl")
                    Button(action: dial) { Image(systemName: "phone.fill").frame(width: 24) }
                        .buttonStyle(.borderedProminent).disabled(!canDial)
                        .accessibilityLabel("Rufnummer anrufen")
                }.controlSize(.large)
            }

            HStack(spacing: 8) {
                shortcut("Favoriten", symbol: "star.fill", destination: .favorites)
                shortcut("Team", symbol: "person.2.fill", destination: .team)
                shortcut("Anrufliste", symbol: "clock", destination: .recents)
            }
            Toggle("Nicht stören", isOn: Binding(get: { phone.doNotDisturb }, set: setDND))
                .toggleStyle(.switch).controlSize(.small).disabled(customer.availabilitySaving)
            if !customer.availabilityMessage.isEmpty {
                Text(customer.availabilityMessage).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let notice = phone.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Divider()
            HStack {
                Button("fonu öffnen") { open(phone.call == nil ? .dial : .conversation) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Beenden", action: quit).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text("Bleibt erreichbar, solange dein Mac wach ist.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .tint(MacStyle.accent)
    }
    private func dial() {
        guard canDial else { return }
        phone.dial(number)
        if phone.call != nil { number = "" }
    }
    private func shortcut(_ title: String, symbol: String, destination: MacDestination) -> some View {
        Button { open(destination) } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(MacStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(MacStyle.accent)
    }
    private var callControls: some View {
        let snapshot = activity.snapshot
        let call = phone.manager.controlledCall
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                MacCallWaveform(snapshot: snapshot)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.contact).font(.headline).lineLimit(1)
                    Text(snapshot.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(snapshot.elapsed).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if call?.phase == .incoming {
                    Button("Annehmen") { phone.answer() }.tint(.green)
                        .disabled(phone.manager.acceptingCall)
                } else {
                    Button { phone.toggleMute() } label: {
                        Image(systemName: call?.isMuted == true ? "mic.slash.fill" : "mic.fill")
                    }.tint(call?.isMuted == true ? MacStyle.accent : .secondary)
                        .accessibilityLabel(call?.isMuted == true ? "Mikrofon einschalten" : "Mikrofon stummschalten")
                        .disabled(call?.phase != .active)
                    Button { phone.toggleHold() } label: {
                        Image(systemName: call?.isHeld == true ? "play.fill" : "pause.fill")
                    }.accessibilityLabel(call?.isHeld == true ? "Gespräch fortsetzen" : "Gespräch halten")
                        .disabled(call?.phase != .active || call?.holdPending == true || call?.isRemoteHeld == true
                            || phone.manager.consultation != nil || phone.manager.consultationPending || phone.manager.transferPending)
                }
                Spacer(minLength: 0)
                Button(call?.phase == .incoming ? "Ablehnen" : "Auflegen") { phone.end() }
                    .tint(.red).disabled(call == nil || call?.phase == .ending)
            }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(12).background(MacStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
