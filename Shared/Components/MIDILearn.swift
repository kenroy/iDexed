import SwiftUI
import DexedKit

/// Makes a control assignable to a MIDI controller: a context menu (right-click, or long-press on iOS) with MIDI Learn and
/// Remove Mapping, and a small badge showing the assigned controller or that it is waiting to learn one.
struct MIDIMappableModifier: ViewModifier {
    @Environment(SynthEngine.self) private var engine
    let control: MappableControl

    private var mapped: MIDIControllerKey? { engine.mappedController(for: control) }
    private var isLearning: Bool { engine.learningControl == control }

    func body(content: Content) -> some View {
        if engine.isHostedPlugin {
            content          // inside a host the host owns MIDI mapping
        } else {
            content
                .overlay(alignment: .topTrailing) { badge }
                .overlay {
                    if engine.midiLearnMode && !isLearning {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .contextMenu {
                    Button(isLearning ? "Cancel MIDI Learn" : "MIDI Learn…", systemImage: "pianokeys") { engine.toggleLearning(control) }
                    if let mapped {
                        Text("Mapped to \(mapped.description)")
                        Button("Remove Mapping", systemImage: "xmark.circle", role: .destructive) { engine.removeMapping(for: control) }
                    }
                }
        }
    }

    @ViewBuilder private var badge: some View {
        if isLearning {
            Text("MOVE A CC")
                .font(.system(size: 8, weight: .heavy)).foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.orange, in: Capsule())
                .offset(x: 6, y: -4)
        } else if let mapped {
            Text("CC\(mapped.cc)")
                .font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.accent, in: Capsule())
                .offset(x: 6, y: -4)
                .accessibilityLabel("Mapped to \(mapped.description)")
        }
    }
}

extension View {
    func midiMappable(_ control: MappableControl) -> some View { modifier(MIDIMappableModifier(control: control)) }
}
