import SwiftUI

/// Draws a DX7-style 4-rate / 4-level envelope. `center` is the zero line for the pitch EG (level 50).
struct EnvelopeView: View {
    var rates: [Int]
    var levels: [Int]
    var tint: Color = Theme.accent
    var bipolar = false
    /// Current envelope stage of the sounding voice (0…3, 3 = release); nil when silent.
    var stage: Int?

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = 6
            let w = size.width - pad * 2, h = size.height - pad * 2
            func y(_ level: Int) -> CGFloat { pad + h * (1 - CGFloat(level) / 99) }

            // Segment durations: faster rate → shorter segment.
            func span(_ rate: Int) -> CGFloat { 0.08 + CGFloat(99 - rate) / 99 * 0.9 }
            let spans = [span(rates[0]), span(rates[1]), span(rates[2]), 0.45 /* sustain */, span(rates[3])]
            let total = spans.reduce(0, +)
            var x = pad
            var pts: [CGPoint] = [CGPoint(x: x, y: y(levels[3]))]
            let targets = [levels[0], levels[1], levels[2], levels[2], levels[3]]
            for (s, lvl) in zip(spans, targets) {
                x += w * s / total
                pts.append(CGPoint(x: x, y: y(lvl)))
            }

            if bipolar {
                var mid = Path(); mid.move(to: CGPoint(x: pad, y: y(50))); mid.addLine(to: CGPoint(x: pad + w, y: y(50)))
                ctx.stroke(mid, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var area = Path()
            area.move(to: CGPoint(x: pts[0].x, y: pad + h))
            pts.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: pts.last!.x, y: pad + h))
            area.closeSubpath()
            ctx.fill(area, with: .color(tint.opacity(0.16)))

            var line = Path()
            line.addLines(pts)
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let stage, (0...3).contains(stage) {
                let range = stage == 2 ? 2...4 : stage == 3 ? 4...5 : stage...(stage + 1)
                var hl = Path()
                hl.addLines(Array(pts[range]))
                ctx.stroke(hl, with: .color(.white), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                ctx.draw(Text("\(stage + 1)").font(.caption.weight(.bold)).foregroundStyle(.white),
                         at: CGPoint(x: pad + 8, y: pad + 8))
            }
            for p in pts.dropFirst().prefix(4) {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
            }
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
