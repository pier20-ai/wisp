// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Menu bar mirroring (docs/multi-window.md §10): the host reads a shared app's menu bar through
// Accessibility and sends it per app (menuTree); a phantom app builds its own menu bar from it and
// sends the item the user chose back (menuPress).

/// One item of a remote app's menu bar, as read through Accessibility on the host: a top-level menu
/// (AXMenuBarItem), or an item of a menu (AXMenuItem). Titles and shortcuts only, no icons.
/// Wire: [u16 index][u8 flags][str title][str mark][str key][u8 mods] then, with a submenu,
/// [u16 count] count x MenuNode. flags: bit0 enabled, bit1 separator, bit2 has a submenu.
/// A separator is just [u16 index][u8 flags].
public struct MenuNode: Equatable {
    /// Its index among its AX siblings (the path to press it), not its position in `children`:
    /// the host leaves some items out (the Apple menu, items it can't read).
    public var index: UInt16
    public var title: String
    public var enabled: Bool
    public var separator: Bool
    /// AXMenuItemMarkChar: "✓" when checked, "-" for mixed, "" when off.
    public var mark: String
    /// The shortcut as an NSMenuItem keyEquivalent: a lowercase letter (shift is in `mods`), another
    /// character, or a function-key character (NSUpArrowFunctionKey…); "" = none.
    public var key: String
    public var mods: Mods
    /// nil: not a submenu.
    public var children: [MenuNode]?

    public struct Mods: OptionSet, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Mods(rawValue: 1)
        public static let shift = Mods(rawValue: 2)
        public static let option = Mods(rawValue: 4)
        public static let control = Mods(rawValue: 8)
    }

    public init(index: UInt16, title: String, enabled: Bool = true, separator: Bool = false, mark: String = "",
                key: String = "", mods: Mods = [], children: [MenuNode]? = nil) {
        self.index = index; self.title = title; self.enabled = enabled; self.separator = separator
        self.mark = mark; self.key = key; self.mods = mods; self.children = children
    }

    public static func separator(_ index: UInt16) -> MenuNode { MenuNode(index: index, title: "", enabled: false, separator: true) }

    /// e.g. "⇧⌘S", for logs and dumps.
    public var shortcut: String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let names: [Unicode.Scalar: String] = [
            "\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "⎋", "\u{8}": "⌫", "\u{7f}": "⌫", "\u{3}": "⌤",
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\u{F728}": "⌦",
            "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
        ]
        if key.unicodeScalars.count == 1, let u = key.unicodeScalars.first {
            if let n = names[u] { return s + n }
            if u.value >= 0xF704 && u.value <= 0xF71A { return s + "F\(u.value - 0xF704 + 1)" }
        }
        return s + key.uppercased()
    }

    /// Encodes the node and its subtree into at most `budget` bytes; children that don't fit are left
    /// out (the subtree is cut there). nil if not even the node itself fits.
    public func encode(budget: Int) -> Data? {
        var w = Writer()
        w.u16(index)
        w.u8((enabled ? 1 : 0) | (separator ? 2 : 0) | (children != nil ? 4 : 0))
        if !separator {
            w.str(title, max: 120); w.str(mark, max: 8); w.str(key, max: 16); w.u8(mods.rawValue)
        }
        if let children {
            var parts: [Data] = []
            var used = w.data.count + 2
            for c in children {
                guard used < budget, let d = c.encode(budget: budget - used) else { break }
                used += d.count
                parts.append(d)
            }
            w.u16(UInt16(parts.count))
            parts.forEach { w.bytes($0) }
        }
        return w.data.count <= budget ? w.data : nil
    }

    public static func decode(_ r: inout Reader, depth: Int = 0) -> MenuNode? {
        guard depth < 16, let index = r.u16(), let flags = r.u8() else { return nil }
        var n = MenuNode(index: index, title: "", enabled: flags & 1 != 0, separator: flags & 2 != 0)
        if !n.separator {
            guard let t = r.str(), let m = r.str(), let k = r.str(), let mods = r.u8() else { return nil }
            n.title = t; n.mark = m; n.key = k; n.mods = Mods(rawValue: mods)
        }
        if flags & 4 != 0 {
            guard let count = r.u16() else { return nil }
            var kids: [MenuNode] = []
            for _ in 0 ..< count {
                guard let c = decode(&r, depth: depth + 1) else { return nil }
                kids.append(c)
            }
            n.children = kids
        }
        return n
    }

    /// Indented text, one item per line (logs, `wisp view --menus`).
    public func dump(indent: String = "") -> String {
        if separator { return indent + "---" }
        var line = indent + (mark.isEmpty ? "" : "[\(mark)] ") + title
        if !shortcut.isEmpty { line += "  " + shortcut }
        if !enabled { line += "  (disabled)" }
        return ([line] + (children ?? []).map { $0.dump(indent: indent + "  ") }).joined(separator: "\n")
    }
}

