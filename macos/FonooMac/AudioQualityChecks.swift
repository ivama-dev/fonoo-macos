#if DEBUG && canImport(linphonesw)
import Foundation
import linphonesw
import linphone

/// Exercises the shipped media engine with generated WAV files, never the microphone.
/// Both SIP peers bind to loopback, use no accounts, and require SRTP. This does not
/// test acoustic echo cancellation or the public provider/mobile network.
@MainActor
enum AudioQualityChecks {
    struct Scenario {
        let name: String
        var loss: Float = 0
        var burst: Float = 0
        var latency: UInt32 = 0
        var bandwidth: Float = 0
        var jitter: Float = 0
        var codec = "opus"
        var isOverloaded: Bool { name == "overloaded-link" }
        var testsRecovery: Bool { name == "constrained-link" || isOverloaded }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PhoneError.message(message) }
    }
    static func run() throws {
        let arguments = ProcessInfo.processInfo.arguments
        let requestedPath = arguments.firstIndex(of: "--audio-report").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        let root = requestedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("fonoo-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if requestedPath == nil { try? FileManager.default.removeItem(at: root) } }
        bctbx_set_log_handler { _, _, _, _ in }
        Core.enableLogCollection(state: .Disabled)
        LoggingService.Instance.logLevel = .Fatal
        let inputA = root.appendingPathComponent("generated-700Hz.wav")
        let inputB = root.appendingPathComponent("generated-6000Hz.wav")
        try writeTone(inputA, frequency: 700)
        try writeTone(inputB, frequency: 6000)
        var scenarios = [Scenario(name: "clean"), Scenario(name: "loss-1-percent", loss: 1),
            Scenario(name: "loss-3-percent", loss: 3), Scenario(name: "loss-5-percent", loss: 5),
            Scenario(name: "burst-loss", loss: 3, burst: 0.65),
            Scenario(name: "jitter", latency: 35, bandwidth: 96_000, jitter: 0.7),
            Scenario(name: "constrained-link", loss: 1, latency: 40, bandwidth: 64_000),
            Scenario(name: "overloaded-link", loss: 1, latency: 40, bandwidth: 42_000),
            Scenario(name: "g711-fallback", codec: "PCMA")]
        if let index = arguments.firstIndex(of: "--audio-case"), index + 1 < arguments.count {
            scenarios = scenarios.filter { $0.name == arguments[index + 1] }
            try require(!scenarios.isEmpty, "Unknown synthetic audio case")
        } else {
            scenarios.removeAll { $0.isOverloaded }
        }
        var results: [[String: Any]] = []
        for scenario in scenarios {
            let result = try exercise(scenario, root: root, inputs: [inputA, inputB])
            results.append(result)
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
        let report: [String: Any] = ["status": "pass", "scope": "native-sdk-loopback-generated-audio-srtp",
            "limits": "No microphone, acoustic echo or real provider/mobile path tested. Random loss simulation; measured loss reported separately.",
            "scenarios": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"), options: .atomic)
        print("PASS: native SDK encrypted audio under loss, bursts, jitter and constrained bandwidth")
    }
    static func makePeer(_ codec: String, input: URL, output: URL) throws -> Core {
        let config = try Factory.Instance.createConfigFromString(data: """
        [sip]
        store_auth_info=0
        bind_address=127.0.0.1
        ipv6_enabled=0
        [storage]
        uri=null
        call_logs_db_uri=null
        [rtp]
        bind_address=127.0.0.1
        [net]
        use_nat=0
        """)
        let peer = try Factory.Instance.createCoreWithConfig(config: config, systemContext: nil)
        var ready = false
        defer { if !ready { peer.stop() } }
        peer.autoIterateEnabled = false
        peer.videoCaptureEnabled = false
        peer.videoDisplayEnabled = false
        peer.ipv6Enabled = false
        peer.useFiles = true
        peer.playFile = input.path
        peer.recordFile = output.path
        peer.ring = nil
        peer.ringback = nil
        try peer.setPrimarycontact(newValue: "sip:synthetic@127.0.0.1")
        try peer.setMediaencryption(newValue: .SRTP)
        peer.mediaEncryptionMandatory = true
        peer.audioPort = -1
        LinphoneSIPCore.configureSpeechAudio(peer)
        for payload in peer.audioPayloadTypes { _ = payload.enable(enabled: payload.mimeType.lowercased() == codec.lowercased()) }
        let transports = try Factory.Instance.createTransports()
        transports.udpPort = -1
        transports.tcpPort = 0
        transports.tlsPort = 0
        transports.dtlsPort = 0
        try peer.setTransports(newValue: transports)
        try peer.start()
        peer.networkReachable = true
        try require(peer.audioAdaptiveJittcompEnabled && peer.audioJittcomp == 60 && peer.adaptiveRateControlEnabled,
                    "Speech policy was not retained by SDK startup")
        try require(peer.config?.getInt(section: "rtp", key: "jitter_buffer_max_size", defaultValue: 500) == 200,
                    "Audio delay limit missing")
        try require(!peer.agcEnabled && !peer.echoLimiterEnabled && !peer.noiseSuppressionEnabled && peer.echoCancellationEnabled,
                    "Unexpected software processing policy")
        if codec == "opus" {
            let fmtp = peer.audioPayloadTypes.first { $0.mimeType.lowercased() == "opus" }?.recvFmtp ?? ""
            try require(fmtp.contains("useinbandfec=1") && fmtp.contains("maxaveragebitrate=40000"), "Opus policy missing")
        }
        ready = true
        return peer
    }
    static func pump(_ peers: [Core], seconds: TimeInterval, until predicate: (() -> Bool)? = nil) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            peers.forEach { $0.iterate() }
            if predicate?() == true { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < end
        return predicate?() ?? true
    }
    static func exercise(_ scenario: Scenario, root: URL, inputs: [URL]) throws -> [String: Any] {
        // G.711 cannot carry 6 kHz: use another generated low-band tone for that case.
        var inputs = inputs
        let frequencies = scenario.codec == "opus" && !scenario.isOverloaded ? [700.0, 6000.0] : [700.0, 1100.0]
        if frequencies[1] == 1100 {
            let lowBand = root.appendingPathComponent("generated-1100Hz.wav")
            try writeTone(lowBand, frequency: 1100)
            inputs[1] = lowBand
        }
        let outputs = (0..<2).map { root.appendingPathComponent(scenario.name + "-received-\($0).wav") }
        for output in outputs {
            // SDK 5.5.23's MSFileRec does not reserve a WAV header in a new file.
            // Seed one silent PCM sample so it appends past a valid header instead
            // of overwriting the first 44 audio bytes on close. Startup is trimmed.
            try writeTone(output, frequency: 0, sampleCount: 1)
        }
        var peers: [Core] = []
        defer { peers.forEach { $0.stop() } }
        for index in 0..<2 { peers.append(try makePeer(scenario.codec, input: inputs[index], output: outputs[index])) }
        for peer in peers {
            var simulation = OrtpNetworkSimulatorParams()
            simulation.enabled = scenario.name == "clean" || scenario.codec != "opus" ? 0 : 1
            simulation.loss_rate = scenario.loss
            simulation.consecutive_loss_probability = scenario.burst
            simulation.latency = scenario.latency
            simulation.max_bandwidth = scenario.bandwidth
            simulation.max_buffer_size = 24_000
            simulation.jitter_burst_density = scenario.jitter
            // oRTP 5.5.23 uses a 0...1 fraction here, despite its header calling
            // it a percentage. 85 would consume up to 85 times the link budget.
            simulation.jitter_strength = scenario.jitter > 0 ? 0.85 : 0
            simulation.rtp_only = 1
            simulation.mode = OrtpNetworkSimulatorInbound
            try require(linphone_core_set_network_simulator_params(peer.getCobject, &simulation) == 0, "Network simulation rejected")
        }
        var incoming: Call?
        var callbackError: Error?
        let delegate = CoreDelegateStub(onCallStateChanged: { core, call, state, _ in
            if state == .StreamsRunning { LinphoneSIPCore.configureSpeechQueue(call) }
            if state == .IncomingReceived {
                incoming = call
                do {
                    let params = try core.createCallParams(call: call)
                    params.mediaEncryption = .SRTP
                    params.videoEnabled = false
                    try call.acceptWithParams(params: params)
                } catch { callbackError = error }
            }
        })
        peers.forEach { $0.addDelegate(delegate: delegate) }
        defer { peers.forEach { $0.removeDelegate(delegate: delegate) } }
        guard let port = peers[1].transportsUsed?.udpPort, port > 0 else { throw PhoneError.message("Loopback SIP transport unavailable") }
        let address = try Factory.Instance.createAddress(addr: "sip:synthetic@127.0.0.1:\(port);transport=udp")
        let params = try peers[0].createCallParams(call: nil)
        params.videoEnabled = false
        params.mediaEncryption = .SRTP
        let started = ProcessInfo.processInfo.systemUptime
        guard let outgoing = peers[0].inviteAddressWithParams(addr: address, params: params) else { throw PhoneError.message("Synthetic call could not start") }
        let connected = pump(peers, seconds: 8) { outgoing.state == .StreamsRunning && incoming?.state == .StreamsRunning }
        if let callbackError { throw callbackError }
        try require(connected, "Synthetic call did not establish: \(outgoing.state)")
        let connectedMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        _ = pump(peers, seconds: 9)
        guard let incoming else { throw PhoneError.message("Synthetic peer missing") }
        let calls = [outgoing, incoming]
        var congestionStart: [[String: Any]] = []
        var recovery: [[String: Any]] = []
        if scenario.testsRecovery {
            congestionStart = calls.compactMap { call in
                call.audioStats.map { ["jitter_buffer_ms": $0.jitterBufferSizeMs,
                    "upload_kbit_per_second": $0.uploadBandwidth, "round_trip_ms": $0.roundTripDelay * 1_000] }
            }
            // Allow RTCP-driven rate control time to react, then restore the link
            // without replacing the call or media engine.
            _ = pump(peers, seconds: 21)
        }
        var directions: [[String: Any]] = []
        for call in calls {
            try require(call.state == .StreamsRunning, "Media ended during impairment")
            try require(call.currentParams?.mediaEncryption == .SRTP, "Audio encryption missing")
            try require(call.currentParams?.usedAudioPayloadType?.mimeType.lowercased() == scenario.codec.lowercased(), "Wrong codec negotiated")
            guard let stats = call.audioStats else { throw PhoneError.message("Audio statistics missing") }
            try require(stats.rtpPacketRecv > 100 && stats.rtpPacketSent > 100,
                        "Bidirectional RTP missing in \(scenario.name): \(stats.rtpPacketRecv)/\(stats.rtpPacketSent)")
            guard let transport = linphone_call_get_meta_rtp_transport(call.getCobject, 0),
                  let session = transport.pointee.session else { throw PhoneError.message("Synthetic RTP session missing") }
            var jitterParameters = JBParameters()
            rtp_session_get_jitter_buffer_params(session, &jitterParameters)
            try require(jitterParameters.adaptive != 0 && jitterParameters.max_size == 200 && jitterParameters.max_packets == 12,
                        "Audio buffer limit was not applied to the live RTP session")
            let levels = LinphoneSIPCore.measuredAudioLevels(call, microphoneEnabled: true)
            var waveformCheck: [String: Any] = [:]
            if scenario.name == "clean" {
                try require(levels.microphone.map { MacMicrophoneMeter.normalizedLevel($0) > 0.1 } == true
                            && levels.playback.map { MacMicrophoneMeter.normalizedLevel($0) > 0.1 } == true,
                            "Call activity did not receive measured send/playback levels")
                let muted = LinphoneSIPCore.measuredAudioLevels(call, microphoneEnabled: false)
                try require(muted.microphone == nil && muted.playback == levels.playback,
                            "Muting must leave receive-level display available")
                waveformCheck = try checkSpeechWaveform(call, peers: peers)
            }
            directions.append(["codec": scenario.codec, "received_packets": stats.rtpPacketRecv,
                "sent_packets": stats.rtpPacketSent, "observed_receive_loss_percent": stats.localLossRate,
                "cumulative_lost_packets": stats.rtpCumPacketLoss,
                "late_packets": stats.latePacketsCumulativeNumber, "jitter_buffer_ms": stats.jitterBufferSizeMs,
                "adaptive_buffer_limit_ms": jitterParameters.max_size,
                "queue_packet_limit": jitterParameters.max_packets,
                "observed_upload_kbit_per_second": stats.uploadBandwidth,
                "observed_download_kbit_per_second": stats.downloadBandwidth,
                "round_trip_ms": stats.roundTripDelay * 1_000,
                "microphone_level_db": levels.microphone ?? -120,
                "playback_level_db": levels.playback ?? -120,
                "speech_waveform": waveformCheck])
        }
        if scenario.testsRecovery {
            let receivedBefore = calls.map { $0.audioStats?.rtpPacketRecv ?? 0 }
            for call in calls {
                var restored = OrtpNetworkSimulatorParams()
                // The Core setter only affects future calls in SDK 5.5.23.
                // Disable the simulator on each existing RTP session instead.
                guard let transport = linphone_call_get_meta_rtp_transport(call.getCobject, 0),
                      let session = transport.pointee.session else {
                    throw PhoneError.message("Synthetic RTP session missing")
                }
                rtp_session_enable_network_simulation(session, &restored)
            }
            // RTCP reports have a randomized interval: wait for fresh feedback,
            // rather than interpreting the last congested RTT as a new sample.
            _ = pump(peers, seconds: 18) {
                calls.enumerated().allSatisfy { index, call in
                    guard let stats = call.audioStats else { return false }
                    return stats.rtpPacketRecv > receivedBefore[index] + 100 &&
                        stats.roundTripDelay > 0 && stats.roundTripDelay * 1_000 < 50 && stats.jitterBufferSizeMs <= 250
                }
            }
            for (index, call) in calls.enumerated() {
                guard let stats = call.audioStats else { throw PhoneError.message("Recovery statistics missing") }
                try require(call.state == .StreamsRunning && stats.rtpPacketRecv > receivedBefore[index] + 100,
                            "Audio did not resume after congestion")
                try require(stats.roundTripDelay > 0 && stats.roundTripDelay * 1_000 < 50 && stats.jitterBufferSizeMs <= 250,
                            "Media delay did not recover after congestion: RTT \(stats.roundTripDelay * 1_000) ms, buffer \(stats.jitterBufferSizeMs) ms")
                recovery.append(["additional_received_packets": stats.rtpPacketRecv - receivedBefore[index],
                    "round_trip_ms": stats.roundTripDelay * 1_000, "jitter_buffer_ms": stats.jitterBufferSizeMs])
            }
        }
        try outgoing.terminate()
        try require(pump(peers, seconds: 4) { peers.allSatisfy { $0.callsNb == 0 } }, "Synthetic hangup did not complete")
        for index in 0..<2 {
            let measurements = try measure(outputs[index], frequency: frequencies[1 - index],
                                           maximumSeconds: scenario.testsRecovery ? 30 : nil,
                                           enforceContinuity: !scenario.isOverloaded)
            directions[index].merge(measurements) { _, new in new }
        }
        return ["case": scenario.name, "status": "pass", "connect_ms": connectedMs,
                "quality_scope": scenario.isOverloaded ? "overload-survival-and-recovery; audible degradation permitted and measured" : "continuity-and-spectral-release-check",
                "configured_loss_percent": scenario.loss, "configured_burst_probability": scenario.burst,
                "configured_latency_ms": scenario.latency, "configured_bandwidth_bits_per_second": scenario.bandwidth,
                "congestion_at_9_seconds": congestionStart, "recovery": recovery, "directions": directions]
    }
    static func checkSpeechWaveform(_ call: Call, peers: [Core]) throws -> [String: Any] {
        var envelope = MacSpeechEnvelope()
        var lastSample: TimeInterval = 0
        var frames = 0
        var shapes: Set<[Int]> = []
        var low = 1.0, high = 0.0
        _ = pump(peers, seconds: 2) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSample >= MacSpeechEnvelope.sampleInterval else { return false }
            lastSample = now
            // Receive-only: proves the display still follows decoded RTP audio
            // with a muted microphone, without another audio capture session.
            envelope.sample(LinphoneSIPCore.measuredAudioLevels(call, microphoneEnabled: false), at: now)
            frames += 1
            low = min(low, envelope.level); high = max(high, envelope.level)
            shapes.insert(envelope.bars.map { Int(($0 * 1_000).rounded()) })
            return false
        }
        try require(frames >= 20 && shapes.count >= 3 && high > 0 && high <= 1 && high > low,
                    "Speech waveform did not follow measured receive audio: \(frames) frames, \(shapes.count) shapes, \(low)...\(high)")
        return ["frames": frames, "distinct_shapes": shapes.count, "minimum_level": low,
                "maximum_level": high, "source": "measured-receive-audio-microphone-muted"]
    }
    static func writeTone(_ url: URL, frequency: Double, sampleCount: Int = 48_000 * 55) throws {
        let rate = 48_000
        let samples = sampleCount
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16); text("data"); u32(UInt32(samples * 2))
        for index in 0..<samples {
            let time = Double(index) / Double(rate)
            let amplitude = 7_000.0 * (0.75 + 0.25 * sin(2 * .pi * 3 * time))
            let sample = Int16((amplitude * sin(2 * .pi * frequency * time)).rounded())
            u16(UInt16(bitPattern: sample))
        }
        try data.write(to: url)
    }
    static func measure(_ url: URL, frequency: Double, maximumSeconds: Int? = nil,
                        enforceContinuity: Bool = true) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        func u16(_ index: Int) -> Int { Int(data[index]) | Int(data[index + 1]) << 8 }
        func u32(_ index: Int) -> Int { u16(index) | u16(index + 2) << 16 }
        try require(data.count >= 44 && String(decoding: data.prefix(4), as: UTF8.self) == "RIFF", "Decoded WAV missing")
        var position = 12, rate = 0, channels = 0, audio: Swift.Range<Int>?
        while position + 8 <= data.count {
            let size = u32(position + 4), start = position + 8
            try require(size <= data.count - start, "Truncated decoded WAV")
            let tag = String(decoding: data[position..<position + 4], as: UTF8.self)
            if tag == "fmt " {
                try require(size >= 16 && u16(start) == 1 && u16(start + 14) == 16, "Expected linear PCM16")
                channels = u16(start + 2); rate = u32(start + 4)
            } else if tag == "data" { audio = start..<start + size }
            position = start + size + size % 2
        }
        guard let audio, rate >= 8_000, channels > 0 && channels <= 2 else { throw PhoneError.message("Invalid decoded PCM format") }
        var samples: [Double] = []
        for position in stride(from: audio.lowerBound, to: audio.upperBound - channels * 2 + 1, by: channels * 2) {
            samples.append(Double(Int16(bitPattern: UInt16(u16(position)))))
        }
        try require(samples.count >= rate * 6, "Decoded audio too short")
        if let maximumSeconds { samples = Array(samples.prefix(rate * maximumSeconds)) }
        // Ignore call-start and writer-stop transients; check the sustained stream.
        samples = Array(samples.dropFirst(rate).dropLast(rate / 2))
        let power = samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)
        let rms = sqrt(power)
        let window = rate / 50
        var quietRun = 0, longestQuietRun = 0, quietWindows = 0, totalWindows = 0
        for start in stride(from: 0, through: samples.count - window, by: window) {
            let energy = samples[start..<start + window].reduce(0) { $0 + $1 * $1 } / Double(window)
            if energy < 300 * 300 { quietRun += 1; quietWindows += 1 } else { quietRun = 0 }
            longestQuietRun = max(longestQuietRun, quietRun); totalWindows += 1
        }
        let quietFraction = Double(quietWindows) / Double(max(totalWindows, 1))
        let continuous = quietFraction < 0.12 && longestQuietRun * 20 <= 300
        try require(rms > 900 && (!enforceContinuity || continuous),
                    "Decoded stream has excessive silence/dropouts in \(url.lastPathComponent): RMS \(Int(rms)), quiet \(quietFraction), longest \(longestQuietRun * 20) ms")
        // Windowed spectral measurement tolerates timing corrections by the jitter
        // buffer; a whole-file phase correlation would incorrectly penalize them.
        let spectralWindow = rate / 5
        var energyFractions: [Double] = []
        for start in stride(from: 0, through: samples.count - spectralWindow, by: spectralWindow) {
            var real = 0.0, imaginary = 0.0, energy = 0.0
            for index in 0..<spectralWindow {
                let value = samples[start + index]
                let angle = 2 * Double.pi * frequency * Double(index) / Double(rate)
                real += value * cos(angle); imaginary += value * sin(angle); energy += value * value
            }
            energyFractions.append(2 * (real * real + imaginary * imaginary) / (Double(spectralWindow) * max(energy, 1)))
        }
        let toneFraction = energyFractions.reduce(0, +) / Double(max(energyFractions.count, 1))
        try require(toneFraction > 0.25, "Expected audio frequency did not survive media path")
        return ["decoded_seconds": Double(samples.count) / Double(rate), "rms": Int(rms),
                "continuity_quality": continuous ? "pass" : "degraded",
                "expected_hz": frequency, "tone_energy_fraction": toneFraction,
                "quiet_fraction": quietFraction, "longest_quiet_interval_ms": longestQuietRun * 20]
    }
}
#endif
