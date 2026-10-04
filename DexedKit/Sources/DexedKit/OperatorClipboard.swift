import Foundation

/// Dexed's operator clipboard format: the operator's 21 voice bytes as hex text, optionally followed by a comment line
/// (`\n; description`). Using the same format means operators can be copied between iDexed and Dexed.
public enum OperatorClipboard {
    public static let size = Patch.opStride          // 21 bytes
    public static let envelopeSize = 8               // rates 1–4 and levels 1–4 are the first 8 bytes

    public static func encode(_ bytes: [UInt8], description: String? = nil) -> String {
        var text = bytes.prefix(size).map { String(format: "%02x", $0) }.joined()
        if let description, !description.isEmpty { text += "\n; " + description }
        return text
    }

    /// Returns the 21 operator bytes, or nil if the text isn't operator data.
    public static func decode(_ text: String) -> [UInt8]? {
        let digits = Array(text.drop { $0.isWhitespace }.utf8.prefix(size * 2))
        guard digits.count == size * 2 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        return bytes
    }
}

extension Patch {
    /// The 21 bytes of one operator (0 = OP1 … 5 = OP6).
    public func operatorBytes(_ op: Int) -> [UInt8] {
        let start = Patch.offset(op: op, .rate1)
        return Array(bytes[start ..< start + Patch.opStride])
    }

    /// Replaces a whole operator, or just its envelope (first 8 bytes) when `envelopeOnly` is set.
    /// Values are clamped to each parameter's valid range so pasted junk can't crash the engine.
    public mutating func setOperatorBytes(_ op: Int, _ new: [UInt8], envelopeOnly: Bool = false) {
        let count = envelopeOnly ? OperatorClipboard.envelopeSize : Patch.opStride
        for (i, field) in OperatorField.allCases.enumerated() where i < count && i < new.count {
            let limit = Parameters.operatorInfo(field, op: op).max
            bytes[Patch.offset(op: op, field)] = UInt8(min(Int(new[i]), limit))
        }
    }
}
