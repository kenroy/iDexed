import SwiftUI
import DexedKit

struct VoiceView: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var selectedOperator: Int
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var algorithmBinding: Binding<Int> {
        Binding(get: { engine.patch.algorithm }, set: { engine.setParameter(134, $0) })
    }

    var body: some View {
        // Order matters: the tall Global card goes second so the three columns come out roughly even on iPad/Mac.
        MasonryLayout(minColumnWidth: 340, spacing: 12) {
            algorithmPanel
            globalPanel
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
                Knob(title: "Bend Range", value: $engine.pitchBendRange, range: 0...12)
                Knob(title: "Tune", value: Binding(get: { Int((engine.masterTune * 200).rounded()) },
                                                   set: { engine.masterTune = Double($0) / 200 }),
                     range: 0...200, displayOffset: 100)
                Knob(title: "Cutoff", value: Binding(get: { Int((engine.filterCutoff * 100).rounded()) },
                                                     set: { engine.filterCutoff = Double($0) / 100 }), range: 0...100)
                Knob(title: "Reso", value: Binding(get: { Int((engine.filterResonance * 100).rounded()) },
                                                   set: { engine.filterResonance = Double($0) / 100 }), range: 0...100)
            }
            Picker("Engine", selection: $engine.engineType) {
                ForEach(EngineType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Mono mode", isOn: $engine.monoMode)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mod Wheel").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                ParamRow {
                    Knob(title: "Range", value: $engine.modWheelRange, range: 0...127)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Toggle("Pitch", isOn: $engine.modWheelPitch)
                            Toggle("Amp", isOn: $engine.modWheelAmp)
                            Toggle("EG", isOn: $engine.modWheelEG)
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        Text("Pitch = vibrato, Amp = tremolo. Depth also depends on the voice's Pitch/Amp Mod Sens.")
                            .font(.caption2).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                }
            }
        }
    }
}
