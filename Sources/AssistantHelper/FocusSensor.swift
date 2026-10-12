import AppKit
import ApplicationServices
import AssistantCore

/// Reads the frontmost app (NSWorkspace, no permission) and its focused window title
/// (Accessibility) and reports each change as a focus Signal.
@MainActor
final class FocusSensor {
    private let onSignal: (Signal) -> Void
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?

    init(onSignal: @escaping (Signal) -> Void) {
        self.onSignal = onSignal
    }

    /// Whether window titles can be read. Asks macOS to show the Accessibility prompt once if not.
    static func requestAccessibility() -> Bool {
        // The value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe in Swift 6.
        let prompt = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        frontmostChanged()
    }

    private func frontmostChanged() {
        guard let running = NSWorkspace.shared.frontmostApplication else { return }
        observe(pid: running.processIdentifier)
        report()
    }

    private func report() {
        guard let running = NSWorkspace.shared.frontmostApplication else { return }
        let app = App(
            bundleID: running.bundleIdentifier ?? "pid.\(running.processIdentifier)",
            name: running.localizedName ?? "Unknown")
        onSignal(.focus(app: app, windowTitle: focusedWindowTitle()))
    }

    private func focusedWindowTitle() -> String? {
        guard let window = focusedWindow() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    private func focusedWindow() -> AXUIElement? {
        guard let observedApp else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(observedApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }

    // MARK: Accessibility observer

    private func observe(pid: pid_t) {
        stopObserving()
        observedApp = AXUIElementCreateApplication(pid)
        guard Self.hasAccessibility else { return }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let sensor = Unmanaged<FocusSensor>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { sensor.accessibilityNotified(name) }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created, let observedApp else { return }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, observedApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        watchFocusedWindowTitle()
    }

    private func watchFocusedWindowTitle() {
        guard let observer else { return }
        if let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
        }
        observedWindow = focusedWindow()
        if let observedWindow {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(observer, observedWindow, kAXTitleChangedNotification as CFString, refcon)
        }
    }

    private func accessibilityNotified(_ name: String) {
        if name == kAXFocusedWindowChangedNotification as String {
            watchFocusedWindowTitle()
        }
        report()
    }

    private func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedApp = nil
        observedWindow = nil
    }
}
