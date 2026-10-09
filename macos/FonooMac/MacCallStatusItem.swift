import AppKit
import Combine

/// One native status item, replacing the static menu-bar extra. Its presence and
/// timer do not depend on any SwiftUI window or inspector lifecycle.
@MainActor
final class MacCallStatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let phone: PhoneStore
    private let activity: MacCallActivity
    private let showWindow: () -> Void
    private let miniCallWindow: MacMiniCallWindow
    private var observation: AnyCancellable?

    init(phone: PhoneStore, activity: MacCallActivity, miniCallWindow: MacMiniCallWindow, showWindow: @escaping () -> Void) {
        self.phone = phone; self.activity = activity; self.miniCallWindow = miniCallWindow; self.showWindow = showWindow
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.imagePosition = .imageLeading
        observation = activity.$snapshot.sink { [weak self] in self?.update($0) }
    }
    private func update(_ snapshot: MacCallActivity.Snapshot) {
        guard let button = item.button else { return }
        button.title = snapshot.hasCall ? " " + (snapshot.elapsed.isEmpty ? snapshot.label : snapshot.elapsed) : ""
        button.image = Self.image(snapshot)
        button.toolTip = snapshot.hasCall ? "fonoo · \(snapshot.label) · \(snapshot.contact)\(snapshot.elapsed.isEmpty ? "" : " · " + snapshot.elapsed)" : "fonoo öffnen"
        button.setAccessibilityLabel(snapshot.hasCall ? "fonoo, \(snapshot.label), \(snapshot.elapsed)" : "fonoo")
    }
    static func image(_ snapshot: MacCallActivity.Snapshot) -> NSImage? {
        guard snapshot.hasCall else {
            let image = NSImage(systemSymbolName: "phone.bubble", accessibilityDescription: "fonoo")
            image?.isTemplate = true
            return image
        }
        let glyph = NSImage(systemSymbolName: snapshot.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [snapshot.tint]))
        let image = NSImage(size: NSSize(width: 46, height: 18), flipped: false) { _ in
            glyph?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            snapshot.tint.setFill()
            for (index, level) in snapshot.waveform.enumerated() {
                let height = 3 + level * 13
                NSBezierPath(roundedRect: NSRect(x: 21 + Double(index) * 5, y: (18 - height) / 2,
                    width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = activity.snapshot
        add(snapshot.hasCall ? snapshot.label + (snapshot.elapsed.isEmpty ? "" : " · " + snapshot.elapsed) : phone.registration.label,
            to: menu, action: nil)
        if snapshot.hasCall { add(snapshot.contact, to: menu, action: nil) }
        add(snapshot.hasCall ? "Zum Gespräch" : "fonoo öffnen", to: menu, action: #selector(openWindow))
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
        let dnd = add("Nicht stören", to: menu, action: #selector(toggleDND))
        dnd.state = phone.doNotDisturb ? .on : .off
        add("fonoo beenden", to: menu, action: #selector(quit))
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
    @objc private func toggleDND() { phone.doNotDisturb.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    func remove() {
        observation?.cancel(); observation = nil
        NSStatusBar.system.removeStatusItem(item)
    }
    #if DEBUG
    var buttonTitle: String { item.button?.title ?? "" }
    var buttonLabel: String { item.button?.accessibilityLabel() ?? "" }
    var isVisible: Bool { item.isVisible }
    #endif
}
