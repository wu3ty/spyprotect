import Foundation

struct SecurityCheck: Identifiable {
    enum Status {
        case secure
        case warning
        /// Not reliably determinable from the command line without elevated privileges
        /// or parsing undocumented private plists - reported honestly rather than
        /// guessed, with instructions for a manual check.
        case manual
    }

    let id = UUID()
    let title: String
    let detail: String
    let status: Status
    /// x-apple.systempreferences: deep link into the relevant System Settings pane, if
    /// one exists for this check.
    let settingsURL: URL?
    let hint: String
}

enum SecurityChecker {
    static func runChecks() -> [SecurityCheck] {
        [
            fileVaultCheck(),
            guestAccountCheck(),
            firewallCheck(),
            remoteLoginCheck(),
            screenSharingCheck(),
            startupSecurityCheck(),
            notificationPreviewCheck(),
            airDropCheck(),
        ]
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, text)
        } catch {
            return (-1, "")
        }
    }

    // MARK: - Pure parsing helpers (exposed, not private, so tests can exercise them
    // directly with canned command output instead of depending on this machine's
    // actual security configuration).

    static func isFileVaultOn(_ output: String) -> Bool {
        output.contains("FileVault is On")
    }

    static func isGuestEnabled(status: Int32, output: String) -> Bool {
        // Missing key (non-zero exit, empty output) means the default, which is off.
        status == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func isFirewallOn(_ output: String) -> Bool {
        output.lowercased().contains("enabled")
    }

    static func isLaunchdServiceRunning(_ output: String) -> Bool {
        output.contains("state = running")
    }

    private static func fileVaultCheck() -> SecurityCheck {
        let (_, output) = run("/usr/bin/fdesetup", ["status"])
        let on = isFileVaultOn(output)
        return SecurityCheck(
            title: "FileVault Disk Encryption",
            detail: on
                ? "Enabled. Without it, anyone with physical access can boot from external media and read the disk directly, bypassing the login screen entirely."
                : "Disabled. This is the single biggest bypass of everything else SpyProtect logs - someone can reboot from external media and read your disk without ever touching the lock screen.",
            status: on ? .secure : .warning,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault"),
            hint: "System Settings \u{2192} Privacy & Security \u{2192} FileVault"
        )
    }

    private static func guestAccountCheck() -> SecurityCheck {
        let (status, output) = run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "GuestEnabled"])
        let enabled = isGuestEnabled(status: status, output: output)
        return SecurityCheck(
            title: "Guest Account",
            detail: enabled
                ? "Enabled. Anyone can log into the Guest account without a password, sidestepping your lock screen entirely by using a different account."
                : "Disabled - good.",
            status: enabled ? .warning : .secure,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preferences.users"),
            hint: "System Settings \u{2192} Users & Groups"
        )
    }

    private static func firewallCheck() -> SecurityCheck {
        let (status, output) = run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        if status != 0 {
            return SecurityCheck(
                title: "Firewall",
                detail: "Couldn't determine the firewall state automatically.",
                status: .manual,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall"),
                hint: "System Settings \u{2192} Privacy & Security \u{2192} Firewall"
            )
        }
        let on = isFirewallOn(output)
        return SecurityCheck(
            title: "Firewall",
            detail: on ? "Enabled." : "Disabled. An open network stack makes the lock screen irrelevant if someone can reach exposed services over the network instead of standing in front of the machine.",
            status: on ? .secure : .warning,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall"),
            hint: "System Settings \u{2192} Privacy & Security \u{2192} Firewall"
        )
    }

    private static func remoteLoginCheck() -> SecurityCheck {
        let (status, output) = run("/bin/launchctl", ["print", "system/com.openssh.sshd"])
        if status != 0 {
            return SecurityCheck(
                title: "Remote Login (SSH)",
                detail: "Off, or couldn't be confirmed automatically.",
                status: .manual,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preferences.sharing"),
                hint: "System Settings \u{2192} General \u{2192} Sharing \u{2192} Remote Login"
            )
        }
        let running = isLaunchdServiceRunning(output)
        return SecurityCheck(
            title: "Remote Login (SSH)",
            detail: running ? "Enabled. Someone on the same network can reach this Mac without touching the lock screen at all." : "Disabled - good.",
            status: running ? .warning : .secure,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preferences.sharing"),
            hint: "System Settings \u{2192} General \u{2192} Sharing \u{2192} Remote Login"
        )
    }

    private static func screenSharingCheck() -> SecurityCheck {
        let (status, output) = run("/bin/launchctl", ["print", "system/com.apple.screensharing"])
        if status != 0 {
            return SecurityCheck(
                title: "Screen Sharing",
                detail: "Off, or couldn't be confirmed automatically.",
                status: .manual,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preferences.sharing"),
                hint: "System Settings \u{2192} General \u{2192} Sharing \u{2192} Screen Sharing"
            )
        }
        let running = isLaunchdServiceRunning(output)
        return SecurityCheck(
            title: "Screen Sharing",
            detail: running ? "Enabled. Same risk as Remote Login - accessible over the network, bypassing the lock screen." : "Disabled - good.",
            status: running ? .warning : .secure,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preferences.sharing"),
            hint: "System Settings \u{2192} General \u{2192} Sharing \u{2192} Screen Sharing"
        )
    }

    private static func startupSecurityCheck() -> SecurityCheck {
        SecurityCheck(
            title: "Startup Security (external boot)",
            detail: "Can't be checked while macOS is running - this setting only appears in Recovery Mode. If it allows booting from external/untrusted media, someone can boot around FileVault and reset your password entirely. Worth verifying once: restart, hold the power button until \"Loading startup options\" appears, choose Options, then Startup Security Utility.",
            status: .manual,
            settingsURL: nil,
            hint: "Check via Recovery Mode \u{2192} Startup Security Utility"
        )
    }

    private static func notificationPreviewCheck() -> SecurityCheck {
        SecurityCheck(
            title: "Notification Previews on Lock Screen",
            detail: "Can't be read reliably from here. If message/email previews show on the lock screen, exam-related content could be visible to anyone glancing at the screen without unlocking at all.",
            status: .manual,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
            hint: "System Settings \u{2192} Notifications \u{2192} Show Previews \u{2192} When Unlocked"
        )
    }

    private static func airDropCheck() -> SecurityCheck {
        SecurityCheck(
            title: "AirDrop Visibility",
            detail: "Can't be read reliably from here. If set to \"Everyone,\" nearby devices can push files without any lock-screen interaction.",
            status: .manual,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preferences.sharing"),
            hint: "System Settings \u{2192} General \u{2192} AirDrop & Handoff"
        )
    }
}
