import SwiftUI
import DexedKit

/// Rotary control driven by a vertical drag (works with touch, trackpad and mouse).
struct Knob: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...99
    var labels: [String]?
    var displayOffset = 0
    var accessibilityTitle: String?
    /// When set, the knob can be assigned to a MIDI controller (see `MIDIMappableModifier`).
    var control: MappableControl?
    var tint: Color = Theme.accent
    var size: CGFloat = 46

    @State private var dragStart: Int?
    @State private var learnTapHandled = false
    @Environment(SynthEngine.self) private var engine

    private var fraction: Double {
        Double(value - range.lowerBound) / Double(max(1, range.upperBound - range.lowerBound))
    }

    var body: some View {
        if let control {
            knob.midiMappable(control)
        } else {
            knob
        }
    }

    private var knob: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Capsule().fill(.white)
                    .frame(width: 2.5, height: size * 0.2)
                    .offset(y: -size * 0.22)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // In MIDI Learn Mode a tap selects this knob for learning instead of changing its value.
                        if engine.midiLearnMode, let control {
                            if !learnTapHandled { learnTapHandled = true; engine.toggleLearning(control) }
                            return
                        }
                        if dragStart == nil { dragStart = value }
                        let span = Double(range.upperBound - range.lowerBound)
                        let pointsForFullRange = 180.0
                        let delta = Int((-g.translation.height / pointsForFullRange * span).rounded())
                        value = min(range.upperBound, max(range.lowerBound, (dragStart ?? value) + delta))
                    }
                    .onEnded { _ in dragStart = nil; learnTapHandled = false }
            )
            Text(display)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: size + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityValue(display)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private var display: String {
        if let labels, labels.indices.contains(value) { return labels[value] }
        let v = value - displayOffset
        return displayOffset != 0 && v > 0 ? "+\(v)" : "\(v)"
    }
}
