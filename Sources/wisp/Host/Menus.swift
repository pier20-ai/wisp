// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// Menu bar mirroring, host side (docs/multi-window.md §10): reads a shared app's menu bar through
// Accessibility (AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem …) and presses its items. Lazily:
// only when a viewer asks (a phantom app starting, or one of its menus about to open), so the
// enabled and checked states are as fresh as one round trip allows.

/// Reads and presses on a serial queue of its own: a big menu bar takes tens of milliseconds to read,
/// and AXPress on an item that opens a modal panel can block until the messaging timeout. Input
/// injection on the main queue never waits for either.
final class MenuReader {
    private let q = DispatchQueue(label: "wisp.menus", qos: .userInitiated)
    static let maxDepth = 5
    static let maxItemsPerMenu = 400
    /// Seconds an app may take to answer one Accessibility call before we give up on it.
    static let timeout: Float = 1

    /// Reads app `pid`'s menu bar: `menu` = MenuTree.wholeBar for the bar plus every menu, else that
    /// one top-level menu (its AX index). Calls `done` on the reader's queue with the messages to send.
    func read(pid: pid_t, appName: String, menu: UInt16, done: @escaping ([MenuTree]) -> Void) {
        q.async {
            let t0 = Date()
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            guard let bar = Self.element(app, kAXMenuBarAttribute) else {
                let why = AXIsProcessTrusted() ? "\(appName) has no menu bar that Accessibility can read" : "\(Brand.name) has no Accessibility permission on this Mac"
                log("menus: \(appName): \(why)")
                done([.none(why)])
                return
            }
            let top = Self.children(bar)
            var out: [MenuTree] = []
            var items = 0
            if menu == MenuTree.wholeBar {
                // Index 0 is the Apple menu: it belongs to the viewer's Mac, not the remote app.
                let titles = top.enumerated().dropFirst().map { MenuTree.MenuTitle(index: UInt16($0.offset), title: Self.string($0.element, kAXTitleAttribute)) }
                out.append(.bar(titles))
                for t in titles {
                    let node = Self.topMenu(top[Int(t.index)], index: t.index, title: t.title)
                    items += node.count
                    out.append(.menu(node))
                }
            } else if Int(menu) < top.count, menu > 0 {
                let e = top[Int(menu)]
                let node = Self.topMenu(e, index: menu, title: Self.string(e, kAXTitleAttribute))
                items += node.count
                out.append(.menu(node))
            } else {
                // The menu bar changed under us: send the whole bar instead.
                self.read(pid: pid, appName: appName, menu: MenuTree.wholeBar, done: done)
                return
            }
            log(String(format: "menus: read %@'s %@ (%d items) in %.0f ms", appName,
                       menu == MenuTree.wholeBar ? "menu bar" : "menu #\(menu)", items, Date().timeIntervalSince(t0) * 1000))
            done(out)
        }
    }

