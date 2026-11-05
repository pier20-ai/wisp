// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ScreenCaptureKit
import SwiftUI
import Tailnet
import WispCommon

// The host window: sharing this Mac's windows. A native sidebar window (NavigationSplitView, the
// system sidebar material; Liquid Glass on macOS 26+) with a unified toolbar, and four sections:
// Sharing (who is connected, the shared windows with live thumbnails, whether this Mac is ready),
// Allowed Viewers, Permissions and Log. Closing the window leaves sharing on: the menu bar item and
// the toolbar's Stop Sharing end it.

// MARK: - Model

/// What the host window shows, refreshed once a second from the Host. Main queue.
@Observable
final class HostModel {
    struct Viewer: Equatable {
        var name: String
        var device: String
        var initials: String
        var address: String
        /// "RTT 12 ms · click→screen 48 ms · 9.6 Mbps".
        var detail: String
    }

    struct Card: Identifiable, Equatable {
        var id: UInt16
        var title: String
        var appName: String
        var size: String
        /// "60 fps" or "idle".
        var rate: String
        var isPrimary: Bool
        var open: Bool
        var thumbnail: NSImage?
        static func == (a: Card, b: Card) -> Bool {
            a.id == b.id && a.title == b.title && a.size == b.size && a.rate == b.rate && a.open == b.open && a.thumbnail === b.thumbnail
        }
    }

    var listening = false
    var error: String?
    var viewer: Viewer?
    var cards: [Card] = []
    var maxStreams = 3
    var screenRecording = Permissions.screenRecording
    var accessibility = Permissions.accessibility
    var screenLockEnabled: Bool?
    var screenLocked = false
    /// Where viewers connect to: this Mac's tailnet name and addresses.
    var addresses: [String] = tailscaleAddresses()

    @ObservationIgnored var chooseWindow: () -> Void = {}
    @ObservationIgnored var disconnectViewer: () -> Void = {}
    @ObservationIgnored var stopSharing: () -> Void = {}
}

/// The allow-list and the LAN switch, read from and written to the settings (AccessPolicy reads them
/// for every connection, so changes apply to the next one). Main queue.
@Observable
final class AccessSettings {
    var allowed: [String] = AccessPolicy.fromDefaults().allowedViewers {
        didSet { Brand.defaults.set(allowed, forKey: AccessPolicy.allowedViewersKey) }
    }
    var allowLAN: Bool = AccessPolicy.fromDefaults().allowLAN {
        didSet { Brand.defaults.set(allowLAN, forKey: AccessPolicy.allowLANKey) }
    }
    /// The tailnet's users (login, display name), for "Add from Tailnet".
    var users: [(login: String, name: String)] = []

    func add(_ login: String) {
        let l = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !allowed.contains(where: { $0.caseInsensitiveCompare(l) == .orderedSame }) else { return }
        allowed.append(l)
    }

    func loadUsers() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var seen = Set<String>()
            let peers: [TailnetPeer]
            do { peers = try Tailnet.peers() } catch { Log.warning(.tailnet, "no tailnet users for the allow-list: \(error.localizedDescription)"); peers = [] }
            let users = peers.compactMap { p -> (String, String)? in
                guard !p.userLoginName.isEmpty, seen.insert(p.userLoginName).inserted else { return nil }
                return (p.userLoginName, p.userDisplayName)
            }
            DispatchQueue.main.async { self?.users = users }
        }
    }
}

/// The app's log (host and viewer), for the Log section. Main queue.
final class LogStore {
    static let shared = LogStore()
    private(set) var lines: [String] = []
    private var observers: [UUID: (String) -> Void] = [:]

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
        observers.values.forEach { $0(line) }
    }

    func observe(_ f: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    func remove(_ id: UUID) { observers[id] = nil }
}

// MARK: - Controller

