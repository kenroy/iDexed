import Foundation

struct FactoryBank: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }
}

enum FactoryBanks {
    static let all: [FactoryBank] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "syx", subdirectory: nil) ?? []
        return urls.map(FactoryBank.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()
}