    /// Finds the item at `path` in app `pid`'s menu bar (by index, checking each title; by title
    /// among its siblings if the index doesn't match) and presses it. `done` gets an error text, or nil.
    func press(pid: pid_t, path: [MenuTree.MenuTitle], done: @escaping (String?) -> Void) {
        q.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            guard let bar = Self.element(app, kAXMenuBarAttribute) else { done("no menu bar through Accessibility"); return }
            var current = bar
            for (depth, step) in path.enumerated() {
                // A menu bar item's or a submenu item's children are [AXMenu]; the menu's are the items.
                let level = depth == 0 ? Self.children(current) : Self.children(Self.children(current).first ?? current)
                let i = Int(step.index)
                if i < level.count, Self.string(level[i], kAXTitleAttribute) == step.title {
                    current = level[i]
                } else if let m = level.first(where: { Self.string($0, kAXTitleAttribute) == step.title }) {
                    current = m
                } else {
                    done("no item \"\(step.title)\" at level \(depth + 1) (the menu changed)")
                    return
                }
            }
            guard path.count >= 2 else { done("that is a menu, not an item"); return }
            if let enabled = Self.bool(current, kAXEnabledAttribute), !enabled { done("the item is disabled"); return }
            let err = AXUIElementPerformAction(current, kAXPressAction as CFString)
            switch err {
            case .success: done(nil)
            // The app runs the action synchronously (e.g. a modal "Save" panel) and hasn't answered yet:
            // the press was delivered.
            case .cannotComplete: log("menus: the app is still busy with the item after \(Int(Self.timeout)) s (normal for items that open a dialog)"); done(nil)
            default: done("AXPress failed (\(err.rawValue))")
            }
        }
    }

    // MARK: Reading

    private static let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute,
                                     kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute,
                                     kAXChildrenAttribute] as CFArray

    private static func topMenu(_ e: AXUIElement, index: UInt16, title: String) -> MenuNode {
        let menu = children(e).first
        return MenuNode(index: index, title: title, enabled: bool(e, kAXEnabledAttribute) ?? true,
                        children: menu.map { items(of: $0, depth: 1) } ?? [])
    }

    /// The items of an AXMenu.
    private static func items(of menu: AXUIElement, depth: Int) -> [MenuNode] {
        var out: [MenuNode] = []
        for (i, e) in children(menu).prefix(maxItemsPerMenu).enumerated() {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [AnyObject], v.count == 8 else { continue }
            func ok(_ x: AnyObject) -> AnyObject? {
                if CFGetTypeID(x) == AXValueGetTypeID(), AXValueGetType(x as! AXValue) == .axError { return nil }
                return x
            }
            let title = ok(v[0]) as? String ?? ""
            let enabled = (ok(v[1]) as? Bool) ?? true
            let mark = ok(v[2]) as? String ?? ""
            let char = ok(v[3]) as? String ?? ""
            let axMods = (ok(v[4]) as? Int) ?? 0
            let vkey = ok(v[5]) as? Int
            let glyph = (ok(v[6]) as? Int) ?? 0
            let kids = (ok(v[7]) as? [AXUIElement]) ?? []
            let submenu = kids.first
            if title.isEmpty && submenu == nil { out.append(.separator(UInt16(i))); continue }
            guard !title.isEmpty else { continue }
            var key = keyEquivalent(char: char, glyph: glyph, virtualKey: vkey)
            // A bare letter or digit is a fn/🌐 shortcut (fn-F: Enter Full Screen), which AX can't express: leave it out.
            if axMods == 8, key.count == 1, key.first!.isLetter || key.first!.isNumber { key = "" }
            var mods: MenuNode.Mods = []
            if !key.isEmpty {
                if axMods & 8 == 0 { mods.insert(.command) } // kAXMenuItemModifierNoCommand
                if axMods & 1 != 0 { mods.insert(.shift) }
                if axMods & 2 != 0 { mods.insert(.option) }
                if axMods & 4 != 0 { mods.insert(.control) }
            }
            var node = MenuNode(index: UInt16(i), title: title, enabled: enabled, mark: mark, key: key, mods: mods)
            if let submenu { node.children = depth < maxDepth ? items(of: submenu, depth: depth + 1) : [] }
            out.append(node)
        }
        return out
    }

    /// AX's shortcut (a character, else a Carbon menu glyph, else a virtual key code) as an NSMenuItem
    /// keyEquivalent. AX reports letters in upper case; shift is in the modifiers, so they become lower case.
    static func keyEquivalent(char: String, glyph: Int, virtualKey: Int?) -> String {
        if glyph != 0, let g = glyphs[glyph] { return g }
        if let u = char.unicodeScalars.first, char.unicodeScalars.count == 1, u.value >= 0x20 {
            return u.properties.isUppercase ? char.lowercased() : char
        }
        if let vk = virtualKey, vk != 0, let k = virtualKeys[vk] { return k }
        return ""
    }

    private static func fn(_ c: Int) -> String { String(UnicodeScalar(UInt32(c))!) }

    /// Carbon's kMenu…Glyph values (Menus.h) for keys that have no printable character.
    private static let glyphs: [Int: String] = {
        var g: [Int: String] = [
            0x02: "\t", 0x04: "\u{3}", 0x09: " ", 0x0A: fn(NSDeleteFunctionKey), 0x0B: "\r", 0x0D: "\r",
            0x17: "\u{8}", 0x1B: "\u{1b}", 0x1C: fn(NSClearLineFunctionKey),
            0x62: fn(NSPageUpFunctionKey), 0x6B: fn(NSPageDownFunctionKey),
            0x64: fn(NSLeftArrowFunctionKey), 0x65: fn(NSRightArrowFunctionKey),
            0x68: fn(NSUpArrowFunctionKey), 0x6A: fn(NSDownArrowFunctionKey),
            0x66: fn(NSHomeFunctionKey), 0x69: fn(NSEndFunctionKey), 0x67: fn(NSHelpFunctionKey),
        ]
        for i in 0 ..< 12 { g[0x6F + i] = fn(NSF1FunctionKey + i) }       // F1–F12
        for i in 0 ..< 3 { g[0x87 + i] = fn(NSF13FunctionKey + i) }       // F13–F15
        for i in 0 ..< 4 { g[0x8F + i] = fn(NSF16FunctionKey + i) }       // F16–F19
        return g
    }()

    /// Virtual key codes (kVK_…) for keys without a character or glyph.
    private static let virtualKeys: [Int: String] = [
        36: "\r", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}", 117: fn(NSDeleteFunctionKey),
        123: fn(NSLeftArrowFunctionKey), 124: fn(NSRightArrowFunctionKey), 125: fn(NSDownArrowFunctionKey), 126: fn(NSUpArrowFunctionKey),
        115: fn(NSHomeFunctionKey), 119: fn(NSEndFunctionKey), 116: fn(NSPageUpFunctionKey), 121: fn(NSPageDownFunctionKey),
        122: fn(NSF1FunctionKey), 120: fn(NSF2FunctionKey), 99: fn(NSF3FunctionKey), 118: fn(NSF4FunctionKey),
        96: fn(NSF5FunctionKey), 97: fn(NSF6FunctionKey), 98: fn(NSF7FunctionKey), 100: fn(NSF8FunctionKey),
        101: fn(NSF9FunctionKey), 109: fn(NSF10FunctionKey), 103: fn(NSF11FunctionKey), 111: fn(NSF12FunctionKey),
    ]

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return v as? String ?? ""
    }

    private static func bool(_ e: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? Bool
    }
}

