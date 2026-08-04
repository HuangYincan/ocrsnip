import AppKit
import Vision
import Carbon
import UserNotifications

// MARK: - HotKey constants

/// HotKey signature — "OCR" in ASCII
private let hotKeySig: UInt32 = 0x4F4352

/// Default global hotkey: ⌘⇧2
private let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_2)
private let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)

/// Global pointer: the C callback needs to reach our app instance
private var activeApp: OCRApp?

/// Carbon event handler — fires on hotkey press
private func hotKeyPressed(
    _: EventHandlerCallRef?,
    _: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    activeApp?.captureAndOCR()
    return noErr
}

// MARK: - Main App

class OCRApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    // ── Config (override before calling app.run() if you want custom keys) ──
    var hotKeyCode: UInt32 = defaultKeyCode
    var hotKeyModifiers: UInt32 = defaultModifiers
    // ─────────────────────────────────────────────────────────────────────────

    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?

    // ── App Lifecycle ────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_: Notification) {
        activeApp = self
        NSApp.setActivationPolicy(.accessory)           // no dock icon

        // Request notification permissions (macOS 10.14+)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Menu‑bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "📷"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "截图 OCR（⌘⇧2）",
                     action: #selector(captureAndOCR),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // Edit hotkey helper
        menu.addItem(withTitle: "打开 Quick Action 编辑快捷键…",
                     action: #selector(showBindingsHelp),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出",
                     action: #selector(quitApp),
                     keyEquivalent: "q")
        statusItem.menu = menu

        registerGlobalHotKey()
    }

    // MARK: - HotKey Registration

    private func registerGlobalHotKey() {
        var hotKey: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySig, id: 1)
        let status = RegisterEventHotKey(
            hotKeyCode,
            hotKeyModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &hotKey
        )
        if status != noErr {
            print("⚠️  HotKey registration failed (error \(status))")
        }
        hotKeyRef = hotKey

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyPressed,
            1,
            &eventSpec,
            nil,
            nil
        )
    }

    // MARK: - Capture + OCR

    @objc func captureAndOCR() {
        let tmp = "/tmp/ocrsnip.png"

        // 1. Interactive region selection via macOS built‑in screencapture
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", tmp]

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            print("⚠️  screencapture failed: \(error.localizedDescription)")
            cleanUp(tmp)
            return
        }

        guard proc.terminationStatus == 0,
              let image = NSImage(contentsOfFile: tmp) else {
            // User pressed Escape; nothing to do
            cleanUp(tmp)
            return
        }

        // 2. Convert to CGImage for Vision framework
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            cleanUp(tmp)
            return
        }

        // 3. Vision OCR
        let request = VNRecognizeTextRequest { [weak self] request, error in
            defer { self?.cleanUp(tmp) }

            if let error = error {
                self?.sendNotification(title: "⚠️ OCR 失败", body: error.localizedDescription)
                return
            }

            let text = request.results?
                .compactMap { $0 as? VNRecognizedTextObservation }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            guard let text = text, !text.isEmpty else {
                self?.sendNotification(title: "⚠️ 未识别到文字", body: "")
                return
            }

            // 4. Copy to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            // 5. Notification
            self?.sendNotification(title: "✓ OCR 完成",
                                   body: text.truncated(80))
        }
        request.recognitionLevel       = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages   = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }

    // MARK: - Helper Methods

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func showBindingsHelp() {
        let alert = NSAlert()
        alert.messageText = "自定义快捷键"
        alert.informativeText = """
        当前绑定: ⌘⇧2

        如需更改,请打开系统设置 → 键盘 → 键盘快捷键,
        找到 "App 快捷键" → 添加 → 选择 ocrsnip,
        填入菜单名 "截图 OCR" 和你的快捷键即可。

        或者修改源码中 defaultKeyCode / defaultModifiers 的值。
        """
        alert.runModal()
    }

    @objc private func quitApp() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - String helpers

private extension String {
    func truncated(_ max: Int) -> String {
        count <= max ? self : prefix(max) + "…"
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = OCRApp()
app.delegate = delegate
activeApp = delegate
// Remove parse-as-library trick: this IS top-level code, which is correct for main.swift
app.run()