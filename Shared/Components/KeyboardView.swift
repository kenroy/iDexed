import SwiftUI

/// On-screen piano with true multi-touch on iOS/iPadOS and mouse input on macOS.
struct KeyboardView: View {
    var firstNote: Int          // must be a C
    var whiteKeyCount: Int
    var activeNotes: Set<Int>
    var onNoteOn: (Int, Int) -> Void
    var onNoteOff: (Int) -> Void

    private static let blackClasses: Set<Int> = [1, 3, 6, 8, 10]

    private struct Layout {
        var whites: [Int]
        var blacks: [(note: Int, x: CGFloat)]   // x as fraction of one white width
    }

    private var layout: Layout {
        var whites: [Int] = []
        var blacks: [(Int, CGFloat)] = []
        var n = firstNote
        while whites.count < whiteKeyCount && n <= 127 {
            if Self.blackClasses.contains(n % 12) { blacks.append((n, CGFloat(whites.count))) }
            else { whites.append(n) }
            n += 1
        }
        return Layout(whites: whites, blacks: blacks)
    }

    private let blackWidth: CGFloat = 0.62
    private let blackHeightFraction: CGFloat = 0.6

    var body: some View {
        let l = layout
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(l.whites.count)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(l.whites, id: \.self) { n in
                        Rectangle()
                            .fill(activeNotes.contains(n) ? Theme.accent : Color(white: 0.94))
                            .overlay(alignment: .bottom) {
                                if n % 12 == 0 {
                                    Text("C\(n / 12 - 2)").font(.caption2).foregroundStyle(.black.opacity(0.45)).padding(.bottom, 4)
                                }
                            }
                            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                    }
                }
                ForEach(l.blacks, id: \.note) { b in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(activeNotes.contains(b.note) ? Theme.accent : Color(white: 0.08))
                        .frame(width: w * blackWidth, height: geo.size.height * blackHeightFraction)
                        .offset(x: b.x * w - w * blackWidth / 2)
                        .shadow(radius: 1.5, y: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                KeyTouchSurface { point, size in
                    hit(point, size: size, layout: l)
                } noteOn: { n, v in onNoteOn(n, v) } noteOff: { n in onNoteOff(n) }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piano keyboard")
    }

    private func hit(_ p: CGPoint, size: CGSize, layout l: Layout) -> (note: Int, velocity: Int)? {
        guard size.width > 0, size.height > 0, p.x >= 0, p.x < size.width, p.y >= 0, p.y <= size.height else { return nil }
        let w = size.width / CGFloat(l.whites.count)
        let velocity = Int(70 + min(1, max(0, p.y / size.height)) * 57)
        if p.y < size.height * blackHeightFraction {
            for b in l.blacks {
                let x0 = b.x * w - w * blackWidth / 2
                if p.x >= x0 && p.x <= x0 + w * blackWidth { return (b.note, velocity) }
            }
        }
        let idx = min(l.whites.count - 1, Int(p.x / w))
        return (l.whites[idx], velocity)
    }
}

// MARK: - Platform touch surfaces

#if canImport(UIKit)
import UIKit

private struct KeyTouchSurface: UIViewRepresentable {
    var hit: (CGPoint, CGSize) -> (note: Int, velocity: Int)?
    var noteOn: (Int, Int) -> Void
    var noteOff: (Int) -> Void

    init(hit: @escaping (CGPoint, CGSize) -> (note: Int, velocity: Int)?,
         noteOn: @escaping (Int, Int) -> Void, noteOff: @escaping (Int) -> Void) {
        self.hit = hit; self.noteOn = noteOn; self.noteOff = noteOff
    }

    final class Surface: UIView {
        var hit: ((CGPoint, CGSize) -> (note: Int, velocity: Int)?)?
        var noteOn: ((Int, Int) -> Void)?
        var noteOff: ((Int) -> Void)?
        private var held: [UITouch: Int] = [:]

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { press(t) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                let h = hit?(t.location(in: self), bounds.size)
                if held[t] != h?.note {
                    release(t)
                    if h != nil { press(t) }
                }
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach(release) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach(release) }

        private func press(_ t: UITouch) {
            guard let h = hit?(t.location(in: self), bounds.size) else { return }
            held[t] = h.note
            noteOn?(h.note, h.velocity)
        }
        private func release(_ t: UITouch) {
            if let n = held.removeValue(forKey: t) { noteOff?(n) }
        }
    }

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ v: Surface, context: Context) {
        v.hit = hit; v.noteOn = noteOn; v.noteOff = noteOff
    }
}
#else
import AppKit

private struct KeyTouchSurface: NSViewRepresentable {
    var hit: (CGPoint, CGSize) -> (note: Int, velocity: Int)?
    var noteOn: (Int, Int) -> Void
    var noteOff: (Int) -> Void

    init(hit: @escaping (CGPoint, CGSize) -> (note: Int, velocity: Int)?,
         noteOn: @escaping (Int, Int) -> Void, noteOff: @escaping (Int) -> Void) {
        self.hit = hit; self.noteOn = noteOn; self.noteOff = noteOff
    }

    final class Surface: NSView {
        var hit: ((CGPoint, CGSize) -> (note: Int, velocity: Int)?)?
        var noteOn: ((Int, Int) -> Void)?
        var noteOff: ((Int) -> Void)?
        private var held: Int?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { press(event) }
        override func mouseDragged(with event: NSEvent) {
            let h = hit?(convert(event.locationInWindow, from: nil), bounds.size)
            if held != h?.note {
                release()
                if h != nil { press(event) }
            }
        }
        override func mouseUp(with event: NSEvent) { release() }

        private func press(_ e: NSEvent) {
            guard let h = hit?(convert(e.locationInWindow, from: nil), bounds.size) else { return }
            held = h.note
            noteOn?(h.note, h.velocity)
        }
        private func release() {
            if let n = held { noteOff?(n); held = nil }
        }
    }

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ v: Surface, context: Context) {
        v.hit = hit; v.noteOn = noteOn; v.noteOff = noteOff
    }
}
#endif
