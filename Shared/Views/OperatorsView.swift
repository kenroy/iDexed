import SwiftUI
import DexedKit

struct OperatorsView: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var selectedOperator: Int

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)]
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(1...6, id: \.self) { op in
                OperatorCard(op: op, isSelected: selectedOperator == op)
                    .onTapGesture { selectedOperator = op }
            }
        }
    }
}

struct OperatorCard: View {
    @Environment(SynthEngine.self) private var engine
    let op: Int
    var isSelected: Bool

    private func info(_ f: OperatorField) -> ParameterInfo { Parameters.operatorInfo(f, op: op - 1) }
    private var tint: Color { isActive ? Theme.operatorColor(op) : Color(white: 0.5) }
    /// A switched-off operator is silent, so it shows no meter or envelope-stage activity.
    private var isActive: Bool { engine.operatorEnabled[op - 1] }
    @State private var pasteFailed = false

    /// Copy / paste an operator's values or just its envelope (same text format as Dexed, so it works between the two).
    @ViewBuilder private var operatorActions: some View {
        Button("Copy Operator", systemImage: "doc.on.doc") {
            SystemClipboard.set(engine.operatorClipboardText(op - 1))
        }
        Button("Paste Operator", systemImage: "doc.on.clipboard") { paste(envelopeOnly: false) }
        Button("Paste Envelope Only", systemImage: "waveform.path") { paste(envelopeOnly: true) }
    }

    private func paste(envelopeOnly: Bool) {
        guard let text = SystemClipboard.text(), engine.pasteOperator(op - 1, from: text, envelopeOnly: envelopeOnly) else {
            pasteFailed = true
            return
        }
    }

    var body: some View {
        @Bindable var engine = engine
        let p = engine.patch
        Panel(title: nil) {
            HStack {
                Text("OP \(op)").font(.headline.weight(.heavy)).foregroundStyle(tint)
                if AlgorithmGraph.all[p.algorithm].carriers.contains(op) {
                    Text("CARRIER").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.2), in: Capsule()).foregroundStyle(Theme.accent)
                }
                Text(p.frequencyDescription(op: op - 1))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.lcd.opacity(isActive ? 1 : 0.35))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.lcdBackground, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Frequency \(p.frequencyDescription(op: op - 1))")
                Spacer()
                Menu { operatorActions } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.dim)
                }
                .menuStyle(.button).buttonStyle(.plain)
                .accessibilityLabel("Operator \(op) actions")
                Toggle("Enabled", isOn: $engine.operatorEnabled[op - 1])
                    .labelsHidden().toggleStyle(.switch).tint(tint)
                    .accessibilityLabel("Operator \(op) enabled")
            }
            EnvelopeView(rates: [.rate1, .rate2, .rate3, .rate4].map { p[op: op - 1, field: $0] },
                         levels: [.level1, .level2, .level3, .level4].map { p[op: op - 1, field: $0] },
                         tint: tint, stage: isActive && engine.status.operatorStages[op - 1] >= 0 ? engine.status.operatorStages[op - 1] : nil)
                .frame(height: 76)
                .opacity(isActive ? 1 : 0.4)
            LevelBar(level: isActive ? engine.status.operatorLevels[op - 1] : 0)
                .frame(height: 6)
                .opacity(isActive ? 1 : 0.4)

            group("Output") {
                ParamControl(info: info(.outputLevel), tint: tint)
                ParamControl(info: info(.oscMode), tint: tint)
                ParamControl(info: info(.freqCoarse), tint: tint)
                ParamControl(info: info(.freqFine), tint: tint)
                ParamControl(info: info(.detune), tint: tint)
            }
            group("EG Rate") {
                ForEach(Array([OperatorField.rate1, .rate2, .rate3, .rate4].enumerated()), id: \.offset) { i, f in
                    ParamControl(info: info(f), tint: tint, title: "\(i + 1)")
                }
            }
            group("EG Level") {
                ForEach(Array([OperatorField.level1, .level2, .level3, .level4].enumerated()), id: \.offset) { i, f in
                    ParamControl(info: info(f), tint: tint, title: "\(i + 1)")
                }
            }
            group("Scaling") {
                ParamControl(info: info(.breakPoint), tint: tint)
                ParamControl(info: info(.leftDepth), tint: tint)
                ParamControl(info: info(.leftCurve), tint: tint)
                ParamControl(info: info(.rightDepth), tint: tint)
                ParamControl(info: info(.rightCurve), tint: tint)
            }
            group("Sensitivity") {
                ParamControl(info: info(.rateScaling), tint: tint)
                ParamControl(info: info(.ampModSens), tint: tint)
                ParamControl(info: info(.keyVelSens), tint: tint)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5))
        .contextMenu { operatorActions }
        .alert("Nothing to paste", isPresented: $pasteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The clipboard doesn't contain operator data. Copy an operator first.")
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
            ParamRow { content() }
        }
        .opacity(isActive ? 1 : 0.45)
    }
}
