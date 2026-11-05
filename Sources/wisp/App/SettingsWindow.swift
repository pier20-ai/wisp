// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ServiceManagement
import SwiftUI
import WispCommon

// Settings (⌘,): a toolbar-tabbed window, each tab a grouped SwiftUI Form (the System Settings look).
// Sharing: the host's options (the same defaults keys as `wisp send`'s flags, read when sharing
// starts) and "Share this Mac at login". Viewing: the viewer's options. Allowed Viewers: the allow-list.

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClose: (() -> Void)?
    /// The tailnet's users, for the allow-list's "From Tailnet" menu.
    var tailnetUsers: () -> [(login: String, name: String)] = { [] }
    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() {
        let access = AccessSettings()
        access.users = tailnetUsers()
        if access.users.isEmpty { access.loadUsers() }
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let vc = NSHostingController(rootView: view.frame(width: 520).fixedSize(horizontal: false, vertical: true))
            vc.sizingOptions = [.preferredContentSize]
            vc.title = title // the toolbar-style tab controller titles the window after the selected tab
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tab("Sharing", "rectangle.on.rectangle", SharingSettings())
        tab("Viewing", "macwindow.on.rectangle", ViewingSettings())
        tab("Allowed Viewers", "person.2", Form { AllowListEditor(access: access) }.formStyle(.grouped))
        tab("Troubleshooting", "stethoscope", TroubleshootingSettings())
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.title = "\(Brand.name) Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
    }

    func windowWillClose(_ n: Notification) { DispatchQueue.main.async { self.onClose?() } }
}

private let store = Brand.defaults

struct SharingSettings: View {
    private static let d = HostOptions()
    @AppStorage("kbps", store: store) private var kbps = d.kbps
    @AppStorage("fps", store: store) private var fps = d.fps
    @AppStorage("fec", store: store) private var fec = d.fec
    @AppStorage("codec", store: store) private var codec = "hevc"
    @AppStorage("virtualDisplay", store: store) private var virtualDisplay = d.virtualDisplay
    @AppStorage("maxStreams", store: store) private var maxStreams = d.maxStreams
    @AppStorage(Prefs.shareAtLaunchKey, store: store) private var shareAtLaunch = false
    @AppStorage(ClipboardSync.hostKey, store: store) private var shareClipboard = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Bitrate ceiling") {
                    HStack {
                        Slider(value: Binding(get: { Double(kbps) / 1000 }, set: { kbps = Int(($0 * 1000).rounded()) }), in: 2 ... 50, step: 1)
                            .frame(width: 200)
                        Text("\(kbps / 1000) Mbps").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Codec", selection: $codec) {
                    Text("HEVC").tag("hevc")
                    Text("H.264").tag("h264")
                }
                Picker("Error correction", selection: $fec) {
                    Text("Off").tag(0)
                    Text("1 parity packet per 4").tag(4)
                    Text("1 per 8").tag(8)
                    Text("1 per 16").tag(16)
                }
            } header: {
                Text("Video")
            } footer: {
                Text("The bitrate is shared by the windows that are changing; an idle window sends nothing. Error correction repairs lost packets without a round trip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Put shared windows on virtual displays", isOn: $virtualDisplay)
                Stepper("At most \(maxStreams) window\(maxStreams == 1 ? "" : "s") at once", value: $maxStreams, in: 1 ... 6)
            } header: {
                Text("Windows")
            } footer: {
                Text("Virtual displays (a private macOS API) give each shared window a HiDPI display of its own, sized to the viewer's screen, so text stays sharp on a Mac with no monitor. An M4 Mac mini sustains about 3 streams.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Share clipboard with viewers", isOn: $shareClipboard)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("While a viewer is connected, what's copied on either Mac can be pasted on the other: text, rich text, HTML and images up to 10 MB, not files. Passwords copied from a password manager are never sent. Applies at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Share this Mac at login", isOn: Binding(get: { shareAtLaunch && loginStatus != .notRegistered }, set: setShareAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve \(Brand.name) in Login Items.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { Permissions.openLoginItemsSettings() }
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Startup")
            } footer: {
                Text("\(Brand.name) opens at login and starts sharing; viewers open windows from their menu. Changes to video and windows apply the next time sharing starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setShareAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        shareAtLaunch = on
        loginStatus = SMAppService.mainApp.status
    }
}

struct ViewingSettings: View {
    @AppStorage(Prefs.phantomsKey, store: store) private var phantoms = true
    @AppStorage(Prefs.reconnectKey, store: store) private var reconnect = false
    @AppStorage("outlineRemoteWindows", store: store) private var outline = true
    @AppStorage(ClipboardSync.viewerKey, store: store) private var shareClipboard = true

    var body: some View {
        Form {
            Section {
                Toggle("Open each remote app as an app of its own", isOn: $phantoms)
                Toggle("Reconnect to the last Mac when \(Brand.name) opens", isOn: $reconnect)
                Toggle("Outline remote windows in teal", isOn: $outline)
                Toggle("Share clipboard with remote Macs", isOn: $shareClipboard)
            } footer: {
                Text("Remote apps of their own (phantom apps) get a Dock icon, ⌘Tab and their own mirrored menu bar. Off: remote windows open in \(Brand.name) itself. Applies to the next connection. The teal outline marks every remote window, so it's clear which windows aren't on this Mac. The clipboard (text, images; not files or passwords from a password manager) goes both ways while connected, if the other Mac shares it too; this applies at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Verbose logging, and the logs and diagnostics (as in the menu's Troubleshooting submenu).
struct TroubleshootingSettings: View {
    @AppStorage(Log.verboseKey, store: store) private var verbose = false
    @State private var autoUpdate = Updates.shared.checksAutomatically

    var body: some View {
        Form {
            if Updates.shared.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(get: { autoUpdate }, set: { on in
                        autoUpdate = on
                        Updates.shared.checksAutomatically = on
                    }))
                } footer: {
                    Text("Once a day \(Brand.name) looks at its latest release on GitHub, and offers a new version when there is one. Check for Updates… in the menu looks now.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Verbose logging", isOn: Binding(get: { verbose }, set: { on in
                    verbose = on
                    Log.verbose = on
                    Log.info(.app, "verbose logging \(on ? "on" : "off")")
                }))
            } footer: {
                Text("Adds per-event detail to the logs (connections, messages, probes, menus). Phantom apps pick it up when they next open. The logs are in \(LogFile.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Reveal Logs in Finder") { (NSApp.delegate as? AppDelegate)?.revealLogs() }
                    Button("Copy Diagnostics") { (NSApp.delegate as? AppDelegate)?.copyDiagnostics() }
                }
            } footer: {
                Text("Copy Diagnostics puts a report on the clipboard for an issue: versions, permissions, settings, the Macs on your tailnet and the end of the log. Other people's logins are replaced by a hash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Welcome

/// First launch, nothing set up yet: a popover under the menu bar item saying where the app lives.
final class WelcomeController: NSHostingController<WelcomeView> {
    init(share: @escaping () -> Void, showMenu: @escaping () -> Void) {
        super.init(rootView: WelcomeView(share: share, showMenu: showMenu))
        sizingOptions = [.preferredContentSize]
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}

struct WelcomeView: View {
    var share: () -> Void
    var showMenu: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to \(Brand.name)").font(.headline)
                    Text("Use apps on another Mac as if they were on this one.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("\(Brand.name) lives in the menu bar. Its menu lists the Macs on your tailnet: choose one that's sharing to see its windows, then a window to open it here.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("To use this Mac from another one, share it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Share Windows from This Mac…", action: share)
                Spacer()
                Button("Show the Menu", action: showMenu).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
