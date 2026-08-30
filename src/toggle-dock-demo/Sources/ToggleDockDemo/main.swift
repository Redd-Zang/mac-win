import AppKit
import ApplicationServices

private enum WindowToggleMode: String {
    case allWindows
    case currentWindow

    static var selected: WindowToggleMode {
        WindowToggleMode(rawValue: UserDefaults.standard.string(forKey: "windowToggleMode") ?? "") ?? .allWindows
    }

    var title: String { self == .allWindows ? "全部窗口" : "当前窗口" }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private lazy var dockClickTracker = DockClickTracker { application, wasFrontmost in
        ManagedWindows.toggle(application, wasFrontmost: wasFrontmost, mode: .selected)
    }
    private lazy var settingsController = SettingsWindowController { mode in
        UserDefaults.standard.set(mode.rawValue, forKey: "windowToggleMode")
        self.statusItem.button?.toolTip = "Universal Dock Toggle：\(mode.title)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        dockClickTracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockClickTracker.stop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showSettings() {
        settingsController.show()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "全局窗口控制器")
        button.toolTip = "Universal Dock Toggle：\(WindowToggleMode.selected.title)"

        let menu = NSMenu()
        menu.addItem(withTitle: "Universal Dock Toggle 正在运行", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }
}

@MainActor
private final class SettingsWindowController: NSObject {
    private let window: NSWindow
    private let modeControl: NSSegmentedControl
    private let onModeChange: (WindowToggleMode) -> Void

    init(onModeChange: @escaping (WindowToggleMode) -> Void) {
        self.onModeChange = onModeChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 235), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        modeControl = NSSegmentedControl(labels: ["全部窗口", "当前窗口"], trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        window.title = "Universal Dock Toggle 设置"
        window.isReleasedWhenClosed = false
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        let title = NSTextField(labelWithString: "窗口切换方式")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "全部窗口：呼出或最小化该应用的全部可访问窗口。\n当前窗口：只操作该应用当前正在使用的窗口。")
        description.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: "选择会立即保存。")
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, modeControl, description, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(stack)
        window.contentView = contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24)
        ])
    }

    func show() {
        modeControl.selectedSegment = WindowToggleMode.selected == .allWindows ? 0 : 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func modeChanged() {
        onModeChange(modeControl.selectedSegment == 1 ? .currentWindow : .allWindows)
    }
}

private final class DockClickTracker {
    private let onDockClick: @MainActor @Sendable (NSRunningApplication, Bool) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressesMouseUp = false

    init(onDockClick: @escaping @MainActor @Sendable (NSRunningApplication, Bool) -> Void) {
        self.onDockClick = onDockClick
    }

    func start() {
        guard AXIsProcessTrusted(), eventTap == nil else { return }

        let eventMask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.handleEvent,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            publishDiagnostic(state: "event-tap-unavailable", target: nil)
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        publishDiagnostic(state: "listening", target: nil)
    }

