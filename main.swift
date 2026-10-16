import AppKit
import Carbon
import UserNotifications
import ScreenCaptureKit
import ApplicationServices

// MARK: - HotKey constants

/// HotKey signature — "OCR" in ASCII
private let hotKeySig: UInt32 = 0x4F4352

/// Default global hotkeys: ⌘⇧2 for OCR, ⌘⇧3 for pinned screenshots.
/// ⌘⇧3 is intercepted with a session event tap because macOS reserves it
/// for the built-in full-screen screenshot action.
private let ocrKeyCode: UInt32 = UInt32(kVK_ANSI_2)
private let screenshotKeyCode: UInt32 = UInt32(kVK_ANSI_3)
private let escapeKeyCode: UInt16 = UInt16(kVK_Escape)
private let defaultKeyModifiers: UInt32 = UInt32(cmdKey | shiftKey)

private enum HotKeyID: UInt32 {
    case ocr = 1
    case pinnedScreenshot = 2
}

/// Global pointer: the C callback needs to reach our app instance
private var activeApp: OCRApp?
private var screenshotEventTap: CFMachPort?
private var screenshotEventTapSource: CFRunLoopSource?
private var suppressScreenshotKeyUp = false

private func appHotKey(for event: CGEvent) -> AppHotKey? {
    let flags = event.flags
    return HotKeyMatch.match(
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        command: flags.contains(.maskCommand),
        shift: flags.contains(.maskShift),
        control: flags.contains(.maskControl),
        option: flags.contains(.maskAlternate)
    )
}

