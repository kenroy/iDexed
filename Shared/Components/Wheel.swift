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
            let w = geo.size.width
            let capH: CGFloat = 36
            let grooveW: CGFloat = 12
            let travel = max(1, h - capH)
            ZStack(alignment: .top) {
                // The plate the groove is cut into.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(white: 0.095))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1))

                // Centre notch on either side of the groove (pitch only), so the rest position is easy to find.
                if springsToCenter {
                    HStack(spacing: grooveW + 12) {
                        Rectangle().fill(.white.opacity(0.30)).frame(width: 5, height: 1.5)
                        Rectangle().fill(.white.opacity(0.30)).frame(width: 5, height: 1.5)
                    }
                    .offset(y: capH / 2 + travel / 2 - 0.75)
                }

                // The groove: a recessed slot, shadowed along its top-left lip and catching light along the bottom-right.
                RoundedRectangle(cornerRadius: grooveW / 2, style: .continuous)
                    .fill(LinearGradient(colors: [Color.black, Color(white: 0.02)], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: grooveW / 2, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.black.opacity(0.95), .white.opacity(0.20)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                    )
                    .overlay(alignment: .top) {      // inner shadow at the top of the slot
                        LinearGradient(colors: [.black.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: grooveW / 2, style: .continuous))
                    }
                    .frame(width: grooveW)
                    .padding(.vertical, capH / 2 - 4)
                    .frame(maxHeight: .infinity)

                // The raised slider cap sitting in the groove.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.68), Color(white: 0.36)], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
                    .overlay {                       // grip ridges with a teal indicator line in the middle
                        VStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { _ in ridge }
                            Capsule().fill(Theme.accent).frame(width: w - 14, height: 3)
                                .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                            ForEach(0..<2, id: \.self) { _ in ridge }
                        }
                    }
                    .frame(width: w - 4, height: capH)
                    .shadow(color: .black.opacity(0.65), radius: 3, y: 2)
                    .offset(y: (1 - CGFloat(value)) * travel)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let v = 1 - Double((g.location.y - capH / 2) / travel)
                        onChange(min(1, max(0, v)))
                    }
                    .onEnded { _ in
                        if springsToCenter { withAnimation(.snappy(duration: 0.12)) { onChange(0.5) } }
                    }
            )
        }
    }

    private var ridge: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.35)).frame(height: 1)
            Rectangle().fill(.white.opacity(0.28)).frame(height: 1)
        }
        .frame(width: 18)
    }
}
