import SwiftUI
import DexedKit

struct VoiceView: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var selectedOperator: Int
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedSource: ModSource = .wheel

    private var algorithmBinding: Binding<Int> {
        Binding(get: { engine.patch.algorithm }, set: { engine.setParameter(134, $0) })
    }

    var body: some View {
        // Order matters: the cards are dealt into the shortest column in turn, which keeps three columns roughly even.
        MasonryLayout(minColumnWidth: 340, spacing: 12) {
            algorithmPanel
            globalPanel
            controllersPanel
            pitchEGPanel
            lfoPanel
        }
    }

    private var algorithmPanel: some View {
        Panel(title: "Algorithm") {
            AlgorithmView(algorithm: engine.patch.algorithm, feedbackLevel: engine.patch.feedback,
                          enabled: engine.operatorEnabled, selected: $selectedOperator)
                .frame(height: 190)
            HStack {
                Stepper(value: algorithmBinding, in: 0...31) {
                    Text("Algorithm \(engine.patch.algorithm + 1)")
                        .font(.body.monospacedDigit().weight(.semibold))
                }
            }
            ParamRow {
                ParamControl(info: Parameters.feedback, tint: .orange)
                ParamControl(info: Parameters.oscSync)
            }
        }
    }

    private var pitchEGPanel: some View {
        Panel(title: "Pitch Envelope") {
            EnvelopeView(rates: Parameters.pitchRates.map { engine.patch[$0.offset] },
                         levels: Parameters.pitchLevels.map { engine.patch[$0.offset] },
                         tint: .purple, bipolar: true,
                         stage: engine.status.pitchStage >= 0 ? engine.status.pitchStage : nil)
                .frame(height: 80)
            ParamRow {
                Text("Pitch EG Rate").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                ForEach(Array(Parameters.pitchRates.enumerated()), id: \.offset) { i, p in ParamControl(info: p, tint: .purple, title: "\(i + 1)") }
            }
            ParamRow {
                Text("Pitch EG Level").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                ForEach(Array(Parameters.pitchLevels.enumerated()), id: \.offset) { i, p in ParamControl(info: p, tint: .purple, title: "\(i + 1)") }
            }
        }
    }

    private var lfoPanel: some View {
        Panel(title: "LFO") {
            ParamRow {
                ParamControl(info: Parameters.lfoWave)
                ParamControl(info: Parameters.lfoSync)
            }
            ParamRow {
                ParamControl(info: Parameters.lfoSpeed)
                ParamControl(info: Parameters.lfoDelay)
                ParamControl(info: Parameters.lfoPitchDepth)
                ParamControl(info: Parameters.lfoAmpDepth)
                ParamControl(info: Parameters.pitchModSens)
            }
        }
    }

    private var globalPanel: some View {
        @Bindable var engine = engine
        return Panel(title: "Global") {
            ParamRow {
                ParamControl(info: Parameters.transpose)
                Knob(title: "Tune", value: Binding(get: { Int((engine.masterTune * 200).rounded()) },
                                                   set: { engine.masterTune = Double($0) / 200 }),
                     range: 0...200, displayOffset: 100, control: .masterTune)
                Knob(title: "Cutoff", value: Binding(get: { Int((engine.filterCutoff * 100).rounded()) },
                                                     set: { engine.filterCutoff = Double($0) / 100 }), range: 0...100, control: .cutoff)
                Knob(title: "Reso", value: Binding(get: { Int((engine.filterResonance * 100).rounded()) },
                                                   set: { engine.filterResonance = Double($0) / 100 }), range: 0...100, control: .resonance)
            }
            Picker("Engine", selection: $engine.engineType) {
                ForEach(EngineType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Mono mode", isOn: $engine.monoMode)
            Toggle("Normalize velocity (÷127 × 100)", isOn: $engine.normalizeVelocity)
        }
    }

    private var controllersPanel: some View {
        @Bindable var engine = engine
        return Panel(title: "Controllers") {
            // Every group is the same shape: knobs on the left in a fixed grid, switches beside them, a note underneath.
            group("Pitch Bend", note: "A Step above 0 snaps the bend to that many semitones and overrides Up and Down.") {
                Knob(title: "Up", value: $engine.pitchBendUp, range: 0...48)
                Knob(title: "Down", value: $engine.pitchBendDown, range: 0...48)
                Knob(title: "Step", value: $engine.pitchBendStep, range: 0...12)
            }

            sectionDivider
            HStack(alignment: .top, spacing: 16) {
                group("Portamento") {
                    Knob(title: "Time", value: $engine.portamentoTime, range: 0...99)
                } switches: {
                    Toggle("Glissando", isOn: $engine.glissando)
                }
                group("MPE") {
                    Knob(title: "Bend", value: $engine.mpeBendRange, range: 1...96)
                } switches: {
                    Toggle("Enabled", isOn: $engine.mpeEnabled)
                }
            }
            noteText("MPE bends each note by its own channel's pitch wheel. It switches itself off if two notes share a channel.")

            sectionDivider
            VStack(alignment: .leading, spacing: 6) {
                Text("MIDI Controller").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                Picker("Controller", selection: $selectedSource) {
                    ForEach(ModSource.allCases) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)
                let routing = routingBinding(selectedSource)
                controlRow {
                    Knob(title: "Range", value: routing.range, range: 0...127)
                } switches: {
                    Toggle("Pitch", isOn: routing.pitch)
                    Toggle("Amp", isOn: routing.amp)
                    Toggle("EG", isOn: routing.eg)
                }
                noteText("\(selectedSource.title): Pitch = vibrato, Amp = tremolo, EG = envelope level. Depth also depends on the voice's Pitch/Amp Mod Sens.")
            }
        }
    }

    private func routingBinding(_ source: ModSource) -> Binding<ControllerRouting> {
        Binding(get: { engine.routing(source) }, set: { engine.controllerRouting[source] = $0 })
    }

    /// Knobs, then switches vertically centred on the dials.
    private func controlRow<K: View, S: View>(@ViewBuilder _ knobs: () -> K, @ViewBuilder switches: () -> S = { EmptyView() }) -> some View {
        // One row, so the switches sit right beside the knobs they belong to.
        ParamRow {
            knobs()
            HStack(spacing: 6) { switches() }
                .toggleStyle(SwitchChipStyle())
                .padding(.top, 22)
        }
    }

    private var sectionDivider: some View {
        Divider().overlay(Theme.panelStroke).padding(.vertical, 8)
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group<K: View, S: View>(_ title: String, note: String? = nil, @ViewBuilder _ knobs: () -> K,
                                         @ViewBuilder switches: () -> S = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
            controlRow(knobs, switches: switches)
            if let note { noteText(note) }
        }
    }
}

/// An always-visible capsule that fills with the accent colour when on, so its state is obvious at a glance.
private struct SwitchChipStyle: ToggleStyle {
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