extension MenuNode {
    /// Items in this subtree, itself included.
    var count: Int { 1 + (children ?? []).reduce(0) { $0 + $1.count } }
}

// MARK: - Synthetic apps

/// A made-up menu bar for the synthetic apps (`wisp send --synthetic`), so a loopback viewer can test
/// mirroring: several menus, a submenu, checked, mixed and disabled items, and shortcuts of every kind.
/// Choosing "Show Sidebar" toggles its checkmark (and "Show Toolbar" with it), so a refresh shows a change.
/// Main queue.
final class SyntheticMenus {
    private var sidebar: [String: Bool] = [:]

    func tree(appKey: String, appName: String) -> [MenuNode] {
        let on = sidebar[appKey] ?? true
        func item(_ i: Int, _ t: String, _ key: String = "", _ mods: MenuNode.Mods = [.command], enabled: Bool = true, mark: String = "",
                  children: [MenuNode]? = nil) -> MenuNode {
            MenuNode(index: UInt16(i), title: t, enabled: enabled, mark: mark, key: key, mods: key.isEmpty ? [] : mods, children: children)
        }
        func sep(_ i: Int) -> MenuNode { .separator(UInt16(i)) }
        let fnKey = { (c: Int) in String(UnicodeScalar(UInt32(c))!) }
        return [
            MenuNode(index: 1, title: appName, children: [
                item(0, "About \(appName)"), sep(1),
                item(2, "Settings…", ","), item(3, "Check for Updates…", enabled: false), sep(4),
                item(5, "Services", children: [item(0, "No Services Apply", enabled: false)]), sep(6),
                item(7, "Hide \(appName)", "h"), item(8, "Hide Others", "h", [.command, .option]), item(9, "Show All"), sep(10),
                item(11, "Quit \(appName)", "q"),
            ]),
            MenuNode(index: 2, title: "File", children: [
                item(0, "New Window", "n"), item(1, "Open…", "o"),
                item(2, "Open Recent", children: [item(0, "notes.txt"), item(1, "plan.md"), sep(2), item(3, "Clear Menu")]),
                sep(3), item(4, "Close", "w"), item(5, "Close All", "w", [.command, .option]),
                item(6, "Save", "s"), item(7, "Save As…", "s", [.command, .shift]),
                item(8, "Revert to Saved", enabled: false),
            ]),
            MenuNode(index: 3, title: "Edit", children: [
                item(0, "Undo Typing", "z"), item(1, "Redo", "z", [.command, .shift], enabled: false), sep(2),
                item(3, "Cut", "x"), item(4, "Copy", "c"), item(5, "Paste", "v"), item(6, "Select All", "a"), sep(7),
                item(8, "Delete Line", "\u{8}", [.command, .control]),
                item(9, "AutoFill"), item(10, "Start Dictation…"), item(11, "Emoji & Symbols", " ", [.command, .control]),
            ]),
            MenuNode(index: 4, title: "View", children: [
                item(0, "Show Sidebar", "b", mark: on ? "✓" : ""), item(1, "Show Toolbar", "t", [.command, .option], mark: on ? "-" : "✓"),
                sep(2), item(3, "Reload", fnKey(NSF5FunctionKey), []), item(4, "Go Back", fnKey(NSLeftArrowFunctionKey)),
                sep(5), item(6, "Enter Full Screen", "f", [.command, .control]),
            ]),
            MenuNode(index: 5, title: "Window", children: [
                item(0, "Minimize", "m"), item(1, "Zoom"), sep(2), item(3, "Tile Synth Windows", "t", [.command, .control, .shift]),
                sep(4), item(5, "Bring All to Front"), sep(6), item(7, "synthetic test 1", mark: "✓"),
            ]),
            MenuNode(index: 6, title: "Help", children: [item(0, "\(appName) Help", "?")]),
        ]
    }

