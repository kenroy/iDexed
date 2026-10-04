import SwiftUI
import DexedKit

struct BankView: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var showTab: Tab

    var body: some View {
        let names = engine.bank.names
        Panel(title: engine.bankName) {
            LazyVStack(spacing: 0) {
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
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
