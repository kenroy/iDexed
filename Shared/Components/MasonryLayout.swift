import SwiftUI

/// Packs views of different heights into as many columns as fit, always adding the next view to the shortest column.
/// Unlike a grid, short cards don't leave dead space underneath them.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 340
    var spacing: CGFloat = 12

    /// A proposal can be unbounded (infinity) or invalid (NaN), for example when a plug-in host asks the view for its
    /// ideal size. Fall back to a single column then; converting those values to Int would crash.
    private func usableWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite, proposed > 0 else { return minColumnWidth }
        return proposed
    }

    private func columnCount(for width: CGFloat) -> Int {
        let columns = ((width + spacing) / (minColumnWidth + spacing)).rounded(.down)
        guard columns.isFinite else { return 1 }
        return max(1, Int(min(columns, 12)))
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let width = usableWidth(width)
        let n = columnCount(for: width)
        let columnWidth = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = [CGFloat](repeating: 0, count: n)
        var frames: [CGRect] = []
        for subview in subviews {
            let h = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: h))
            heights[column] += h + spacing
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = usableWidth(proposal.width)
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: usableWidth(bounds.width), subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
