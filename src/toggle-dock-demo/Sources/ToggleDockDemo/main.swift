import AppKit
import ApplicationServices
import ServiceManagement

private enum WindowToggleMode: String {
    case allWindows
    case currentWindow

    static var selected: WindowToggleMode {
        WindowToggleMode(rawValue: UserDefaults.standard.string(forKey: "windowToggleMode") ?? "") ?? .allWindows
    }

    var title: String { self == .allWindows ? "全部窗口" : "当前窗口" }
}

private enum DesktopClickAction {
    static var minimizesAllWindows: Bool {
        UserDefaults.standard.bool(forKey: "desktopClickMinimizesAllWindows")
    }
}

private enum DesktopClickSystemConfiguration {
    static func setWallpaperClickToStageManagerOnly() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.WindowManager", "EnableStandardClickToShowDesktop", "-bool", "false"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MacWin",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "无法自动更新 macOS 的墙纸点击设置。"]
            )
        }
    }
}

private enum DesktopWidgetSystemConfiguration {
    enum Visibility: String {
        case hidden
        case visible
        case unset
    }

    private static let domain = "com.apple.WindowManager"
    private static let key = "StandardHideWidgets"

    static func currentVisibility() throws -> Visibility {
        let (status, output, errorOutput) = try runDefaults(["read", domain, key])
        guard status == 0 else {
            if errorOutput.localizedCaseInsensitiveContains("does not exist") {
                return .unset
            }
            throw configurationError("无法读取 macOS 的桌面小组件显示设置。")
        }

        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true": return .hidden
        case "0", "false": return .visible
        default: throw configurationError("macOS 返回了无法识别的桌面小组件显示设置。")
        }
    }

    static func hideDesktopWidgets() throws {
        try requireSuccess(["write", domain, key, "-bool", "true"], message: "无法临时隐藏桌面小组件。")
    }

    static func restoreDesktopWidgets(to visibility: Visibility) throws {
        switch visibility {
        case .hidden:
            try requireSuccess(["write", domain, key, "-bool", "true"], message: "无法恢复桌面小组件显示设置。")
        case .visible:
            try requireSuccess(["write", domain, key, "-bool", "false"], message: "无法恢复桌面小组件显示设置。")
        case .unset:
            try requireSuccess(["delete", domain, key], message: "无法恢复桌面小组件显示设置。")
        }
    }

    private static func requireSuccess(_ arguments: [String], message: String) throws {
        let (status, _, _) = try runDefaults(arguments)
        guard status == 0 else { throw configurationError(message) }
    }

    private static func runDefaults(_ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let standardOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let standardError = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, standardOutput, standardError)
    }

    private static func configurationError(_ message: String) -> NSError {
        NSError(domain: "MacWin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum RecordingPrivacyMode {
    private static let activeKey = "recordingPrivacyModeActive"
    private static let previousWidgetVisibilityKey = "recordingPrivacyPreviousWidgetVisibility"

    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }

    static var previousWidgetVisibility: DesktopWidgetSystemConfiguration.Visibility? {
        guard let value = UserDefaults.standard.string(forKey: previousWidgetVisibilityKey) else { return nil }
        return DesktopWidgetSystemConfiguration.Visibility(rawValue: value)
    }

    static func begin(with previousWidgetVisibility: DesktopWidgetSystemConfiguration.Visibility) {
        UserDefaults.standard.set(previousWidgetVisibility.rawValue, forKey: previousWidgetVisibilityKey)
        UserDefaults.standard.set(true, forKey: activeKey)
    }

    static func end() {
        UserDefaults.standard.removeObject(forKey: previousWidgetVisibilityKey)
        UserDefaults.standard.set(false, forKey: activeKey)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recordingPrivacyMenuItem: NSMenuItem!
    private lazy var dockClickTracker = DockClickTracker(
        onDockClick: { application, wasFrontmost in
            ManagedWindows.toggle(application, wasFrontmost: wasFrontmost, mode: .selected)
        },
        onBlankDesktopClick: {
            ManagedWindows.minimizeAllWindows()
        }
    )
    private lazy var settingsController = SettingsWindowController { mode in
        UserDefaults.standard.set(mode.rawValue, forKey: "windowToggleMode")
        self.statusItem.button?.toolTip = "MacWin：\(mode.title)"
    } onOpenAccessibilitySettings: {}

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--restarted"),
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count > 1 {
            NSApp.terminate(nil)
            return
        }
        configureStatusItem()
        if !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "MacWin 需要辅助功能权限"
            alert.informativeText = "请在系统设置的“隐私与安全性 → 辅助功能”中启用 MacWin。授权完成后，请退出并重新打开 MacWin，Dock 点击功能才会生效。"
            alert.addButton(withTitle: "前往授权")
            alert.addButton(withTitle: "稍后设置")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        dockClickTracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockClickTracker.stop()
        restoreRecordingPrivacyModeIfNeeded()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showSettings() {
        settingsController.show()
    }

    @objc private func restart() {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundleURL.path, "--args", "--restarted"]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func toggleRecordingPrivacyMode() {
        if RecordingPrivacyMode.isActive {
            do {
                try restoreRecordingPrivacyMode()
            } catch {
                NSAlert(error: error).runModal()
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "进入录屏隐私模式？"
        alert.informativeText = "MacWin 将最小化可访问窗口，并临时隐藏所有桌面小组件。退出该模式或退出 MacWin 时，会恢复进入前的小组件显示状态；不会修改台前调度，也不会切换桌面空间。"
        alert.addButton(withTitle: "进入隐私模式")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let previousVisibility = try DesktopWidgetSystemConfiguration.currentVisibility()
            RecordingPrivacyMode.begin(with: previousVisibility)
            try DesktopWidgetSystemConfiguration.hideDesktopWidgets()
            ManagedWindows.minimizeAllWindows()
            updateRecordingPrivacyMenuItem()
        } catch {
            RecordingPrivacyMode.end()
            NSAlert(error: error).runModal()
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "全局窗口控制器")
        button.toolTip = "MacWin：\(WindowToggleMode.selected.title)"

        let menu = NSMenu()
        menu.addItem(withTitle: "MacWin 正在运行", action: nil, keyEquivalent: "")
        recordingPrivacyMenuItem = menu.addItem(withTitle: "", action: #selector(toggleRecordingPrivacyMode), keyEquivalent: "")
        updateRecordingPrivacyMenuItem()
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重启 MacWin", action: #selector(restart), keyEquivalent: "r")
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func updateRecordingPrivacyMenuItem() {
        recordingPrivacyMenuItem?.title = RecordingPrivacyMode.isActive ? "退出录屏隐私模式" : "进入录屏隐私模式…"
    }

    private func restoreRecordingPrivacyMode() throws {
        guard let previousVisibility = RecordingPrivacyMode.previousWidgetVisibility else {
            RecordingPrivacyMode.end()
            updateRecordingPrivacyMenuItem()
            return
        }
        try DesktopWidgetSystemConfiguration.restoreDesktopWidgets(to: previousVisibility)
        RecordingPrivacyMode.end()
        updateRecordingPrivacyMenuItem()
    }

    private func restoreRecordingPrivacyModeIfNeeded() {
        guard RecordingPrivacyMode.isActive else { return }
        try? restoreRecordingPrivacyMode()
    }
}

@MainActor
private final class SettingsWindowController: NSObject {
    private let window: NSWindow
    private let modeControl: NSSegmentedControl
    private let authorizationStatus = NSTextField(labelWithString: "")
    private let launchAtLogin = NSButton(checkboxWithTitle: "登录时自动启动 MacWin", target: nil, action: nil)
    private let desktopClickMinimizeAll = NSButton(checkboxWithTitle: "点击空白桌面时最小化所有窗口", target: nil, action: nil)
    private let onModeChange: (WindowToggleMode) -> Void
    private let onOpenAccessibilitySettings: () -> Void

    init(onModeChange: @escaping (WindowToggleMode) -> Void, onOpenAccessibilitySettings: @escaping () -> Void) {
        self.onModeChange = onModeChange
        self.onOpenAccessibilitySettings = onOpenAccessibilitySettings
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        modeControl = NSSegmentedControl(labels: ["全部窗口", "当前窗口"], trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        window.title = "MacWin 设置"
        window.isReleasedWhenClosed = false
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)
        desktopClickMinimizeAll.target = self
        desktopClickMinimizeAll.action = #selector(desktopClickMinimizeAllChanged)

        let title = NSTextField(labelWithString: "窗口切换方式")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "全部窗口：呼出或最小化该应用的全部可访问窗口。\n当前窗口：只操作该应用当前正在使用的窗口。")
        description.textColor = .secondaryLabelColor
        let permissionTitle = NSTextField(labelWithString: "系统权限")
        permissionTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let permissionButton = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAccessibilitySettings))
        authorizationStatus.textColor = .secondaryLabelColor
        let desktopClickDescription = NSTextField(wrappingLabelWithString: "仅在左键点击空白墙纸时生效，不影响桌面图标、窗口、Dock 或右键。启用时 MacWin 会先征得确认，再自动将“显示桌面”设为“仅在台前调度时点按”；台前调度状态不会被修改。")
        desktopClickDescription.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: "窗口模式和开机启动设置会立即保存。")
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, modeControl, description, desktopClickMinimizeAll, desktopClickDescription, permissionTitle, authorizationStatus, permissionButton, launchAtLogin, hint])
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
        authorizationStatus.stringValue = AXIsProcessTrusted() ? "辅助功能权限：已授权" : "辅助功能权限：未授权，请开启后重新打开 MacWin。"
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        desktopClickMinimizeAll.state = DesktopClickAction.minimizesAllWindows ? .on : .off
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func modeChanged() {
        onModeChange(modeControl.selectedSegment == 1 ? .currentWindow : .allWindows)
    }

    @objc private func openAccessibilitySettings() {
        onOpenAccessibilitySettings()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func desktopClickMinimizeAllChanged() {
        guard desktopClickMinimizeAll.state == .on else {
            UserDefaults.standard.set(false, forKey: "desktopClickMinimizesAllWindows")
            return
        }

        let alert = NSAlert()
        alert.messageText = "自动配置墙纸点击行为？"
        alert.informativeText = "MacWin 将把“系统设置 → 桌面与程序坞 → 显示桌面”改为“仅在台前调度时点按”，以避免空白桌面点击与 macOS 原生显示桌面冲突。不会修改台前调度的开关。"
        alert.addButton(withTitle: "自动设置并启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            desktopClickMinimizeAll.state = .off
            return
        }

        do {
            try DesktopClickSystemConfiguration.setWallpaperClickToStageManagerOnly()
            UserDefaults.standard.set(true, forKey: "desktopClickMinimizesAllWindows")
        } catch {
            desktopClickMinimizeAll.state = .off
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .warning
            errorAlert.messageText = "无法自动配置墙纸点击行为"
            errorAlert.informativeText = "请在“系统设置 → 桌面与程序坞 → 显示桌面”手动选择“仅在台前调度时点按”。"
            errorAlert.addButton(withTitle: "打开系统设置")
            errorAlert.addButton(withTitle: "取消")
            if errorAlert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        }
    }

    @objc private func launchAtLoginChanged() {
        do {
            if launchAtLogin.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

private final class DockClickTracker {
    private let onDockClick: @MainActor @Sendable (NSRunningApplication, Bool) -> Void
    private let onBlankDesktopClick: @MainActor @Sendable () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressesMouseUp = false

    init(
        onDockClick: @escaping @MainActor @Sendable (NSRunningApplication, Bool) -> Void,
        onBlankDesktopClick: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onDockClick = onDockClick
        self.onBlankDesktopClick = onBlankDesktopClick
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
        if let application = tracker.dockApplication(at: event.location),
           ManagedWindows.canToggle(application) {
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

        guard tracker.isBlankDesktopClick(at: event.location) else {
            return Unmanaged.passUnretained(event)
        }
        tracker.suppressesMouseUp = true
        tracker.publishDiagnostic(state: "desktop-handled", target: nil)
        let action = tracker.onBlankDesktopClick
        Task { @MainActor in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastDesktopClickTimestamp")
            action()
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

    private func isBlankDesktopClick(at location: CGPoint) -> Bool {
        guard DesktopClickAction.minimizesAllWindows,
              !hasWindow(at: location),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }

        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(location.x),
            Float(location.y),
            &element
        ) == .success, let element else { return false }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == finder.processIdentifier else { return false }

        return !isDesktopIcon(element)
    }

    private func hasWindow(at location: CGPoint) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        return windowInfo.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame.contains(location)
        }
    }

    private func isDesktopIcon(_ element: AXUIElement) -> Bool {
        var elementInPath: AXUIElement? = element
        for _ in 0..<5 {
            guard let current = elementInPath else { return false }
            if let role = stringAttribute(of: current, named: kAXRoleAttribute),
               role == kAXButtonRole || role == kAXImageRole {
                return true
            }
            elementInPath = parent(of: current)
        }
        return false
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

    static func minimizeAllWindows() {
        NSWorkspace.shared.runningApplications.forEach { application in
            guard canToggle(application) else { return }
            windows(of: application)
                .filter(isMinimizable)
                .filter { !isMinimized($0) }
                .forEach { _ = setMinimized($0, to: true) }
        }
    }

    private static func toggleAllWindows(_ application: NSRunningApplication, windows: [AXUIElement], wasFrontmost: Bool) {
        if wasFrontmost, windows.contains(where: { !isMinimized($0) }) {
            windows.forEach { _ = setMinimized($0, to: true) }
            return
        }
        application.unhide()
        windows.forEach { _ = setMinimized($0, to: false) }
        _ = application.activate(options: [.activateAllWindows])
        raise(windows.first(where: { !isMinimized($0) }))
    }

    private static func toggleCurrentWindow(_ application: NSRunningApplication, windows: [AXUIElement], wasFrontmost: Bool) {
        let window = focusedWindow(of: application, among: windows)
            ?? windows.first(where: { !isMinimized($0) })
            ?? windows.first!
        if wasFrontmost, !isMinimized(window) {
            _ = setMinimized(window, to: true)
            return
        }
        application.unhide()
        _ = setMinimized(window, to: false)
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

    private static func setMinimized(_ window: AXUIElement, to minimized: Bool) -> Bool {
        guard isMinimizable(window) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
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
