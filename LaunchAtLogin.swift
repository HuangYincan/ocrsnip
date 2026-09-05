import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginAction: Equatable {
    case none
    case register
    case unregister
}

enum LaunchAtLogin {
    static func status(from serviceStatus: SMAppService.Status) -> LaunchAtLoginStatus {
        switch serviceStatus {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        case .notRegistered:
            return .disabled
        @unknown default:
            return .unavailable
        }
    }

    static func current() -> LaunchAtLoginStatus {
        status(from: SMAppService.mainApp.status)
    }

    /// Checkmark is on when the user asked for login launch, including the
    /// pending-approval state in System Settings.
    static func menuChecked(_ status: LaunchAtLoginStatus) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    static func action(enable: Bool, current: LaunchAtLoginStatus) -> LaunchAtLoginAction {
        if enable {
            switch current {
            case .enabled, .requiresApproval:
                return .none
            case .disabled, .unavailable:
                return .register
            }
        }
        switch current {
        case .disabled:
            return .none
        case .enabled, .requiresApproval, .unavailable:
            return .unregister
        }
    }

    static func shouldOpenLoginItemsSettings(enable: Bool, status: LaunchAtLoginStatus) -> Bool {
        enable && status == .requiresApproval
    }

    static func notification(
        enable: Bool,
        status: LaunchAtLoginStatus
    ) -> (title: String, body: String)? {
        guard enable else { return nil }
        switch status {
        case .requiresApproval:
            return (
                "⚠️ 开机自启待授权",
                "已打开系统设置，请在「通用 → 登录项」中允许 ocrsnip。"
            )
        case .unavailable:
            return (
                "⚠️ 无法开机自启",
                "请将 ocrsnip.app 放到「应用程序」文件夹后再试。"
            )
        case .enabled, .disabled:
            return nil
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        switch action(enable: enabled, current: current()) {
        case .none:
            break
        case .register:
            try SMAppService.mainApp.register()
        case .unregister:
            try SMAppService.mainApp.unregister()
        }
        return current()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
