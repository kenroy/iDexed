import SwiftUI
import DexedKit

@main
struct iDexedApp: App {
    /// Created after the first frame, so the splash is on screen while the audio engine and MIDI start up.
    @State private var engine: SynthEngine?

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let engine {
                    ContentView()
                        .environment(engine)
                        .transition(.opacity)
                } else {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: engine == nil)
            .task { await start() }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 640)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 860)
        .commands { ShortcutCommands() }
        #endif
    }

    private func start() async {
        guard engine == nil else { return }
        let began = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(60))      // let the splash render first
        let created = SynthEngine()
        loadDefaultBank(into: created)
        // Hold the splash long enough for the operators to finish wiring up.
        let remaining = Duration.milliseconds(1900) - (ContinuousClock.now - began)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
        engine = created
    }

    private func loadDefaultBank(into engine: SynthEngine) {
        guard engine.bankName == "Init Bank",
              let first = FactoryBanks.all.first(where: { $0.name.hasPrefix("Dexed") }) ?? FactoryBanks.all.first,
              let data = try? Data(contentsOf: first.url) else { return }
        try? engine.importSysEx(data, name: first.name)
    }
}

/// Shown while the synth engine starts: the six operators drop into place, wire up to the output and the sixth gets its
/// feedback loop. Matches the launch screen colour so there's no flash between the two.
private struct SplashView: View {
    @State private var appeared = false

    private let tile: CGFloat = 46
    private let gap: CGFloat = 14

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 26) {
                Text("iDexed")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.lcd)
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .background(Theme.lcdBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: appeared)

                operators
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { appeared = true }
    }

    private var operators: some View {
        let width = tile * 6 + gap * 5
        return ZStack(alignment: .topLeading) {
            // Output bus under the row, drawn left to right once the operators have landed.
            Path { p in
                let y = tile + 16
                p.move(to: CGPoint(x: tile / 2, y: y))
                p.addLine(to: CGPoint(x: width - tile / 2, y: y))
                for i in 0..<6 {
                    let x = tile / 2 + CGFloat(i) * (tile + gap)
                    p.move(to: CGPoint(x: x, y: tile)); p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .trim(from: 0, to: appeared ? 1 : 0)
            .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .animation(.easeInOut(duration: 0.7).delay(0.9), value: appeared)

            // Feedback loop around operator 6.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .trim(from: 0, to: appeared ? 1 : 0)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: tile + 10, height: tile + 10)
                .offset(x: width - tile - 5, y: -5)
                .animation(.easeInOut(duration: 0.5).delay(1.4), value: appeared)

            ForEach(1...6, id: \.self) { op in
                Text("\(op)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(width: tile, height: tile)
                    .background(Theme.operatorColor(op), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .offset(x: CGFloat(op - 1) * (tile + gap), y: appeared ? 0 : -40)
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.2 + Double(op) * 0.1), value: appeared)
            }
        }
        .frame(width: width, height: tile + 20, alignment: .topLeading)
    }
}
