import Foundation
import ServiceManagement

/// Wraps SMAppService so the rest of the app can ask:
///   - is Echo set to start at login?
///   - flip it on/off.
///
/// SMAppService.mainApp is the modern API (macOS 13+) and uses the .app bundle's
/// own identifier, no helper bundle needed.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Human-readable label for the current state.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "Not enabled"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Awaiting approval in System Settings"
        case .notFound: return "Not available"
        @unknown default: return "Unknown"
        }
    }
}
