import SwiftUI

/// Vertical performance slider with a labelled caption underneath. A pitch wheel springs back to centre when
/// released; a mod wheel stays where you leave it.
struct Wheel: View {
    var title: String
    var caption: String
    var value: Double              // 0…1
    var springsToCenter: Bool
    var onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            track
            Text(caption)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            let step = 0.05
            switch dir {
            case .increment: onChange(min(1, value + step))
            case .decrement: onChange(max(0, value - step))
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumbH: CGFloat = 26
            let travel = max(1, h - thumbH)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))

                // Groove running the full length, with tick marks along it.
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 3)
                    .padding(.vertical, thumbH / 2)
                    .frame(maxHeight: .infinity)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    let isCenter = springsToCenter && f == 0.5
                    Rectangle()
                        .fill(.white.opacity(isCenter ? 0.55 : 0.25))
                        .frame(width: isCenter ? 18 : 10, height: 1)
                        .offset(y: thumbH / 2 + CGFloat(1 - f) * travel - 0.5)
                }

                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.24)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .center) {
                        Rectangle().fill(.black.opacity(0.35)).frame(height: 1)      // grip line
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                    .frame(height: thumbH)
                    .padding(.horizontal, 2)
                    .offset(y: (1 - CGFloat(value)) * travel)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let v = 1 - Double((g.location.y - thumbH / 2) / travel)
                        onChange(min(1, max(0, v)))
                    }
                    .onEnded { _ in
                        if springsToCenter { withAnimation(.snappy(duration: 0.12)) { onChange(0.5) } }
                    }
            )
        }
    }
}
