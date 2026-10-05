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

/// What an import did.
public struct BankImportSummary: Equatable, Sendable {
    public var copied = 0
    /// Already in the destination with the same size.
    public var duplicates = 0
    /// Files that aren't `.syx`, so the browser couldn't use them.
    public var notBanks = 0
    public var failed = 0
    public init() {}

    public var text: String {
        var parts = ["Imported \(copied) bank\(copied == 1 ? "" : "s")"]
        if duplicates > 0 { parts.append("\(duplicates) already there") }
        if notBanks > 0 { parts.append("\(notBanks) skipped (not .syx)") }
        if failed > 0 { parts.append("\(failed) couldn't be copied") }
        return parts.joined(separator: ", ") + "."
    }
}

/// Finds and opens DX7 bank files in a folder (for the bank browser).
public enum BankFolder {
    /// Copies `.syx` files into `destination`. A chosen folder keeps its name and structure underneath, so a big
    /// collection stays organised. Files already there with the same size are left alone; a different file with the same
    /// name is kept as "name 2.syx". Other kinds of file are counted and skipped.
    public static func importBanks(from sources: [URL], into destination: URL) -> BankImportSummary {
        var summary = BankImportSummary()
        let fm = FileManager.default
        for source in sources {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                let base = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                let rootParts = source.standardizedFileURL.pathComponents
                guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { summary.failed += 1; continue }
                for case let file as URL in walker {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    guard file.pathExtension.lowercased() == "syx" else { summary.notBanks += 1; continue }
                    let parts = file.deletingLastPathComponent().standardizedFileURL.pathComponents
                    var folder = base
                    for part in parts.dropFirst(rootParts.count) { folder.appendPathComponent(part, isDirectory: true) }
                    copy(file, toFolder: folder, summary: &summary)
                }
            } else if source.pathExtension.lowercased() == "syx" {
                copy(source, toFolder: destination, summary: &summary)
            } else {
                summary.notBanks += 1
            }
        }
        return summary
    }

    private static func copy(_ file: URL, toFolder folder: URL, summary: inout BankImportSummary) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                let a = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
                let b = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -2
                if a == b { summary.duplicates += 1; return }
                let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
                var n = 2
                repeat {
                    target = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
                    n += 1
                } while fm.fileExists(atPath: target.path)
            }
            try fm.copyItem(at: file, to: target)
            summary.copied += 1
        } catch {
            summary.failed += 1
        }
    }

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
