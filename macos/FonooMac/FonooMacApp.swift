import AppKit
import AVFoundation
import Combine
import Security
import SwiftUI

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static var runningChecks: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains { ["--check-authentication", "--check-sip-lifecycle", "--check-telephony", "--check-audio", "--check-microphone-ui", "--preview-call-ui", "--preview-team-ui"].contains($0) }
        #else
        return false
        #endif
    }
    let phone: PhoneStore
    let customer: CustomerAccount = {
        #if DEBUG
        if TeamPreview.enabled { return CustomerAccount(teamPreview: true) }
        #endif
        return CustomerAccount()
    }()
    lazy var callActivity = MacCallActivity(manager: phone.manager)
    private var statusItem: MacCallStatusItem?
    private var miniCallWindow: MacMiniCallWindow?
    var openMainWindow: (() -> Void)?
    #if DEBUG
    private var previewCore: MacCallPreviewCore?
    #endif
    private var observations: Set<AnyCancellable> = []
    private var ringTimer: Timer?
    private var ringingID: UUID?
    private var attentionRequest: Int?

    override init() {
        #if DEBUG
        if TeamPreview.enabled { phone = PhoneStore(previewCore: TeamPreviewCore()) }
        else if ProcessInfo.processInfo.arguments.contains("--preview-call-ui") {
            let core = MacCallPreviewCore()
            phone = PhoneStore(previewCore: core)
            previewCore = core
        } else { phone = PhoneStore() }
        #else
        phone = PhoneStore()
        #endif
        super.init()
        #if DEBUG
        if Self.runningChecks { return }
        #endif
        customer.attach(phone: phone)
        phone.manager.$call.sink { [weak self] call in
            self?.updateIncomingAlert(call)
        }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.phone.becameInactive(background: true) }
            }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.phone.becameActive()
                    await self?.customer.refresh()
                }
            }.store(in: &observations)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Self.runningChecks { installStatusItem(); return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-sip-lifecycle") {
            Task { @MainActor in
                do {
                    // Isolated SDK lifecycle, no account, microphone or production request.
                    try await phone.connection?.shutdown()
                    let connection = SIPConnectionCoordinator { LinphoneSIPCore() }
                    try connection.start()
                    guard connection.running else { throw PhoneError.message("SDK nicht gestartet.") }
                    try await connection.restart()
                    guard connection.running else { throw PhoneError.message("Neustart fehlgeschlagen.") }
                    try await connection.shutdown()
                    print("PASS: Liblinphone start, restart and shutdown; no accounts, calls or microphone")
                    fflush(stdout); exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); fflush(stdout); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-authentication") {
            Task { @MainActor in
                do { try await CustomerAccount.runAuthenticationChecks(); fflush(stdout); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); fflush(stdout); exit(1) }
            }
            return
        }
        if let previewCore {
            installStatusItem()
            previewCore.start()
            NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)
                .sink { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        let before = self.callActivity.snapshot.elapsed
                        try? await Task.sleep(for: .seconds(1.2))
                        let after = self.callActivity.snapshot.elapsed
                        let passed = window.isMiniaturized && self.callActivity.snapshot.hasCall && self.callActivity.isSampling
                            && self.statusItem?.isVisible == true && self.miniCallWindow?.isVisible == true && before != after
                        print("\(passed ? "PASS" : "FAIL"): minimized window; mini call and status visible, elapsed \(before) -> \(after), label \(self.statusItem?.buttonLabel ?? "")")
                        fflush(stdout)
                    }
                }.store(in: &observations)
            NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        let hidden = self?.miniCallWindow?.isVisible == false
                        print("\(hidden ? "PASS" : "FAIL"): call window restored; mini call hidden"); fflush(stdout)
                    }
                }
                .store(in: &observations)
            callActivity.$snapshot.dropFirst().filter { !$0.hasCall }.sink { [weak self] _ in
                Task { @MainActor in
                    let hidden = self?.miniCallWindow?.isVisible == false
                    print("\(hidden ? "PASS" : "FAIL"): call ended; mini call hidden"); fflush(stdout)
                }
            }.store(in: &observations)
            return
        }
        #if canImport(linphonesw)
        if ProcessInfo.processInfo.arguments.contains("--check-microphone-ui") {
            Task { @MainActor in
                do { try await checkMicrophonePreview(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-audio") {
            do { try AudioQualityChecks.run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        #endif
        guard ProcessInfo.processInfo.arguments.contains("--check-telephony") else { return }
        do {
            #if canImport(linphonesw)
            let core = LinphoneSIPCore()
            try core.validateMacRuntime()
            #else
            guard let core = phone.engines else { throw PhoneError.message("Engine fehlt.") }
            try core.start()
            core.refreshAudioDevices()
            #endif
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.fonoo.macos.runtime-check",
                kSecAttrAccount as String: UUID().uuidString]
            let payload = Data("local-fixture".utf8)
            let added = SecItemAdd(query.merging([kSecValueData as String: payload,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, value in value } as CFDictionary, nil)
            guard added == errSecSuccess else { throw PhoneError.message("Keychain write: \(added)") }
            defer { SecItemDelete(query as CFDictionary) }
            var result: CFTypeRef?
            let read = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, value in value } as CFDictionary, &result)
            guard read == errSecSuccess, result as? Data == payload else { throw PhoneError.message("Keychain read: \(read)") }
            print("PASS: native macOS SDK, TLS trust bundle, audio enumeration and Keychain round trip")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
        #endif
    }
    private func installStatusItem() {
        let miniCall = MacMiniCallWindow(phone: phone, activity: callActivity) { [weak self] in self?.showMainWindow() }
        miniCallWindow = miniCall
        statusItem = MacCallStatusItem(phone: phone, activity: callActivity, miniCallWindow: miniCall) { [weak self] in self?.showMainWindow() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        callActivity.stop()
        miniCallWindow?.stop()
        statusItem?.remove()
    }
    #if DEBUG && canImport(linphonesw)
    private func checkMicrophonePreview() async throws {
        let core = LinphoneSIPCore()
        let manager = CallManager(core: core, audio: AudioManager(), diagnostics: Diagnostics())
        try core.validateMacRuntime()
        core.reloadAudioDevices()
        let hardware = MacAudioHardware()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw PhoneError.message("Mikrofonberechtigung fehlt; Test fragt nicht selbst nach Zugriff.")
        }
        guard manager.audioDevices.filter({ $0.id.hasPrefix("input:") && $0.isSelected }).count == 1,
              manager.audioDevices.filter({ $0.id.hasPrefix("output:") && $0.isSelected }).count == 1 else {
            throw PhoneError.message("Aktuelle Eingabe und Ausgabe sind nicht eindeutig markiert.")
        }
        let inputs = manager.audioDevices.filter { $0.id.hasPrefix("input:") }
        let targets = inputs.filter { MacAudioHardware.isSystemDefault($0) || hardware.uid(for: $0) == "BuiltInMicrophoneDevice" }
        guard !targets.isEmpty else { throw PhoneError.message("Kein Testmikrofon verfügbar.") }
        let meter = MacMicrophoneMeter.shared
        for input in targets {
            try core.selectAudioDevice(id: input.id)
            await meter.monitor(input: input, hardware: hardware, manager: manager)
            try await Task.sleep(for: .seconds(1.5))
            guard meter.status == .listening, meter.previewSampleCount > 3, meter.isPreviewRunning,
                  let range = meter.previewPowerRange, range.upperBound.isFinite else {
                throw PhoneError.message("Keine echten Mikrofonpegel für \(hardware.name(for: input)).")
            }
            print("PASS: \(hardware.name(for: input)), \(meter.previewSampleCount) echte Pegel, Bereich \(range) dB")
            try AudioManager().prepare()
            guard !meter.isPreviewRunning else { throw PhoneError.message("Preview läuft nach Übergabe an Telefonie weiter.") }
            meter.stop()
            guard !meter.isPreviewRunning, meter.status == .idle, meter.level == 0 else {
                throw PhoneError.message("Preview bleibt nach dem Schließen aktiv.")
            }
            print("PASS: Mikrofon beim Gesprächsstart und beim Schließen freigegeben")
        }
    }
    #endif
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }
    func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func showMiniCallWindow() {
        guard phone.call != nil else { return }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), !window.isMiniaturized {
            window.miniaturize(nil)
        }
        miniCallWindow?.show()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard phone.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Gespräch beenden und fonoo schließen?"
        alert.informativeText = "Dein laufendes Gespräch wird getrennt."
        alert.addButton(withTitle: "Weiter telefonieren")
        alert.addButton(withTitle: "Beenden")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    private func updateIncomingAlert(_ call: CallSession?) {
        guard let call, call.phase == .incoming else {
            ringTimer?.invalidate(); ringTimer = nil; ringingID = nil
            if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
            attentionRequest = nil
            return
        }
        guard ringingID != call.id else { return }
        ringingID = call.id
        attentionRequest = NSApp.requestUserAttention(.criticalRequest)
        NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.orderFront(nil)
        NSSound(named: "Glass")?.play()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in NSSound(named: "Glass")?.play() }
        RunLoop.main.add(timer, forMode: .common)
        ringTimer = timer
    }
}

