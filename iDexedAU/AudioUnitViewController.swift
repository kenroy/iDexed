import CoreAudioKit
import DexedKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Entry point of the AUv3 extension: creates the instrument and hosts the same SwiftUI editor the app uses.
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    /// The host may create the audio unit on any thread, before or after the view loads.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        private var unit: DexedAudioUnit?
        func set(_ u: DexedAudioUnit) { lock.lock(); unit = u; lock.unlock() }
        func get() -> DexedAudioUnit? { lock.lock(); defer { lock.unlock() }; return unit }
    }
    private nonisolated let box = Box()
    private var editorAttached = false

    public nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try DexedAudioUnit(componentDescription: componentDescription, options: [])
        Self.loadDefaultBank(into: unit.session)
        box.set(unit)
        Task { @MainActor in self.attachEditorIfPossible() }
        return unit
    }

    /// A new instance starts on the first Dexed factory bank instead of 32 empty voices, so there are real sounds (and host
    /// presets) straight away. A saved project replaces this when the host restores its state, which happens after creation.
    private nonisolated static func loadDefaultBank(into session: HostedSession) {
        let banks = FactoryBanks.all
        guard let bank = banks.first(where: { $0.name.hasPrefix("Dexed") }) ?? banks.first,
              let data = try? Data(contentsOf: bank.url),
              let cartridge = try? Cartridge(sysex: data) else { return }
        var settings = session.settings
        settings.bank = cartridge
        settings.bankName = bank.name
        settings.program = 0
        settings.patch = cartridge.patch(at: 0)
        session.apply(settings)
    }

    #if canImport(AppKit)
    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        preferredContentSize = NSSize(width: 900, height: 640)
        attachEditorIfPossible()
    }
    #else
    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 900, height: 640)
        attachEditorIfPossible()
    }
    #endif

    private func attachEditorIfPossible() {
        guard !editorAttached, isViewLoaded, let unit = box.get() else { return }
        editorAttached = true
        let engine = SynthEngine(hosted: unit.session)
        let root = ContentView().environment(engine)

        #if canImport(AppKit)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #else
        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        #endif
    }
}
