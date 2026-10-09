import Foundation
import AVFoundation
#if canImport(linphonesw)
import linphonesw
import linphone

/// Only this file imports the SIP/media SDK. The SDK owns RTP, codecs and echo cancellation.
@MainActor
final class LinphoneSIPCore: SIPCore {
    var onEvent: ((SIPEvent) -> Void)?
    #if DEBUG
    private var wireCheckCA: URL?
    static func wireCheckCore(ca: URL) -> LinphoneSIPCore {
        let value = LinphoneSIPCore(); value.wireCheckCA = ca; return value
    }
    #endif
    var sdkVersion: String { Core.getVersion }
    var supportsSIPTracing: Bool { true }
    func start() throws { _ = try ensureCore() }
    func shutdown() async throws {
        guard calls.isEmpty else { throw PhoneError.message("Bitte zuerst alle Gespräche beenden.") }
        var timedOut = false
        var deregistrationFailed = false
        if let core {
            let needsConfirmation = core.defaultAccount?.state == .Ok || core.defaultAccount?.state == .Progress || core.defaultAccount?.state == .Refreshing
            try unregister()
            let deadline = Date().addingTimeInterval(3)
            while core.defaultAccount?.state == .Ok || core.defaultAccount?.state == .Progress || core.defaultAccount?.state == .Refreshing {
                if Date() >= deadline { timedOut = true; break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            deregistrationFailed = needsConfirmation && core.defaultAccount?.state == .Failed
            iterateTimer?.invalidate(); iterateTimer = nil
            setSIPTracing(false)
            if let delegate { core.removeDelegate(delegate: delegate) }
            core.clearAllAuthInfo()
            core.stop()
        }
        delegate = nil; core = nil; activeSIPAccount = nil; account = nil
        calls.removeAll()
        defaultAudioCodecs.removeAll(); ids.removeAll(); audioTraces.removeAll(); callTimings.removeAll()
        onEvent = nil; wantsRegistration = false
        if timedOut || deregistrationFailed { throw PhoneError.message("Liblinphone wurde beendet; die SIP-Abmeldung wurde nicht bestätigt. Engine-Wechsel erneut ausdrücklich starten.") }
    }
    private var loggingDelegate: LoggingServiceDelegateStub?
    private var traceGeneration = UUID()
    private var sipTracing = false

    func setSIPTracing(_ enabled: Bool) {
        traceGeneration = UUID()
        sipTracing = enabled
        let logging = LoggingService.Instance
        // Disable the default stdout sink and SDK file collection before raising verbosity.
        bctbx_set_log_handler { _, _, _, _ in }
        Core.enableLogCollection(state: .Disabled)
        if let loggingDelegate { logging.removeDelegate(delegate: loggingDelegate) }
        loggingDelegate = nil
        if enabled {
            let generation = traceGeneration
            let callback = LoggingServiceDelegateStub(onLogMessageWritten: { [weak self] _, _, _, message in
                let packet = SIPTracePacket.sanitized(message)
                let mediaEvent = MediaTrace.sanitized(message)
                guard packet != nil || mediaEvent != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.sipTracing, self.traceGeneration == generation else { return }
                    if let packet { self.onEvent?(.sipPacket(packet)) }
                    if let mediaEvent { self.onEvent?(.callTrace(mediaEvent)) }
                }
            })
            loggingDelegate = callback
            logging.addDelegate(delegate: callback)
        }
        logging.logLevel = enabled ? .Message : .Fatal
    }

    private var defaultAudioCodecs: [(payload: linphonesw.PayloadType, enabled: Bool)] = []
    private var core: Core?
    private var delegate: CoreDelegateStub?
    private var iterateTimer: Timer?
    private var account: SIPAccount?
    private var activeSIPAccount: Account?
    private var calls: [UUID: Call] = [:]
    private var ids: [OpaquePointer: UUID] = [:]
    private struct AudioTraceState {
        var lastReportAt: TimeInterval = -.infinity
        var lastFormat = ""
        var receivedRTCP = false
        var lastSummary = ""
    }
    private var audioTraces: [UUID: AudioTraceState] = [:]
    private enum CallMilestone: String, Hashable {
        case connected = "SIP Connected"
        case streamsRunning = "Audio-Engine StreamsRunning"
        case firstReceivedRTP = "Erstes empfangenes Audio-RTP beobachtet"
    }
    private struct CallTimingState {
        let startedAt: TimeInterval
        var milestones: Set<CallMilestone> = []
    }
    private var callTimings: [UUID: CallTimingState] = [:]
    private var outgoingID: UUID?
    private var wantsRegistration = false
    private var systemCallAudio = false

    private func trace(_ message: String) { onEvent?(.registrationTrace(message)) }

    /// Shared by the app and the real SDK media checks. Keep one processing chain:
    /// the SDK selects hardware echo cancellation where available, with software
    /// fallback on macOS. Its experimental AGC/half-duplex limiter stay disabled.
    static func configureSpeechAudio(_ value: Core) {
        value.audioAdaptiveJittcompEnabled = true
        value.audioJittcomp = 60
        // Keep adaptation from accumulating the SDK's default 500 ms of audio
        // delay during congestion. Longer network queues need bitrate adaptation.
        value.config?.setInt(section: "rtp", key: "jitter_buffer_max_size", value: 200)
        value.adaptiveRateControlEnabled = true
        value.adaptiveRateAlgorithm = "advanced"
        // Leave bandwidth unknown so the SDK can adapt to actual RTCP feedback.
        value.uploadBandwidth = 0
        value.downloadBandwidth = 0
        value.uploadPtime = 0 // Codec default: Opus starts at 20 ms and may adapt.
        value.downloadPtime = 20
        value.agcEnabled = false
        value.echoLimiterEnabled = false
        value.noiseSuppressionEnabled = false
        value.micGainDb = 0
        value.playbackGainDb = 0
        #if os(macOS)
        value.echoCancellationEnabled = true
        #else
        // iOS VoiceProcessingIO already provides echo cancellation through the
        // voiceChat audio route. Do not add another software canceller.
        value.echoCancellationEnabled = false
        #endif
        for payload in value.audioPayloadTypes where payload.mimeType.lowercased() == "opus" {
            // Receiver preferences, not a fixed encoder bitrate. FEC only helps
            // when the sending encoder includes recovery data and it arrives in time.
            payload.recvFmtp = "useinbandfec=1;stereo=0;sprop-stereo=0;usedtx=0;maxaveragebitrate=40000"
        }
    }

    /// SDK 5.5.23 derives queue capacity assuming 200 packets/s. Our speech
    /// normally uses 20 ms packets (50/s), so its capacity can hold far more
    /// audio than the adaptive delay target. Bound that queue independently.
    static func configureSpeechQueue(_ call: Call) {
        guard let transport = linphone_call_get_meta_rtp_transport(call.getCobject, 0),
              let session = transport.pointee.session else { return }
        var parameters = JBParameters()
        rtp_session_get_jitter_buffer_params(session, &parameters)
        parameters.max_packets = 12 // About 240 ms at normal 20 ms packetization.
        rtp_session_set_jitter_buffer_params(session, &parameters)
    }

    #if os(macOS) && DEBUG
    /// Local smoke check: loads the SDK, bundled trust store and Core Audio without credentials or calls.
    func validateMacRuntime() throws {
        _ = try ensureCore()
        refreshAudioDevices()
    }
    #endif

    private func ensureCore() throws -> Core {
        if let core { trace("Telefonie-Engine ist bereits bereit."); return core }
        trace("Telefonie-Engine wird initialisiert.")
        // No config file: liblinphone must not persist SIP credentials outside Keychain.
        let config = try Factory.Instance.createConfigFromString(data: "[sip]\nstore_auth_info=0\n[storage]\nuri=null\ncall_logs_db_uri=null\n")
        let value = try Factory.Instance.createCoreWithConfig(config: config, systemContext: nil)
        value.autoIterateEnabled = false
        value.callkitEnabled = systemCallAudio
        value.pushNotificationEnabled = false
        value.videoCaptureEnabled = false
        value.videoDisplayEnabled = false
        value.maxCalls = 2 // One original call plus one explicitly requested consultation.
        value.setUserAgent(name: "fonoo", version: "0.1")
        Self.configureSpeechAudio(value)
        // Use the CA bundle shipped by the pinned SDK explicitly, rather than
        // relying on its platform-dependent default resource discovery.
        let framework = Bundle.main.privateFrameworksURL.flatMap {
            Bundle(url: $0.appendingPathComponent("linphone.framework"))
        }
        #if DEBUG
        let anchor = wireCheckCA ?? framework?.url(forResource: "rootca", withExtension: "pem")
        #else
        let anchor = framework?.url(forResource: "rootca", withExtension: "pem")
        #endif
        guard let trustBundle = anchor,
              let pem = try? String(contentsOf: trustBundle, encoding: .utf8),
              pem.contains("-----BEGIN CERTIFICATE-----") else {
            trace("FEHLER: Der mitgelieferte TLS-Zertifikatsspeicher fehlt oder ist nicht lesbar.")
            throw PhoneError.message("TLS-Zertifikatsspeicher nicht verfügbar. Bitte fonoo neu installieren.")
        }
        value.rootCa = trustBundle.path
        let rootCount = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        trace("TLS-Vertrauen: SDK-Zertifikatsspeicher geladen (\(rootCount) Zertifikate). Zertifikatskette und Servername werden geprüft.")
        value.verifyServerCertificates(yesno: true)
        value.verifyServerCn(yesno: true)
        LoggingService.Instance.logLevel = sipTracing ? .Message : .Fatal
        let callbacks = CoreDelegateStub(
            onCallStateChanged: { [weak self] _, call, state, _ in self?.handle(call, state: state) },
            onTransferStateChanged: { [weak self] _, call, state in
                guard let self, let pointer = call.getCobject, let id = self.ids[pointer] else { return }
                let result: TransferState
                switch state {
                case .Connected, .StreamsRunning: result = .succeeded
                case .Error: result = .failed(call.errorInfo?.protocolCode ?? 0)
                default: result = .progressing
                }
                self.onEvent?(.transfer(id, result))
            },
            onCallStatsUpdated: { [weak self] _, call, stats in
                guard let self, stats.type == .Audio, let pointer = call.getCobject, let id = self.ids[pointer] else { return }
                // Early media can contain RTP before Connected; do not confuse it with answered speech.
                if stats.rtpPacketRecv > 0 { self.recordCallMilestone(.firstReceivedRTP, id: id) }
                guard call.state == .StreamsRunning else { return }
                self.recordAudioTrace(call, stats: stats, id: id)
                self.onEvent?(.media(MediaSnapshot(codec: call.currentParams?.usedAudioPayloadType?.mimeType ?? "–",
                    downloadKbps: stats.downloadBandwidth, uploadKbps: stats.uploadBandwidth,
                    jitterMs: stats.jitterBufferSizeMs, lossPercent: stats.localLossRate, iceStatus: Self.iceLabel(stats.iceState),
                    audioDirection: call.currentParams.map { String(describing: $0.audioDirection) } ?? "Nicht verfügbar",
                    inputDevice: call.inputAudioDevice.map { String(describing: $0.type) } ?? "Keines",
                    outputDevice: call.outputAudioDevice.map { String(describing: $0.type) } ?? "Keines")))
            },
            onAudioDeviceChanged: { [weak self] _, _ in self?.refreshAudioDevices() },
            onAudioDevicesListUpdated: { [weak self] _ in self?.refreshAudioDevices() },
            onAccountRegistrationStateChanged: { [weak self] core, registeredAccount, state, _ in
                // addAccount can emit callbacks before the default account is set.
                // Track our account directly; ignore late events from removed accounts.
                guard let self, let active = self.activeSIPAccount,
                      active.getCobject == registeredAccount.getCobject else { return }
                self.trace("SDK-Registrierungszustand: \(state)")
                if state == .Failed, let info = registeredAccount.errorInfo {
                    self.trace("FEHLER: SDK-Grund \(info.reason); Protokollcode \(info.protocolCode). Code 0 bedeutet: kein SIP-Antwortcode verfügbar.")
                }
                let status: RegistrationStatus
                switch state {
                case .Ok: status = self.wantsRegistration ? .registered : .unregistering
                case .Progress, .Refreshing: status = self.wantsRegistration ? .registering : .unregistering
                case .Failed: status = .failed(registeredAccount.errorInfo?.protocolCode ?? 0)
                case .Cleared:
                    status = .offline
                    if !self.wantsRegistration { core.clearAllAuthInfo() }
                default: status = .offline
                }
                self.onEvent?(.registration(status))
            })
        value.addDelegate(delegate: callbacks)
        try value.start()
        trace("Telefonie-Engine gestartet; Zertifikats- und Servernamenprüfung aktiviert.")
        trace("Sprachprofil: adaptiver Audiopuffer \(value.audioAdaptiveJittcompEnabled), Startpuffer \(value.audioJittcomp) ms; adaptive Datenrate \(value.adaptiveRateControlEnabled); zusätzliche Software-AGC \(value.agcEnabled), Echo-Limiter \(value.echoLimiterEnabled), Rauschfilter \(value.noiseSuppressionEnabled). Opus: Mono, kontinuierliche Sprache, FEC-Empfang angeboten, maximal 40 kbit/s angefordert.")
        defaultAudioCodecs = value.audioPayloadTypes.map { ($0, $0.enabled()) }
        core = value
        delegate = callbacks
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.core?.iterate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iterateTimer = timer
        return value
    }

    func register(account: SIPAccount, password: String, turnPassword: String) throws {
        guard calls.isEmpty else { throw PhoneError.message("Zugangsdaten erst nach dem Gespräch ändern.") }
        trace("Registrierungsauftrag: \(account.transport.rawValue), Port \(account.port).")
        let nat = try account.nat.validated()
        guard !nat.usesTURN || !turnPassword.isEmpty else {
            throw PhoneError.message("TURN-Passwort fehlt. Bitte im SIP-Konto ergänzen.")
        }
        let value = try ensureCore()
        let compatibility = account.compatibility
        guard !compatibility.forceTURN || nat.usesTURN else {
            throw PhoneError.message("Erzwungenes TURN benötigt ICE und TURN.")
        }
        if compatibility.g711Only {
            let supported = defaultAudioCodecs.filter {
                compatibility.allowsCodec(mime: $0.payload.mimeType, rate: $0.payload.clockRate)
            }
            guard !supported.isEmpty else { throw PhoneError.message("G.711 ist in der Telefonie-Engine nicht verfügbar.") }
        }
        for codec in defaultAudioCodecs {
            let enabled = compatibility.g711Only
                ? compatibility.allowsCodec(mime: codec.payload.mimeType, rate: codec.payload.clockRate)
                : codec.enabled
            guard codec.payload.enable(enabled: enabled) == 0 else {
                throw PhoneError.message("Audio-Codecs konnten nicht eingestellt werden.")
            }
        }
        value.forcedIceRelayEnabled = compatibility.forceTURN
        trace(compatibility.g711Only ? "Audio-Codecs: ausschließlich G.711 (PCMA/PCMU)." : "Audio-Codecs: SDK-Standard wiederhergestellt.")
        trace(compatibility.forceTURN ? "ICE: TURN-Relay wird erzwungen; ohne funktionierenden Relay-Weg keine Audioverbindung." : "ICE: automatische Auswahl des Medienwegs.")
        let policy = try value.createNatPolicy()
        policy.iceEnabled = nat.iceEnabled
        policy.stunEnabled = nat.iceEnabled && !nat.turnEnabled
        policy.turnEnabled = nat.usesTURN
        policy.stunServer = nat.effectiveEndpoint
        policy.stunServerUsername = nat.usesTURN ? nat.turnUsername : nil
        policy.udpTurnTransportEnabled = nat.usesTURN && nat.turnTransport == .udp
        policy.tcpTurnTransportEnabled = nat.usesTURN && nat.turnTransport == .tcp
        policy.tlsTurnTransportEnabled = nat.usesTURN && nat.turnTransport == .tls
        value.tlsCert = nil
        value.tlsKey = nil
        wantsRegistration = false
        activeSIPAccount = nil
        value.clearAccounts()
        value.clearAllAuthInfo()
        trace("Bisherige Kontokonfiguration entfernt; neue SIP-Identität und Route werden vorbereitet.")
        self.account = account
        let identity = try Factory.Instance.createAddress(addr: "sip:\(account.username)@\(account.effectiveDomain)")
        let server = try Factory.Instance.createAddress(addr: "sip:\(account.server):\(account.port)")
        let transport: TransportType = account.transport == .tls ? .Tls : account.transport == .tcp ? .Tcp : .Udp
        try server.setTransport(newValue: transport)
        let params = try value.createAccountParams()
        try params.setIdentityaddress(newValue: identity)
        try params.setServeraddress(newValue: server)
        try params.setRoutesaddresses(newValue: [server])
        params.natPolicy = policy
        params.registerEnabled = true
        params.expires = 600
        params.pushNotificationAllowed = false
        params.remotePushNotificationAllowed = false
        let auth = try Factory.Instance.createAuthInfo(username: account.username, userid: account.effectiveAuthName,
            passwd: password, ha1: nil, realm: nil, domain: account.effectiveDomain)
        value.addAuthInfo(info: auth)
        if nat.usesTURN {
            let turnAuth = try Factory.Instance.createAuthInfo(username: nat.turnUsername, userid: nil,
                passwd: turnPassword, ha1: nil, realm: nil, domain: nat.turnServer)
            value.addAuthInfo(info: turnAuth)
        }
        trace(nat.iceEnabled
            ? (nat.usesTURN ? "Audio: ICE mit TURN über \(nat.turnTransport.rawValue), Port \(nat.turnPort). Zugangsdaten separat geladen; ICE wählt den Medienweg beim Anruf."
                : "Audio: ICE mit STUN, Port \(nat.stunPort). Kein TURN-Relay aktiviert.")
            : "Audio: ICE/STUN/TURN ausgeschaltet.")
        trace("Authentifizierungsdaten an die Engine übergeben (Inhalt ausgeblendet).")
        value.useRfc2833ForDtmf = account.dtmf == .rfc2833
        value.useInfoForDtmf = account.dtmf == .info
        try value.setMediaencryption(newValue: account.mediaEncryption == .srtp ? .SRTP : .None)
        value.mediaEncryptionMandatory = account.mediaEncryption == .srtp
        let sipAccount = try value.createAccount(params: params)
        activeSIPAccount = sipAccount
        wantsRegistration = true
        onEvent?(.registration(.registering))
        trace("Registrierung an die Engine übergeben; Ablaufzeit 600 Sekunden. Warte auf SDK-Rückmeldung.")
        do {
            try value.addAccount(account: sipAccount)
            // The SDK only accepts a default account already present in its list.
            value.defaultAccount = sipAccount
            trace("SIP-Konto hinzugefügt und als Standardkonto gesetzt; Statusrückmeldungen sind zugeordnet.")
        } catch {
            activeSIPAccount = nil
            wantsRegistration = false
            value.clearAllAuthInfo()
            throw error
        }
    }

    func unregister() throws {
        trace("Abmeldung angefordert.")
        guard calls.isEmpty else { throw PhoneError.message("Bitte zuerst das Gespräch beenden.") }
        wantsRegistration = false
        guard let core, let account = core.defaultAccount, let params = account.params?.clone() else {
            onEvent?(.registration(.offline)); return
        }
        guard params.registerEnabled else {
            core.clearAllAuthInfo()
            onEvent?(.registration(.offline))
            return
        }
        onEvent?(.registration(.unregistering))
        params.registerEnabled = false
        account.params = params
    }

    func invite(number: String, id: UUID) throws {
        guard let core, let account, calls.isEmpty || (calls.count == 1 && calls.values.allSatisfy { $0.state == .Paused }) else { throw PhoneError.message("Bitte das erste Gespräch vollständig halten.") }
        let address = try Factory.Instance.createAddress(addr: "sip:\(account.username)@\(account.effectiveDomain)")
        try address.setUsername(newValue: number)
        let params = try core.createCallParams(call: nil)
        params.audioEnabled = true
        params.videoEnabled = false
        core.micEnabled = true
        outgoingID = id
        defer { outgoingID = nil }
        guard let call = core.inviteAddressWithParams(addr: address, params: params) else {
            throw PhoneError.message("Anruf konnte nicht aufgebaut werden.")
        }
        // OutgoingInit can run synchronously during inviteAddressWithParams.
        if let pointer = call.getCobject, ids[pointer] == nil, call.state != .End, call.state != .Error, call.state != .Released {
            ids[pointer] = id
            calls[id] = call
            callTimings[id] = CallTimingState(startedAt: ProcessInfo.processInfo.systemUptime)
        }
        refreshAudioDevices()
    }
    func transfer(id: UUID, number: String) throws {
        guard let account else { throw PhoneError.message("SIP-Konto fehlt.") }
        let address = try Factory.Instance.createAddress(addr: "sip:\(account.username)@\(account.effectiveDomain)")
        try address.setUsername(newValue: SIPAccount.normalizedNumber(number))
        try find(id).transferTo(referTo: address)
    }
    func transfer(id: UUID, destinationID: UUID) throws {
        try find(id).transferToAnother(dest: find(destinationID))
    }
    func answer(id: UUID) throws {
        let call = try find(id)
        guard call.state == .IncomingReceived || call.state == .IncomingEarlyMedia else { throw PhoneError.message("Der Anruf ist nicht mehr verfügbar.") }
        guard let core else { throw PhoneError.message("Telefonie-Engine ist nicht verfügbar.") }
        onEvent?(.callTrace("Annahme: SDK-Zustand \(call.state)."))
        let params = try core.createCallParams(call: call)
        params.audioEnabled = true
        params.videoEnabled = false
        core.micEnabled = true
        try call.acceptWithParams(params: params)
        onEvent?(.callTrace("Annahme an die Engine übergeben; aktueller SDK-Zustand: \(call.state). Eine ICE-Ermittlung kann die SIP-Antwort verzögern."))
    }
    func end(id: UUID) throws {
        let call = try find(id)
        if call.state == .IncomingReceived || call.state == .IncomingEarlyMedia { try call.decline(reason: .Declined) }
        else { try call.terminate() }
    }
    func setMuted(_ muted: Bool, id: UUID) throws {
        _ = try find(id)
        core?.micEnabled = !muted
    }
    func setHeld(_ held: Bool, id: UUID) throws {
        let call = try find(id)
        if held { try call.pause() } else { try call.resume() }
    }
    func sendDTMF(_ digit: String, id: UUID) throws {
        guard digit.utf8.count == 1, let byte = digit.utf8.first, "0123456789*#".contains(digit) else { return }
        try find(id).sendDtmf(dtmf: CChar(byte))
    }
    func selectAudioDevice(id: String) throws {
        guard let core else { throw PhoneError.message("Telefonie ist nicht bereit.") }
        #if os(macOS)
        let isInput = id.hasPrefix("input:")
        let deviceID = String(id.dropFirst(isInput ? 6 : 7))
        guard (isInput || id.hasPrefix("output:")),
              let device = core.extendedAudioDevices.first(where: {
                  $0.id == deviceID && $0.hasCapability(capability: isInput ? .CapabilityRecord : .CapabilityPlay)
              }) else { throw PhoneError.message("Das Audiogerät ist nicht mehr verbunden.") }
        if isInput {
            core.defaultInputAudioDevice = device
            core.inputAudioDevice = device
            for call in calls.values { call.inputAudioDevice = device }
        } else {
            core.defaultOutputAudioDevice = device
            core.outputAudioDevice = device
            for call in calls.values { call.outputAudioDevice = device }
        }
        #else
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let external = inputs.first { "port:" + $0.uid == id }
        guard id == "iphone" || id == "speaker" || external != nil else {
            if session.currentRoute.outputs.contains(where: { "output:" + $0.uid == id }) { return }
            throw PhoneError.message("Das Audiogerät ist nicht mehr verbunden.")
        }
        // Keep SDK audio processing, but use iOS hardware routes for the user selection.
        let devices = core.extendedAudioDevices.filter { $0.hasCapability(capability: .CapabilityPlay) }
        let defaultDevice = devices.first { $0.deviceName.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased() == "default" }
        let output = id == "speaker" ? devices.first { $0.type == .Speaker } ?? defaultDevice
            : id == "iphone" ? devices.first { $0.type == .Earpiece } ?? defaultDevice : defaultDevice
        if let output {
            core.outputAudioDevice = output
            for call in calls.values { call.outputAudioDevice = output }
        }
        if let input = core.extendedAudioDevices.first(where: {
            $0.hasCapability(capability: .CapabilityRecord) &&
            $0.deviceName.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased() == "default"
        }) {
            core.inputAudioDevice = input
            for call in calls.values { call.inputAudioDevice = input }
        }
        // A prior speaker override must be released before selecting a headset.
        try session.overrideOutputAudioPort(.none)
        try session.setPreferredInput(external ?? inputs.first { $0.portType == .builtInMic })
        if id == "speaker" { try session.overrideOutputAudioPort(.speaker) }
        #endif
        refreshAudioDevices()
    }
    func reloadAudioDevices() {
        #if os(macOS)
        // Re-enumeration is for idle plug/unplug discovery. Do not recreate
        // sound cards underneath live media or override the user's call route.
        if let core, calls.isEmpty {
            let inputID = core.defaultInputAudioDevice?.id
            let outputID = core.defaultOutputAudioDevice?.id
            core.reloadSoundDevices()
            if let input = core.extendedAudioDevices.first(where: { $0.id == inputID && $0.hasCapability(capability: .CapabilityRecord) }) {
                core.defaultInputAudioDevice = input
                core.inputAudioDevice = input
            }
            if let output = core.extendedAudioDevices.first(where: { $0.id == outputID && $0.hasCapability(capability: .CapabilityPlay) }) {
                core.defaultOutputAudioDevice = output
                core.outputAudioDevice = output
            }
        }
        #endif
        refreshAudioDevices()
    }
    func refreshAudioDevices() {
        guard core != nil else { return }
        #if os(macOS)
        guard let core else { return }
        let inputID = (core.inputAudioDevice ?? core.defaultInputAudioDevice)?.id
        let outputID = (core.outputAudioDevice ?? core.defaultOutputAudioDevice)?.id
        let devices = core.extendedAudioDevices.flatMap { device -> [AudioDeviceOption] in
            var options: [AudioDeviceOption] = []
            if device.hasCapability(capability: .CapabilityRecord) {
                options.append(AudioDeviceOption(id: "input:" + device.id, name: device.deviceName, symbol: "mic", isSelected: device.id == inputID))
            }
            if device.hasCapability(capability: .CapabilityPlay) {
                options.append(AudioDeviceOption(id: "output:" + device.id, name: device.deviceName, symbol: "speaker.wave.2", isSelected: device.id == outputID))
            }
            return options
        }
        onEvent?(.audioDevices(devices, selectedID: outputID.map { "output:" + $0 }))
        #else
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        var devices = [
            AudioDeviceOption(id: "iphone", name: "iPhone", symbol: "iphone"),
            AudioDeviceOption(id: "speaker", name: "Lautsprecher", symbol: "speaker.wave.2.fill")
        ]
        let external = inputs.filter { [.bluetoothHFP, .headsetMic, .usbAudio, .carAudio, .lineIn].contains($0.portType) }
        for port in external {
            let name = port.portType == .headsetMic ? "Kabel-Headset" : port.portName
            devices.append(AudioDeviceOption(id: "port:" + port.uid, name: name, symbol: "headphones"))
        }
        var selected: String?
        if let output = session.currentRoute.outputs.first {
            switch output.portType {
            case .builtInReceiver: selected = "iphone"
            case .builtInSpeaker: selected = "speaker"
            default:
                let input = external.first { $0.uid == output.uid || $0.portName == output.portName }
                    ?? external.first { candidate in
                        session.currentRoute.inputs.contains { $0.uid == candidate.uid }
                    }
                if let input { selected = "port:" + input.uid }
                else {
                    // Display the actual system output even when it has no selectable microphone.
                    let id = "output:" + output.uid
                    let name = output.portType == .headphones ? "Kopfhörer" : output.portName
                    devices.append(AudioDeviceOption(id: id, name: name, symbol: "headphones"))
                    selected = id
                }
            }
        }
        onEvent?(.audioDevices(devices, selectedID: selected))
        #endif
    }
    func microphoneLevel(id: UUID) -> Float? {
        guard let call = calls[id], call.state == .StreamsRunning, core?.micEnabled == true else { return nil }
        let level = call.recordVolume
        return level.isFinite ? level : nil
    }
    func callAudioLevels(id: UUID) -> CallAudioLevels {
        guard let call = calls[id] else { return CallAudioLevels(microphone: nil, playback: nil) }
        return Self.measuredAudioLevels(call, microphoneEnabled: core?.micEnabled == true)
    }
    static func measuredAudioLevels(_ call: Call, microphoneEnabled: Bool) -> CallAudioLevels {
        guard call.state == .StreamsRunning else {
            return CallAudioLevels(microphone: nil, playback: nil)
        }
        let microphone = call.recordVolume
        let playback = call.playVolume
        return CallAudioLevels(microphone: microphoneEnabled && microphone.isFinite ? microphone : nil,
            playback: playback.isFinite ? playback : nil)
    }
    func setNetworkAvailable(_ available: Bool) { core?.networkReachable = available }
    func setSystemCallAudio(_ enabled: Bool) {
        systemCallAudio = enabled
        core?.callkitEnabled = enabled
    }
    func systemAudioActivated(_ active: Bool) {
        guard systemCallAudio else { return }
        core?.activateAudioSession(activated: active)
    }
    private func fonooCallID(_ call: Call) -> String? {
        let header = call.remoteParams?.getCustomHeader(headerName: "X-Fonoo-Call-ID") ?? ""
        if header.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil { return header }
        return call.callLog?.callId
    }
    func refreshRegistration() {
        if wantsRegistration {
            trace("Erneuerung der Registrierung angefordert.")
            core?.refreshRegisters()
        }
    }
    private func find(_ id: UUID) throws -> Call {
        guard let call = calls[id] else { throw PhoneError.message("Das Gespräch wurde bereits beendet.") }
        return call
    }
    private func recordAudioTrace(_ call: Call, stats: CallStats, id: UUID, force: Bool = false) {
        guard stats.type == .Audio else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var previous = audioTraces[id] ?? AudioTraceState()
        let payload = call.currentParams?.usedAudioPayloadType
        // MIME comes from negotiation; admit only a bounded codec token, never raw SDP.
        let mime = payload?.mimeType ?? ""
        let codec = mime.range(of: "^[A-Za-z0-9._-]{1,24}$", options: .regularExpression) != nil ? mime : "Unbekannt"
        // This is the negotiated RTP clock, not microphone sample rate or measured audio bandwidth.
        // In particular, G.722 uses an 8 kHz RTP clock for 16 kHz audio; Opus always signals 48 kHz.
        let format = "\(codec); RTP-Takt \(payload?.clockRate ?? 0) Hz; Kanäle \(payload?.channels ?? 0)"
        // RTCP traffic does not prove a reception report block is present. A zero SDK value
        // must therefore not be presented as confirmed zero loss at the peer.
        previous.receivedRTCP = previous.receivedRTCP || stats.rtcpDownloadBandwidth > 0
        let receivedRTCP = previous.receivedRTCP
        func number(_ value: Float) -> String {
            guard value.isFinite, value >= 0 else { return "n/v" }
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        }
        let local = "Empfang: Verlust \(number(stats.localLossRate)) %, Jitter \(number(stats.senderInterarrivalJitter * 1_000)) ms, Puffer \(number(stats.jitterBufferSizeMs)) ms"
        let peer = receivedRTCP
            ? "RTCP empfangen; SDK-Werte für unseren Versand (Gegenstellenbericht nicht verifiziert): Verlust \(number(stats.receiverLossRate)) %, Jitter \(number(stats.receiverInterarrivalJitter * 1_000)) ms"
            : "Gegenstellenwerte noch nicht verfügbar (kein RTCP beobachtet)"
        let rtt = receivedRTCP && stats.roundTripDelay > 0 ? number(stats.roundTripDelay * 1_000) + " ms" : "n/v"
        let summary = "\(format). \(local). \(peer). RTT \(rtt). RTP-Pakete empfangen/gesendet \(stats.rtpPacketRecv)/\(stats.rtpPacketSent); Empfangsverluste kumuliert \(stats.rtpCumPacketLoss), verspätet \(stats.latePacketsCumulativeNumber)."
        let shouldReport = force || previous.lastFormat != format || now - previous.lastReportAt >= 15
        previous.lastFormat = format
        previous.lastSummary = summary
        if shouldReport { previous.lastReportAt = now }
        audioTraces[id] = previous
        if shouldReport {
            // The app-generated call ID correlates simultaneous calls without names or SIP identities.
            onEvent?(.callTrace("Audio [\(id.uuidString.prefix(8))]: \(summary)"))
        }
    }
    private func recordCallMilestone(_ milestone: CallMilestone, id: UUID,
                                     observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard var timing = callTimings[id], timing.milestones.insert(milestone).inserted else { return }
        callTimings[id] = timing
        let elapsedMs = Int(max(0, observedAt - timing.startedAt) * 1_000)
        let limitation = milestone == .firstReceivedRTP
            ? " Auflösung durch Statistik-Callbacks begrenzt; keine Messung des ersten hörbaren Sprachsignals." : ""
        onEvent?(.callTrace("Rufaufbau [\(id.uuidString.prefix(8))]: \(milestone.rawValue) nach \(elapsedMs) ms ab erstem lokalen Anrufereignis.\(limitation)"))
    }
    private func finishAudioTrace(id: UUID) {
        callTimings.removeValue(forKey: id)
        guard let last = audioTraces.removeValue(forKey: id), !last.lastSummary.isEmpty else { return }
        onEvent?(.callTrace("Audio-Abschluss [\(id.uuidString.prefix(8))], letzter Messstand: \(last.lastSummary)"))
    }
    private func handle(_ call: Call, state: Call.State) {
        let observedAt = ProcessInfo.processInfo.systemUptime
        guard let pointer = call.getCobject else { return }
        onEvent?(.callTrace("SDK-Anrufzustand: \(state)"))
        if state == .Released {
            if let id = ids.removeValue(forKey: pointer) {
                finishAudioTrace(id: id)
                calls.removeValue(forKey: id)
            }
            return
        }
        if ids[pointer] == nil {
            guard state == .IncomingReceived || state == .IncomingEarlyMedia || state == .OutgoingInit else { return }
            let id = outgoingID ?? UUID()
            ids[pointer] = id
            calls[id] = call
            callTimings[id] = CallTimingState(startedAt: observedAt)
        }
        guard let id = ids[pointer] else { return }
        if state == .Connected { recordCallMilestone(.connected, id: id, observedAt: observedAt) }
        if state == .StreamsRunning { recordCallMilestone(.streamsRunning, id: id, observedAt: observedAt) }
        let mapped: SIPCallState
        switch state {
        case .IncomingReceived, .IncomingEarlyMedia: mapped = .incoming
        case .OutgoingInit, .OutgoingProgress, .OutgoingEarlyMedia: mapped = .connecting
        case .OutgoingRinging: mapped = .ringing
        case .Connected, .StreamsRunning: mapped = .active
        case .Pausing: mapped = .holding
        case .Paused: mapped = .held
        case .Resuming: mapped = .resuming
        case .PausedByRemote: mapped = .remoteHeld
        case .End: mapped = .ended
        case .Error: mapped = .failed(call.errorInfo?.protocolCode ?? 0)
        default: return
        }
        let event = SIPCallEvent(id: id, number: call.remoteAddress?.username ?? "Unbekannt",
            displayName: call.remoteAddress?.displayName ?? "", state: mapped, signalingID: fonooCallID(call))
        // Remove before notifying: the manager may start another call from an end event.
        if state == .End || state == .Error {
            finishAudioTrace(id: id)
            calls.removeValue(forKey: id)
            ids.removeValue(forKey: pointer)
        }
        onEvent?(.call(event))
        if state == .StreamsRunning {
            Self.configureSpeechQueue(call)
            if let stats = call.audioStats { recordAudioTrace(call, stats: stats, id: id, force: true) }
            refreshAudioDevices()
        }
    }
    private static func iceLabel(_ state: IceState) -> String {
        switch state {
        case .NotActivated: "Nicht aktiv / Gegenstelle ohne ICE"
        case .Failed: "Fehlgeschlagen"
        case .InProgress: "Verbindungsprüfung läuft"
        case .HostConnection: "Direkte Verbindung"
        case .ReflexiveConnection: "Direkt über NAT"
        case .RelayConnection: "Relay-Verbindung (TURN)"
        }
    }
    deinit { iterateTimer?.invalidate() }
}

#endif
