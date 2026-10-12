import AppKit
import ApplicationServices
import AssistantCore

/// Reads the frontmost app (NSWorkspace, no permission) and its focused window title
/// (Accessibility) and reports each change as an activeWindow Signal.
@MainActor
final class ActiveWindowSensor: SignalSource {
    private var deliver: ((Signal) -> Void)?
    private let browser = BrowserURLReader()
    /// Bumped on every report, so a slow URL read can't overwrite a newer window.
    private var reportNumber = 0
    private var activationToken: NSObjectProtocol?
    private var permissionTimer: Timer?

    private var frontmost: NSRunningApplication?
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?

    /// Whether window titles can be read. Asks macOS to show the Accessibility prompt once if not.
    static func requestAccessibility() -> Bool {
        // The value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe in Swift 6.
        let prompt = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    func start(delivering deliver: @escaping (Signal) -> Void) {
        guard activationToken == nil else { return }
        self.deliver = deliver
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostChanged(to: app) }
        }
        if !Self.hasAccessibility { waitForAccessibility() }
        frontmostChanged(to: NSWorkspace.shared.frontmostApplication)
    }

    /// Titles start flowing as soon as Dara grants Accessibility, without needing an app switch.
    private func waitForAccessibility() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.hasAccessibility else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.frontmostChanged(to: self.frontmost)
            }
        }
    }

    private func frontmostChanged(to app: NSRunningApplication?) {
        // The helper's own panels (quick-add, alerts) are never what Dara is working on.
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        frontmost = app
        observe(pid: app.processIdentifier)
        report()
    }

    private func report() {
        guard let frontmost, let deliver else { return }
        let app = App(
            bundleID: frontmost.bundleIdentifier ?? "pid.\(frontmost.processIdentifier)",
            name: frontmost.localizedName ?? "Unknown")
        let title = focusedWindowTitle()
        guard browser.reads(app.bundleID) else {
            return deliver(.activeWindow(app: app, windowTitle: title))
        }
        // Re-read on every report: switching tabs changes the window title, which triggers one.
        reportNumber += 1
        let number = reportNumber
        browser.url(ofFrontTabIn: app.bundleID) { [weak self] url in
            guard let self, number == reportNumber else { return }
            deliver(.activeWindow(app: app, windowTitle: title, url: url))
        }
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

    // The observer's refcon is unretained: the helper keeps this sensor alive for its whole run,
    // and stopObserving() removes every registration before the observer is released.
    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func observe(pid: pid_t) {
        stopObserving()
        observedApp = AXUIElementCreateApplication(pid)
        guard Self.hasAccessibility else { return }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let sensor = Unmanaged<ActiveWindowSensor>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { sensor.accessibilityNotified(name) }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created, let observedApp else { return }
        observer = created
        AXObserverAddNotification(created, observedApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        // Common modes, so titles keep updating while the dropdown is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        watchFocusedWindowTitle()
    }

    private func watchFocusedWindowTitle() {
        guard let observer else { return }
        if let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
        }
        observedWindow = focusedWindow()
        if let observedWindow {
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
            if let observedWindow {
                AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
            }
            if let observedApp {
                AXObserverRemoveNotification(observer, observedApp, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedApp = nil
        observedWindow = nil
    }
}
