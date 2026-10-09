import AppKit

/// Short local dial-key feedback, independent of SIP and the call's audio engine.
@MainActor
final class MacDialpadFeedback {
    static let shared = MacDialpadFeedback()
    static let preferenceKey = "fonoo.macos.dialpadSounds"
    private var sounds: [String: NSSound] = [:]
    private var playing: NSSound?

    private init() {}

    @discardableResult
    func play(_ key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool != false,
              let frequencies = Self.frequencies[key] else { return false }
        if sounds[key] == nil {
            sounds[key] = NSSound(data: Self.aiff(frequencies))
            sounds[key]?.volume = 0.25
        }
        // Rapid/repeated clicks restart one short sound rather than accumulating voices.
        playing?.stop()
        playing = sounds[key]
        return playing?.play() ?? false
    }

    private static let frequencies: [String: (Double, Double)] = [
        "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
        "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
        "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
        "*": (941, 1209), "0": (941, 1336), "#": (941, 1477)
    ]

    private static func aiff(_ frequencies: (Double, Double)) -> Data {
        let rate = 44_100
        let frames = rate * 80 / 1_000
        let fadeFrames = rate * 5 / 1_000
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        // NSSound's in-memory initializer accepts uncompressed AIFF. The sample
        // rate is 44100 encoded as an IEEE 80-bit extended value (AIFF COMM).
        text("FORM"); word(UInt32(46 + frames * 2)); text("AIFFCOMM")
        word(UInt32(18)); word(UInt16(1)); word(UInt32(frames)); word(UInt16(16))
        data.append(contentsOf: [0x40, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 0])
        text("SSND"); word(UInt32(8 + frames * 2)); word(UInt32(0)); word(UInt32(0))
        for frame in 0..<frames {
            let time = Double(frame) / Double(rate)
            // Smooth attack/release avoids a sharp click at the waveform boundaries.
            let ramp = min(1, Double(min(frame, frames - 1 - frame)) / Double(fadeFrames))
            let envelope = 0.5 - 0.5 * cos(.pi * ramp)
            let sample = 0.3 * envelope * (sin(2 * .pi * frequencies.0 * time) + sin(2 * .pi * frequencies.1 * time))
            word(Int16(sample * Double(Int16.max)))
        }
        return data
    }
}
