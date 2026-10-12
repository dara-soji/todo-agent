import Carbon.HIToolbox

/// A system-wide shortcut (⌥Space for quick-add) via Carbon hot keys, which need no permission.
@MainActor
final class HotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let pressed: () -> Void

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey, pressed: @escaping () -> Void) {
        self.pressed = pressed
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.pressed() }
            return noErr
        }
        // Unretained: the helper keeps this HotKey for its whole run.
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5444_4F41), id: 1)  // 'TDOA'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
