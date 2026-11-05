// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The product's names and identifiers, in one place. To rename the product, change these AND
/// scripts/brand.env (the build scripts' copy; scripts/bundle-app.sh refuses to build if the two
/// disagree). See "Renaming" in docs/development.md.
///
/// Everything that would otherwise mix state between two brands derives from these: the defaults
/// domain, the log and Application Support directories, and the phantom apps' bundle IDs.
public enum Brand {
    /// Display name: the app bundle (Name.app), menus, windows and messages.
    public static let name = "Wisp"
    /// The command-line name, as used in usage text and messages.
    public static let cli = "wisp"
    /// The app's bundle identifier. Changing it makes macOS treat the app as a new one: Screen
    /// Recording and Accessibility must be granted again, and its defaults start empty. A placeholder
    /// reverse-DNS name: a fork should use a domain it controls.
    public static let bundleID = "com.pier20.Wisp"
    /// Copyright line (the app's Info.plist gets it from scripts/brand.env).
    public static let copyright = "Copyright © 2026 the Wisp contributors. GPL-3.0-or-later."

    // Derived. A rename changes all of these together, so two brands never share state.

    /// Phantom apps get bundle IDs "<prefix><16 hex>".
    public static let phantomBundleIDPrefix = bundleID + ".phantom."
    /// App keys of the synthetic test apps (`send --synthetic`).
    public static let syntheticAppKeyPrefix = bundleID + ".synthetic."
    /// The Info.plist key that marks a generated phantom app bundle.
    public static let phantomInfoKey = name + "Phantom"
    /// The defaults domain: `defaults write <defaultsDomain> <key> <value>`.
    public static let defaultsDomain = bundleID
    /// ~/Library/Logs/<name>. WISP_LOG_DIR overrides it (tests beside a copy that's in use).
    public static let logDirectory = override("WISP_LOG_DIR") ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    /// ~/Library/Application Support/<name> (phantom apps, the phantom socket). WISP_SUPPORT_DIR
    /// overrides it, so a test's phantoms never touch those of a copy that's in use.
    public static let supportDirectory = override("WISP_SUPPORT_DIR") ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent(name, isDirectory: true)

    private static func override(_ variable: String) -> URL? {
        guard let p = ProcessInfo.processInfo.environment[variable], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// The settings store, always the brand's domain: the app reads it as its standard defaults; the
    /// CLI and phantom apps (whose own domains differ) read the same domain explicitly.
    public static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == defaultsDomain { return .standard }
        return UserDefaults(suiteName: defaultsDomain) ?? .standard
    }()
}
