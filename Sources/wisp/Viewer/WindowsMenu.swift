// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// Menu bar item listing the host's windows under their apps' icons. Choosing one opens it in a
/// local window of its own (a new stream; in phantom mode, in its app's phantom); a checkmark shows
/// the ones open here, and choosing one of those brings its window to the front (stages 2 and 3 of
/// docs/multi-window.md). In phantom mode this is all of Wisp while connected: it also says how the
/// connection is, shows the host's refusals (e.g. its stream limit), and has Disconnect.
final class RemoteWindowsMenu: NSObject, NSMenuDelegate {
    /// The user chose host window `id`.
    var onChoose: ((UInt32) -> Void)?
    /// Whether host window `id` is open in a local window.
    var isOpen: (UInt32) -> Bool = { _ in false }
    var onDisconnect: (() -> Void)?
    /// Connection state ("Connecting…", "Disconnected: …"); nil while connected.
    var status: String? { didSet { rebuild() } }
    /// The host's last refusal (e.g. its stream limit), shown at the top until the next window opens.
    var notice: String? { didSet { rebuild(); updateButton() } }
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let client: Client
    private let hostName: String
    private let phantoms: Bool
    private var windows: [RemoteWindow]?
    private var firstAsked = Date()

    init(client: Client, hostName: String, phantoms: Bool = false) {
        self.client = client
        self.hostName = hostName
        self.phantoms = phantoms
        super.init()
        updateButton()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        client.requestWindowList() // so the first open already has a list
        rebuild()
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    /// A new list from the host (replies can land while the menu is open: it's rebuilt in place).
    func update(_ list: [RemoteWindow]) {
        windows = list
        rebuild()
    }

    private func updateButton() {
        let symbol = notice == nil ? "macwindow.on.rectangle" : "exclamationmark.triangle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Windows on \(hostName)")
        item.button?.toolTip = notice ?? "Windows on \(hostName)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        client.requestWindowList() // titles change; refresh in place when the answer arrives
        rebuild()
    }

    /// Redraws the list (e.g. after a local window opened or closed, so the checkmarks move).
    func rebuild() {
        menu.removeAllItems()
        if let status { menu.addItem(note(status)) }
        if let notice { menu.addItem(note("⚠︎ " + notice)) }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        if let windows {
            if windows.isEmpty { menu.addItem(note("\(hostName) has no windows to share")) }
            // Group by app, apps in the order the host listed them (front to back).
            var order: [String] = []
            var byApp: [String: [RemoteWindow]] = [:]
            for w in windows {
                if byApp[w.entry.appKey] == nil { order.append(w.entry.appKey) }
                byApp[w.entry.appKey, default: []].append(w)
            }
            for (i, key) in order.enumerated() {
                let group = byApp[key]!
                if i > 0 { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: group[0].entry.appName))
                let icon = group[0].icon.flatMap(NSImage.init(data:))
                icon?.size = NSSize(width: 16, height: 16)
                for w in group {
                    let e = w.entry
                    let mi = NSMenuItem(title: e.title.isEmpty ? e.appName : e.title, action: #selector(choose(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.tag = Int(e.id)
                    mi.image = icon
                    let open = isOpen(e.id)
                    mi.state = open ? .on : .off
                    mi.toolTip = "\(e.appName) · \(e.points.w)×\(e.points.h) pt · window \(e.id)" + (open ? " · open here" : "")
                    menu.addItem(mi)
                }
            }
        } else if status == nil {
            let old = Date().timeIntervalSince(firstAsked) > 3
            menu.addItem(note(old ? "\(hostName) didn't answer: its \(Brand.name) may be too old to list windows" : "Asking \(hostName) for its windows…"))
        }
        guard phantoms else { return }
        menu.addItem(.separator())
        let d = NSMenuItem(title: "Disconnect from \(hostName)", action: #selector(disconnect), keyEquivalent: "")
        d.target = self
        menu.addItem(d)
        menu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    private func note(_ s: String) -> NSMenuItem {
        let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func choose(_ sender: NSMenuItem) { onChoose?(UInt32(sender.tag)) }
    @objc private func disconnect() { onDisconnect?() }
}
