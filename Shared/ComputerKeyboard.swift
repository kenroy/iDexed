import SwiftUI

#if canImport(AppKit)
import AppKit
#else
import GameController
#endif

/// Plays notes from the computer / external keyboard, using the same layout as Dexed (JUCE's piano keys):
/// A W S E D F T G Y H U J K O L P ; = C … E (white keys on the home row, black keys above), Z / X = octave down / up.
/// Works app-wide without needing SwiftUI focus, and stays out of the way while typing in a text field.
@MainActor
final class ComputerKeyboard {
    var noteOn: (Int) -> Void = { _ in }
    var noteOff: (Int) -> Void = { _ in }
    var octave: () -> Int = { 4 }
    var shiftOctave: (Int) -> Void = { _ in }
    /// Left / right arrow keys: scroll the on-screen keyboard one octave, exactly like its arrow buttons.
    var scrollKeyboard: (Int) -> Void = { _ in }
    /// Set while a text field is being edited so typed letters aren't played.
    var isTypingText = false

    /// Physical key → note currently sounding, so releasing a key always ends the note it started
    /// even if the octave changed while it was held.
    private var held: [Int: Int] = [:]
    private var started = false

    func releaseAll() {
        for note in held.values { noteOff(note) }
        held.removeAll()
    }

    /// Returns true if the key is one we handle (so the caller can swallow it).
    @discardableResult
    private func key(id: Int, semitone: Int?, octaveStep: Int?, scrollStep: Int? = nil, pressed: Bool) -> Bool {
        guard semitone != nil || octaveStep != nil || scrollStep != nil else { return false }
        if pressed {
            if isTypingText { return false }
            if let step = scrollStep { scrollKeyboard(step); return true }
            if let step = octaveStep { shiftOctave(step); return true }
            if let semitone, held[id] == nil {
                let note = octave() * 12 + semitone
                guard (0...127).contains(note) else { return true }
                held[id] = note
                noteOn(note)
            }
            return true
        }
        if let note = held.removeValue(forKey: id) { noteOff(note); return true }
        return !isTypingText
    }

    func start() {
        guard !started else { return }
        started = true
        platformStart()
    }

    // MARK: - macOS

    #if canImport(AppKit)
    // Physical (ANSI) key codes, so the layout stays a piano on non-QWERTY keyboards too.
    private static let semitones: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11,
        40: 12, 31: 13, 37: 14, 35: 15, 41: 16,
    ]
    private var monitor: Any?

    private func platformStart() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            // Pull out plain values first: NSEvent itself can't cross into the main-actor closure.
            let info = KeyInfo(
                pressed: event.type == .keyDown, keyCode: event.keyCode, isRepeat: event.type == .keyDown && event.isARepeat,
                hasShortcutModifier: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                inPanelOrSheet: event.window is NSPanel || event.window?.attachedSheet != nil,
                editingText: event.window?.firstResponder is NSText)
            let handled = MainActor.assumeIsolated { self.handle(info) }
            return handled ? nil : event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
    }

    private struct KeyInfo: Sendable {
        var pressed: Bool
        var keyCode: UInt16
        var isRepeat: Bool
        var hasShortcutModifier: Bool
        var inPanelOrSheet: Bool
        var editingText: Bool
    }

    private func handle(_ k: KeyInfo) -> Bool {
        let step: Int? = k.keyCode == 6 ? -1 : k.keyCode == 7 ? 1 : nil
        let scroll: Int? = k.keyCode == 123 ? -1 : k.keyCode == 124 ? 1 : nil     // ← →
        let semitone = Self.semitones[k.keyCode]
        if k.pressed {
            // Leave shortcuts, sheets/panels and text editing alone.
            if k.hasShortcutModifier || k.inPanelOrSheet || k.editingText { return false }
            if k.isRepeat {
                // Holding an arrow keeps scrolling; other repeats are swallowed so notes don't retrigger.
                if let scroll { scrollKeyboard(scroll) }
                return semitone != nil || step != nil || scroll != nil
            }
        }
        return key(id: Int(k.keyCode), semitone: semitone, octaveStep: step, scrollStep: scroll, pressed: k.pressed)
    }

    // MARK: - iOS / iPadOS (hardware keyboard)

    #else
    private static let semitones: [GCKeyCode: Int] = [
        .keyA: 0, .keyW: 1, .keyS: 2, .keyE: 3, .keyD: 4, .keyF: 5, .keyT: 6, .keyG: 7, .keyY: 8, .keyH: 9,
        .keyU: 10, .keyJ: 11, .keyK: 12, .keyO: 13, .keyL: 14, .keyP: 15, .semicolon: 16,
    ]

    private func platformStart() {
        attach(GCKeyboard.coalesced)
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach(GCKeyboard.coalesced) }
        }
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
    }

    private func attach(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] input, _, code, pressed in
            let modifiers: [GCKeyCode] = [.leftGUI, .rightGUI, .leftControl, .rightControl, .leftAlt, .rightAlt]
            let hasModifier = modifiers.contains { input.button(forKeyCode: $0)?.isPressed == true }
            MainActor.assumeIsolated {
                guard let self else { return }
                if pressed && hasModifier { return }
                let step: Int? = code == .keyZ ? -1 : code == .keyX ? 1 : nil
                let scroll: Int? = code == .leftArrow ? -1 : code == .rightArrow ? 1 : nil
                self.key(id: code.rawValue, semitone: Self.semitones[code], octaveStep: step, scrollStep: scroll, pressed: pressed)
            }
        }
    }
    #endif
}