/// Owns the Host while sharing is on, and its window. Main queue.
final class HostController: NSObject, NSWindowDelegate, SCContentSharingPickerObserver {
    private var core: Host?
    let model = HostModel()
    let access = AccessSettings()
    private var window: NSWindow?
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var lastBytes = 0
    private var lastFrames: [UInt16: Int] = [:]
    private var thumbnails: [UInt16: NSImage] = [:]
    var onVisibilityChange: (() -> Void)?
    /// What the menu shows about sharing changed (a viewer came or went, sharing started).
    var onStateChange: (() -> Void)?
    /// Sharing stopped (Stop Sharing): this controller is done.
    var onStopped: (() -> Void)?
    private var lastSummary: String?

    var isVisible: Bool { window?.isVisible ?? false }

    /// For the menu: "Alex Doe · alex-mbp connected", "2 windows shared", "Waiting for a viewer".
    var summary: String? {
        guard core != nil else { return nil }
        if !model.listening { return model.error ?? "Not listening" }
        if let v = model.viewer { return "\(v.name) · \(v.device) connected" }
        let n = model.cards.count
        return n == 0 ? "Waiting for a viewer" : "\(n) window\(n == 1 ? "" : "s") shared · waiting for a viewer"
    }

    override init() {
        super.init()
        model.chooseWindow = { [weak self] in self?.chooseWindow() }
        model.disconnectViewer = { [weak self] in self?.core?.server.disconnectViewer() }
        model.stopSharing = { [weak self] in self?.stopSharing() }
    }

