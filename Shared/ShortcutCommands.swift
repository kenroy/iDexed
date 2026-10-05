import SwiftUI
import DexedKit

/// What the Mac menu shortcuts can do to the focused window.
struct ShortcutActions {
    var toggleOperator: (Int) -> Void
    var focusOperator: (Int) -> Void
    var show: (Tab) -> Void
}

private struct ShortcutActionsKey: FocusedValueKey { typealias Value = ShortcutActions }

extension FocusedValues {
    var shortcutActions: ShortcutActions? {
        get { self[ShortcutActionsKey.self] }
        set { self[ShortcutActionsKey.self] = newValue }
    }
}

/// Dexed's shortcuts: ⌃⇧1–6 toggle an operator, ⌃1–6 jump to it, ⌃G / ⌃P / ⌃L switch sections.
struct ShortcutCommands: Commands {
    @FocusedValue(\.shortcutActions) private var actions

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Global Parameters") { actions?.show(.voice) }
                .keyboardShortcut("g", modifiers: .control)
            Button("Operator Parameters") { actions?.show(.operators) }
                .keyboardShortcut("p", modifiers: .control)
            Button("Cartridge Manager") { actions?.show(.bank) }
                .keyboardShortcut("l", modifiers: .control)
            Divider()
            ForEach(1...6, id: \.self) { op in
                Button("Show Operator \(op)") { actions?.focusOperator(op) }
                    .keyboardShortcut(KeyEquivalent(Character("\(op)")), modifiers: .control)
            }
            Divider()
            ForEach(1...6, id: \.self) { op in
                Button("Toggle Operator \(op)") { actions?.toggleOperator(op) }
                    .keyboardShortcut(KeyEquivalent(Character("\(op)")), modifiers: [.control, .shift])
            }
        }
    }
}
