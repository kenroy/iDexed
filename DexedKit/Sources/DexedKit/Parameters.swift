import Foundation

/// Static description of one editable voice parameter.
public struct ParameterInfo: Identifiable, Sendable {
    public var id: Int { offset }
    public let offset: Int
    public let name: String
    public let max: Int
    public let labels: [String]?
    /// Subtracted from the stored value for display (e.g. transpose is stored 0…48 but shown −24…+24).
    public let displayOffset: Int

    init(_ offset: Int, _ name: String, max: Int, labels: [String]? = nil, displayOffset: Int = 0) {
        self.offset = offset; self.name = name; self.max = max; self.labels = labels; self.displayOffset = displayOffset
    }
}

public enum Parameters {
    public static let lfoWaves = ["Triangle", "Saw Down", "Saw Up", "Square", "Sine", "Sample & Hold"]
    public static let curves = ["-LIN", "-EXP", "+EXP", "+LIN"]

    public static func operatorInfo(_ field: OperatorField, op: Int) -> ParameterInfo {
        let off = Patch.offset(op: op, field)
        switch field {
        case .rate1: return .init(off, "Rate 1", max: 99)
        case .rate2: return .init(off, "Rate 2", max: 99)
        case .rate3: return .init(off, "Rate 3", max: 99)
        case .rate4: return .init(off, "Rate 4", max: 99)
        case .level1: return .init(off, "Level 1", max: 99)
        case .level2: return .init(off, "Level 2", max: 99)
        case .level3: return .init(off, "Level 3", max: 99)
        case .level4: return .init(off, "Level 4", max: 99)
        case .breakPoint: return .init(off, "Breakpoint", max: 99)
        case .leftDepth: return .init(off, "L Depth", max: 99)
        case .rightDepth: return .init(off, "R Depth", max: 99)
        case .leftCurve: return .init(off, "L Curve", max: 3, labels: curves)
        case .rightCurve: return .init(off, "R Curve", max: 3, labels: curves)
        case .rateScaling: return .init(off, "Rate Scaling", max: 7)
        case .ampModSens: return .init(off, "A Mod Sens", max: 3)
        case .keyVelSens: return .init(off, "Key Vel", max: 7)
        case .outputLevel: return .init(off, "Level", max: 99)
        case .oscMode: return .init(off, "Mode", max: 1, labels: ["Ratio", "Fixed"])
        case .freqCoarse: return .init(off, "Coarse", max: 31)
        case .freqFine: return .init(off, "Fine", max: 99)
        case .detune: return .init(off, "Tune", max: 14, displayOffset: 7)
        }
    }

    public static let algorithm = ParameterInfo(134, "Algorithm", max: 31)
    public static let feedback = ParameterInfo(135, "Feedback", max: 7)
    public static let oscSync = ParameterInfo(136, "OSC Key Sync", max: 1, labels: ["Off", "On"])
    public static let lfoSpeed = ParameterInfo(137, "Speed", max: 99)
    public static let lfoDelay = ParameterInfo(138, "Delay", max: 99)
    public static let lfoPitchDepth = ParameterInfo(139, "PMD", max: 99)
    public static let lfoAmpDepth = ParameterInfo(140, "AMD", max: 99)
    public static let lfoSync = ParameterInfo(141, "LFO Key Sync", max: 1, labels: ["Off", "On"])
    public static let lfoWave = ParameterInfo(142, "Wave", max: 5, labels: lfoWaves)
    public static let pitchModSens = ParameterInfo(143, "P Mod Sens", max: 7)
    public static let transpose = ParameterInfo(144, "Transpose", max: 48, displayOffset: 24)
    public static let pitchRates = (0..<4).map { ParameterInfo(126 + $0, "Pitch EG Rate \($0 + 1)", max: 99) }
    public static let pitchLevels = (0..<4).map { ParameterInfo(130 + $0, "Pitch EG Level \($0 + 1)", max: 99) }
}
