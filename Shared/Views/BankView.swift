import SwiftUI
import DexedKit

/// The Bank tab: the current bank (32 slots) next to the bank browser.
struct BankView: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var showTab: Tab
    var library: BankLibrary

    /// Widths at which the layout changes: three equal columns, then two, then one page-scrolling column.
    private let threeColumnWidth: CGFloat = 960
    private let twoColumnWidth: CGFloat = 800

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= threeColumnWidth {
                // Current bank | banks | voices: equal widths, each filling the height and scrolling on its own.
                let width = (geo.size.width - 24) / 3
                HStack(alignment: .top, spacing: 12) {
                    ScrollView { currentBank }.frame(width: width)
                    LibraryPanel(library: library, mode: .banks).frame(width: width)
                    LibraryPanel(library: library, mode: .voices).frame(width: width)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else if geo.size.width >= twoColumnWidth {
                // Current bank | library, each scrolling on its own.
                HStack(alignment: .top, spacing: 12) {
                    ScrollView { currentBank }
                    ScrollView { LibraryPanel(library: library) }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        currentBank
                        LibraryPanel(library: library)
                    }
                }
            }
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
                    .contextMenu {
                        if !engine.isHostedPlugin {
                            Button("Send Voice to DX7", systemImage: "arrow.up.right.square") {
                                engine.sendVoiceToDX7(i == engine.programIndex ? engine.patch : engine.bank.patch(at: i))
                            }
                            .disabled(!engine.hasSysExDestination)
                            Button("Send Bank to DX7", systemImage: "arrow.up.right.square") { engine.sendBankToDX7() }
                                .disabled(!engine.hasSysExDestination)
                        }
                    }
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