/// A menuTree message (MsgType.menuTree).
public enum MenuTree: Equatable {
    /// The app's top-level menus, the Apple menu left out: (AX index, title).
    case bar([MenuTitle])
    /// One top-level menu with its items.
    case menu(MenuNode)
    /// No menu bar to show (why).
    case none(String)

    public struct MenuTitle: Equatable {
        public var index: UInt16
        public var title: String
        public init(index: UInt16, title: String) { self.index = index; self.title = title }
    }

    public static let maxBytes = 60000
    /// menuRequest's "all menus".
    public static let wholeBar: UInt16 = 0xFFFF

    public func encode(appKey: String) -> Data {
        message(.menuTree) { w in
            w.str(appKey)
            switch self {
            case .bar(let items):
                w.u8(0)
                let list = items.prefix(64)
                w.u16(UInt16(list.count))
                for i in list { w.u16(i.index); w.str(i.title, max: 120) }
            case .menu(let node):
                w.u8(1)
                w.bytes(node.encode(budget: Self.maxBytes - 400) ?? Data())
            case .none(let why):
                w.u8(2)
                w.str(why)
            }
        }
    }

    /// Decodes the payload after the type byte.
    public static func decode(_ d: Data) -> (appKey: String, tree: MenuTree)? {
        var r = Reader(d)
        guard let key = r.str(), let kind = r.u8() else { return nil }
        switch kind {
        case 0:
            guard let n = r.u16() else { return nil }
            var items: [MenuTitle] = []
            for _ in 0 ..< n {
                guard let i = r.u16(), let t = r.str() else { return nil }
                items.append(MenuTitle(index: i, title: t))
            }
            return (key, .bar(items))
        case 1:
            guard let node = MenuNode.decode(&r) else { return nil }
            return (key, .menu(node))
        case 2:
            return (key, .none(r.str() ?? ""))
        default:
            return nil
        }
    }

    /// The menuRequest message for app `key`'s menu `menu` (wholeBar = all of them).
    public static func request(appKey key: String, menu: UInt16) -> Data {
        message(.menuRequest) { $0.str(key); $0.u16(menu) }
    }

    public static func decodeRequest(_ d: Data) -> (appKey: String, menu: UInt16)? {
        var r = Reader(d)
        guard let key = r.str(), let m = r.u16() else { return nil }
        return (key, m)
    }
}

/// A menuPress message: which item of which app to choose, for which stream's window.
public struct MenuPress: Equatable {
    public var appKey: String
    /// The stream whose window should be in front when the item is chosen (0 = none in particular).
    public var stream: UInt16
    /// From the top-level menu down to the item: (AX index, title) at each level.
    public var path: [MenuTree.MenuTitle]

    public init(appKey: String, stream: UInt16, path: [MenuTree.MenuTitle]) { self.appKey = appKey; self.stream = stream; self.path = path }

    public func encode() -> Data {
        message(.menuPress) { w in
            w.str(appKey); w.u16(stream)
            let p = path.prefix(16)
            w.u8(UInt8(p.count))
            for s in p { w.u16(s.index); w.str(s.title, max: 120) }
        }
    }

    public static func decode(_ d: Data) -> MenuPress? {
        var r = Reader(d)
        guard let key = r.str(), let stream = r.u16(), let n = r.u8() else { return nil }
        var path: [MenuTree.MenuTitle] = []
        for _ in 0 ..< n {
            guard let i = r.u16(), let t = r.str() else { return nil }
            path.append(MenuTree.MenuTitle(index: i, title: t))
        }
        return MenuPress(appKey: key, stream: stream, path: path)
    }

    /// e.g. "File > Open Recent > notes.txt"
    public var describe: String { path.map(\.title).joined(separator: " > ") }
}
