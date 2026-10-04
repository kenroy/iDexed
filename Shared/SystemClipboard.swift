import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Plain-text access to the system clipboard (the operator clipboard is plain text, like Dexed's).
enum SystemClipboard {
    static func text() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    static func set(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
