import SwiftUI
import UniformTypeIdentifiers
import DexedKit

/// A voice being dragged from the bank browser onto a slot of the current bank.
struct VoicePayload: Codable, Transferable {
    var bytes: [UInt8]
    init(_ patch: Patch) { bytes = patch.bytes }
    var patch: Patch { Patch(bytes: bytes) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// The bank browser's data: the bundled factory banks plus an optional folder of the user's own `.syx` files.
/// The folder is remembered with a security-scoped bookmark so it survives relaunching in the sandbox.
@MainActor
@Observable
final class BankLibrary {
    struct Entry: Identifiable, Hashable {
        let id: URL
        let name: String
        let folder: String
        let isFactory: Bool
    }

    private(set) var factory: [Entry] = FactoryBanks.all.map { Entry(id: $0.url, name: $0.name, folder: "", isFactory: true) }
    private(set) var user: [Entry] = []
    private(set) var folderName: String?
    private(set) var selected: Entry?
    private(set) var preview: Cartridge?
    private(set) var previewError: String?

    private var scopedURL: URL?
    private static let bookmarkKey = "bankLibraryFolderBookmark"

    init() { restoreFolder() }

    // MARK: Choosing a folder

    func chooseFolder(_ url: URL) {
        releaseFolder()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        saveBookmark(for: url)
        scan(url)
    }

    func forgetFolder() {
        releaseFolder()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        user = []
        folderName = nil
        if let selected, !selected.isFactory { self.selected = nil; preview = nil }
    }

    func rescan() {
        guard let scopedURL else { return }
        scan(scopedURL)
    }

    private func scan(_ url: URL) {
        folderName = url.lastPathComponent
        user = BankFolder.scan(url).map { Entry(id: $0.url, name: $0.name, folder: $0.folder, isFactory: false) }
    }

    private func releaseFolder() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func saveBookmark(for url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        if stale { saveBookmark(for: url) }
        scan(url)
    }

    // MARK: Previewing

    func select(_ entry: Entry?) {
        selected = entry
        guard let entry else { preview = nil; previewError = nil; return }
        do {
            preview = try BankFolder.load(entry.id)
            previewError = nil
        } catch {
            preview = nil
            previewError = "Couldn't read “\(entry.name)”: \(error.localizedDescription)"
        }
    }
}