/// Session event tap callback. Returning nil consumes ⌘⇧3 before macOS's
/// built-in full-screen screenshot shortcut can play its shutter sound.
/// ⌘⇧2 is left for Carbon RegisterEventHotKey so OCR still works if the
/// tap is installed but not actually receiving keys.
private func screenshotEventTapCallback(
    _: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let screenshotEventTap {
            CGEvent.tapEnable(tap: screenshotEventTap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    case .keyDown:
        guard appHotKey(for: event) == .pinnedScreenshot else {
            return Unmanaged.passUnretained(event)
        }

        suppressScreenshotKeyUp = true
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async {
                activeApp?.captureAndPinScreenshot()
            }
        }
        return nil
    case .keyUp:
        guard suppressScreenshotKeyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(screenshotKeyCode) else {
            return Unmanaged.passUnretained(event)
        }
        suppressScreenshotKeyUp = false
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

/// Carbon event handler — routes each global hotkey to its action
private func hotKeyPressed(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let app = activeApp else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else {
        return status
    }

    switch hotKeyID.id {
    case HotKeyID.ocr.rawValue:
        app.captureAndOCR()
    case HotKeyID.pinnedScreenshot.rawValue:
        app.captureAndPinScreenshot()
    default:
        break
    }
    return noErr
}

// MARK: - Pinned screenshot window

/// An image view that lets the user move the screenshot window anywhere on screen
/// and zoom with the scroll wheel while the pointer is over it.
private final class PinnedScreenshotView: NSImageView {
    private var dragStartLocation: NSPoint?
    private var windowStartOrigin: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        applyZoom(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if PinnedScreenshotInteraction.shouldDismiss(clickCount: event.clickCount) {
            window?.close()
            return
        }
        guard let window else { return }
        dragStartLocation = NSEvent.mouseLocation
        windowStartOrigin = window.frame.origin
        window.makeKeyAndOrderFront(nil)
    }

    override func mouseDragged(with _: NSEvent) {
        guard let dragStartLocation,
              let windowStartOrigin,
              let window else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let delta = NSPoint(
            x: currentLocation.x - dragStartLocation.x,
            y: currentLocation.y - dragStartLocation.y
        )
        window.setFrameOrigin(NSPoint(
            x: windowStartOrigin.x + delta.x,
            y: windowStartOrigin.y + delta.y
        ))
    }

    override func mouseUp(with _: NSEvent) {
        dragStartLocation = nil
        windowStartOrigin = nil
    }

    override func keyDown(with event: NSEvent) {
        // Escape dismisses this pinned screenshot without affecting the source app.
        if event.keyCode == escapeKeyCode {
            window?.close()
            return
        }
        super.keyDown(with: event)
    }

    private func applyZoom(with event: NSEvent) {
        guard let window else { return }
        let isMomentum = !event.momentumPhase.isEmpty
        guard PinnedScreenshotZoom.shouldApply(
            isMomentum: isMomentum,
            deltaY: event.scrollingDeltaY
        ) else {
            return
        }

        let factor = PinnedScreenshotZoom.scaleFactor(
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let newFrame = PinnedScreenshotZoom.scaledFrame(
            current: window.frame,
            factor: factor,
            anchorInWindow: event.locationInWindow,
            maxSize: visible.size
        )
        window.setFrame(newFrame, display: true)
    }
}

private final class PinnedScreenshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == escapeKeyCode {
            close()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Region selection overlay

@MainActor
private final class ScreenRegionSelector {
    private var overlayWindows: [ScreenRegionSelectionWindow] = []
    private var selectionViews: [ScreenRegionSelectionView] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var keyMonitor: Any?
    private var didPushCursor = false
    private var previousActivationPolicy: NSApplication.ActivationPolicy = .accessory
    private var desktopFrame: CGRect = .null
    private var startScreenPoint: CGPoint?
    private var currentScreenPoint: CGPoint?

    static func selectRegion() async -> CGRect? {
        let selector = ScreenRegionSelector()
        return await selector.select()
    }

    private func select() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlay()
        }
    }

    private func presentOverlay() {
        desktopFrame = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) { partial, frame in
            partial = partial.union(frame)
        }
        guard !desktopFrame.isNull, !desktopFrame.isEmpty else {
            finish(with: nil)
            return
        }

        previousActivationPolicy = NSApp.activationPolicy()
        for screen in NSScreen.screens {
            let window = ScreenRegionSelectionWindow(frame: screen.frame)
            let view = ScreenRegionSelectionView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                screenFrame: screen.frame
            )
            view.coordinator = self
            window.contentView = view
            overlayWindows.append(window)
            selectionViews.append(view)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in overlayWindows {
            window.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let focused = overlayWindows.first { $0.frame.contains(mouse) } ?? overlayWindows.first
        focused?.makeKeyAndOrderFront(nil)
        focused?.makeFirstResponder(focused?.contentView)
        NSCursor.crosshair.push()
        didPushCursor = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == escapeKeyCode else { return event }
            self?.finish(with: nil)
            return nil
        }
    }

    private func finish(with rect: CGRect?) {
        guard let continuation else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
        selectionViews.removeAll()
        NSApp.setActivationPolicy(previousActivationPolicy)
        self.continuation = nil
        continuation.resume(returning: rect)
    }

    fileprivate func regionDragBegan(atScreenPoint point: CGPoint) {
        let clamped = clampToDesktop(point)
        startScreenPoint = clamped
        currentScreenPoint = clamped
        publishSelection()
    }

    fileprivate func regionDragChanged(atScreenPoint point: CGPoint) {
        currentScreenPoint = clampToDesktop(point)
        publishSelection()
    }

    fileprivate func regionDragEnded(atScreenPoint point: CGPoint) {
        currentScreenPoint = clampToDesktop(point)
        publishSelection()
        guard let selection = selectionRect,
              selection.width >= 4,
              selection.height >= 4 else {
            finish(with: nil)
            return
        }
        finish(with: selection)
    }

    fileprivate func regionSelectionCancelled() {
        finish(with: nil)
    }

    private func publishSelection() {
        let rect = selectionRect
        for view in selectionViews {
            view.setGlobalSelection(rect)
        }
    }

    private var selectionRect: CGRect? {
        guard let startScreenPoint, let currentScreenPoint else { return nil }
        return CGRect(
            x: min(startScreenPoint.x, currentScreenPoint.x),
            y: min(startScreenPoint.y, currentScreenPoint.y),
            width: abs(startScreenPoint.x - currentScreenPoint.x),
            height: abs(startScreenPoint.y - currentScreenPoint.y)
        )
    }

    private func clampToDesktop(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, desktopFrame.minX), desktopFrame.maxX),
            y: min(max(point.y, desktopFrame.minY), desktopFrame.maxY)
        )
    }
}

