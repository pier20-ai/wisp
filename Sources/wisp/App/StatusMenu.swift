// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Tailnet
import WispCommon

/// What the menu bar item asks the app to do.
protocol StatusMenuActions: AnyObject {
    /// Connect to `address` (a tailnet name or IP), shown as `label`.
    func connect(to address: String, label: String)
    func disconnect()
    func openHostWindow()
    func stopSharing()
    func openSettings()
    func revealLogs()
    func copyDiagnostics()
    /// The viewer session, if connected or connecting.
    var session: ViewerSession? { get }
    /// Sharing from this Mac (the host window's host is running), and who is connected to it.
    var sharingSummary: String? { get }
}

/// The app's menu bar item: the app icon's glyph, and a native NSMenu (Liquid Glass on macOS 26+):
///
///     [host · Connected · 12 ms            (switch)]
///     Windows
///       [icon] Safari — Start Page            ✓
///       2 of 3 open
///     Other Macs on your tailnet
///       ● studio-mac      Sharing
///       ○ old-mini        Not sharing
///       Connect to Address…
///     Share Windows from This Mac…
///     Settings…                               ⌘,
///     Check for Updates…                      (release builds)
///     Quit Wisp                              ⌘Q
///
/// The Macs come from Tailscale (TailnetDiscovery), refreshed every 5 s while the menu is open; the
/// windows from the connected host (ViewerSession). Main queue.
final class StatusMenuController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let discovery = TailnetDiscovery()
    private weak var actions: StatusMenuActions?
    private let header = HeaderView()
    private lazy var headerItem: NSMenuItem = {
        let mi = NSMenuItem()
        mi.view = header
        return mi
    }()
    /// The connected host's stream limit (from a probe), for "N of 3 open".
    private var hostMaxStreams: [String: Int] = [:]
    private var isOpen = false
    private var headerTimer: Timer?
    /// WISP_MENU_DUMP=<path>: the menu tree is written there after every rebuild (tests can't click).
    private let dumpPath = ProcessInfo.processInfo.environment["WISP_MENU_DUMP"]

    init(actions: StatusMenuActions) {
        self.actions = actions
        super.init()
        item.button?.image = Glyph.menuBar()
        item.button?.toolTip = Brand.name
        item.button?.setAccessibilityTitle(Brand.name)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        header.onToggle = { [weak self] on in self?.toggle(on) }
        discovery.onChange = { [weak self] in self?.rebuild() }
        discovery.refresh()
        rebuild()
        if dumpPath != nil { dumpTimer = every(2) { [weak self] in self?.rebuild() } } // keep the dump current
    }
    private var dumpTimer: DispatchSourceTimer?

    // MARK: Menu delegate

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        actions?.session?.client.requestWindowList() // titles change: refreshed in place when the answer comes
        discovery.start()
        probeConnectedHost()
        rebuild()
        // The latency in the header, live while the menu is open (common modes: the menu is tracking).
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateHeader() }
        RunLoop.main.add(t, forMode: .common)
        headerTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        discovery.stop()
        headerTimer?.invalidate()
        headerTimer = nil
    }

    // MARK: Building

    /// The session changed (connected, a window opened, a new window list…).
    func sessionChanged() {
        if let s = actions?.session, s.isConnected, hostMaxStreams[s.hostName] == nil { probeConnectedHost() }
        updateButton()
        rebuild()
    }

    private func probeConnectedHost() {
        guard let s = actions?.session, s.isConnected else { return }
        let host = s.hostName
        Probe.run(host: host) { [weak self] r in
            if case .sharing(let reply) = r, reply.maxStreams > 0 { self?.hostMaxStreams[host] = reply.maxStreams; self?.rebuild() }
        }
    }

    private func updateButton() {
        let notice = actions?.session?.notice
        item.button?.image = Glyph.menuBar()
        item.button?.appearsDisabled = false
        item.button?.toolTip = notice.map { "\(Brand.name): \($0)" } ?? actions?.session.map { "\(Brand.name): \($0.isConnected ? "connected to" : "connecting to") \(label(for: $0.hostName))" } ?? Brand.name
    }

    /// The name to show for a host the user connected to (its tailnet name if we know it).
    private func label(for host: String) -> String {
        if let m = discovery.mac(matching: host) { return m.peer.shortName }
        if host == Prefs.lastHost, let l = Prefs.lastHostLabel, !l.isEmpty { return l }
        return host
    }

    /// The header: the host, its state and latency, and the switch.
    private func updateHeader() {
        if let s = actions?.session {
            let state: String
            if let st = s.status { state = st.hasPrefix("Connecting") ? "Connecting…" : st }
            else if let rtt = s.client.latency.rttMin { state = "Connected · \(max(1, Int((Double(rtt) / 1000).rounded()))) ms" }
            else { state = "Connected" }
            header.set(title: label(for: s.hostName), subtitle: state, on: true, enabled: true, warning: s.notice != nil)
        } else if let lastHost = Prefs.lastHost {
            header.set(title: label(for: lastHost), subtitle: "Not connected", on: false, enabled: true, warning: false)
        } else {
            header.set(title: "Not connected", subtitle: "Choose a Mac that's sharing below", on: false, enabled: false, warning: false)
        }
    }

    func rebuild() {
        menu.removeAllItems()
        let session = actions?.session

        updateHeader()
        menu.addItem(headerItem)
        if let notice = session?.notice { menu.addItem(note("⚠︎ " + notice, wrap: true)) }

        // The connected host's windows.
        if let s = session, s.isConnected {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Windows"))
            if let list = s.windowList {
                if list.isEmpty { menu.addItem(note("\(label(for: s.hostName)) has no windows to share")) }
                for w in list where DemoWindows.shows(w.entry.appName) {
                    let e = w.entry
                    let mi = NSMenuItem(title: e.title.isEmpty ? e.appName : e.title, action: #selector(chooseWindow(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.tag = Int(e.id)
                    if let png = w.icon, let icon = NSImage(data: png) {
                        icon.size = NSSize(width: 18, height: 18)
                        mi.image = icon
                    }
                    if #available(macOS 14.4, *), !e.title.isEmpty, e.title != e.appName { mi.subtitle = e.appName }
                    mi.state = s.isOpen(e.id) ? .on : .off
                    mi.toolTip = "\(e.appName) · \(e.points.w)×\(e.points.h) pt"
                    menu.addItem(mi)
                }
                for fake in DemoWindows.fakes {
                    let mi = NSMenuItem(title: fake.title, action: #selector(ignoreDemoWindow(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.image = fake.icon
                    if #available(macOS 14.4, *) { mi.subtitle = fake.app }
                    menu.addItem(mi)
                }
                let max = hostMaxStreams[s.hostName] ?? 3
                menu.addItem(note("\(s.openCount) of \(max) open", small: true))
            } else {
                menu.addItem(note("Asking \(label(for: s.hostName)) for its windows…"))
            }
        }

        // The other Macs on the tailnet.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Other Macs on your tailnet"))
        let current = session?.hostName
        let others = discovery.macs.filter { current == nil || discovery.mac(matching: current!)?.peer.address != $0.peer.address }
        if let error = discovery.error {
            menu.addItem(note(error, wrap: true))
        } else if !discovery.loaded {
            menu.addItem(note("Looking…"))
        } else if others.isEmpty {
            menu.addItem(note("No other Macs on your tailnet"))
        }
        for m in others { menu.addItem(macItem(m)) }
        let other = NSMenuItem(title: "Connect to Address…", action: #selector(connectToAddress), keyEquivalent: "")
        other.target = self
        menu.addItem(other)

        // This Mac, settings, quit.
        menu.addItem(.separator())
        if let sharing = actions?.sharingSummary {
            let show = NSMenuItem(title: "Sharing from This Mac…", action: #selector(openHost), keyEquivalent: "")
            show.target = self
            show.image = Glyph.dot(.systemGreen)
            if #available(macOS 14.4, *) { show.subtitle = sharing }
            menu.addItem(show)
            let stop = NSMenuItem(title: "Stop Sharing", action: #selector(stopSharing), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else {
            let share = NSMenuItem(title: "Share Windows from This Mac…", action: #selector(openHost), keyEquivalent: "")
            share.target = self
            menu.addItem(share)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if let update = Updates.shared.menuItem() { menu.addItem(update) }
        let troubleshooting = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Troubleshooting")
        for (title, action) in [("Reveal Logs in Finder", #selector(revealLogs)), ("Copy Diagnostics", #selector(copyDiagnostics))] {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            sub.addItem(mi)
        }
        troubleshooting.submenu = sub
        menu.addItem(troubleshooting)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        dump()
    }

    private func macItem(_ m: TailnetDiscovery.Mac) -> NSMenuItem {
        let p = m.peer
        let status: String
        let color: NSColor?
        if !p.online { status = "Offline"; color = nil }
        else if let r = m.probe { status = r.summary; color = r.isSharing ? .systemGreen : .tertiaryLabelColor }
        else { status = discovery.probes ? "Checking…" : "Online"; color = .tertiaryLabelColor }
        let mi = NSMenuItem(title: p.shortName, action: nil, keyEquivalent: "")
        mi.image = color.map { Glyph.dot($0) } ?? Glyph.dot(nil)
        if #available(macOS 14.4, *) { mi.subtitle = status } else { mi.title = "\(p.shortName) — \(status)" }
        mi.toolTip = "\(p.dnsName.isEmpty ? p.hostName : p.dnsName) · \(p.address)"
            + (p.userDisplayName.isEmpty ? "" : " · \(p.userDisplayName)")
        if p.online, m.probe?.isSharing ?? !discovery.probes {
            mi.action = #selector(connectToMac(_:))
            mi.target = self
            mi.representedObject = p
        } else {
            mi.isEnabled = false
        }
        return mi
    }

    private func note(_ s: String, small: Bool = false, wrap: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if small || wrap {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            mi.attributedTitle = NSAttributedString(string: wrap ? Self.wrapped(s) : s, attributes: [
                .font: NSFont.menuFont(ofSize: small ? NSFont.smallSystemFontSize : 0),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
            ])
        }
        return mi
    }

    /// Menu items don't wrap: long notes are broken into lines of about 48 characters.
    private static func wrapped(_ s: String, width: Int = 48) -> String {
        var lines: [String] = [], line = ""
        for word in s.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > width { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func toggle(_ on: Bool) {
        if on {
            guard let host = Prefs.lastHost else { return }
            Log.info(.app, "menu: switch on, connecting to the last Mac, \(host)")
            actions?.connect(to: host, label: label(for: host))
        } else {
            Log.info(.app, "menu: switch off, disconnecting")
            actions?.disconnect()
        }
    }

    @objc private func chooseWindow(_ sender: NSMenuItem) { actions?.session?.open(windowID: UInt32(sender.tag)) }

    @objc private func connectToMac(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? TailnetPeer else { return }
        Log.info(.app, "menu: connect to \(p.shortName) (\(p.dnsName.isEmpty ? "no MagicDNS name" : p.dnsName)) at \(p.connectAddress)")
        actions?.connect(to: p.connectAddress, label: p.shortName)
    }

    @objc private func connectToAddress() {
        let a = NSAlert()
        a.messageText = "Connect to a Mac"
        a.informativeText = "Its Tailscale name or address (the host window on that Mac shows it)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. studio-mac or 100.101.102.103"
        field.stringValue = Prefs.lastHost ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        Log.info(.app, "menu: connect to the address \"\(host)\"" + (discovery.mac(matching: host).map { ", the tailnet's \($0.peer.shortName) (\($0.peer.address))" } ?? ", not a tailnet Mac Tailscale listed"))
        actions?.connect(to: host, label: discovery.mac(matching: host)?.peer.shortName ?? host)
    }

    @objc private func openHost() { actions?.openHostWindow() }
    @objc private func stopSharing() { actions?.stopSharing() }
    @objc private func openSettings() { actions?.openSettings() }
    @objc private func revealLogs() { actions?.revealLogs() }
    @objc private func copyDiagnostics() { actions?.copyDiagnostics() }

    // MARK: Debug

    private func dump() {
        guard let dumpPath else { return }
        var out = "\(Brand.name) status item: image \(item.button?.image.map { "\(Int($0.size.width))x\(Int($0.size.height)) pt template=\($0.isTemplate)" } ?? "none")\n"
        for mi in menu.items {
            if mi.isSeparatorItem { out += "-----\n"; continue }
            var line = mi.isSectionHeader ? "## \(mi.title)" : "  \(mi.attributedTitle?.string.replacingOccurrences(of: "\n", with: " ") ?? mi.title)"
            if let v = mi.view as? HeaderView { line = "[header] \(v.describe)" }
            if #available(macOS 14.4, *), let sub = mi.subtitle { line += "  |  \(sub)" }
            if mi.state == .on { line += "  ✓" }
            if !mi.keyEquivalent.isEmpty { line += "  ⌘\(mi.keyEquivalent.uppercased())" }
            if mi.image != nil { line += "  [image]" }
            if !mi.isEnabled { line += "  (disabled)" }
            out += line + "\n"
            for sub in mi.submenu?.items ?? [] { out += "      > \(sub.title)\n" }
        }
        do { try out.write(toFile: dumpPath, atomically: true, encoding: .utf8) } catch { Log.failed(.app, "writing \(dumpPath)", error) }
    }
}

extension TailnetPeer {
    /// What to connect to: its Tailscale IP. The MagicDNS short name looked nicer but doesn't resolve
    /// for a device shared in from another tailnet (it belongs to the sharer's DNS), which left the
    /// viewer "Connecting…" forever. The name is still what the menu shows.
    var connectAddress: String { address }
}

// MARK: - Header row

/// The menu's first row: the connected (or last) Mac, its state and latency, and a switch to connect
/// or disconnect. A plain view: the menu draws its glass behind it.
final class HeaderView: NSView {
    var onToggle: ((Bool) -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        icon.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        toggle.target = self
        toggle.action = #selector(switched)
        toggle.controlSize = .small
        toggle.setAccessibilityLabel("Connected")
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, subtitle s: String, on: Bool, enabled: Bool, warning: Bool) {
        title.stringValue = t
        subtitle.stringValue = s
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        icon.contentTintColor = warning ? .systemOrange : (on ? .controlAccentColor : .secondaryLabelColor)
        setAccessibilityLabel("\(t), \(s)")
    }

    var describe: String { "\(title.stringValue) | \(subtitle.stringValue) | switch \(toggle.state == .on ? "on" : "off")\(toggle.isEnabled ? "" : " (disabled)")" }

    @objc private func switched() { onToggle?(toggle.state == .on) }
}

// MARK: - Glyphs

enum Glyph {
    /// The menu bar icon: the app icon's "Trail" (a window lifting up and to the right, leaving a
    /// trail) as an 18 pt monochrome template image, so the menu bar tints it for light, dark and
    /// the selected state. Drawn on the icon's 1024 grid (scripts/make-icon.swift), scaled down.
    static func menuBar() -> NSImage {
        let size: CGFloat = 18
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // The icon's body is 824 units, inset 100: map that onto 18 pt with a hair of margin.
            let k = (size - 1) / 824
            ctx.translateBy(x: 0.5 - 100 * k, y: 0.5 - 100 * k)
            ctx.scaleBy(x: k, y: k)
            // The trail: the icon's centre line, one bold round stroke.
            let trail = CGMutablePath()
            trail.move(to: CGPoint(x: 640, y: 214))
            trail.addCurve(to: CGPoint(x: 172, y: 322), control1: CGPoint(x: 420, y: 186), control2: CGPoint(x: 205, y: 206))
            trail.addCurve(to: CGPoint(x: 560, y: 548), control1: CGPoint(x: 142, y: 430), control2: CGPoint(x: 330, y: 500))
            ctx.setLineCap(.round)
            ctx.setLineWidth(78)
            ctx.setStrokeColor(.black)
            ctx.addPath(trail)
            ctx.strokePath()
            // The window, turned 8° anticlockwise about (604, 590), with a clear gap around it so the
            // trail runs "under" it.
            let t = CGAffineTransform(translationX: 604, y: 590).rotated(by: 8 * .pi / 180)
            let body = CGRect(x: -240, y: -162, width: 480, height: 324)
            ctx.saveGState()
            ctx.concatenate(t)
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: body.insetBy(dx: -46, dy: -46), cornerWidth: 86, cornerHeight: 86, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.setFillColor(.black)
            // Outline, then the title bar filled.
            let outline = CGPath(roundedRect: body, cornerWidth: 60, cornerHeight: 60, transform: nil)
            ctx.addPath(outline)
            ctx.setLineWidth(64)
            ctx.strokePath()
            ctx.addPath(outline)
            ctx.clip()
            ctx.fill(CGRect(x: body.minX, y: body.maxY - 110, width: body.width, height: 110))
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = Brand.name
        return img
    }

    /// A status dot for the menu: filled in `color`, or hollow (nil: offline).
    static func dot(_ color: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let d = r.insetBy(dx: 2.5, dy: 2.5)
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: d).fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                let p = NSBezierPath(ovalIn: d.insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 1
                p.stroke()
            }
            return true
        }
        return img
    }
}


/// Debug, for screenshots: WISP_DEMO_WINDOWS="Safari,Zed" lists only those apps' windows in the
/// menu, and WISP_DEMO_FAKE_WINDOWS="Xcode|Package.swift;Notes|Groceries" adds made-up entries (with
/// this Mac's icon for the app, when it has the app) that do nothing when chosen.
enum DemoWindows {
    struct Fake { let app: String; let title: String; let icon: NSImage? }
    private static let env = ProcessInfo.processInfo.environment
    private static let only: Set<String>? = env["WISP_DEMO_WINDOWS"].map { Set($0.split(separator: ",").map(String.init)) }
    static func shows(_ app: String) -> Bool { only?.contains(app) ?? true }
    static let fakes: [Fake] = (env["WISP_DEMO_FAKE_WINDOWS"] ?? "").split(separator: ";").compactMap { item in
        let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let path = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
            .map { "\($0)/\(parts[0]).app" }.first { FileManager.default.fileExists(atPath: $0) }
        let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
        icon?.size = NSSize(width: 18, height: 18)
        return Fake(app: parts[0], title: parts[1], icon: icon)
    }
}

extension StatusMenuController {
    @objc func ignoreDemoWindow(_ sender: Any?) {}
}
