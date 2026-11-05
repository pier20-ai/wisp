// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import WispCommon

/// The host's permissions and the settings that affect it, read without prompting (the host window
/// polls them), and the System Settings panes to fix them.
enum Permissions {
    /// Screen & System Audio Recording (capture). Some macOS versions only see a new grant after a relaunch.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// Accessibility (input injection, window moves, menus). Seen at once when granted.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var isMacOS27OrLater: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    /// Where Accessibility lives in System Settings on this macOS.
    static var accessibilityLocation: String {
        isMacOS27OrLater ? "Privacy & Security › Device Control and Data Access › Accessibility" : "Privacy & Security › Accessibility"
    }
    /// The Accessibility row's name in the host window.
    static var accessibilityTitle: String { isMacOS27OrLater ? "Device Control (Accessibility)" : "Accessibility" }

    /// Asks once (the app then shows up in the list, which macOS only does for apps that asked) and
    /// opens the Screen Recording pane.
    static func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
    }

    /// Adds the app to the Accessibility list (switched off) and opens that pane. On macOS 27 it sits
    /// under Device Control and Data Access; the anchor is still Privacy_Accessibility.
    static func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
        openPrivacyPane("Privacy_Accessibility")
    }

    /// System Settings › Lock Screen ("Require password after screen saver begins or display is turned off").
    static func openLockScreenSettings() {
        open("x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension", fallback: "x-apple.systempreferences:com.apple.preference.security?General")
    }

    /// System Settings › General › Login Items.
    static func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension", fallback: "x-apple.systempreferences:com.apple.preferences.users")
    }

    /// The Privacy & Security extension (macOS 13+) at `anchor`; the old preference pane URL as a fallback.
    private static func openPrivacyPane(_ anchor: String) {
        open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
             fallback: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private static func open(_ url: String, fallback: String) {
        if let u = URL(string: url), NSWorkspace.shared.open(u) { return }
        if let u = URL(string: fallback) { NSWorkspace.shared.open(u) }
    }

    /// Whether the screen locks (a password after sleep or the screen saver), which would send every
    /// viewer's input to the lock screen once it kicks in: `sysadminctl -screenLock status` (no root
    /// needed). nil if unknown. Runs the tool off the main thread; `done` on the main queue.
    static func screenLockEnabled(_ done: @escaping (Bool?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
            p.arguments = ["-screenLock", "status"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe // it reports on stderr
            var result: Bool?
            var ran = false
            do { try p.run(); ran = true } catch { Log.failed(.host, "running sysadminctl -screenLock status", error) }
            if ran {
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
                p.waitUntilExit()
                if out.contains("screenlock is off") { result = false } else if out.contains("screenlock delay is") { result = true }
            }
            DispatchQueue.main.async { done(result) }
        }
    }
}
