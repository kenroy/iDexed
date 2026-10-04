import SwiftUI
import DexedKit

/// Binds a `ParameterInfo` to the engine and renders it as a knob (numeric) or menu (named choices).
struct ParamControl: View {
    @Environment(SynthEngine.self) private var engine
    let info: ParameterInfo
    var tint: Color = Theme.accent
    var title: String?

    private var binding: Binding<Int> {
        Binding(get: { engine.patch[info.offset] }, set: { engine.setParameter(info.offset, $0) })
    }

    var body: some View {
        if let labels = info.labels, info.max <= 5 {
            VStack(spacing: 3) {
                Picker(title ?? info.name, selection: binding) {
                    ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(tint)
                Text(title ?? info.name).font(.caption2).foregroundStyle(Theme.dim)
            }
            .frame(minWidth: 70)
        } else {
            Knob(title: title ?? info.name, value: binding, range: 0...info.max, labels: info.labels,
                 displayOffset: info.displayOffset, accessibilityTitle: info.name, tint: tint)
        }
    }
}

struct ParamRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) { content }
                .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}
