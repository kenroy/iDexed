// Generates the iDexed app icon (standard, dark and tinted variants, plus a pre-masked macOS version).
//
//   swiftc -O -o /tmp/icongen Tools/IconGenerator/main.swift && /tmp/icongen <output-directory>
//
// The artwork mirrors the app's algorithm diagram: two modulator→carrier pairs (2→1 and 4→3) in the operator colours,
// with both carriers joined by the glowing output bus, and a line leaving box 4 to show it is modulated from above.
import SwiftUI
import AppKit

enum IconStyle { case standard, dark, tinted }

struct IconView: View {
    var style: IconStyle = .standard
    let size: CGFloat = 1024
    let box: CGFloat = 282
    let radius: CGFloat = 74
    let teal = Color(red: 0.36, green: 0.86, blue: 0.76)

    // Two pairs, balanced and centred.
    var colL: CGFloat { 512 - 188 }
    var colR: CGFloat { 512 + 188 }
    var rowTop: CGFloat { 338 }
    var rowBottom: CGFloat { rowTop + box + 62 }
    var busY: CGFloat { rowBottom + box / 2 + 74 }

    var accent: Color { style == .tinted ? .white : teal }

    var body: some View {
        ZStack {
            background
            Canvas { ctx, _ in
                let round = StrokeStyle(lineWidth: 24, lineCap: .round, lineJoin: .round)
                let lineOpacity: Double = style == .tinted ? 0.62 : 0.55

                var mods = Path()
                for x in [colL, colR] {
                    mods.move(to: CGPoint(x: x, y: rowTop + box / 2))
                    mods.addLine(to: CGPoint(x: x, y: rowBottom - box / 2))
                }
                ctx.stroke(mods, with: .color(.white.opacity(lineOpacity)), style: round)

                // A line leaving the top of box 4: it is modulated by something further up the chain.
                var stub = Path()
                let stubTop = rowTop - box / 2
                stub.move(to: CGPoint(x: colR, y: stubTop))
                stub.addLine(to: CGPoint(x: colR, y: stubTop - 120))
                ctx.stroke(stub,
                           with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(lineOpacity + 0.1)]),
                                                 startPoint: CGPoint(x: colR, y: stubTop - 120),
                                                 endPoint: CGPoint(x: colR, y: stubTop)),
                           style: round)

                // Output bus joining both carriers.
                var bus = Path()
                bus.move(to: CGPoint(x: colL, y: rowBottom + box / 2)); bus.addLine(to: CGPoint(x: colL, y: busY))
                bus.addLine(to: CGPoint(x: colR, y: busY)); bus.addLine(to: CGPoint(x: colR, y: rowBottom + box / 2))
                var glow = ctx
                glow.addFilter(.blur(radius: 22))
                glow.stroke(bus, with: .color(accent.opacity(style == .dark ? 0.75 : 0.9)),
                            style: StrokeStyle(lineWidth: 40, lineCap: .round, lineJoin: .round))
                ctx.stroke(bus, with: .color(accent), style: round)
            }

            operatorBox("2", hue: 0.09, gray: 0.74, x: colL, y: rowTop)
            operatorBox("4", hue: 0.42, gray: 0.88, x: colR, y: rowTop)
            operatorBox("1", hue: 0.02, gray: 0.58, x: colL, y: rowBottom)
            operatorBox("3", hue: 0.16, gray: 0.96, x: colR, y: rowBottom)

            rim
        }
        .frame(width: size, height: size)
    }

    var background: some View {
        ZStack {
            switch style {
            case .standard:
                LinearGradient(colors: [Color(red: 0.125, green: 0.135, blue: 0.157), Color(red: 0.045, green: 0.05, blue: 0.06)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [teal.opacity(0.30), .clear], center: UnitPoint(x: 0.5, y: 0.86), startRadius: 0, endRadius: 560)
            case .dark:
                LinearGradient(colors: [Color(red: 0.085, green: 0.092, blue: 0.108), Color(red: 0.02, green: 0.022, blue: 0.028)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [teal.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.86), startRadius: 0, endRadius: 560)
            case .tinted:
                LinearGradient(colors: [Color(white: 0.11), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.white.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.86), startRadius: 0, endRadius: 560)
            }
        }
    }

    /// A thin top-lit edge just inside the icon shape so it keeps its outline on dark wallpapers.
    var rim: some View {
        RoundedRectangle(cornerRadius: 228, style: .continuous)
            .inset(by: 3)
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(style == .dark ? 0.36 : 0.30), .white.opacity(0.10), .white.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 5)
    }

    func operatorBox(_ n: String, hue: Double, gray: Double, x: CGFloat, y: CGFloat) -> some View {
        let fill: Color
        switch style {
        case .standard: fill = Color(hue: hue, saturation: 0.62, brightness: 0.95)
        case .dark:     fill = Color(hue: hue, saturation: 0.58, brightness: 0.84)
        case .tinted:   fill = Color(white: gray)
        }
        return Text(n)
            .font(.system(size: 168, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.black.opacity(style == .tinted ? 0.88 : 0.78))
            .frame(width: box, height: box)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [fill, fill.opacity(0.84)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.30), lineWidth: 4))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
            .position(x: x, y: y)
    }
}

