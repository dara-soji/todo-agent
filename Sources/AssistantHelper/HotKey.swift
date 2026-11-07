import Carbon.HIToolbox

/// A system-wide shortcut (⌥Space for quick-add) via Carbon hot keys, which need no permission.
/// Reports both press and release, so the caller can tell a tap from a hold.
@MainActor
final class HotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let pressed: () -> Void
    private let released: () -> Void
    /// False when another app already owns the shortcut.
    private(set) var isRegistered = false

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey,
         pressed: @escaping () -> Void, released: @escaping () -> Void = {}) {
        self.pressed = pressed
        self.released = released
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            MainActor.assumeIsolated { isRelease ? hotKey.released() : hotKey.pressed() }
            return noErr
        }
        // Unretained: the helper keeps this HotKey for its whole run.
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), callback, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5444_4F41), id: 1)  // 'TDOA'
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
        isRegistered = installed == noErr && registered == noErr
        if !isRegistered {
            // Usually another app owns the shortcut; Add task… in the menu still works.
            NSLog("TodoAgent: couldn't register the quick-add shortcut (\(installed), \(registered))")
        }
    }
}
