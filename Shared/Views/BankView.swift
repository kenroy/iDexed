import SwiftUI
import DexedKit

/// The Bank tab: the current bank (32 slots) next to the bank browser.
struct BankView: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var showTab: Tab
    var library: BankLibrary

    var body: some View {
        MasonryLayout(minColumnWidth: 380, spacing: 12) {
            currentBank
            LibraryPanel(library: library)
        }
    }

    private var currentBank: some View {
        let names = engine.bank.names
        return Panel(title: "Current Bank · \(engine.bankName)") {
            VStack(spacing: 0) {
                ForEach(names.indices, id: \.self) { i in
                    Button {
                        engine.selectProgram(i)
                    } label: {
                        HStack {
                            Text(String(format: "%02d", i + 1)).font(.body.monospacedDigit()).foregroundStyle(Theme.dim)
                                .frame(width: 32, alignment: .leading)
                            Text(i == engine.programIndex ? engine.patch.name : names[i])
                                .font(.body.weight(i == engine.programIndex ? .semibold : .regular))
                            Spacer()
                            if i == engine.programIndex { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                        }
                        .padding(.vertical, 9).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(i == engine.programIndex ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    // Drop a voice from the browser onto this slot to replace it.
                    .dropDestination(for: VoicePayload.self) { items, _ in
                        guard let voice = items.first else { return false }
                        engine.replaceVoice(at: i, with: voice.patch)
                        return true
                    }
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
