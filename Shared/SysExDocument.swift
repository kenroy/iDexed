import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let sysex = UTType(filenameExtension: "syx", conformingTo: .data) ?? .data
}

struct SysExDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.sysex, .data]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension UTType {
    /// An iDexed MIDI mapping profile: JSON in a file with this extension.
    static let mappingProfile = UTType(filenameExtension: "idexedmap", conformingTo: .json) ?? .json
}

/// A MIDI mapping profile on its way to a file.
struct MappingProfileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.mappingProfile, .json, .data]
    var name: String
    var data: Data

    init(name: String, data: Data) { self.name = name; self.data = data }
    init(configuration: ReadConfiguration) throws { name = "Profile"; data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
