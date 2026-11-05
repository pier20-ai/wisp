// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// Updates through Sparkle (https://sparkle-project.org), for release builds.
///
/// scripts/bundle-app.sh embeds Sparkle.framework, and puts SUFeedURL and SUPublicEDKey in Info.plist,
/// only in Developer ID builds; the feed is the appcast.xml attached to the latest GitHub release.
/// Sparkle is loaded at run time rather than linked, because the same binary also runs as the CLI
/// and inside phantom apps, which have no Frameworks folder: those never load it. A build without
/// Sparkle (a source build) simply has no updater, and the menu item and setting are hidden.
final class Updates: NSObject { // main thread only, like the rest of the app
    static let shared = Updates()

    /// SPUStandardUpdaterController, once started.
    private var controller: NSObject?
    private let driverDelegate = UserDriverDelegate()

    var isAvailable: Bool { controller != nil }

    /// The SPUUpdater, for its KVC-compliant settings.
    private var updater: NSObject? { controller?.value(forKey: "updater") as? NSObject }

    var checksAutomatically: Bool {
        get { (updater?.value(forKey: "automaticallyChecksForUpdates") as? Bool) ?? false }
        set {
            updater?.setValue(newValue, forKey: "automaticallyChecksForUpdates")
            Log.info(.app, "updates: automatic checks \(newValue ? "on" : "off")")
        }
    }

    func start() {
        guard controller == nil else { return }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            Log.info(.app, "updates: none in this build (no SUFeedURL)")
            return
        }
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
              let bundle = Bundle(url: url) else {
            Log.warning(.app, "updates: SUFeedURL is set but Sparkle.framework is missing")
            return
        }
        do { try bundle.loadAndReturnError() } catch {
            Log.error(.app, "updates: could not load Sparkle: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error.localizedDescription)")
            return
        }
        guard let cls = NSClassFromString("SPUStandardUpdaterController") as? NSObject.Type else {
            Log.error(.app, "updates: Sparkle loaded but SPUStandardUpdaterController is missing")
            return
        }
        // alloc + initWithUpdaterDelegate:userDriverDelegate: (which starts the updater). Through
        // perform, each returns its object unbalanced by one retain; it lives as long as the app anyway.
        guard let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let made = alloc.perform(NSSelectorFromString("initWithUpdaterDelegate:userDriverDelegate:"),
                                       with: nil, with: driverDelegate)?.takeUnretainedValue() as? NSObject else {
            Log.error(.app, "updates: could not create the updater")
            return
        }
        controller = made
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info(.app, "updates: Sparkle \(version), feed \(feed), automatic checks \(checksAutomatically ? "on" : "off")")
    }

    /// "Check for Updates…": Sparkle's own action, which also enables and disables the item.
    func menuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        let mi = NSMenuItem(title: "Check for Updates…", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
        mi.target = controller
        return mi
    }
}

/// Wisp lives in the menu bar, so a scheduled update shouldn't steal focus: Sparkle's "gentle
/// reminders" show it without activating the app in the middle of something else.
private final class UserDriverDelegate: NSObject {
    @objc var supportsGentleScheduledUpdateReminders: Bool { true }
}
