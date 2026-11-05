// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ServiceManagement
import WispCommon

// Wisp.app: a menu bar app. Its menu lists the Macs on the tailnet and the connected host's windows
// (StatusMenu.swift); "Share Windows from This Mac…" opens the host window (HostWindow.swift);
// Settings (SettingsWindow.swift). No Dock icon unless one of its windows is open.

/// The app's settings keys, in `Brand.defaults` (the host's options are read by HostOptions.fromDefaults,
/// the access list by AccessPolicy.fromDefaults).
enum Prefs {
    /// The Mac last connected to (as typed or chosen), and its tailnet name for display.
    static let lastHostKey = "lastHost", lastHostLabelKey = "lastHostLabel"
    /// Remote windows in phantom apps (default) or in this app.
    static let phantomsKey = "phantoms"
    /// Connect to the last Mac when the app opens.
    static let reconnectKey = "reconnectAtLaunch"
    /// Start sharing when the app opens (with "Share this Mac at login", the app opens at login).
    static let shareAtLaunchKey = "shareAtLaunch"
    /// The welcome popover has been shown.
    static let welcomedKey = "welcomed"

    static var lastHost: String? { Brand.defaults.string(forKey: lastHostKey).flatMap { $0.isEmpty ? nil : $0 } }
    static var lastHostLabel: String? { Brand.defaults.string(forKey: lastHostLabelKey) }
    static var usePhantoms: Bool {
        if let e = ProcessInfo.processInfo.environment["WISP_PHANTOMS"] { return e != "0" }
        return Brand.defaults.object(forKey: phantomsKey) as? Bool ?? true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuActions {
    private var statusMenu: StatusMenuController!
    private var host: HostController?
    private var settings: SettingsController?
    private(set) var session: ViewerSession?
    private var welcome: NSPopover?
    /// Debug: WISP_OPEN=host,settings,welcome opens those at launch (tests can't click the menu).
    private let testOpen = Set((ProcessInfo.processInfo.environment["WISP_OPEN"] ?? "").split(separator: ",").map(String.init))

    func applicationDidFinishLaunching(_ n: Notification) {
        // The host window's log view shows what the file gets (debug lines only with verbose logging).
        Log.hook = { _, _, line in DispatchQueue.main.async { LogStore.shared.append(line) } }
        logLaunch()
        LegacyMigration.run() // before anything reads the settings
        Log.info(.app, "settings: " + Diagnostics.settingsLines(hash: { Diagnostics.hashLogin($0, me: "") }, environment: false).joined(separator: "; "))
        NSApp.mainMenu = makeMainMenu()
        Updates.shared.start() // before the menu, which offers Check for Updates…
        statusMenu = StatusMenuController(actions: self)
        updateActivationPolicy()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--connect"), i + 1 < args.count {
            // A phantom app opened from the Dock started us, to connect to its host.
            connect(to: args[i + 1], label: args[i + 1])
        } else if Brand.defaults.bool(forKey: Prefs.reconnectKey), let last = Prefs.lastHost {
            connect(to: last, label: Prefs.lastHostLabel ?? last)
        }
        if Brand.defaults.bool(forKey: Prefs.shareAtLaunchKey) || testOpen.contains("host") {
            openHostWindow(show: testOpen.contains("host") || !Brand.defaults.bool(forKey: Prefs.shareAtLaunchKey), pick: false)
        }
        if testOpen.contains("settings") { openSettings() }
        if testOpen.contains("welcome") || (!Brand.defaults.bool(forKey: Prefs.welcomedKey) && Prefs.lastHost == nil && session == nil && host == nil) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcome() }
        }
        // Debug: WISP_TEST_STOP=<seconds> stops sharing then, as Stop Sharing does, and starts it again 2 s later.
        if let delay = ProcessInfo.processInfo.environment["WISP_TEST_STOP"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Log.info(.app, "test: stopping sharing, as Stop Sharing does")
                self?.stopSharing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    Log.info(.app, "test: sharing again")
                    self?.openHostWindow(show: false, pick: false)
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["WISP_MENU_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.dumpWindows(to: path + ".windows") }
            // The report Copy Diagnostics would copy, to <file>.diagnostics (tests leave the clipboard alone).
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.makeDiagnostics { report in
                    do { try report.write(toFile: path + ".diagnostics", atomically: true, encoding: .utf8) } catch {
                        Log.failed(.app, "writing \(path).diagnostics", error)
                    }
                }
            }
        }
    }

    /// The first lines of every run: what's running, where, on what, with which permissions.
    private func logLaunch() {
        Log.info(.app, "\(Diagnostics.versionLine) starting, pid \(getpid()), arguments: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        Log.info(.app, "bundle \(Diagnostics.bundleLocation) (\(Bundle.main.bundleIdentifier ?? "no bundle ID")), \(Diagnostics.macOSLine), \(Diagnostics.hardwareLine)")
        Log.info(.app, "permissions: \(Diagnostics.permissionsLine); logs in \(LogFile.dir.path) (verbose \(Log.verbose ? "on" : "off")), support files in \(Brand.supportDirectory.path)")
        let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("WISP_") }.sorted { $0.key < $1.key }
        if !env.isEmpty { Log.info(.app, "environment: " + env.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
    }

    // MARK: Diagnostics

    @objc func revealLogs() {
        do { try FileManager.default.createDirectory(at: LogFile.dir, withIntermediateDirectories: true) } catch { Log.failed(.app, "creating \(LogFile.dir.path)", error) }
        Log.flush()
        let file = Log.fileURL
        Log.info(.app, "revealing the logs in Finder: \(LogFile.dir.path)")
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(LogFile.dir)
        }
    }

    /// Copies the diagnostics report (Diagnostics.report) to the clipboard, with what the menu last
    /// found on each Mac and the state of the viewer and host.
    @objc func copyDiagnostics() {
        Log.info(.app, "copying diagnostics")
        makeDiagnostics { report in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            Log.info(.app, "copied diagnostics to the clipboard (\(report.count) characters)")
        }
    }

    /// The report, built off the main thread; `done` on the main queue.
    private func makeDiagnostics(_ done: @escaping (String) -> Void) {
        let probes = Dictionary(statusMenu.discovery.macs.compactMap { m in m.probe.map { (m.peer.address, $0) } }, uniquingKeysWith: { a, _ in a })
        var state: [String] = []
        if let s = session {
            state.append("viewer: \(s.hostName), \(s.status ?? "connected"), \(s.openCount) windows open\(s.notice.map { ", notice: \($0)" } ?? "")")
        } else {
            state.append("viewer: not connected")
        }
        state.append("host: " + (host.map { $0.summary ?? "starting" } ?? "not sharing"))
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Diagnostics.report(probes: probes, state: state)
            DispatchQueue.main.async { done(report) }
        }
    }

    /// Debug (WISP_MENU_DUMP): the app's windows, their views and toolbars, for tests that can't see the screen.
    private func dumpWindows(to path: String) {
        func tree(_ v: NSView, _ depth: Int, _ out: inout [String]) {
            guard depth < 7 else { return }
            let name = String(describing: type(of: v))
            if !name.hasPrefix("_") || depth < 3 { out.append(String(repeating: "  ", count: depth) + name + " \(Int(v.frame.width))x\(Int(v.frame.height))") }
            v.subviews.forEach { tree($0, depth + 1, &out) }
        }
        var out = ["activation policy: \(NSApp.activationPolicy() == .regular ? "regular" : "accessory")"]
        for w in NSApp.windows where w.isVisible {
            out.append("window \"\(w.title)\" \(type(of: w)) \(Int(w.frame.width))x\(Int(w.frame.height)) key=\(w.isKeyWindow) toolbar=\(w.toolbar.map { "\($0.items.count) items: " + $0.items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }.joined(separator: ", ") } ?? "none") style=\(w.toolbarStyle.rawValue)")
            if let v = w.contentView { var lines: [String] = []; tree(v, 1, &lines); out += lines.prefix(60) }
        }
        do { try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) } catch { Log.failed(.app, "writing \(path)", error) }
    }

    // MARK: Viewer

    func connect(to address: String, label: String) {
        if let s = session {
            // Already connected (or connecting) there; a session that lost its host is replaced.
            if s.hostName == address, s.status == nil || s.status!.hasPrefix("Connecting") { return }
            Log.info(.viewer, "switching from \(s.hostName) to \(address)")
            let old = s
            session = nil
            old.onClose = nil
            old.disconnect()
        }
        Brand.defaults.set(address, forKey: Prefs.lastHostKey)
        Brand.defaults.set(label, forKey: Prefs.lastHostLabelKey)
        let phantoms = Prefs.usePhantoms
        let v = ViewerSession(host: address, phantoms: phantoms, ownMenu: false)
        v.onChange = { [weak self] in self?.statusMenu.sessionChanged() }
        v.onClose = { [weak self, weak v] error in
            guard let self, session === v else { return }
            session = nil
            statusMenu.sessionChanged()
            updateActivationPolicy()
            if let error {
                Log.warning(.viewer, "couldn't connect to \(label): \(error)")
                // Tests (WISP_NO_ALERTS=1) can't click OK: the log has it.
                if ProcessInfo.processInfo.environment["WISP_NO_ALERTS"] == "1" { return }
                let a = NSAlert()
                a.messageText = "Couldn't connect to \(label)"
                a.informativeText = error
                NSApp.activate()
                a.runModal()
            }
        }
        session = v
        Log.info(.viewer, "connecting to \(describeAddress(address))\(label == address ? "" : ", shown as \(label)"), "
                 + (phantoms ? "windows in phantom apps" : "windows in this app"))
        v.show()
        statusMenu.sessionChanged()
        updateActivationPolicy()
    }

    func disconnect() { session?.disconnect() }

    // MARK: Host

    var sharingSummary: String? { host?.summary }

    func openHostWindow() { openHostWindow(show: true, pick: true) }

    /// Starts sharing if it isn't on, and shows the host window (`pick`: then the window picker, if
    /// nothing is shared yet and Screen Recording is allowed).
    private func openHostWindow(show: Bool, pick: Bool) {
        if host == nil {
            let h = HostController()
            h.onVisibilityChange = { [weak self] in self?.updateActivationPolicy() }
            h.onStateChange = { [weak self] in self?.statusMenu.rebuild() }
            h.onStopped = { [weak self, weak h] in
                guard let self, host === h else { return }
                Log.info(.host, "sharing stopped")
                host = nil
                statusMenu.rebuild()
                updateActivationPolicy()
            }
            host = h
            Log.info(.host, "starting to share this Mac")
            h.start()
        }
        if show { host?.show(pick: pick) }
        statusMenu.rebuild()
    }

    func stopSharing() { host?.stopSharing() }

    // MARK: Settings and welcome

    @objc func openSettings() {
        if settings == nil {
            let s = SettingsController()
            s.onClose = { [weak self] in self?.updateActivationPolicy() }
            s.tailnetUsers = { [weak self] in self?.statusMenu.discovery.users ?? [] }
            settings = s
        }
        settings?.show()
        updateActivationPolicy()
    }

    private func showWelcome() {
        guard let button = statusMenu.item.button, button.window != nil else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = WelcomeController(
            share: { [weak self] in self?.welcome?.close(); self?.openHostWindow() },
            showMenu: { [weak self] in
                self?.welcome?.close()
                DispatchQueue.main.async { self?.statusMenu.item.button?.performClick(nil) }
            })
        welcome = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if testOpen.isEmpty, ProcessInfo.processInfo.environment["WISP_MENU_DUMP"] == nil {
            Brand.defaults.set(true, forKey: Prefs.welcomedKey)
        }
        Log.info(.app, "welcome popover shown")
    }

    // MARK: App

    /// A Dock icon and main menu only while a window of ours is open (the host window, Settings, or
    /// remote windows shown in this app rather than in phantoms); otherwise just the menu bar item.
    private func updateActivationPolicy() {
        let inProcessWindows = session != nil && !Prefs.usePhantoms
        let regular = (host?.isVisible ?? false) || (settings?.isVisible ?? false) || inProcessWindows
        let want: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) {
        Log.info(.app, "quitting" + (session.map { ", disconnecting from \($0.hostName)" } ?? "") + (host == nil ? "" : ", stopping sharing"))
        host?.terminate()
        session?.stop()
        Log.flush()
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Opened again from Finder or Spotlight: show the menu.
        Log.debug(.app, "reopened (visible windows: \(hasVisibleWindows))")
        if !hasVisibleWindows { statusMenu.item.button?.performClick(nil) }
        return true
    }
}

// MARK: - Menu

func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let app = NSMenu()
    app.addItem(withTitle: "About \(Brand.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide \(Brand.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = app
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let helpItem = NSMenuItem()
    let help = NSMenu(title: "Help")
    help.addItem(withTitle: "Reveal Logs in Finder", action: #selector(AppDelegate.revealLogs), keyEquivalent: "")
    help.addItem(withTitle: "Copy Diagnostics", action: #selector(AppDelegate.copyDiagnostics), keyEquivalent: "")
    helpItem.submenu = help

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Stop Viewing This Window", action: #selector(RemoteView.stopViewing(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    main.addItem(helpItem)
    NSApp.helpMenu = help
    return main
}

func runApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // a menu bar app: a Dock icon only while one of its windows is open
    let delegate = AppDelegate()
    app.delegate = delegate
    // SIGTERM / Ctrl-C quit like ⌘Q: phantoms quit, shared windows go back, displays are removed.
    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler {
            Log.info(.app, "signal \(sig == SIGINT ? "SIGINT" : "SIGTERM"): quitting")
            NSApp.terminate(nil)
        }
        s.resume()
        return s
    }
    withExtendedLifetime(signals) { app.run() }
    exit(0)
}