    /// Starts listening (viewers can connect and open any window from their menu).
    func start(retry: Bool = true) {
        let h = Host(opts: .fromDefaults())
        core = h
        model.maxStreams = h.maxStreams
        h.onShareChanged = { [weak self] _ in self?.refresh() }
        do {
            try h.start()
            model.listening = true
            model.error = nil
            Log.info(.host, "sharing: viewers on your tailnet can connect to \(model.addresses.isEmpty ? "this Mac" : model.addresses.joined(separator: ", ")); "
                     + "\(h.maxStreams) windows at most; \(Diagnostics.permissionsLine)")
        } catch {
            core = nil
            // Sharing was just stopped: the old listeners may take a moment to let go of the ports.
            if retry, error.localizedDescription.contains("already in use") {
                Log.info(.host, "the ports are still taken (\(error.localizedDescription)); trying again in 1.5 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start(retry: false) }
                return
            }
            model.listening = false
            model.error = error.localizedDescription
            Log.error(.host, "could not start sharing: \(error.localizedDescription)")
        }
        if timer == nil { timer = every(1) { [weak self] in self?.refresh() } }
        access.loadUsers()
        loadTailnetName()
        refresh()
    }

    /// This Mac's MagicDNS name, shown first among the addresses.
    private func loadTailnetName() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let me: TailnetPeer?
            do { me = try Tailnet.peers().first(where: { $0.isSelf }) } catch {
                Log.warning(.tailnet, "this Mac's tailnet name is unknown: \(error.localizedDescription)")
                return
            }
            guard let me else { return }
            Log.info(.tailnet, "this Mac on the tailnet: \(me.shortName) \(me.tailscaleIPs.joined(separator: " ")) (\(me.dnsName.isEmpty ? "no MagicDNS" : me.dnsName))")
            DispatchQueue.main.async {
                guard let self else { return }
                let name = me.dnsName.isEmpty ? [] : [me.shortName]
                self.model.addresses = name + me.tailscaleIPs.filter { !$0.contains(":") }
            }
        }
    }

    func show(pick: Bool) {
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        onVisibilityChange?()
        if pick, core?.primaryID == nil, model.listening, Permissions.screenRecording { chooseWindow() }
    }

    private func makeWindow() {
        let root = HostWindowView(model: model, access: access)
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = "\(Brand.name) — Sharing"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 820, height: 600))
        w.minSize = NSSize(width: 640, height: 440)
        w.setFrameAutosaveName("HostWindow")
        if !w.setFrameUsingName("HostWindow") { w.center() }
        window = w
    }

    func windowWillClose(_ n: Notification) {
        // Sharing goes on (the menu bar item says so, and has Stop Sharing).
        DispatchQueue.main.async { self.onVisibilityChange?() }
    }

    /// Stop Sharing: the viewer is disconnected, every window goes back where it was, virtual displays
    /// are removed (one at a time, as usual), and the ports are closed.
    func stopSharing() {
        timer?.cancel()
        timer = nil
        let h = core
        core = nil
        model.listening = false
        model.viewer = nil
        model.cards = []
        window?.close()
        Task { @MainActor [weak self] in
            await h?.shutdown()
            self?.onStopped?()
        }
    }

    /// The app is quitting: put windows back and remove displays now (synchronously).
    func terminate() { core?.stop() }

    // MARK: Refresh

    private func refresh() {
        guard let core else { return }
        ticks += 1
        let server = core.server
        let bytes = server.bytesOut.total
        let mbps = Double(bytes - lastBytes) * 8 / 1_000_000
        lastBytes = bytes

        if let v = server.currentViewer {
            var parts: [String] = []
            if let (s, at) = core.lastStats, Date().timeIntervalSince(at) < 12 {
                if s.rttMin != 0xFFFF { parts.append("RTT \(s.rttMin) ms") }
                if s.inputSamples > 0, s.inputP50 != 0xFFFF { parts.append("click→screen \(s.inputP50) ms") }
            }
            parts.append(String(format: "%.1f Mbps", mbps))
            let who = v.who
            model.viewer = HostModel.Viewer(name: who.userName, device: who.kind == .tailnet ? who.deviceName : (v.name.isEmpty ? who.label : v.name),
                                            initials: who.initials, address: who.address, detail: parts.joined(separator: " · "))
        } else if model.viewer != nil {
            model.viewer = nil
        }

        let statuses = core.streamStatuses
        var frames: [UInt16: Int] = [:]
        model.cards = statuses.map { s in
            let fps = s.framesSent - (lastFrames[s.id] ?? s.framesSent)
            frames[s.id] = s.framesSent
            let scale = s.points.width > 0 ? s.pixels.width / s.points.width : 0
            let size = s.points.width > 0 ? "\(Int(s.points.width))×\(Int(s.points.height)) pt" + (scale > 0 ? String(format: " @%gx", (scale * 10).rounded() / 10) : "") : "—"
            let rate = !s.open ? "not open" : (fps > 0 ? "\(fps) fps" : "idle")
            return HostModel.Card(id: s.id, title: s.title.isEmpty ? s.appName : s.title, appName: s.appName, size: size, rate: rate,
                                  isPrimary: s.isPrimary, open: s.open, thumbnail: thumbnails[s.id])
        }
        lastFrames = frames
        thumbnails = thumbnails.filter { id, _ in statuses.contains { $0.id == id } }
        if isVisible, ticks % 2 == 0 {
            for s in statuses {
                core.thumbnail(stream: s.id, width: 480) { [weak self] cg in
                    guard let self, let cg else { return }
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    thumbnails[s.id] = img
                    if let i = model.cards.firstIndex(where: { $0.id == s.id }) { model.cards[i].thumbnail = img }
                }
            }
        }

        if ticks % 2 == 0 || ticks == 1 {
            let sr = Permissions.screenRecording, ax = Permissions.accessibility
            if sr != model.screenRecording || ticks == 1 { Log.info(.host, "permission: Screen Recording \(sr ? "granted" : "not granted")") }
            if ax != model.accessibility || ticks == 1 { Log.info(.host, "permission: \(Permissions.accessibilityTitle) \(ax ? "granted" : "not granted")") }
            if sr != model.screenRecording { model.screenRecording = sr }
            if ax != model.accessibility { model.accessibility = ax }
        }
        if model.screenLocked != core.screenLocked { model.screenLocked = core.screenLocked }
        if ticks % 15 == 1 {
            Permissions.screenLockEnabled { [weak self] on in
                if self?.model.screenLockEnabled != on { Log.info(.host, "screen lock (password after sleep or screen saver): \(on.map { $0 ? "on" : "off" } ?? "unknown")") }
                self?.model.screenLockEnabled = on
            }
        }

        let s = summary
        if s != lastSummary { lastSummary = s; onStateChange?() }
    }

    // MARK: Window picker

    func chooseWindow() {
        guard let core else { return }
        guard Permissions.screenRecording else {
            log("Screen Recording isn't allowed yet. Turn on \(Brand.name) in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen \(Brand.name).")
            Permissions.openScreenRecordingSettings()
            return
        }
        guard core.streamStatuses.count < core.maxStreams || core.primaryID != nil else {
            log("\(core.maxStreams) windows are shared already: the viewer can close one, or raise the limit in Settings")
            NSSound.beep()
            return
        }
        if #available(macOS 15.2, *) {
            // The system picker: click the window you want to share.
            let picker = SCContentSharingPicker.shared
            var cfg = SCContentSharingPickerConfiguration()
            cfg.allowedPickerModes = [.singleWindow]
            if let id = Bundle.main.bundleIdentifier { cfg.excludedBundleIDs = [id] }
            picker.defaultConfiguration = cfg
            picker.add(self)
            picker.isActive = true
            picker.present(using: .window)
        } else {
            chooseFromList()
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard #available(macOS 15.2, *), let w = filter.includedWindows.first else { return }
        picker.isActive = false
        DispatchQueue.main.async { self.share(w) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        picker.isActive = false
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { Log.warning(.host, "window picker failed: \(Log.describe(error))"); self.chooseFromList() }
    }

    /// Fallback for macOS before 15.2: a plain list.
    private func chooseFromList() {
        Task { @MainActor in
            guard let windows = await Host.windows(for: "the window list to share from"), !windows.isEmpty else { Log.info(.host, "no windows to share"); return }
            let mine = Bundle.main.bundleIdentifier
            let list = windows.filter { $0.owningApplication?.bundleIdentifier != mine }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
            for w in list {
                popup.addItem(withTitle: "\(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "untitled")")
            }
            let alert = NSAlert()
            alert.messageText = "Choose a window to share"
            alert.accessoryView = popup
            alert.addButton(withTitle: "Share")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 else { return }
            share(list[popup.indexOfSelectedItem])
        }
    }

    private func share(_ w: SCWindow) {
        Task { @MainActor in
            do {
                try await core?.share(w)
                refresh()
            } catch {
                log("could not share that window: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Views

enum HostSection: String, CaseIterable, Identifiable {
    case sharing = "Sharing", allowed = "Allowed Viewers", permissions = "Permissions", log = "Log"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .sharing: "rectangle.on.rectangle"
        case .allowed: "person.2"
        case .permissions: "lock.shield"
        case .log: "text.alignleft"
        }
    }
}

struct HostWindowView: View {
    @Bindable var model: HostModel
    @Bindable var access: AccessSettings
    @State private var section: HostSection? = .sharing

    var body: some View {
        NavigationSplitView {
            List(HostSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            Group {
                switch section ?? .sharing {
                case .sharing: SharingPane(model: model)
                case .allowed: Form { AllowListEditor(access: access) }.formStyle(.grouped)
                case .permissions: Form { ReadinessSection(model: model, title: "Permissions") }.formStyle(.grouped)
                case .log: LogPane()
                }
            }
            .navigationTitle((section ?? .sharing).rawValue)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseWindow() } label: { Label("Share a Window…", systemImage: "plus.rectangle.on.rectangle") }
                    .help("Choose a window to share")
                    .disabled(!model.listening)
                Button(role: .destructive) { model.stopSharing() } label: { Label("Stop Sharing", systemImage: "stop.circle") }
                    .help("Stop sharing this Mac")
            }
        }
    }
}

struct SharingPane: View {
    @Bindable var model: HostModel

    var body: some View {
        Form {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Connected") {
                if let v = model.viewer {
                    HStack(spacing: 12) {
                        Avatar(initials: v.initials)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(v.name) · \(v.device)").font(.body.weight(.medium)).lineLimit(1)
                            Text(v.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        DisconnectButton { model.disconnectViewer() }
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.questionmark").font(.title2).foregroundStyle(.secondary)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.listening ? "No one is connected" : "Not sharing").font(.body.weight(.medium))
                            Text(model.addresses.isEmpty
                                 ? "Tailscale isn't running on this Mac, so viewers can't reach it."
                                 : "Viewers on your tailnet connect to \(model.addresses.joined(separator: " or ")).")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Shared windows · \(model.cards.count) of \(model.maxStreams)") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(model.cards) { WindowCard(card: $0) }
                    ForEach(0 ..< max(0, model.maxStreams - model.cards.count), id: \.self) { _ in
                        FreeSlot { model.chooseWindow() }
                    }
                }
                .padding(.vertical, 4)
            }
            ReadinessSection(model: model, title: "Ready to share")
        }
        .formStyle(.grouped)
    }
}

struct Avatar: View {
    var initials: String
    var body: some View {
        Text(initials)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .accessibilityHidden(true)
    }
}

struct DisconnectButton: View {
    var action: () -> Void
    var body: some View {
        if #available(macOS 26, *) {
            Button("Disconnect", action: action).buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            Button("Disconnect", action: action).buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// A small label floating over a thumbnail: Liquid Glass on macOS 26+, a material before.
struct FloatingBadge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

struct WindowCard: View {
    var card: HostModel.Card
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let t = card.thumbnail {
                    Image(nsImage: t).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).padding(4)
                } else {
                    Image(systemName: "macwindow").font(.largeTitle).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(card.rate).font(.caption2.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .modifier(FloatingBadge())
                    .padding(6)
            }
            .frame(height: 110)
            HStack(spacing: 4) {
                Text(card.title).font(.callout.weight(.medium)).lineLimit(1)
                if card.isPrimary {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).help("The window viewers open first")
                }
            }
            Text("\(card.appName) · \(card.size)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .accessibilityElement(children: .combine)
    }
}

struct FreeSlot: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.title3)
                Text("Free slot").font(.callout)
                Text("Share a window, or let the viewer open one").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.tertiary))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Share a window")
    }
}