    func trees(appKey: String, appName: String, menu: UInt16) -> [MenuTree] {
        let all = tree(appKey: appKey, appName: appName)
        if menu == MenuTree.wholeBar {
            return [.bar(all.map { MenuTree.MenuTitle(index: $0.index, title: $0.title) })] + all.map { .menu($0) }
        }
        return all.first { $0.index == menu }.map { [.menu($0)] } ?? [.none("no menu #\(menu)")]
    }

    /// Logs the press (a loopback test looks for "synthetic menu:"); "Show Sidebar" toggles. Returns
    /// the title of the item pressed (the host makes a window for "New Window").
    @discardableResult
    func press(appKey: String, appName: String, _ p: MenuPress) -> String? {
        var node: MenuNode? = MenuNode(index: 0, title: "", children: tree(appKey: appKey, appName: appName))
        for step in p.path { node = node?.children?.first { $0.index == step.index && $0.title == step.title } }
        guard let node, node.children == nil else {
            log("synthetic menu: \(appName): no item \(p.describe)")
            return nil
        }
        guard node.enabled else { log("synthetic menu: \(appName): \(p.describe) is disabled"); return nil }
        if node.title == "Show Sidebar" { sidebar[appKey] = !(sidebar[appKey] ?? true) }
        log("synthetic menu: \(appName): pressed \(p.describe) (stream #\(p.stream))"
            + (node.title == "Show Sidebar" ? ", sidebar now \(sidebar[appKey]! ? "on" : "off")" : ""))
        return node.title
    }
}