private final class ScreenRegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        // Fully clear windows click through on macOS. A tiny alpha fill keeps
        // the overlay invisible enough while still receiving mouse events.
        backgroundColor = NSColor.black.withAlphaComponent(0.01)
        ignoresMouseEvents = false
        hasShadow = false
        level = .screenSaver
        sharingType = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        isReleasedWhenClosed = false
    }
}

@MainActor
private final class ScreenRegionSelectionView: NSView {
    weak var coordinator: ScreenRegionSelector?
    private let screenFrame: CGRect
    private var selectionInView: CGRect?

    init(frame: CGRect, screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.regionDragBegan(atScreenPoint: screenPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.regionDragChanged(atScreenPoint: screenPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.regionDragEnded(atScreenPoint: screenPoint(for: event))
    }

    override func rightMouseDown(with _: NSEvent) {
        coordinator?.regionSelectionCancelled()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == escapeKeyCode {
            coordinator?.regionSelectionCancelled()
            return
        }
        super.keyDown(with: event)
    }

    func setGlobalSelection(_ rect: CGRect?) {
        let old = selectionInView
        let new = localSelection(from: rect)
        selectionInView = new
        let pad: CGFloat = 3
        let dirty = (old ?? .null).union(new ?? .null).insetBy(dx: -pad, dy: -pad)
        if dirty.isNull || dirty.isEmpty {
            return
        }
        setNeedsDisplay(dirty.intersection(bounds))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        dirtyRect.fill()

        guard let hole = selectionInView, !hole.isEmpty else { return }
        let visible = hole.intersection(dirtyRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        visible.fill(using: .copy)

        let borderPath = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        borderPath.stroke()
    }

    private func localSelection(from global: CGRect?) -> CGRect? {
        guard let global else { return nil }
        let local = CGRect(
            x: global.minX - screenFrame.minX,
            y: global.minY - screenFrame.minY,
            width: global.width,
            height: global.height
        )
        let clipped = local.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }
        return clipped
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
    }
}

private enum CaptureSound {
    private static let shutter: NSSound? = {
        let paths = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
        ]
        for path in paths {
            if let sound = NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true) {
                return sound
            }
        }
        return NSSound(named: "Glass")
    }()

    static func playShutter() {
        shutter?.stop()
        shutter?.currentTime = 0
        shutter?.play()
    }
}

private enum ScreenCaptureError: LocalizedError {
    case missingImage

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "ScreenCaptureKit 未返回图像"
        }
    }
}

// MARK: - Main App

class OCRApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!
    private var appUpdater: AppUpdater!
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var pinnedWindows: [PinnedScreenshotWindow] = []
    private var isCapturingRegion = false
    private var isRunningOCR = false
    private var appToRestoreAfterCapture: NSRunningApplication?
    private static let maxPinnedWindowCount = 8
    private static let statusNotificationID = "ocrsnip.status"

    // ── App Lifecycle ────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_: Notification) {
        activeApp = self
        NSApp.setActivationPolicy(.accessory)           // no dock icon

        // Request notification permissions (macOS 10.14+)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Menu-bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "📷"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "截图 OCR（⌘⇧2）",
                     action: #selector(captureAndOCR),
                     keyEquivalent: "")
        menu.addItem(withTitle: "框选截图并置顶（⌘⇧3）",
                     action: #selector(captureAndPinScreenshot),
                     keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部置顶截图",
                     action: #selector(closeAllPinnedScreenshots),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let launchItem = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLoginItem = launchItem
        syncLaunchAtLoginMenuItem()
        menu.addItem(launchItem)
        menu.addItem(withTitle: "打开 Quick Action 编辑快捷键…",
                     action: #selector(showBindingsHelp),
                     keyEquivalent: "")
        menu.addItem(.separator())
        appUpdater = AppUpdater()
        appUpdater.addMenuItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出",
                     action: #selector(quitApp),
                     keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu

        registerGlobalHotKeys()
    }

    func applicationWillTerminate(_: Notification) {
        closeAllPinnedScreenshots()
        unregisterGlobalHotKeys()
    }

    // MARK: - HotKey Registration

    private func registerGlobalHotKeys() {
        let tapRegistered = registerScreenshotEventTap()
        var registrations: [(keyCode: UInt32, id: HotKeyID, label: String)] = [
            (ocrKeyCode, .ocr, "⌘⇧2")
        ]
        if !tapRegistered {
            registrations.append((screenshotKeyCode, .pinnedScreenshot, "⌘⇧3"))
        }

        for registration in registrations {
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: hotKeySig, id: registration.id.rawValue)
            let status = RegisterEventHotKey(
                registration.keyCode,
                defaultKeyModifiers,
                id,
                GetEventDispatcherTarget(),
                0,
                &hotKey
            )
            if status != noErr {
                print("⚠️  HotKey \(registration.label) registration failed (error \(status))")
            } else if let hotKey {
                hotKeyRefs.append(hotKey)
            }
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyPressed,
            1,
            &eventSpec,
            nil,
            nil
        )
        if status != noErr {
            print("⚠️  HotKey event handler installation failed (error \(status))")
        }
    }

    @discardableResult
    private func registerScreenshotEventTap() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            print("⚠️  Hotkey event tap unavailable; grant ocrsnip Accessibility access")
            return false
        }

        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: screenshotEventTapCallback,
            userInfo: nil
        ) else {
            print("⚠️  Hotkey event tap unavailable; grant ocrsnip Accessibility access or disable macOS's built-in ⌘⇧3 shortcut")
            return false
        }

        screenshotEventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            screenshotEventTap = nil
            print("⚠️  ⌘⇧3 event tap run loop source creation failed")
            return false
        }
        screenshotEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func unregisterScreenshotEventTap() {
        if let source = screenshotEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            screenshotEventTapSource = nil
        }
        if let tap = screenshotEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            screenshotEventTap = nil
        }
        suppressScreenshotKeyUp = false
    }

    private func unregisterGlobalHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        unregisterScreenshotEventTap()
    }

    // MARK: - Capture

    @objc func captureAndOCR() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isRunningOCR, !self.isCapturingRegion else { return }
            self.isRunningOCR = true
            defer { self.isRunningOCR = false }
            guard let image = await self.captureRegionImage() else {
                self.restorePreviousApp()
                return
            }
            self.restorePreviousApp()
            self.statusItem.button?.title = "⏳"
            defer { self.statusItem.button?.title = "📷" }
            await self.recognizeText(in: image)
        }
    }

    @objc func captureAndPinScreenshot() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isCapturingRegion else { return }
            guard let image = await self.captureRegionImage() else {
                self.restorePreviousApp()
                return
            }
            self.appToRestoreAfterCapture = nil
            self.evictOldestPinnedWindowsIfNeeded()
            let window = self.makePinnedScreenshotWindow(for: image)
            self.pinnedWindows.append(window)
            window.delegate = self
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
            CaptureSound.playShutter()
        }
    }

    @MainActor
    private func captureRegionImage() async -> NSImage? {
        guard !isCapturingRegion else { return nil }
        isCapturingRegion = true
        defer { isCapturingRegion = false }
        appToRestoreAfterCapture = NSWorkspace.shared.frontmostApplication

        // A changed signing identity can invalidate an existing TCC grant.
        // captureImage(in:) may still return a blank/redacted image, so do not
        // treat a non-nil image as proof that Screen Recording is authorized.
        guard CGPreflightScreenCaptureAccess() else {
            appToRestoreAfterCapture = nil
            showScreenRecordingPermissionAlert()
            return nil
        }

        switch ScreenCaptureStrategy.preferred() {
        case .nativeRegionSelection:
            if #available(macOS 15.2, *) {
                return await captureWithNativeRegionSelection()
            }
            return await captureWithLegacyScreencapture()
        case .legacyScreencaptureCLI:
            return await captureWithLegacyScreencapture()
        }
    }

    @MainActor
    private func showScreenRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = """
        ocrsnip 当前无法读取屏幕内容，已停止截图。

        首次使用请点击「请求授权」。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制（或屏幕录制）」中允许 ocrsnip，然后完全退出并重新打开，再次按快捷键截图。

        更新或重新签名后，旧授权可能失效。若开关已经打开，请先关闭再开启；仍无效时，移除旧条目，再添加 Applications 中的 ocrsnip。
        """
        alert.addButton(withTitle: "请求授权")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Only request on an explicit click. The caller ends this capture
            // attempt even if access is granted, so no overlay covers the OS UI.
            _ = CGRequestScreenCaptureAccess()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    @available(macOS 15.2, *)
    @MainActor
    private func captureWithNativeRegionSelection() async -> NSImage? {
        do {
            var snapshots = try await captureDisplaySnapshots()
            defer { snapshots.removeAll() }
            guard let rect = await ScreenRegionSelector.selectRegion() else {
                return nil
            }
            guard let cropped = cropSnapshot(snapshots, cocoaRect: rect) else {
                sendNotification(title: "⚠️ 截图失败", body: "无法裁剪所选区域")
                return nil
            }
            snapshots.removeAll()
            return NSImage(cgImage: cropped, size: rect.size)
        } catch {
            sendNotification(title: "⚠️ 截图失败", body: Self.screenCaptureErrorMessage(error))
            return nil
        }
    }

    private struct DisplaySnapshot {
        var cocoaFrame: CGRect
        var image: CGImage
    }

    @available(macOS 15.2, *)
    private func captureDisplaySnapshots() async throws -> [DisplaySnapshot] {
        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        var snapshots: [DisplaySnapshot] = []
        snapshots.reserveCapacity(NSScreen.screens.count)
        for screen in NSScreen.screens {
            let image = try await captureScreenImage(in: screen.frame, primaryFrame: primaryFrame)
            snapshots.append(DisplaySnapshot(cocoaFrame: screen.frame, image: image))
        }
        guard !snapshots.isEmpty else {
            throw ScreenCaptureError.missingImage
        }
        return snapshots
    }

    private func cropSnapshot(_ snapshots: [DisplaySnapshot], cocoaRect: CGRect) -> CGImage? {
        let pieces: [(image: CGImage, cocoaRect: CGRect)] = snapshots.compactMap { snap in
            let intersection = snap.cocoaFrame.intersection(cocoaRect)
            guard !intersection.isNull,
                  intersection.width >= 1,
                  intersection.height >= 1,
                  let image = ScreenSnapshotCrop.crop(
                      snap.image,
                      cocoaRect: cocoaRect,
                      screenCocoaFrame: snap.cocoaFrame
                  ) else {
                return nil
            }
            return (image, intersection)
        }
        return ScreenSnapshotCrop.composite(pieces: pieces, canvasCocoa: cocoaRect)
    }

    @available(macOS 15.2, *)
    private func captureScreenImage(in rect: CGRect, primaryFrame: CGRect) async throws -> CGImage {
        let quartzRect = ScreenCaptureGeometry.quartzScreenRect(
            fromCocoa: rect,
            primaryFrame: primaryFrame
        )
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: quartzRect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: ScreenCaptureError.missingImage)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    @MainActor
    private func captureWithLegacyScreencapture() async -> NSImage? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocrsnip-\(UUID().uuidString).png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Both capture backends stay silent; each caller signals completion.
        proc.arguments = ["-i", "-x", path.path]

        let ran: Bool = await withCheckedContinuation { continuation in
            proc.terminationHandler = { _ in
                continuation.resume(returning: true)
            }
            do {
                try proc.run()
            } catch {
                print("⚠️  screencapture failed: \(error.localizedDescription)")
                continuation.resume(returning: false)
            }
        }
        defer { cleanUp(path) }
        guard ran, proc.terminationStatus == 0,
              let data = try? Data(contentsOf: path),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    @MainActor
    private func recognizeText(in image: NSImage) async {
        guard let cgImage = OCRClipboard.cgImage(from: image) else {
            sendNotification(title: "⚠️ OCR 失败", body: "无法读取截图")
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            OCRClipboard.recognize(cgImage)
        }.value

        switch result {
        case .text(let text):
            guard await OCRClipboard.copyToPasteboard(text) else {
                sendNotification(title: "⚠️ 无法写入剪贴板", body: "已重试 3 次，仍未能确认文字写入，请重新截图")
                return
            }
            CaptureSound.playShutter()
            sendNotification(title: "✓ OCR 完成", body: "文字已复制到剪贴板")
        case .empty:
            sendNotification(title: "⚠️ 未识别到文字", body: "请框选更清晰的文字区域后再试")
        case .failed:
            sendNotification(title: "⚠️ OCR 失败", body: "识别过程出错，请重试")
        }
    }

    private static func screenCaptureErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.code == -3801 || nsError.code == 3801 {
            return "请在系统设置 → 隐私与安全性 → 屏幕录制中允许 ocrsnip，然后完全退出并重新打开。"
        }
        return error.localizedDescription
    }

    private func makePinnedScreenshotWindow(for image: NSImage) -> PinnedScreenshotWindow {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let availableFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)

        let imageSize = image.size
        let scale = min(
            1,
            availableFrame.width / max(imageSize.width, 1),
            availableFrame.height / max(imageSize.height, 1)
        )
        let windowSize = NSSize(
            width: max(1, imageSize.width * scale),
            height: max(1, imageSize.height * scale)
        )
        let origin = NSPoint(
            x: availableFrame.midX - windowSize.width / 2,
            y: availableFrame.midY - windowSize.height / 2
        )

        let window = PinnedScreenshotWindow(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let imageView = PinnedScreenshotView(frame: NSRect(origin: .zero, size: windowSize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        return window
    }

    // MARK: - Helper Methods

    private func restorePreviousApp() {
        let app = appToRestoreAfterCapture
        appToRestoreAfterCapture = nil
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        app.activate()
    }

    private func evictOldestPinnedWindowsIfNeeded() {
        while pinnedWindows.count >= Self.maxPinnedWindowCount {
            let oldest = pinnedWindows.removeFirst()
            oldest.close()
        }
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @objc private func closeAllPinnedScreenshots() {
        let windows = pinnedWindows
        pinnedWindows.removeAll()
        windows.forEach { $0.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? PinnedScreenshotWindow else {
            return
        }
        pinnedWindows.removeAll { $0 === window }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body

        let request = UNNotificationRequest(
            identifier: Self.statusNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func menuNeedsUpdate(_: NSMenu) {
        syncLaunchAtLoginMenuItem()
    }

    private func syncLaunchAtLoginMenuItem() {
        launchAtLoginItem.state = LaunchAtLogin.menuChecked(LaunchAtLogin.current()) ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = !LaunchAtLogin.menuChecked(LaunchAtLogin.current())
        do {
            let status = try LaunchAtLogin.setEnabled(enable)
            sender.state = LaunchAtLogin.menuChecked(status) ? .on : .off
            if LaunchAtLogin.shouldOpenLoginItemsSettings(enable: enable, status: status) {
                LaunchAtLogin.openLoginItemsSettings()
            }
            if let message = LaunchAtLogin.notification(enable: enable, status: status) {
                sendNotification(title: message.title, body: message.body)
            }
        } catch {
            sender.state = LaunchAtLogin.menuChecked(LaunchAtLogin.current()) ? .on : .off
            sendNotification(title: "⚠️ 无法设置开机自启", body: error.localizedDescription)
        }
    }

    @objc private func showBindingsHelp() {
        let alert = NSAlert()
        alert.messageText = "快捷键"
        alert.informativeText = """
        当前绑定:
        · 截图 OCR：⌘⇧2
        · 框选截图并置顶：⌘⇧3

        如需更改，请打开系统设置 → 键盘 → 键盘快捷键，
        找到“App 快捷键” → 添加 → 选择 ocrsnip，
        填入对应菜单名和你的快捷键即可。

        如果 ⌘⇧2 / ⌘⇧3 没有响应，请在系统设置 → 隐私与安全性 → 辅助功能
        中允许 ocrsnip，然后完全退出再打开。

        ⌘⇧3 若仍弹出系统截图，请在系统设置 → 键盘 → 键盘快捷键 → 截图中，
        关闭系统自带的“全屏幕截图”快捷键。

        或者修改源码中的 keyCode / defaultKeyModifiers 值。
        """
        alert.runModal()
    }

    @objc private func quitApp() {
        closeAllPinnedScreenshots()
        unregisterGlobalHotKeys()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = OCRApp()
app.delegate = delegate
activeApp = delegate
// Remove parse-as-library trick: this IS top-level code, which is correct for main.swift
app.run()
