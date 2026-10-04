import SwiftUI
import DexedKit

@main
struct iDexedApp: App {
    @State private var engine = SynthEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .task { loadDefaultBank() }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 860)
        #endif
    }

    private func loadDefaultBank() {
        guard engine.bankName == "Init Bank",
              let first = FactoryBanks.all.first(where: { $0.name.hasPrefix("Dexed") }) ?? FactoryBanks.all.first,
              let data = try? Data(contentsOf: first.url) else { return }
        try? engine.importSysEx(data, name: first.name)
    }
}
