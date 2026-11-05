// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// Carries a user over from the product's previous name, WCast (bundle ID app.wcast.WCast), once.
/// The bundle ID changed with the name, so macOS sees a new app: its defaults domain, Application
/// Support directory and TCC grants all start empty. This brings the settings across and clears out
/// the old phantom apps; the grants have to be given again (README.md, "Upgrading from WCast").
///
/// Only the app runs it, and not when WISP_SUPPORT_DIR is set: tests run with their own support
/// directory and must neither reconnect to a host copied from real settings nor touch real phantoms.
/// Main queue.
enum LegacyMigration {
    /// The previous brand's names. These are the only places the code names it.
    static let legacyName = "WCast"
    static let legacyBundleID = "app.wcast.WCast"
    /// Earlier bundle IDs whose settings are carried over, newest first (1.0.0–1.0.1 used app.wisp.Wisp).
    static let earlierBundleIDs = ["app.wisp.Wisp", legacyBundleID]
    /// Set in the new domain once the old settings were copied (or there were none).
    private static let doneKey = "legacySettingsMigrated"

    static func run() {
        guard ProcessInfo.processInfo.environment["WISP_SUPPORT_DIR"] == nil,
              !earlierBundleIDs.contains(Brand.bundleID) else { return }
        migrateSettings()
        DispatchQueue.global(qos: .utility).async { removeOldPhantoms() }
    }

    /// Copies every key of the old defaults domain (last host, allow-list, host options, the
    /// app's toggles) that the new domain doesn't have yet. Once: later changes stay separate.
    private static func migrateSettings() {
        let d = Brand.defaults
        guard !d.bool(forKey: doneKey) else { return }
        for id in earlierBundleIDs {
            let old = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
            var copied: [String] = []
            for (key, value) in old where key != doneKey && d.object(forKey: key) == nil {
                d.set(value, forKey: key)
                copied.append(key)
            }
            if !copied.isEmpty { log("copied \(copied.count) settings from \(id): \(copied.sorted().joined(separator: ", "))") }
        }
        d.set(true, forKey: doneKey)
    }

    /// Unregisters and deletes the phantom apps under ~/Library/Application Support/WCast, so no
    /// WCast-era "remote" app lingers in Spotlight, the Dock or Open With, then the directory itself
    /// once nothing is left in it but the phantoms' socket. A phantom that's running (an old copy of
    /// the app still in use) is left alone; the next launch tries again.
    private static func removeOldPhantoms() {
        let fm = FileManager.default
        let oldSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(legacyName, isDirectory: true)
        guard oldSupport.standardizedFileURL != Brand.supportDirectory.standardizedFileURL,
              fm.fileExists(atPath: oldSupport.path) else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        var kept = 0
        // Both layouts: Phantoms/<host>/<appKey>.app and Phantoms/<host>/<appKey>/<App Name>.app.
        if let walk = fm.enumerator(at: oldSupport.appendingPathComponent("Phantoms"), includingPropertiesForKeys: nil) {
            for case let item as URL in walk where item.pathExtension == "app" {
                walk.skipDescendants()
                if running.contains(item.standardizedFileURL.path) { kept += 1; continue }
                log("removing \(legacyName) phantom app: \(item.lastPathComponent)")
                PhantomStore.remove(item)
            }
        }
        if kept == 0 {
            do { try fm.removeItem(at: oldSupport); log("removed \(oldSupport.path)") } catch { Log.failed(.app, "removing \(oldSupport.path)", error) }
        }
    }
}
