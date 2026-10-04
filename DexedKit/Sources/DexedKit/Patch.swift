import CDexedEngine
import Foundation

/// One DX7 voice in Dexed's *unpacked* 156-byte layout (the layout the msfa engine consumes).
///
/// Layout: 6 operators × 21 bytes (stored OP6 first, as on the DX7), then pitch EG (126–133),
/// algorithm (134), feedback (135), oscillator sync (136), LFO (137–142), pitch-mod sensitivity (143),
/// transpose (144) and the 10-character voice name (145–154).
public struct Patch: Equatable, Sendable {
    public static let size = Int(DEXED_PATCH_SIZE)
    public static let opStride = 21

    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        var b = bytes
        if b.count < Patch.size { b += [UInt8](repeating: 0, count: Patch.size - b.count) }
        self.bytes = Array(b.prefix(Patch.size))
    }

    /// The same "INIT VOICE" Dexed starts with.
    public static let initVoice: Patch = {
        var b = [UInt8](repeating: 0, count: size)
        for op in 0..<6 {
            let o = op * opStride
            b[o ..< o + 4] = [99, 99, 99, 99]  // rates
            b[o + 4 ..< o + 7] = [99, 99, 99]   // levels 1–3 (level 4 = 0)
            b[o + 17] = 0                          // ratio mode
            b[o + 18] = 1                          // coarse
            b[o + 20] = 7                          // detune centre
            b[o + 16] = op == 5 ? 99 : 0           // only OP1 audible
        }
        b[126 ..< 130] = [99, 99, 99, 99]
        b[130 ..< 134] = [50, 50, 50, 50]
        b[134] = 0
        b[137] = 35; b[138] = 0; b[139] = 0; b[140] = 0; b[141] = 1; b[142] = 0
        b[143] = 3; b[144] = 24
        var p = Patch(bytes: b)
        p.name = "INIT VOICE"
        return p
    }()

    public var name: String {
        get {
            let chars = bytes[145 ..< 155].map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : " " }
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
        set {
            let ascii = Array(newValue.uppercased().unicodeScalars.map { $0.value < 127 && $0.value >= 32 ? UInt8($0.value) : 32 }.prefix(10))
            for i in 0..<10 { bytes[145 + i] = i < ascii.count ? ascii[i] : 32 }
        }
    }

    public subscript(offset: Int) -> Int {
        get { Int(bytes[offset]) }
        set { bytes[offset] = UInt8(clamping: newValue) }
    }

    /// Parameter access by operator (0 = OP1 … 5 = OP6; OP1 is stored last).
    public static func offset(op: Int, _ field: OperatorField) -> Int {
        (5 - op) * opStride + field.rawValue
    }

    public subscript(op op: Int, field field: OperatorField) -> Int {
        get { self[Patch.offset(op: op, field)] }
        set { self[Patch.offset(op: op, field)] = newValue }
    }

    /// The operator frequency readout Dexed shows above each operator, e.g. `f = 2 +1` or `1.77828 Hz -1`.
    public func frequencyDescription(op: Int) -> String {
        let coarse = Double(self[op: op, field: .freqCoarse])
        let fine = Double(self[op: op, field: .freqFine])
        func g(_ v: Double) -> String { String(format: "%g", v) }   // up to 6 significant digits, like JUCE
        var text: String
        if self[op: op, field: .oscMode] == 0 {
            let ratio = coarse == 0 ? 0.5 : coarse
            text = "f = " + g(ratio + ratio * (fine / 100))
        } else {
            let base = pow(10, Double(Int(coarse) & 3))
            text = g(base * exp(M_LN10 * (fine / 100))) + " Hz"
        }
        let detune = self[op: op, field: .detune] - 7
        if detune > 0 { text += " +\(detune)" } else if detune < 0 { text += " \(detune)" }
        return text
    }

    public var algorithm: Int { get { self[134] } set { self[134] = newValue } }
    public var feedback: Int { get { self[135] } set { self[135] = newValue } }
}

public enum OperatorField: Int, CaseIterable, Sendable {
    case rate1 = 0, rate2, rate3, rate4
    case level1, level2, level3, level4
    case breakPoint, leftDepth, rightDepth, leftCurve, rightCurve
    case rateScaling, ampModSens, keyVelSens, outputLevel
    case oscMode, freqCoarse, freqFine, detune
}