    func stop() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        runLoopSource = nil
    }

    private static let handleEvent: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let tracker = Unmanaged<DockClickTracker>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tracker.reenableEventTap()
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, tracker.suppressesMouseUp {
            tracker.suppressesMouseUp = false
            return nil
        }

        guard type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }
        guard let application = tracker.dockApplication(at: event.location),
              ManagedWindows.canToggle(application) else {
            return Unmanaged.passUnretained(event)
        }

        tracker.suppressesMouseUp = true
        tracker.publishDiagnostic(state: "handled", target: application)
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
        let action = tracker.onDockClick
        Task { @MainActor in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastDockClickTimestamp")
            UserDefaults.standard.set(application.bundleIdentifier, forKey: "lastDockClickBundleIdentifier")
            action(application, wasFrontmost)
        }
        return nil
    }

    private func dockApplication(at location: CGPoint) -> NSRunningApplication? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateApplication(dock.processIdentifier),
            Float(location.x),
            Float(location.y),
            &element
        ) == .success, let element else { return nil }

        var elementInPath: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = elementInPath else { return nil }
            if let application = application(for: current) {
                return application
            }
            elementInPath = parent(of: current)
        }
        return nil
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(of element: AXUIElement, named attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    private func urlAttribute(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? URL
    }

    private func application(for element: AXUIElement) -> NSRunningApplication? {
        let runningApplications = NSWorkspace.shared.runningApplications
        if let url = urlAttribute(of: element) {
            let path = url.standardizedFileURL.path
            if let application = runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                return application
            }
        }
        guard let title = stringAttribute(of: element, named: kAXTitleAttribute) else { return nil }
        let name = Self.normalized(title)
        return runningApplications.first { Self.normalized($0.localizedName ?? "") == name }
    }

    private func publishDiagnostic(state: String, target: NSRunningApplication?) {
        var value: [String: Any] = ["state": state]
        if let target {
            value["bundleIdentifier"] = target.bundleIdentifier ?? ""
            value["name"] = target.localizedName ?? ""
        }
        UserDefaults.standard.set(value, forKey: "dockClickTrackerDiagnostic")
    }

    private func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        publishDiagnostic(state: "event-tap-reenabled", target: nil)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

}

private enum ManagedWindows {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.loginwindow"
    ]

    static func canToggle(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier,
              !excludedBundleIdentifiers.contains(bundleIdentifier),
              !application.isTerminated else { return false }
        if bundleIdentifier == finderBundleIdentifier { return true }
        return !windows(of: application).isEmpty
    }

    static func toggle(_ application: NSRunningApplication, wasFrontmost: Bool, mode: WindowToggleMode) {
        let windows = windows(of: application)
        let manageableWindows = windows.filter(isMinimizable)
        guard !manageableWindows.isEmpty else {
            if application.bundleIdentifier == finderBundleIdentifier { openFinderDesktop() }
            return
        }

        switch mode {
        case .allWindows:
            toggleAllWindows(application, windows: manageableWindows, wasFrontmost: wasFrontmost)
        case .currentWindow:
            toggleCurrentWindow(application, windows: manageableWindows, wasFrontmost: wasFrontmost)
        }
    }

    private static func toggleAllWindows(_ application: NSRunningApplication, windows: [AXUIElement], wasFrontmost: Bool) {
        if wasFrontmost, windows.contains(where: { !isMinimized($0) }) {
            windows.forEach { setMinimized($0, to: true) }
            return
        }
        application.unhide()
        windows.forEach { setMinimized($0, to: false) }
        _ = application.activate(options: [.activateAllWindows])
        raise(windows.first(where: { !isMinimized($0) }))
    }

    private static func toggleCurrentWindow(_ application: NSRunningApplication, windows: [AXUIElement], wasFrontmost: Bool) {
        let window = focusedWindow(of: application, among: windows)
            ?? windows.first(where: { !isMinimized($0) })
            ?? windows.first!
        if wasFrontmost, !isMinimized(window) {
            setMinimized(window, to: true)
            return
        }
        application.unhide()
        setMinimized(window, to: false)
        _ = application.activate(options: [.activateAllWindows])
        raise(window)
    }

    private static func openFinderDesktop() {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        NSWorkspace.shared.open(desktopURL)
    }

    private static func focusedWindow(of application: NSRunningApplication, among windows: [AXUIElement]) -> AXUIElement? {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        let focusedWindow = unsafeDowncast(value, to: AXUIElement.self)
        return windows.first { CFEqual($0, focusedWindow) }
    }

    private static func raise(_ window: AXUIElement?) {
        guard let window else { return }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func windows(of application: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let value else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let value else { return false }
        return (value as? Bool) ?? false
    }

    private static func setMinimized(_ window: AXUIElement, to minimized: Bool) {
        guard isMinimizable(window) else { return }
        _ = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    private static func isMinimizable(_ window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

