import Foundation

/// One `.syx` file found while browsing a folder of banks.
public struct BankFileInfo: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    /// The file name without its extension, with underscores shown as spaces.
    public var name: String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }
    /// Folder path relative to the folder being browsed, e.g. "Yamaha/DX7II" ("" for the top level).
    public let folder: String
}

/// Finds and opens DX7 bank files in a folder (for the bank browser).
public enum BankFolder {
    /// Recursively lists the `.syx` files under `root`, skipping hidden files, sorted by folder then name.
    /// Stops after `limit` files so a huge folder can't stall the app.
    public static func scan(_ root: URL, limit: Int = 5000) -> [BankFileInfo] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [BankFileInfo] = []
        let rootComponents = root.standardizedFileURL.pathComponents
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "syx",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            let folder = parts.count > rootComponents.count ? parts.dropFirst(rootComponents.count).joined(separator: "/") : ""
            found.append(BankFileInfo(url: url, folder: folder))
            if found.count >= limit { break }
        }
        return found.sorted {
            $0.folder == $1.folder ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                   : $0.folder.localizedStandardCompare($1.folder) == .orderedAscending
        }
    }

    /// Counts the other files in `root`, by extension (lowercased, "" for none), so the browser can say what it skipped.
    public static func skippedFiles(_ root: URL, limit: Int = 20000) -> [String: Int] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var counts: [String: Int] = [:]
        var seen = 0
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            seen += 1
            if seen > limit { break }
            let ext = url.pathExtension.lowercased()
            if ext != "syx" { counts[ext, default: 0] += 1 }
        }
        return counts
    }

    /// Reads a bank (or a single-voice dump, placed in slot 1) from a `.syx` file.
    public static func load(_ url: URL) throws -> Cartridge {
        try Cartridge(sysex: Data(contentsOf: url))
    }
}
