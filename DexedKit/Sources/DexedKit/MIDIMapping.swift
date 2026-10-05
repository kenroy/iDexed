import Foundation

/// Something a MIDI controller can drive: any numeric voice parameter, or one of the global controls.
public enum MappableControl: Hashable, Codable, Sendable {
    case voice(Int)              // byte offset in the unpacked voice (0…144; the name is not mappable)
    case cutoff, resonance, masterTune, volume

    /// Highest raw value, or nil for a continuous 0…1 control.
    public var maxValue: Int? {
        if case .voice(let offset) = self { return Parameters.maxValue(offset: offset) }
        return nil
    }

    public var title: String {
        switch self {
        case .cutoff: "Cutoff"
        case .resonance: "Resonance"
        case .masterTune: "Tune"
        case .volume: "Volume"
        case .voice(let offset): Parameters.name(offset: offset)
        }
    }

    /// Scales a 7-bit controller value onto this control: a raw integer for voice parameters, 0…1 for the globals.
    public func scaled(_ cc: Int) -> Double {
        let unit = Double(max(0, min(127, cc))) / 127
        if let max = maxValue { return (unit * Double(max)).rounded() }
        return unit
    }
}

/// CC numbers the engine already uses for performance control, so they can't be mapped (same as Dexed).
public enum ReservedCC {
    public static let all: Set<Int> = [1, 2, 4, 5, 64, 65, 120, 123]
    public static func isReserved(_ cc: Int) -> Bool { all.contains(cc) || cc > 119 }
}

/// A controller number on a channel.
public struct MIDIControllerKey: Hashable, Codable, Sendable {
    public var channel: Int      // 1…16
    public var cc: Int           // 0…127
    public init(channel: Int, cc: Int) { self.channel = channel; self.cc = cc }
    public var description: String { "CC \(cc) · ch \(channel)" }
}

/// The saved table of controller → control assignments.
public struct MIDIMapping: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var key: MIDIControllerKey
        public var control: MappableControl
    }

    public private(set) var entries: [Entry] = []
    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func control(for key: MIDIControllerKey) -> MappableControl? { entries.first { $0.key == key }?.control }
    public func key(for control: MappableControl) -> MIDIControllerKey? { entries.first { $0.control == control }?.key }

    /// Assigns a controller to a control. A control has one controller and a controller drives one control,
    /// so any earlier assignment of either is replaced.
    public mutating func assign(_ control: MappableControl, to key: MIDIControllerKey) {
        entries.removeAll { $0.control == control || $0.key == key }
        entries.append(Entry(key: key, control: control))
    }

    public mutating func remove(_ control: MappableControl) { entries.removeAll { $0.control == control } }
    public mutating func removeAll() { entries.removeAll() }
}

extension Parameters {
    /// Highest value of the voice parameter stored at `offset` (0…144), or nil if it isn't a numeric parameter.
    public static func maxValue(offset: Int) -> Int? {
        switch offset {
        case 0..<126:
            guard let field = OperatorField(rawValue: offset % Patch.opStride) else { return nil }
            return operatorInfo(field, op: 0).max
        case 126..<134: return 99
        case 134: return algorithm.max
        case 135: return feedback.max
        case 136: return oscSync.max
        case 137...140: return 99
        case 141: return lfoSync.max
        case 142: return lfoWave.max
        case 143: return pitchModSens.max
        case 144: return transpose.max
        default: return nil
        }
    }

    /// A readable name for the voice parameter at `offset`, e.g. "OP3 Level".
    public static func name(offset: Int) -> String {
        switch offset {
        case 0..<126:
            let op = 6 - offset / Patch.opStride
            let field = OperatorField(rawValue: offset % Patch.opStride)
            return "OP\(op) \(field.map { operatorInfo($0, op: 0).name } ?? "?")"
        case 126..<130: return "Pitch EG Rate \(offset - 125)"
        case 130..<134: return "Pitch EG Level \(offset - 129)"
        case 134: return algorithm.name
        case 135: return feedback.name
        case 136: return oscSync.name
        case 137: return lfoSpeed.name
        case 138: return lfoDelay.name
        case 139: return lfoPitchDepth.name
        case 140: return lfoAmpDepth.name
        case 141: return lfoSync.name
        case 142: return lfoWave.name
        case 143: return pitchModSens.name
        case 144: return transpose.name
        default: return "Parameter \(offset)"
        }
    }
}
