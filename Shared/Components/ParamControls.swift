import SwiftUI
import DexedKit

/// Binds a `ParameterInfo` to the engine and renders it as a knob (numeric) or menu (named choices).
struct ParamControl: View {
    @Environment(SynthEngine.self) private var engine
    let info: ParameterInfo
    var tint: Color = Theme.accent
    var title: String?
    /// Space above an on/off chip so it lines up with the dials in the same row.
    var switchInset: CGFloat = 22

    private var binding: Binding<Int> {
        Binding(get: { engine.patch[info.offset] }, set: { engine.setParameter(info.offset, $0) })
    }

    private var isOnOff: Bool { info.max == 1 && info.labels == ["Off", "On"] }

    var body: some View {
        if isOnOff {
            Toggle(title ?? info.name, isOn: Binding(get: { binding.wrappedValue == 1 }, set: { binding.wrappedValue = $0 ? 1 : 0 }))
                .toggleStyle(SwitchChipStyle())
                .padding(.top, switchInset)
        } else if let labels = info.labels, info.max <= 5 {
            VStack(spacing: 3) {
                Menu {
                    Picker(title ?? info.name, selection: binding) {
                        ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    // Same look as the Algorithm selector: the value, then a chevron that marks it as a dropdown.
                    HStack(spacing: 5) {
                        Text(labels[min(max(binding.wrappedValue, 0), labels.count - 1)])
                            .font(.body.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(tint)
                Text(title ?? info.name).font(.caption2).foregroundStyle(Theme.dim)
            }
            .frame(minWidth: 70)
        } else {
            Knob(title: title ?? info.name, value: binding, range: 0...info.max, labels: info.labels,
                 displayOffset: info.displayOffset, accessibilityTitle: info.name,
                 control: .voice(info.offset), tint: tint)
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

/// An always-visible capsule that fills with the accent colour when on, so its state is obvious at a glance.
struct SwitchChipStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(configuration.isOn ? Color.black : Theme.dim)
                .background(Capsule().fill(configuration.isOn ? Color.accentColor : Color.clear))
                .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Theme.dim.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