/// Screen Recording, Accessibility (Device Control on macOS 27) and the screen lock, each with its live
/// state and a button to the right pane of System Settings when something's missing.
struct ReadinessSection: View {
    @Bindable var model: HostModel
    var title: String

    var body: some View {
        Section {
            PermissionRow(symbol: "rectangle.dashed.badge.record", title: "Screen & System Audio Recording",
                          detail: model.screenRecording ? "Viewers see the shared windows." : "Needed to share windows. After allowing it, quit and reopen \(Brand.name).",
                          granted: model.screenRecording, open: Permissions.openScreenRecordingSettings)
            PermissionRow(symbol: "accessibility", title: Permissions.accessibilityTitle,
                          detail: model.accessibility ? "Viewers can click, type, resize and use menus."
                              : "Without it viewers can watch but not control. In \(Permissions.accessibilityLocation).",
                          granted: model.accessibility, open: Permissions.openAccessibilitySettings)
            if model.screenLocked {
                WarningRow(title: "This Mac's screen is locked",
                           detail: "Every click and key from a viewer goes to the lock screen. Unlock this Mac to share.",
                           open: nil)
            } else if model.screenLockEnabled == true {
                WarningRow(title: "The screen lock would stop input",
                           detail: "When this Mac locks, viewers' clicks and keys go to the lock screen. \(Brand.name) keeps it awake while someone is connected.",
                           open: Permissions.openLockScreenSettings)
            }
        } header: {
            Text(title)
        }
    }
}

