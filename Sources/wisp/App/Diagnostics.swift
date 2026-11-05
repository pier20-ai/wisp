// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CryptoKit
import Foundation
import Tailnet
import WispCommon

/// A plain-text report for an issue: version, macOS, hardware, permissions, settings, Tailscale (this
/// Mac and its peers, with whether each Mac is sharing) and the end of the log. Other people's login
/// names (email addresses) never appear: each is replaced by a short hash, the same one throughout
/// the report; only this Mac's own login is shown. Settings hold no secrets; the allow-list (other
/// people's logins) is hashed the same way. "Copy Diagnostics" in the menu, and `wisp diagnostics`.
///
/// `report` blocks (Tailscale's LocalAPI): call it off the main thread.
enum Diagnostics {
    /// "Wisp 1.0.0 (build 42)", or "(not bundled)" for a `swift build` binary.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let v = info["CFBundleShortVersionString"] as? String else { return "\(Brand.name) (not bundled)" }
        return "\(Brand.name) \(v) (build \(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The app bundle's path, or the executable's when it isn't in one (`swift build`).
    static var bundleLocation: String {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : (Bundle.main.executablePath ?? Bundle.main.bundlePath)
    }

    /// "macOS 27.2 (25C56)".
    static var macOSLine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "") (\(sysctl("kern.osversion") ?? "?"))"
    }

    /// "Mac16,1, Apple M4, 16 GB, arm64".
    static var hardwareLine: String {
        let mem = sysctlInt("hw.memsize").map { "\($0 >> 30) GB" } ?? "? GB"
        var arch = "?"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        return [sysctl("hw.model") ?? "?", sysctl("machdep.cpu.brand_string") ?? "?", mem, arch].joined(separator: ", ")
    }

    static var permissionsLine: String {
        "Screen Recording \(Permissions.screenRecording ? "granted" : "not granted"), "
            + "\(Permissions.accessibilityTitle) \(Permissions.accessibility ? "granted" : "not granted")"
    }

    /// The settings that change behaviour, as stored (unset = the default). Logins are hashed.
    static func settingsLines(hash: (String) -> String, environment: Bool = true) -> [String] {
        let d = Brand.defaults
        var out: [String] = []
        var unset: [String] = []
        for key in [Prefs.phantomsKey, Prefs.reconnectKey, Prefs.shareAtLaunchKey, AccessPolicy.allowLANKey, Log.verboseKey,
                    "kbps", "fps", "scale", "codec", "refine", "paceMbps", "fec", "virtualDisplay", "maxStreams",
                    ClipboardSync.viewerKey, ClipboardSync.hostKey, ClipboardSync.maxBytesKey] {
            if let v = d.object(forKey: key) { out.append("\(key) = \(v)") } else { unset.append(key) }
        }
        if !unset.isEmpty { out.append("default: " + unset.joined(separator: ", ")) }
        out.append("\(Prefs.lastHostKey) = \(Prefs.lastHost ?? "none")" + (Prefs.lastHostLabel.map { $0 == Prefs.lastHost ? "" : " (\($0))" } ?? ""))
        let allowed = AccessPolicy.fromDefaults().allowedViewers
        out.append("\(AccessPolicy.allowedViewersKey) = " + (allowed.isEmpty ? "anyone on the tailnet" : allowed.map(hash).joined(separator: ", ")))
        let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("WISP_") }.sorted { $0.key < $1.key }
        if environment, !env.isEmpty { out.append("environment: " + env.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        return out
    }

    /// The whole report. `probes`: what the app's menu last found on each Mac (by address); the CLI
    /// passes none and probes nothing. `state`: lines about the app's viewer and host right now.
    static func report(probes: [String: ProbeResult] = [:], state: [String] = [], logLines: Int = 300) -> String {
        var out: [String] = []
        out.append("\(Brand.name) diagnostics, \(Log.timestamp())")
        out.append("")
        out.append("Version: \(versionLine)")
        out.append("Bundle: \(bundleLocation)")
        out.append("System: \(macOSLine)")
        out.append("Hardware: \(hardwareLine)")
        out.append("Permissions: \(permissionsLine)")
        out.append("Logs: \(LogFile.dir.path) (verbose logging \(Log.verbose ? "on" : "off"))")

        // Tailscale first: it says who "you" is, for hashing everyone else.
        var tailnet: [String] = []
        var me = ""
        do {
            let peers = try Tailnet.peers()
            let selfPeer = peers.first { $0.isSelf }
            me = selfPeer?.userLoginName ?? ""
            func owner(_ p: TailnetPeer) -> String { p.userLoginName.isEmpty ? "?" : hashLogin(p.userLoginName, me: me) }
            tailnet.append("Reached via \(Tailnet.transport)")
            if let s = selfPeer {
                tailnet.append("This Mac: \(s.shortName) (\(s.dnsName.isEmpty ? "no MagicDNS name" : s.dnsName)) \(s.tailscaleIPs.joined(separator: " ")), "
                               + "logged in as \(s.userLoginName.isEmpty ? "?" : s.userLoginName)")
            }
            let others = peers.filter { !$0.isSelf }
            let macs = others.filter(\.isMac)
            tailnet.append("Peers: \(others.count) (\(others.filter(\.online).count) online), \(macs.count) Macs (\(macs.filter(\.online).count) online)")
            for p in macs {
                let wisp: String
                if !p.online { wisp = "offline" } else if let r = probes[p.address] { wisp = describe(r) } else { wisp = "not probed" }
                tailnet.append("  Mac \(p.shortName): \(p.address)\(p.dnsName.isEmpty ? "" : " (\(p.dnsName))"), owner \(owner(p)), \(Brand.name): \(wisp)")
            }
            let rest = Dictionary(grouping: others.filter { !$0.isMac }, by: { $0.os.isEmpty ? "?" : $0.os })
            if !rest.isEmpty {
                tailnet.append("  Other devices: " + rest.keys.sorted().map { "\(rest[$0]!.count) \($0) (\(rest[$0]!.filter(\.online).count) online)" }.joined(separator: ", "))
            }
        } catch {
            tailnet.append("Not available: \(error.localizedDescription) (tried: \(Tailnet.transport))")
        }

        out.append("")
        out.append("Settings:")
        out += settingsLines(hash: { hashLogin($0, me: me) }).map { "  " + $0 }
        out.append("")
        out.append("Tailscale:")
        out += tailnet.map { "  " + $0 }
        if !state.isEmpty {
            out.append("")
            out.append("Now:")
            out += state.map { "  " + $0 }
        }
        let file = Log.fileName == "cli.log" ? "wisp.log" : Log.fileName
        let lines = Log.tail(logLines, file: file)
        out.append("")
        out.append("Last \(lines.count) lines of \(file):")
        out += lines.map { scrub($0, me: me) }
        return out.joined(separator: "\n")
    }

    private static func describe(_ r: ProbeResult) -> String {
        switch r {
        case .sharing(let p): return "sharing as \"\(p.hostName)\", \(p.openStreams) of \(p.maxStreams) open\(p.viewerConnected ? ", in use" : "")"
        case .refused(let why): return "sharing, refused us: \(why)"
        case .olderVersion: return "an older version"
        case .notSharing: return "not sharing"
        }
    }

    /// "you" for this Mac's login, else "user-1a2b3c4d" (SHA-256 of the lowercased login). The same
    /// login hashes the same everywhere, so lines in a report can be matched up.
    static func hashLogin(_ login: String, me: String) -> String {
        if !me.isEmpty, login.caseInsensitiveCompare(me) == .orderedSame { return "you" }
        let digest = SHA256.hash(data: Data(login.lowercased().utf8))
        return "user-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static let emailPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]*[A-Za-z0-9]")

    /// A log line with every login but this Mac's replaced by its hash (the log names who connected).
    static func scrub(_ line: String, me: String) -> String {
        let ns = line as NSString
        var out = line
        for m in emailPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
            let login = ns.substring(with: m.range)
            guard let r = Range(m.range, in: out) else { continue }
            let replacement = hashLogin(login, me: me)
            out.replaceSubrange(r, with: replacement == "you" ? login : replacement)
        }
        return out
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
    }
}