@main
struct FonooMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("fonoo", id: "main") {
            Group {
                #if DEBUG
                if TeamPreview.enabled {
                    MacRootView(isPreview: true, isTeamPreview: true)
                        .safeAreaInset(edge: .bottom) { Text("Vorschau · Beispieldaten").font(.caption).foregroundStyle(.secondary).padding(8) }
                } else if ProcessInfo.processInfo.arguments.contains("--preview-call-ui") {
                    MacRootView(isPreview: true)
                        .safeAreaInset(edge: .bottom) {
                            Text("Vorschau · kein echter Anruf").font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                } else { MacRootView() }
                #else
                MacRootView()
                #endif
            }
                .environmentObject(delegate.phone)
                .environmentObject(delegate.customer)
                .environmentObject(delegate.callActivity)
                .tint(MacStyle.accent)
                .frame(minWidth: 820, minHeight: 580)
                .onAppear {
                    let open = openWindow
                    delegate.openMainWindow = { open(id: "main") }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard !MacAppDelegate.runningChecks else { return }
                    delegate.customer.setPresenceForeground(phase == .active)
                    if phase == .active {
                        delegate.phone.becameActive()
                        Task { await delegate.customer.refresh() }
                    }
                }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            MacTelephonyCommands(phone: delegate.phone, showMiniCall: delegate.showMiniCallWindow)
        }
    }
}

/// Menu availability follows the same observable call state as window controls.
struct MacTelephonyCommands: Commands {
    @ObservedObject var phone: PhoneStore
    let showMiniCall: () -> Void
    var body: some Commands {
        CommandMenu("Telefonie") {
            Button("Kleines Gesprächsfenster anzeigen", action: showMiniCall)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(phone.call == nil)
            Divider()
            Button("Anruf annehmen") { phone.answer() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(phone.call?.phase != .incoming)
            Button("Anruf beenden") { phone.end() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(phone.call == nil)
        }
    }
}