struct PermissionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var granted: Bool
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(granted ? Color.accentColor : .orange).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green).font(.callout)
            } else {
                Button("Open Settings", action: open)
            }
        }
        .padding(.vertical, 2)
    }
}

struct WarningRow: View {
    var title: String
    var detail: String
    var open: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.yellow).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let open { Button("Open Settings", action: open) }
        }
        .padding(.vertical, 2)
    }
}

/// The allow-list: tailnet logins that may connect (empty: anyone on the tailnet), and the LAN switch.
struct AllowListEditor: View {
    @Bindable var access: AccessSettings
    @State private var newLogin = ""

    var body: some View {
        Section {
            if access.allowed.isEmpty {
                Label("Anyone on your tailnet can connect.", systemImage: "person.3").foregroundStyle(.secondary)
            }
            ForEach(access.allowed, id: \.self) { login in
                HStack(spacing: 10) {
                    Avatar(initials: initials(for: login))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name(for: login) ?? login)
                        if name(for: login) != nil { Text(login).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(role: .destructive) { access.allowed.removeAll { $0 == login } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(login)")
                }
            }
            HStack {
                TextField("Tailscale login, e.g. name@example.com", text: $newLogin)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { access.add(newLogin); newLogin = "" }
                Button("Add") { access.add(newLogin); newLogin = "" }.disabled(newLogin.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("From Tailnet") {
                    ForEach(access.users.filter { u in !access.allowed.contains(u.login) }, id: \.login) { u in
                        Button(u.name.isEmpty ? u.login : "\(u.name) (\(u.login))") { access.add(u.login) }
                    }
                }
                .fixedSize()
                .disabled(access.users.isEmpty)
            }
        } header: {
            Text("Allowed viewers")
        } footer: {
            Text("Empty: anyone on your tailnet can connect (Tailscale's own access controls still apply). Otherwise only these people, by their Tailscale login; anyone else is refused and told why. Applies to the next connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Allow connections from outside Tailscale", isOn: $access.allowLAN)
        } footer: {
            Text("Off by default: \(Brand.name) has no encryption of its own, so outside Tailscale its traffic isn't encrypted and nobody can be identified. Connections from this Mac itself are always allowed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if access.users.isEmpty { access.loadUsers() } }
    }

    private func name(for login: String) -> String? {
        access.users.first { $0.login.caseInsensitiveCompare(login) == .orderedSame }.flatMap { $0.name.isEmpty ? nil : $0.name }
    }

    private func initials(for login: String) -> String {
        PeerIdentity.initials(of: name(for: login) ?? login)
    }
}

struct LogPane: View {
    var body: some View {
        LogTextView().ignoresSafeArea(edges: .bottom)
    }
}

/// The log, in an NSTextView (fast with thousands of lines), following new lines while scrolled to the end.
struct LogTextView: NSViewRepresentable {
    final class Coordinator {
        var token: UUID?
        deinit { if let token { LogStore.shared.remove(token) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.drawsBackground = false
        scroll.drawsBackground = false
        let attrs: [NSAttributedString.Key: Any] = [.font: text.font!, .foregroundColor: NSColor.textColor]
        text.textStorage?.append(NSAttributedString(string: LogStore.shared.lines.map { $0 + "\n" }.joined(), attributes: attrs))
        text.scrollToEndOfDocument(nil)
        context.coordinator.token = LogStore.shared.observe { [weak text, weak scroll] line in
            guard let text else { return }
            let atBottom = (scroll?.verticalScroller?.floatValue ?? 1) > 0.98
            text.textStorage?.append(NSAttributedString(string: line + "\n", attributes: attrs))
            if atBottom { text.scrollToEndOfDocument(nil) }
        }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {}
}
