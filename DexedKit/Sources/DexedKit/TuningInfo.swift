import Foundation

/// A readable description of the loaded tuning, built from the Scala (`.scl`) and keyboard-mapping (`.kbm`) text, for the
/// tuning viewer. Standard tuning is described too.
public struct TuningInfo: Equatable, Sendable {
    /// One degree of the scale: the text as written in the file, and its size in cents above the first note.
    public struct Degree: Equatable, Sendable {
        public var index: Int
        public var text: String
        public var cents: Double
    }

    /// The `.kbm` settings, which say which keys play which scale degrees and what the reference pitch is.
    public struct KeyboardMapping: Equatable, Sendable {
        public var size = 0
        public var firstNote = 0, lastNote = 127
        public var middleNote = 60
        public var referenceNote = 69
        public var referenceFrequency = 440.0
        public var formalOctaveDegree = 0
        /// One entry per key of the repeating pattern: a scale degree, or "x" for an unmapped key.
        public var pattern: [String] = []
    }

    public var name: String
    public var description: String
    /// The scale degrees 1…N; the last one is the period (usually the octave).
    public var degrees: [Degree]
    public var mapping: KeyboardMapping?
    public var isStandard: Bool

    public var noteCount: Int { degrees.count }
    public var periodCents: Double { degrees.last?.cents ?? 1200 }

    /// 12-tone equal temperament, which is what iDexed uses when no scale is loaded.
    public static let standard = TuningInfo(
        name: "Standard Tuning (12-TET)", description: "12 equal divisions of the octave, A4 = 440 Hz (master tune aside)",
        degrees: (1...12).map { Degree(index: $0, text: String(format: "%.3f", Double($0) * 100), cents: Double($0) * 100) },
        mapping: nil, isStandard: true)

    /// Builds the description from the text of the loaded files. With no scale, that is the standard tuning.
    public static func parse(scl: String?, kbm: String?, name: String?) -> TuningInfo {
        guard let scl else { return .standard }
        let lines = scl.components(separatedBy: .newlines)
        var body = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("!") }
        // The description is the first line (it may be blank); the next is the number of notes.
        let description = body.isEmpty ? "" : body.removeFirst().trimmingCharacters(in: .whitespaces)
        body = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let declared = body.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") } ?? 0
        let degrees = body.dropFirst().prefix(max(0, declared)).enumerated().compactMap { i, raw -> Degree? in
            let text = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            guard let cents = centsValue(of: text) else { return nil }
            return Degree(index: i + 1, text: text, cents: cents)
        }
        return TuningInfo(name: name ?? "Custom", description: description, degrees: degrees, mapping: kbm.map(parseMapping), isStandard: false)
    }

    /// Cents for a Scala pitch: a number with a decimal point is cents, anything else is a ratio (`3/2`, or `2` meaning 2/1).
    static func centsValue(of text: String) -> Double? {
        if text.contains(".") { return Double(text) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard let numerator = parts.first.flatMap({ Double($0) }), numerator > 0 else { return nil }
        let denominator = parts.count > 1 ? Double(parts[1]) ?? 0 : 1
        guard denominator > 0 else { return nil }
        return 1200 * log2(numerator / denominator)
    }

    static func parseMapping(_ kbm: String) -> KeyboardMapping {
        let values = kbm.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
            .map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        var m = KeyboardMapping()
        func int(_ i: Int, _ fallback: Int) -> Int { i < values.count ? Int(values[i]) ?? fallback : fallback }
        m.size = int(0, 0)
        m.firstNote = int(1, 0); m.lastNote = int(2, 127)
        m.middleNote = int(3, 60); m.referenceNote = int(4, 69)
        m.referenceFrequency = values.count > 5 ? Double(values[5]) ?? 440 : 440
        m.formalOctaveDegree = int(6, 0)
        m.pattern = Array(values.dropFirst(7).prefix(max(0, m.size)))
        return m
    }

    private static func ratioText(forCents c: Double) -> String { String(format: "%.4g", pow(2, c / 1200)) }

    /// A plain-text report, for display and copying.
    public var text: String {
        var out = [name]
        if !description.isEmpty, description != name { out.append(description) }
        out.append("")
        out.append("Notes per period: \(noteCount)")
        out.append(String(format: "Period: %.3f cents (ratio %@)", periodCents, TuningInfo.ratioText(forCents: periodCents)))
        out.append("")
        out.append("Degree   Cents       As written")
        out.append(String(format: "%5d   %9.3f   (the first note)", 0, 0.0))
        for d in degrees { out.append(String(format: "%5d   %9.3f   %@", d.index, d.cents, d.text)) }
        if let m = mapping {
            out.append("")
            out.append("Keyboard mapping")
            out.append("  Keys \(m.firstNote) to \(m.lastNote); scale degree 0 on key \(m.middleNote)")
            out.append(String(format: "  Reference: key %d is %.4f Hz", m.referenceNote, m.referenceFrequency))
            out.append("  Pattern of \(m.size) key\(m.size == 1 ? "" : "s")" + (m.size == 0 ? " (the whole keyboard follows the scale in order)" : ": " + m.pattern.joined(separator: " ")))
            if m.size > 0 { out.append("  Formal octave is scale degree \(m.formalOctaveDegree)") }
        } else if !isStandard {
            out.append("")
            out.append("No keyboard mapping loaded: the scale starts on middle C and repeats every period.")
        }
        return out.joined(separator: "\n")
    }
}
