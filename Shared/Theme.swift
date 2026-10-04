import SwiftUI

enum Theme {
    static let background = Color(red: 0.067, green: 0.072, blue: 0.082)
    static let panel = Color(red: 0.115, green: 0.122, blue: 0.138)
    static let panelStroke = Color.white.opacity(0.07)
    static let lcdBackground = Color(red: 0.035, green: 0.095, blue: 0.065)
    static let lcd = Color(red: 0.52, green: 0.96, blue: 0.66)
    static let accent = Color(red: 0.36, green: 0.86, blue: 0.76)
    static let dim = Color.white.opacity(0.45)

    /// One hue per operator so the algorithm diagram, envelopes and cards read together.
    static func operatorColor(_ op: Int) -> Color {
        let hues: [Double] = [0.02, 0.09, 0.16, 0.42, 0.58, 0.75]
        return Color(hue: hues[(op - 1) % 6], saturation: 0.62, brightness: 0.95)
    }
}

struct Panel<Content: View>: View {
    var title: String?
    var accent: Color = Theme.dim
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(accent)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelStroke))
    }
}
