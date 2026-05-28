import AppKit
import SwiftUI

/// Owns the settings window. Opening one is an "activation dance" for an
/// accessory-policy app: the panel must be closed first (the dropdown
/// would otherwise float above the new window and steal clicks), then the
/// app activates itself ignoring others, then the window orders forward.
/// On close, we drop back to accessory behavior — there's no explicit
/// deactivation; AppKit handles it once no key window remains.
@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let onWillOpen: () -> Void
    private var window: NSWindow?

    init(settings: SettingsStore, onWillOpen: @escaping () -> Void) {
        self.settings = settings
        self.onWillOpen = onWillOpen
    }

    func show() {
        onWillOpen()    // tell the panel controller to dismiss its dropdown

        if window == nil {
            let host = NSHostingController(
                rootView: SettingsView().environmentObject(settings)
            )
            let w = NSWindow(contentViewController: host)
            w.title = "sys-monitor — Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