/// macOS does not round icons for you: a 824 pt squircle centred in the 1024 canvas, with a soft shadow.
struct MacIconView: View {
    var body: some View {
        ZStack {
            IconView(style: .standard)
                .scaleEffect(824 / 1024)
                .frame(width: 824, height: 824)
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .shadow(color: .black.opacity(0.38), radius: 18, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// `opaque` writes an RGB PNG with no alpha channel (required for iOS app icons); otherwise alpha is kept.
@MainActor func write<V: View>(_ view: V, to path: String, scale: CGFloat = 1, opaque: Bool = false) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { print("render failed: \(path)"); exit(1) }
    let rep: NSBitmapImageRep
    if opaque {
        // Flatten onto black in a context with no alpha channel.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { print("context failed: \(path)"); exit(1) }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(full)
        context.draw(cg, in: full)
        guard let flat = context.makeImage() else { print("flatten failed: \(path)"); exit(1) }
        rep = NSBitmapImageRep(cgImage: flat)
    } else {
        rep = NSBitmapImageRep(cgImage: cg)
    }
    guard let png = rep.representation(using: .png, properties: [:]) else { print("encode failed: \(path)"); exit(1) }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(cg.width)x\(cg.height)\(opaque ? ", no alpha" : ""))")
}

struct Masked: View {
    let style: IconStyle
    let side: CGFloat
    var body: some View {
        IconView(style: style).scaleEffect(side / 1024).frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
    }
}

/// How the three variants look on light, dark and tinted home screens (the tint is an approximation of iOS's).
struct Appearances: View {
    func row(_ bg: Color, _ style: IconStyle, tint: Color? = nil) -> some View {
        HStack(spacing: 40) {
            ForEach([240.0, 120.0, 60.0], id: \.self) { side in
                if let tint { Masked(style: style, side: side).colorMultiply(tint) } else { Masked(style: style, side: side) }
            }
        }
        .frame(width: 760, height: 320)
        .background(bg)
    }
    var body: some View {
        VStack(spacing: 0) {
            row(Color(red: 0.86, green: 0.88, blue: 0.92), .standard)
            row(Color(red: 0.03, green: 0.03, blue: 0.045), .dark)
            row(Color(red: 0.03, green: 0.03, blue: 0.045), .tinted, tint: Color(red: 0.55, green: 0.85, blue: 1.0))
        }
    }
}

guard CommandLine.arguments.count > 1 else { print("usage: icongen <output-directory>"); exit(2) }
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    write(IconView(style: .standard), to: "\(out)/AppIcon-1024.png", opaque: true)
    write(IconView(style: .dark), to: "\(out)/AppIcon-1024-dark.png", opaque: true)
    write(IconView(style: .tinted), to: "\(out)/AppIcon-1024-tinted.png", opaque: true)
    write(MacIconView(), to: "\(out)/AppIcon-mac-1024.png")
    write(Appearances(), to: "\(out)/preview-appearances.png")
}
