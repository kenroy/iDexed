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
