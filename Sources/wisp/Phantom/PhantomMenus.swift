// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// A phantom app's menu bar, mirrored from the remote app's (docs/multi-window.md §10). The host reads
// the remote menu bar through Accessibility and sends it (menuTree); this builds real NSMenus from it
// and sends the item the user chose back (menuPress), which the host presses there.
//
// - App menu: About (local), then the remote app menu's own items (Settings… etc.), then local Hide,
//   Hide Others and Show All, then "Quit <App> on <host>…" (the remote Quit, behind a confirmation and
//   with no shortcut), then the local Quit (⌘Q: stop viewing, the remote app keeps running). The
//   remote About, Services, Hide, Hide Others, Show All and Quit are left out.
// - Window: the local one (it acts on the viewer windows), plus the remote Window menu's own items
//   (not its Minimize, Zoom, … or its window list).
// - Every other remote menu as it is, in the remote order. Help becomes NSApp.helpMenu, so its search
//   field searches the mirrored menus.
// - Shortcuts are shown, but only for display: while a remote window is key, every key goes to the
//   remote app (ViewerController's key monitor runs before menu key equivalents), which runs its own
//   shortcut there. With no remote window key, remote menus don't match key equivalents at all
//   (menuHasKeyEquivalent), and a match in the mixed app and Window menus is ignored (pick), so a
//   shortcut never presses a remote item by itself. Only ⌘Q, ⌘H and ⌥⌘H act locally, as before.
// - Fresh state: a menu shows its cached items at once when it opens and asks the host for a fresh
//   copy (menuWillOpen); the reply, one round trip later, updates it in place, open or not.
final class PhantomMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private unowned let owner: PhantomAppDelegate
    /// The remote top-level menus (AX index, title), in order.
    private var bar: [MenuTree.MenuTitle] = []
    /// Their items, by AX index.
    private var trees: [UInt16: MenuNode] = [:]
    /// The NSMenus of remote top-level menus (all but the app and Window menus), by AX index.
    private var menus: [UInt16: NSMenu] = [:]
    /// Each mirrored NSMenu (submenus too, the app and Window menus too) → its top-level menu's AX index.
    private var topIndex: [ObjectIdentifier: UInt16] = [:]
    /// Requests on their way: AX index (wholeBar too) → when sent. A request is not repeated within `timeout`.
    private var pending: [UInt16: Date] = [:]
    private static let timeout: TimeInterval = 1.5
    private var lastBar = Date.distantPast
    /// The remote app menu's Quit item, shown as "Quit <App> on <host>…".
    private var remoteQuit: [MenuTree.MenuTitle]?
    /// Items this class put in the local app and Window menus (removed and remade on each update).
    private static let remoteTag = 0x5743

    init(owner: PhantomAppDelegate) {
        self.owner = owner
        super.init()
        mixed.owner = self
        owner.appMenu.delegate = mixed
        owner.windowMenu.delegate = mixed
    }

    /// The app and Window menus mix local and remote items: they ask for fresh remote items when they
    /// open, but keep AppKit's own key equivalent matching for their local items (⌘Q, ⌘H, ⌥⌘H, ⌘M).
    private final class MixedDelegate: NSObject, NSMenuDelegate {
        weak var owner: PhantomMenus?
        func menuWillOpen(_ menu: NSMenu) { owner?.menuWillOpen(menu) }
    }
    private let mixed = MixedDelegate()

    private var appIndex: UInt16? { bar.first?.index }
    /// The remote Window and Help menus, by their (English) titles: AX gives no other way to tell.
    private var windowIndex: UInt16? { bar.first { $0.index != appIndex && $0.title == "Window" }?.index }
    private var helpIndex: UInt16? { bar.last { $0.title == "Help" }?.index }

    // MARK: Requests

    /// The whole menu bar (when the phantom connects, and when it becomes active after a while).
    func requestBar(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastBar) > 5 else { return }
        lastBar = Date()
        request(MenuTree.wholeBar)
    }

    private func request(_ index: UInt16) {
        if let at = pending[index], Date().timeIntervalSince(at) < Self.timeout { return }
        pending[index] = Date()
        owner.sendToHost(MenuTree.request(appKey: owner.appKey, menu: index))
    }

    /// A menu is about to open: it shows what we have, and asks for a fresh copy of its top-level menu.
    func menuWillOpen(_ menu: NSMenu) {
        guard let i = topIndex[ObjectIdentifier(menu)] else {
            if bar.isEmpty { requestBar() }
            return
        }
        request(i)
    }

    /// Remote menus never match a key equivalent: keys go to the remote app (see the top of this file).
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    private func matches(_ e: NSEvent, _ item: NSMenuItem) -> Bool {
        guard !item.keyEquivalent.isEmpty, let chars = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        var mask = item.keyEquivalentModifierMask.intersection(relevant)
        var key = item.keyEquivalent
        if key != key.lowercased() { key = key.lowercased(); mask.insert(.shift) }
        let mods = e.modifierFlags.intersection(relevant)
        // A shifted character ("?") matches with or without shift in the item's mask.
        return chars == key && (mods == mask || mods.subtracting(.shift) == mask.subtracting(.shift) && key.lowercased() == key.uppercased())
    }

    // MARK: Replies

    /// A menuTree message from the host (as it sent it).
    func received(_ msg: Data) {
        guard let (type, payload) = MessageParser().feed(msg).first, type == .menuTree,
              let (_, tree) = MenuTree.decode(payload) else { return }
        switch tree {
        case .bar(let titles):
            pending[MenuTree.wholeBar] = nil
            guard titles != bar else { return }
            bar = titles
            trees = trees.filter { k, v in titles.contains { $0.index == k && $0.title == v.title } }
            rebuildBar()
        case .menu(let node):
            pending[node.index] = nil
            guard bar.contains(where: { $0.index == node.index }) else { return }
            guard trees[node.index] != node else { return }
            trees[node.index] = node
            update(node.index)
        case .none(let why):
            pending = [:]
            log("phantom \(owner.appName): no remote menus: \(why)")
        }
    }

    // MARK: Building

    /// The top-level menus changed: lay out the menu bar again.
    private func rebuildBar() {
        let main = owner.mainMenu
        menus = [:]
        topIndex = [:]
        let win = windowIndex
        var order: [NSMenuItem] = []
        for t in bar where t.index != appIndex {
            if t.index == win { order.append(owner.windowMenuItem); continue }
            let m = NSMenu(title: t.title)
            m.autoenablesItems = false
            m.delegate = self
            let item = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
            item.submenu = m
            if win == nil, t.index == helpIndex { order.append(owner.windowMenuItem) }
            order.append(item)
            menus[t.index] = m
            topIndex[ObjectIdentifier(m)] = t.index
            if t.index == helpIndex { NSApp.helpMenu = m }
        }
        if !order.contains(where: { $0 === owner.windowMenuItem }) { order.append(owner.windowMenuItem) }
        for item in main.items where item !== owner.appMenuItem { main.removeItem(item) }
        order.forEach { main.addItem($0) }
        if let a = appIndex { topIndex[ObjectIdentifier(owner.appMenu)] = a }
        if let win { topIndex[ObjectIdentifier(owner.windowMenu)] = win }
        bar.forEach { update($0.index) }
        log("phantom \(owner.appName): menu bar mirrored: \(bar.map(\.title).joined(separator: ", "))")
    }

    /// Top-level menu `index`'s items changed (or its NSMenu is new): show them.
    private func update(_ index: UInt16) {
        let node = trees[index]
        let path = [MenuTree.MenuTitle(index: index, title: node?.title ?? "")]
        if index == appIndex {
            fillAppMenu(node, path: path)
        } else if index == windowIndex {
            fillWindowMenu(node, path: path)
        } else if let m = menus[index] {
            reconcile(m, with: items(node?.children ?? [], path: path), top: index)
        }
    }

    private static func isStandardAppItem(_ n: MenuNode) -> Bool {
        let t = n.title
        return t.hasPrefix("About ") || (t == "Services" && n.children != nil) || t.hasPrefix("Hide ") || t == "Hide Others"
            || t == "Show All" || (n.key == "h" && (n.mods == [.command] || n.mods == [.command, .option]))
    }

    private static func isQuit(_ n: MenuNode) -> Bool { (n.key == "q" && n.mods == [.command]) || n.title.hasPrefix("Quit ") }

    /// The app menu: local About, the remote app menu's own items, local Hide…, remote Quit, local Quit.
    private func fillAppMenu(_ node: MenuNode?, path: [MenuTree.MenuTitle]) {
        let m = owner.appMenu
        m.items.filter { $0.tag == Self.remoteTag }.forEach { m.removeItem($0) }
        let kids = node?.children ?? []
        remoteQuit = kids.first(where: Self.isQuit).map { path + [MenuTree.MenuTitle(index: $0.index, title: $0.title)] }
        let own = items(kids.filter { !Self.isStandardAppItem($0) && !Self.isQuit($0) }, path: path)
        // After About and its separator.
        var at = 2
        for item in own + (own.isEmpty ? [] : [NSMenuItem.separator()]) {
            item.tag = Self.remoteTag
            item.submenu.map { register($0, top: path[0].index) }
            m.insertItem(item, at: min(at, m.numberOfItems))
            at += 1
        }
        if remoteQuit != nil, let quit = m.items.firstIndex(where: { $0.action == #selector(NSApplication.terminate(_:)) }) {
            let q = NSMenuItem(title: "Quit \(owner.appName) on \(owner.hostName)…", action: #selector(quitRemote(_:)), keyEquivalent: "")
            q.target = self
            q.tag = Self.remoteTag
            q.toolTip = "Quits \(owner.appName) on \(owner.hostName). Quit \(owner.appName) (⌘Q) only stops viewing it here."
            m.insertItem(q, at: quit)
        }
        topIndex[ObjectIdentifier(m)] = appIndex
    }

    private static let standardWindowItems: Set<String> = [
        "Minimize", "Minimize All", "Zoom", "Zoom All", "Fill", "Center", "Move & Resize", "Full Screen Tile",
        "Enter Full Screen", "Exit Full Screen", "Remove Window from Set", "Show Tab Bar", "Hide Tab Bar",
        "Show All Tabs", "Arrange in Front", "Bring All to Front",
    ]

    /// The local Window menu, plus the remote Window menu's own items (before Bring All to Front; the
    /// remote one's window list, after its own Bring All to Front, is left out: Windows on <host> has it).
    private func fillWindowMenu(_ node: MenuNode?, path: [MenuTree.MenuTitle]) {
        let m = owner.windowMenu
        m.items.filter { $0.tag == Self.remoteTag }.forEach { m.removeItem($0) }
        var kids = node?.children ?? []
        if let end = kids.firstIndex(where: { $0.title == "Bring All to Front" || $0.title == "Arrange in Front" }) { kids = Array(kids[..<end]) }
        let own = items(kids.filter { !Self.standardWindowItems.contains($0.title) }, path: path)
        topIndex[ObjectIdentifier(m)] = windowIndex
        guard !own.isEmpty, var at = m.items.firstIndex(where: { $0.action == #selector(NSApplication.arrangeInFront(_:)) }) else { return }
        for item in [NSMenuItem.sectionHeader(title: "\(owner.appName) on \(owner.hostName)")] + own + [NSMenuItem.separator()] {
            item.tag = Self.remoteTag
            item.submenu.map { register($0, top: path[0].index) }
            m.insertItem(item, at: at)
            at += 1
        }
    }

    /// Items the remote app has but that make no sense here (macOS adds them to every app's Edit
    /// menu; they would act on the host's own text input).
    private static let skipped: Set<String> = ["AutoFill", "Start Dictation…", "Start Dictation", "Emoji & Symbols"]

    /// NSMenuItems for remote items: separators collapsed (none first, last or twice in a row).
    private func items(_ nodes: [MenuNode], path: [MenuTree.MenuTitle]) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for n in nodes where !Self.skipped.contains(n.title) {
            if n.separator {
                if let last = out.last, !last.isSeparatorItem { out.append(.separator()) }
                continue
            }
            let p = path + [MenuTree.MenuTitle(index: n.index, title: n.title)]
            let item = NSMenuItem(title: n.title, action: #selector(pick(_:)), keyEquivalent: n.key)
            item.target = self
            item.keyEquivalentModifierMask = Self.flags(n.mods)
            item.isEnabled = n.enabled
            item.state = n.mark.isEmpty ? .off : ["-", "–", "—"].contains(n.mark) ? .mixed : .on
            item.representedObject = MenuPath(p, enabled: n.enabled)
            // An item with the previous one's shortcut plus more modifiers (Close / Close All ⌥⌘W) is its
            // alternate: shown in its place while those modifiers are held, as in the remote app.
            if let prev = out.last, !prev.isSeparatorItem, !n.key.isEmpty, prev.keyEquivalent == n.key,
               item.keyEquivalentModifierMask.isStrictSuperset(of: prev.keyEquivalentModifierMask) {
                item.isAlternate = true
            }
            if n.title == "Enter Full Screen" || n.title == "Exit Full Screen" {
                // Full screen is the viewer window's (the remote window follows its size).
                item.action = #selector(NSWindow.toggleFullScreen(_:))
                item.target = nil; item.representedObject = nil
            }
            if let kids = n.children {
                let sub = NSMenu(title: n.title)
                sub.autoenablesItems = false
                sub.delegate = self
                items(kids, path: p).forEach { sub.addItem($0) }
                item.submenu = sub
                item.action = nil
            }
            out.append(item)
        }
        while out.last?.isSeparatorItem == true { out.removeLast() }
        return out
    }

    /// Makes `menu`'s items look like `new`: in place when the shape is the same (so an open menu
    /// just updates), else replaced.
    private func reconcile(_ menu: NSMenu, with new: [NSMenuItem], top: UInt16) {
        topIndex[ObjectIdentifier(menu)] = top
        let old = menu.items
        let same = old.count == new.count && zip(old, new).allSatisfy {
            $0.isSeparatorItem == $1.isSeparatorItem && ($0.submenu == nil) == ($1.submenu == nil)
        }
        guard same else {
            menu.removeAllItems()
            new.forEach { $0.submenu.map { register($0, top: top) }; menu.addItem($0) }
            return
        }
        for (o, n) in zip(old, new) where !o.isSeparatorItem {
            if o.title != n.title { o.title = n.title }
            if o.keyEquivalent != n.keyEquivalent { o.keyEquivalent = n.keyEquivalent }
            if o.keyEquivalentModifierMask != n.keyEquivalentModifierMask { o.keyEquivalentModifierMask = n.keyEquivalentModifierMask }
            if o.isEnabled != n.isEnabled { o.isEnabled = n.isEnabled }
            if o.state != n.state { o.state = n.state }
            if o.isAlternate != n.isAlternate { o.isAlternate = n.isAlternate }
            o.representedObject = n.representedObject
            o.action = n.action
            o.target = n.target
            if let os = o.submenu, let ns = n.submenu {
                let kids = ns.items
                ns.removeAllItems()
                reconcile(os, with: kids, top: top)
            }
        }
    }

    private func register(_ menu: NSMenu, top: UInt16) {
        topIndex[ObjectIdentifier(menu)] = top
        menu.items.compactMap(\.submenu).forEach { register($0, top: top) }
    }

    private static func flags(_ m: MenuNode.Mods) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        return f
    }

    // MARK: Choosing

    /// A remote item was chosen: the host presses it, with the key remote window in front.
    /// The app and Window menus enable their items automatically: a remote item there is as enabled as on the host.
    func validateMenuItem(_ item: NSMenuItem) -> Bool { (item.representedObject as? MenuPath)?.enabled ?? true }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let path = (sender.representedObject as? MenuPath)?.path else { return }
        // A key equivalent that slipped through (the mixed menus): the keys belong to the remote app.
        if let e = NSApp.currentEvent, e.type == .keyDown, matches(e, sender) { return }
        press(path)
    }

    func press(_ path: [MenuTree.MenuTitle]) {
        let p = MenuPress(appKey: owner.appKey, stream: owner.menuStream(), path: path)
        log("phantom \(owner.appName): menu: \(p.describe) (stream #\(p.stream))")
        owner.sendToHost(p.encode())
        // Its effect (a checkmark, Undo's title…) shows the next time the menu opens; ask a little
        // later as well, so the cached copy is right sooner.
        if let top = path.first?.index {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.request(top) }
        }
    }

    /// "Quit <App> on <host>…": quits the remote app, after asking. Not on ⌘Q, which stays local.
    @objc private func quitRemote(_ sender: Any?) {
        guard let path = remoteQuit else { return }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Quit \(owner.appName) on \(owner.hostName)?"
        a.informativeText = "\(owner.appName) quits on \(owner.hostName), as if you chose Quit there. If it has unsaved changes, it asks about them in one of its windows on \(owner.hostName).\n\nTo stop viewing it here and leave it running, use Quit \(owner.appName) (⌘Q) instead."
        a.addButton(withTitle: "Quit on \(owner.hostName)")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        press(path)
    }

    /// Test hook: the remote Quit, without asking.
    func pressRemoteQuit() { if let remoteQuit { press(remoteQuit) } }

    // MARK: Debug

    /// The phantom's whole menu bar as text: what the user sees (remote items marked ‹remote›).
    func dump() -> String {
        owner.mainMenu.items.forEach { $0.submenu?.update() } // run the automatic enabling, as opening them would
        func node(_ item: NSMenuItem) -> MenuNode {
            if item.isSeparatorItem { return .separator(0) }
            var key = item.keyEquivalent
            var mods: MenuNode.Mods = []
            let f = item.keyEquivalentModifierMask
            if !key.isEmpty {
                if f.contains(.command) { mods.insert(.command) }
                if f.contains(.shift) || key != key.lowercased() { mods.insert(.shift) }
                if f.contains(.option) { mods.insert(.option) }
                if f.contains(.control) { mods.insert(.control) }
                key = key.lowercased()
            }
            let remote = item.representedObject is MenuPath || item.action == #selector(quitRemote(_:))
            return MenuNode(index: 0, title: item.title + (remote ? " ‹remote›" : "") + (item.isAlternate ? " (alternate)" : ""), enabled: item.isEnabled,
                            mark: item.state == .on ? "✓" : item.state == .mixed ? "-" : "", key: key, mods: mods,
                            children: item.submenu.map { $0.items.map(node) })
        }
        return owner.mainMenu.items.map { item in
            var n = node(item)
            n.title = item.submenu?.title ?? item.title // the app and Window menus' items have no title of their own
            return n.dump()
        }.joined(separator: "\n")
    }

    /// The NSMenu showing remote top-level menu `title` (test hook).
    func menu(titled title: String) -> NSMenu? { owner.mainMenu.items.first { $0.submenu?.title == title }?.submenu }
}

/// An item's path in the remote menu bar (NSMenuItem.representedObject).
final class MenuPath: NSObject {
    let path: [MenuTree.MenuTitle]
    let enabled: Bool
    init(_ p: [MenuTree.MenuTitle], enabled: Bool) { path = p; self.enabled = enabled }
}
