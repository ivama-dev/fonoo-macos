import AppKit
import Combine
import SwiftUI

/// A companion to the main window, using the existing call state and audio levels.
/// Showing it never activates the app or brings the minimized window back.
@MainActor
final class MacMiniCallWindow: NSObject, NSWindowDelegate {
    private let phone: PhoneStore
    private let activity: MacCallActivity
    private let showMainWindow: () -> Void
    private var panel: NSPanel?
    private var observations: Set<AnyCancellable> = []
    private var snapshot = MacCallActivity.Snapshot()
    private weak var mainWindow: NSWindow?
    private var mainIsClosed = false
    private var dismissedCallID: UUID?
    private var focusWhenShown = false
    private var stopped = false

    init(phone: PhoneStore, activity: MacCallActivity, showMainWindow: @escaping () -> Void) {
        self.phone = phone
        self.activity = activity
        self.showMainWindow = showMainWindow
        super.init()
        mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" }
        activity.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.updateVisibility()
        }.store(in: &observations)
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue == "main", let self else { return }
                self.mainWindow = window
                self.mainIsClosed = false
                self.updateVisibility()
            }.store(in: &observations)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue == "main", let self else { return }
                self.mainWindow = window
                self.mainIsClosed = true
                self.updateVisibility()
            }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.keepOnScreen() }.store(in: &observations)
    }

    private var mainIsCompact: Bool { mainIsClosed || mainWindow == nil || mainWindow?.isMiniaturized == true }
    var canShow: Bool { snapshot.hasCall && mainIsCompact }
    var isVisible: Bool { panel?.isVisible == true }

    /// The menu bar can restore a mini window that the user dismissed.
    func show() {
        guard snapshot.hasCall else { return }
        dismissedCallID = nil
        focusWhenShown = true
        updateVisibility()
    }
    private func updateVisibility() {
        guard !stopped else { return }
        if !snapshot.hasCall { focusWhenShown = false }
        if !snapshot.hasCall || !mainIsCompact { dismissedCallID = nil }
        guard canShow, snapshot.callID != dismissedCallID else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil { createPanel() }
        guard let panel else { return }
        if !panel.isVisible {
            keepOnScreen()
            panel.orderFrontRegardless()
        }
        // Minimization finishes asynchronously. Focus an explicitly requested
        // window only once it is shown; automatic showing never takes focus.
        if focusWhenShown {
            panel.makeKeyAndOrderFront(nil)
            focusWhenShown = false
        }
    }
    private func createPanel() {
        let panel = MacCallPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 94),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Gespräch"
        panel.identifier = NSUserInterfaceItemIdentifier("mini-call")
        panel.isFloatingPanel = true
        panel.level = .floating
        // A call is ongoing work: its controls remain available in other apps.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MacMiniCallView(showMainWindow: showMainWindow)
            .environmentObject(phone).environmentObject(activity).tint(MacStyle.accent))
        self.panel = panel
        let screen = mainWindow?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20,
                y: visible.maxY - panel.frame.height - 20))
        }
    }
    private func keepOnScreen() {
        guard let panel else { return }
        let screens = NSScreen.screens
        let visible = (screens.first { $0.visibleFrame.intersects(panel.frame) } ?? mainWindow?.screen ?? NSScreen.main)?.visibleFrame
        guard let visible else { return }
        panel.setFrameOrigin(NSPoint(x: min(max(panel.frame.minX, visible.minX), max(visible.minX, visible.maxX - panel.frame.width)),
            y: min(max(panel.frame.minY, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))))
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissedCallID = snapshot.callID
        sender.orderOut(nil)
        return false // Closing this window never hangs up the call.
    }
    func stop() {
        stopped = true
        observations.removeAll()
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }
}

private final class MacCallPanel: NSPanel {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { true }
}

private struct MacMiniCallView: View {
    @EnvironmentObject private var phone: PhoneStore
    @EnvironmentObject private var activity: MacCallActivity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let showMainWindow: () -> Void

    var body: some View {
        let snapshot = activity.snapshot
        let call = phone.manager.controlledCall
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                MacCallWaveform(snapshot: snapshot).tint(Color(nsColor: snapshot.tint))
                Text(snapshot.contact).font(.callout.weight(.semibold)).lineLimit(1)
                    .help(snapshot.contact)
                Spacer(minLength: 0)
                Text(snapshot.elapsed).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if phone.manager.consultation != nil { Text("Rückfrage").font(.caption2) }
                    Text(snapshot.label).font(.caption).lineLimit(1)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: showMainWindow) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(MacMiniCallButtonStyle(color: MacStyle.accent))
                    .accessibilityLabel("Zum Gespräch").help("Großes Gesprächsfenster öffnen")
                if call?.phase == .incoming {
                    Button { phone.answer() } label: { Image(systemName: "phone.fill") }
                        .buttonStyle(MacMiniCallButtonStyle(color: .green, prominent: true))
                        .accessibilityLabel("Annehmen").help("Anruf annehmen")
                        .disabled(phone.manager.acceptingCall)
                } else {
                    Button { phone.toggleMute() } label: {
                        Image(systemName: call?.isMuted == true ? "mic.slash.fill" : "mic.fill")
                    }.buttonStyle(MacMiniCallButtonStyle(color: call?.isMuted == true ? MacStyle.accent : .secondary,
                        selected: call?.isMuted == true))
                        .accessibilityLabel(call?.isMuted == true ? "Mikrofon einschalten" : "Mikrofon stummschalten")
                        .help(call?.isMuted == true ? "Mikrofon einschalten" : "Mikrofon stummschalten")
                        .disabled(call?.phase != .active)
                    if phone.manager.consultation == nil {
                        Button { phone.toggleHold() } label: {
                            Image(systemName: call?.isHeld == true ? "play.fill" : "pause.fill")
                        }.buttonStyle(MacMiniCallButtonStyle(color: MacStyle.accent, selected: call?.isHeld == true))
                            .accessibilityLabel(call?.isHeld == true ? "Gespräch fortsetzen" : "Gespräch halten")
                            .help(call?.isHeld == true ? "Gespräch fortsetzen" : "Gespräch halten")
                            .disabled(call?.phase != .active || call?.holdPending == true || call?.isRemoteHeld == true
                                || phone.manager.consultationPending || phone.manager.transferPending)
                    }
                }
                Button { phone.end() } label: { Image(systemName: "phone.down.fill") }
                    .buttonStyle(MacMiniCallButtonStyle(color: .red, prominent: true))
                    .accessibilityLabel(call?.phase == .incoming ? "Ablehnen" : "Auflegen")
                    .help(call?.phase == .incoming ? "Anruf ablehnen" : "Gespräch beenden")
                    .disabled(phone.call == nil || phone.call?.phase == .ending)
            }.controlSize(.small)
        }.padding(14).frame(width: 320, height: 94)
            .background {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else { Rectangle().fill(.regularMaterial) }
            }
    }
}

/// Keep call actions recognizable when this floating window isn't key.
/// Native bordered buttons otherwise desaturate their tint in inactive windows.
private struct MacMiniCallButtonStyle: ButtonStyle {
    let color: Color
    var prominent = false
    var selected = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: prominent ? 36 : 30, height: 26)
            .foregroundStyle(prominent ? Color.white : color)
            .background(color.opacity(prominent ? 1 : selected ? 0.24 : colorScheme == .dark ? 0.18 : 0.10), in: shape)
            .overlay { shape.strokeBorder(color.opacity(prominent ? 0 : selected ? 0.42 : 0.20)) }
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.35)
            .contentShape(shape)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
