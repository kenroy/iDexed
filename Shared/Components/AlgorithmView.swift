import SwiftUI
import DexedKit

/// Wiring diagram of the current algorithm. Tap an operator to select it.
struct AlgorithmView: View {
    let algorithm: Int
    var feedbackLevel = 0
    var enabled: [Bool] = Array(repeating: true, count: 6)
    @Binding var selected: Int

    var body: some View {
        let g = AlgorithmGraph.all[max(0, min(31, algorithm))]
        GeometryReader { geo in
            // Leave room for the feedback loop (top and sides) and the output bus (bottom).
            let sideMargin: CGFloat = 18, topMargin: CGFloat = 14
            let rows = CGFloat(g.rowCount)
            let heightBased = (geo.size.height - topMargin - 4) / (rows + (rows - 1) * 0.45 + 0.6)
            let widthBased = (geo.size.width - sideMargin * 2) / (CGFloat(g.width) * 1.5)
            let box: CGFloat = max(18, min(44, heightBased, widthBased))
            let colGap = box * 0.5
            let rowGap = box * 0.45
            let totalW = CGFloat(g.width) * box + CGFloat(max(0, g.width - 1)) * colGap
            let originX = (geo.size.width - totalW) / 2
            let totalH = rows * box + (rows - 1) * rowGap + box * 0.6
            let originY = topMargin + max(0, (geo.size.height - topMargin - totalH) / 2)

            let center: (Int) -> CGPoint = { op in
                CGPoint(x: originX + CGFloat(g.columns[op] ?? 0) * (box + colGap) + box / 2,
                        y: originY + CGFloat(g.rows[op] ?? 0) * (box + rowGap) + box / 2)
            }

            ZStack {
                Canvas { ctx, _ in
                    let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round)
                    // Modulation: down, across, down (right angles, like Dexed).
                    for e in g.edges where !e.isFeedback {
                        let a = center(e.from), b = center(e.to)
                        let startY = a.y + box / 2
                        let endY = b.y - box / 2
                        let midY = endY - max(6, rowGap / 2)
                        var p = Path()
                        p.move(to: CGPoint(x: a.x, y: startY))
                        if abs(a.x - b.x) < 0.5 {
                            p.addLine(to: CGPoint(x: b.x, y: endY))
                        } else {
                            p.addLine(to: CGPoint(x: a.x, y: midY))
                            p.addLine(to: CGPoint(x: b.x, y: midY))
                            p.addLine(to: CGPoint(x: b.x, y: endY))
                        }
                        ctx.stroke(p, with: .color(.white.opacity(0.55)), style: stroke)
                    }
                    // Output bus: every carrier drops to one shared horizontal line.
                    if let bottomRow = g.carriers.compactMap({ g.rows[$0] }).max() {
                        let xs = g.carriers.map { center($0).x }
                        let busY = originY + CGFloat(bottomRow) * (box + rowGap) + box + box * 0.35
                        var p = Path()
                        for c in g.carriers {
                            let a = center(c)
                            p.move(to: CGPoint(x: a.x, y: a.y + box / 2))
                            p.addLine(to: CGPoint(x: a.x, y: busY))
                        }
                        if let lo = xs.min(), let hi = xs.max(), hi > lo {
                            p.move(to: CGPoint(x: lo, y: busY))
                            p.addLine(to: CGPoint(x: hi, y: busY))
                        }
                        ctx.stroke(p, with: .color(Theme.accent), style: stroke)
                    }
                    // Feedback: up and over from the top of the receiving operator, down the side to the
                    // row of the sending operator, then back in (a small box loop when it feeds itself).
                    for e in g.edges where e.isFeedback {
                        let top = center(e.to), src = center(e.from)
                        let rowsInSpan = (g.rows[e.to] ?? 0)...(g.rows[e.from] ?? 0)
                        let blockedRight = (1...6).contains { op in
                            op != e.to && op != e.from && rowsInSpan.contains(g.rows[op] ?? -1)
                                && (g.columns[op] ?? 0) > (g.columns[e.to] ?? 0) - 0.01
                                && (g.columns[op] ?? 0) < (g.columns[e.to] ?? 0) + 1.01
                        }
                        let dir: CGFloat = blockedRight ? -1 : 1
                        let sideX = top.x + dir * (box / 2 + 7)
                        let endY = src.y + box / 2 + 3
                        var p = Path()
                        p.move(to: CGPoint(x: top.x, y: top.y - box / 2))
                        p.addLine(to: CGPoint(x: top.x, y: top.y - box / 2 - 6))
                        p.addLine(to: CGPoint(x: sideX, y: top.y - box / 2 - 6))
                        p.addLine(to: CGPoint(x: sideX, y: endY))
                        p.addLine(to: CGPoint(x: src.x, y: endY))
                        ctx.stroke(p, with: .color(.orange.opacity(feedbackLevel > 0 ? 0.95 : 0.35)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(1...6, id: \.self) { op in
                    let on = enabled[op - 1]
                    Text("\(op)")
                        .font(.system(size: box * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(on ? Color.black.opacity(0.8) : Theme.dim)
                        .frame(width: box, height: box)
                        .background(on ? Theme.operatorColor(op) : Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white, lineWidth: selected == op ? 2.5 : 0))
                        .position(center(op))
                        .onTapGesture { selected = op }
                        .accessibilityLabel("Operator \(op)")
                        .accessibilityAddTraits(selected == op ? .isSelected : [])
                }
            }
        }
    }
}
