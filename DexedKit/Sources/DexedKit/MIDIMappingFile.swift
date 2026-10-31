import Foundation

/// A MIDI mapping profile saved as a file, so it can be copied to another device or shared.
public struct MIDIMappingFile: Codable, Equatable, Sendable {
    public static let formatName = "iDexed MIDI mapping"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var name: String
    public var mapping: MIDIMapping

    public init(name: String, mapping: MIDIMapping) {
        format = Self.formatName; version = Self.currentVersion
        self.name = name; self.mapping = mapping
    }
}

public enum MIDIMappingFileError: LocalizedError, Equatable {
    case notAMappingFile, newerVersion, nothingUsable

    public var errorDescription: String? {
        switch self {
        case .notAMappingFile: "That isn't an iDexed MIDI mapping file."
        case .newerVersion: "That mapping file was made by a newer version of iDexed."
        case .nothingUsable: "That mapping file has no usable controller assignments."
        }
    }
}

extension MIDIMapping {
    /// A copy with only the assignments that make sense: a channel 1…16, a controller number that isn't reserved, and a control
    /// that exists. A file from outside can't put anything else into the app.
    public func sanitized() -> MIDIMapping {
        var clean = MIDIMapping()
        for entry in entries {
            guard (1...16).contains(entry.key.channel), (0...127).contains(entry.key.cc), !ReservedCC.isReserved(entry.key.cc) else { continue }
            if case .voice(let offset) = entry.control, Parameters.maxValue(offset: offset) == nil || !(0...144).contains(offset) { continue }
            clean.assign(entry.control, to: entry.key)
        }
        return clean
    }
}
