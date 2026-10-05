import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
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
    /// `.syx` files in the app's own Cartridges folder (Documents/Cartridges): drop files there, then Rescan.
    private(set) var cartridges: [Entry] = []
    private(set) var user: [Entry] = []
    private(set) var folderName: String?
    /// Files the last scan of the chosen folder skipped because they aren't `.syx`, by extension.
    private(set) var skippedInFolder: [String: Int] = [:]
    private(set) var selected: Entry?
    private(set) var preview: Cartridge?
    private(set) var previewError: String?

    private var scopedURL: URL?
    private static let bookmarkKey = "bankLibraryFolderBookmark"

    init() {
        restoreFolder()
        scanCartridges()
        restoreSelection()
    }

    // MARK: The app's own Cartridges folder

    /// Documents/Cartridges, created on demand. Visible in the Files app on iOS and iPadOS.
    static var cartridgesDirectory: URL? {
        guard let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = docs.appendingPathComponent("Cartridges", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func scanCartridges() {
        guard let dir = Self.cartridgesDirectory else { cartridges = []; return }
        cartridges = BankFolder.scan(dir).map { Entry(id: $0.url, name: $0.name, folder: $0.folder, isFactory: false) }
    }

    /// Copies `.syx` files, or whole folders of them, into the Cartridges folder, then rescans.
    func importBanks(_ urls: [URL]) async -> BankImportSummary {
        guard let dir = Self.cartridgesDirectory else { var s = BankImportSummary(); s.failed = urls.count; return s }
        let summary = await Task.detached { BankFolder.importBanks(from: urls, into: dir) }.value
        rescan()
        return summary
    }

    /// What to open to show the Cartridges folder: the folder itself in Finder (Mac), or the Files app (iOS and iPadOS).
    /// The caller opens it with the `openURL` environment action, which works inside the plug-in too.
    var cartridgesFolderURL: URL? {
        guard let dir = Self.cartridgesDirectory else { return nil }
        #if os(macOS)
        return dir
        #else
        return URL(string: "shareddocuments://" + dir.path)
        #endif
    }

    /// Reveals a bank file in Finder. Mac only: iOS has no way to reveal a single file.
    func reveal(_ entry: Entry) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([entry.id])
        #endif
    }

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
        if let selected, user.contains(selected) { self.selected = nil; preview = nil }
        user = []
        skippedInFolder = [:]
        folderName = nil
    }

    func rescan() {
        scanCartridges()
        guard let scopedURL else { return }
        scan(scopedURL)
    }

    private func scan(_ url: URL) {
        folderName = url.lastPathComponent
        user = BankFolder.scan(url).map { Entry(id: $0.url, name: $0.name, folder: $0.folder, isFactory: false) }
        skippedInFolder = user.isEmpty ? BankFolder.skippedFiles(url) : [:]
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

    /// A stable name for an entry that survives relaunching (the file URLs can move, for example after an app update).
    private static func key(for entry: Entry) -> String {
        (entry.isFactory ? "f:" : "u:") + (entry.folder.isEmpty ? "" : entry.folder + "/") + entry.name
    }

    /// Selects the entry that was open last time, once the lists have been scanned.
    private func restoreSelection() {
        guard let key = UserDefaults.standard.string(forKey: Self.selectionKey) else { return }
        let all = factory + cartridges + user
        if let match = all.first(where: { Self.key(for: $0) == key }) { select(match, remember: false) }
    }

    private static let selectionKey = "bankLibrarySelection"

    func select(_ entry: Entry?, remember: Bool = true) {
        selected = entry
        if remember {
            if let entry { UserDefaults.standard.set(Self.key(for: entry), forKey: Self.selectionKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.selectionKey) }
        }
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
