import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey (default ⌥⌘M) that toggles the panel from any
/// app. Uses Carbon's `RegisterEventHotKey` — the one hotkey mechanism that
/// needs NO Accessibility permission (a CGEventTap or a global NSEvent monitor
/// both do), which keeps the app zero-permission for its core function.
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) { self.onFire = onFire }

    /// Install the handler and register the key. Default ⌥⌘M. Carbon hot-key
    /// events arrive on the main run loop, so firing is already main-thread.
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_M),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { me.onFire() }   // already on the main thread
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        let id = EventHotKeyID(signature: OSType(0x53_4D_4B_31 /* 'SMK1' */), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
