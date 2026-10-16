import AppKit
import Sparkle

/// Sparkle owns scheduling, version comparison, signature validation and replacement.
/// Keep the controller alive for the lifetime of this menu-bar application.
@MainActor
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    func addMenuItems(to menu: NSMenu) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionItem = NSMenuItem(title: "ocrsnip \(version)", action: nil, keyEquivalent: "")
        menu.addItem(versionItem)

        let check = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        // Sparkle validates this item and disables it while a check is in flight.
        check.target = controller
        menu.addItem(check)

        let automatic = NSMenuItem(
            title: "自动检查更新",
            action: #selector(toggleAutomaticChecks(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        menu.addItem(automatic)
    }

    @objc private func toggleAutomaticChecks(_ sender: NSMenuItem) {
        let updater = controller.updater
        updater.automaticallyChecksForUpdates.toggle()
        sender.state = updater.automaticallyChecksForUpdates ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        return true
    }

    func standardUserDriverWillShowModalAlert() {
        // Accessory apps have no Dock window to bring the update alert forward.
        NSApp.activate(ignoringOtherApps: true)
    }
}
