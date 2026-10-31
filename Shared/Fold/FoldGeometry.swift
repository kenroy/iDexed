import SwiftUI

/// Where a partly folded iPhone Duo divides the display, in the coordinates of the view that asked.
struct FoldDivision: Equatable {
    enum Axis: Equatable {
        /// The crease runs across the display: one pane above it, one below.
        case horizontal
        /// The crease runs up and down: one pane to its left, one to its right.
        case vertical
    }

    var axis: Axis
    var frame: CGRect

    /// Where the crease starts and ends along the direction that matters (y for a horizontal crease, x for a vertical one).
    var start: CGFloat { axis == .horizontal ? frame.minY : frame.minX }
    var end: CGFloat { axis == .horizontal ? frame.maxY : frame.maxX }
    var thickness: CGFloat { end - start }
}

enum FoldGeometry {
    /// The fold, while the display is partly folded. Nil when it is fully open or closed, and everywhere except an
    /// iPhone Duo (and always on the Mac).
    ///
    /// For testing without folding the simulator, set the `iDexedFakeFold` default to `horizontal` or `vertical`.
    static func division(in proxy: GeometryProxy) -> FoldDivision? {
        #if os(iOS)
        if let fake = UserDefaults.standard.string(forKey: "iDexedFakeFold") {
            let size = proxy.size
            switch fake {
            case "horizontal": return FoldDivision(axis: .horizontal, frame: CGRect(x: 0, y: size.height * 0.5 - 10, width: size.width, height: 20))
            case "vertical": return FoldDivision(axis: .vertical, frame: CGRect(x: size.width * 0.5 - 10, y: 0, width: 20, height: size.height))
            default: break
            }
        }
        if #available(iOS 27.1, *) {
            for region in proxy.reservedRegions(kind: .division) where region.isActive {
                let f = region.frame
                return FoldDivision(axis: f.width >= f.height ? .horizontal : .vertical, frame: f)
            }
        }
        #endif
        return nil
    }
}

/// A developer aid: draws the fold region and the camera and status regions the system reports, and the safe-area insets
/// (set the `iDexedFoldDebug` default to true).
struct FoldDebugOverlay: View {
    var fold: FoldDivision?
    var proxy: GeometryProxy

    private var occlusions: [CGRect] {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .occlusion, options: [.includeInactive]).map(\.frame)
        }
        #endif
        return []
    }

    var body: some View {
        if UserDefaults.standard.bool(forKey: "iDexedFoldDebug") {
            let boxes = occlusions
            ZStack(alignment: .topLeading) {
                if let fold {
                    Rectangle().fill(Color.red.opacity(0.35))
                        .frame(width: fold.frame.width, height: fold.frame.height)
                        .offset(x: fold.frame.minX, y: fold.frame.minY)
                }
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, f in
                    Rectangle().stroke(Color.yellow, lineWidth: 2)
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                }
                let i = proxy.safeAreaInsets
                let text = "size \(Int(proxy.size.width))x\(Int(proxy.size.height)) insets l\(Int(i.leading)) t\(Int(i.top)) r\(Int(i.trailing)) b\(Int(i.bottom))\n"
                    + (boxes.isEmpty ? "no occlusions" : boxes.map { "occl \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: "\n"))
                    + "\n" + (fold.map { "fold \($0.axis) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "no fold")
                Text(text).font(.caption2.monospaced()).padding(4).background(.black.opacity(0.75)).foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Tells the app about an iPhone Duo's hinge: whether the phone is closed (so the outer display is in use), and whether there is
/// a hinge at all. Does nothing on other devices and on the Mac.
struct HingeObserver: ViewModifier {
    @Binding var closed: Bool
    @Binding var hasHinge: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                closed = new.hinge?.status == .closed
                hasHinge = new.hinge != nil
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    /// For testing without closing the simulator: set the `iDexedFakeFold` default to `closed`.
    static var fakeClosed: Bool {
        #if os(iOS)
        UserDefaults.standard.string(forKey: "iDexedFakeFold") == "closed"
        #else
        false
        #endif
    }
}
