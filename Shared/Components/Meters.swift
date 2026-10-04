import SwiftUI

/// Segmented LED bar. `level` is 0…1; `tricolor` gives the green/yellow/red output-meter look.
struct LevelBar: View {
    var level: Float
    var segments = 24
    var tricolor = false
    var tint: Color = .orange

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 1.5
            let w = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let lit = Int((CGFloat(max(0, min(1, level))) * CGFloat(segments)).rounded(.up))
            for i in 0..<segments {
                let x = CGFloat(i) * (w + gap)
                let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                let frac = Double(i) / Double(segments - 1)
                let on: Color = tricolor ? (frac > 0.85 ? .red : frac > 0.7 ? .yellow : .green)
                                         : Color(hue: 0.08 - 0.08 * frac, saturation: 0.9, brightness: 1)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(i < lit ? on : Color.white.opacity(0.08)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Output meter using the same dB window as Dexed's (roughly −48 dB … 0 dB).
struct OutputMeter: View {
    var level: Float

    var body: some View {
        let db = level > 0 ? 20 * log10(Double(level)) : -96
        let position = Float(max(0, min(1, (db + 48) / 48)))
        LevelBar(level: position, segments: 28, tricolor: true)
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel("Output level")
    }
}
