import SwiftUI
import DexedKit

/// Shows the tuning in use: the scale's notes in cents and as written, and the keyboard mapping. Like Dexed's "Show".
struct TuningInfoView: View {
    @Environment(\.dismiss) private var dismiss
    var info: TuningInfo

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tuning").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(info.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
