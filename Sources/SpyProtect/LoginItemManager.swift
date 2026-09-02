import Foundation
import ServiceManagement

/// Registers SpyProtect to launch automatically at login, via SMAppService - the
/// modern (macOS 13+) replacement for the old SMLoginItemSetEnabled/helper-tool dance.
/// Works directly off the main app bundle, no separate launcher target needed.
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("SpyProtect: failed to \(enabled ? "enable" : "disable") login item: \(error)")
        }
    }
}
