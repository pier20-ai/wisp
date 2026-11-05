// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// The tailnet, as this Mac's Tailscale sees it: who is on it (peers) and who an address belongs to
// (whois). Wisp has no pairing, passwords or certificates of its own: Tailscale's WireGuard tunnel
// is the transport security, and tailnet membership (plus an optional allow-list of tailnet users,
// checked with whois) is the access control.
//
// How we reach Tailscale, in order (the same order as Tailscale's own CLI, safesocket_darwin.go):
//   1. The Mac App Store app ("macos" variant): its network extension, IPNExtension, listens on a
//      localhost port and keeps a file open named ".../io.tailscale.ipn.macos/sameuserproof-<port>-<token>".
//      `lsof -n -a -u<uid> -c IPNExtension -F` shows it; the port and token are in the name.
//   2. The standalone app ("macsys" variant, System Extension): /Library/Tailscale/ipnport is a symlink
//      whose target is the port, and /Library/Tailscale/sameuserproof-<port> (mode 0640, group admin)
//      holds the token.
//   3. The open-source tailscaled: a Unix socket, /var/run/tailscaled.socket (or
//      /var/run/tailscale/tailscaled.sock).
// Over TCP the token goes in HTTP basic auth with an empty user name, as Tailscale's localclient does.
// The LocalAPI is plain HTTP: GET /localapi/v0/status and /localapi/v0/whois?addr=<ip>.
//   4. If none of those answers: the `tailscale` CLI (`status --json`, `whois --json <ip>`), from
//      /Applications/Tailscale.app or $PATH. It prints the same JSON.
//
// Everything here blocks (at most a couple of seconds): call it off the main thread.

/// A device on the tailnet (this Mac included, with `isSelf`).
public struct TailnetPeer: Equatable, Sendable {
    public var hostName: String
    /// The MagicDNS name, without the trailing dot ("my-mac.tailnet-name.ts.net"); "" without MagicDNS.
    public var dnsName: String
    public var tailscaleIPs: [String]
    /// As Tailscale reports it: "macOS", "iOS", "linux", "windows"…
    public var os: String
    public var online: Bool
    public var userLoginName: String
    public var userDisplayName: String
    public var isSelf: Bool

    /// The device's short name: the first label of its MagicDNS name, else its host name.
    public var shortName: String { dnsName.split(separator: ".").first.map(String.init) ?? hostName }
    /// What to connect to: its first IPv4 Tailscale address (works without MagicDNS), else its name.
    public var address: String {
        tailscaleIPs.first { !$0.contains(":") } ?? tailscaleIPs.first ?? (dnsName.isEmpty ? hostName : dnsName)
    }
    public var isMac: Bool { os.lowercased() == "macos" || os.lowercased() == "darwin" }
}

/// Who an address belongs to (whois).
public struct TailnetIdentity: Equatable, Sendable {
    public var userLoginName: String
    public var userDisplayName: String
    /// The device's name on the tailnet (its MagicDNS short name).
    public var deviceName: String
    public var os: String
    public var addresses: [String]

    /// "Alex Doe · alex-mbp".
    public var label: String {
        let who = userDisplayName.isEmpty ? userLoginName : userDisplayName
        return [who, deviceName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public struct TailnetError: LocalizedError {
    public let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// Debug: WISP_DEMO_NAMES="real=shown,other=" shows tailnet devices and users under other names,
/// for screenshots that shouldn't carry real ones; a device mapped to "" is left out. Display only:
/// connections still go to the real addresses.
enum Demo {
    static let map: [String: String] = {
        guard let v = ProcessInfo.processInfo.environment["WISP_DEMO_NAMES"] else { return [:] }
        var m: [String: String] = [:]
        for pair in v.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 { m[String(kv[0])] = String(kv[1]) }
        }
        return m
    }()
    static func name(_ s: String) -> String { map[s] ?? s }
    static func peer(_ p: TailnetPeer) -> TailnetPeer? {
        guard !map.isEmpty else { return p }
        var p = p
        let label = p.dnsName.split(separator: ".").first.map(String.init) ?? p.hostName
        if let shown = map[label] ?? map[p.hostName] {
            if shown.isEmpty { return nil }
            let rest = p.dnsName.split(separator: ".").dropFirst().joined(separator: ".")
            p.dnsName = rest.isEmpty ? "" : shown + "." + rest
            p.hostName = shown
        }
        p.userLoginName = name(p.userLoginName)
        p.userDisplayName = name(p.userDisplayName)
        return p
    }
}

public enum Tailnet {
    /// Every device on the tailnet, this Mac first.
    public static func peers() throws -> [TailnetPeer] {
        let status = try decode(Status.self, path: "/localapi/v0/status", cli: ["status", "--json"])
        guard status.BackendState == nil || status.BackendState == "Running" else {
            throw TailnetError("Tailscale is \(status.BackendState!.lowercased()), not running")
        }
        let users = status.User ?? [:]
        func peer(_ p: Status.PeerStatus, isSelf: Bool) -> TailnetPeer {
            let u = p.UserID.flatMap { users[String($0)] }
            return TailnetPeer(hostName: p.HostName ?? "", dnsName: trimDot(p.DNSName ?? ""), tailscaleIPs: p.TailscaleIPs ?? [],
                               os: p.OS ?? "", online: isSelf ? true : (p.Online ?? false),
                               userLoginName: u?.LoginName ?? "", userDisplayName: u?.DisplayName ?? "", isSelf: isSelf)
        }
        var out: [TailnetPeer] = []
        if let me = status.Self_ { out.append(peer(me, isSelf: true)) }
        out += (status.Peer ?? [:]).values.map { peer($0, isSelf: false) }
        out = out.compactMap(Demo.peer)
            .sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
        return out
    }

    /// Who `ip` (a Tailscale address) belongs to.
    public static func whois(_ ip: String) throws -> TailnetIdentity {
        let w = try decode(WhoIs.self, path: "/localapi/v0/whois?addr=\(ip.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".:"))) ?? ip)",
                           cli: ["whois", "--json", ip])
        guard let node = w.Node else { throw TailnetError("no tailnet device has the address \(ip)") }
        let name = node.ComputedName ?? trimDot(node.Name ?? "").split(separator: ".").first.map(String.init) ?? ""
        return TailnetIdentity(userLoginName: Demo.name(w.UserProfile?.LoginName ?? ""), userDisplayName: Demo.name(w.UserProfile?.DisplayName ?? ""),
                               deviceName: Demo.name(name), os: node.Hostinfo?.OS ?? "", addresses: node.Addresses ?? [])
    }

    /// True for Tailscale's address ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    public static func isTailscaleAddress(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            return a >> 22 == (100 << 2 | 1)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0.prefix(6)) }
            return b == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }

    public static func isLoopback(_ ip: String) -> Bool { ip == "::1" || ip.hasPrefix("127.") || ip == "localhost" }

    /// How Tailscale was reached last ("LocalAPI on localhost:<port> (macsys)", "the tailscale CLI"…), for logs.
    public static var transport: String { lock.lock(); defer { lock.unlock() }; return lastTransport }

    /// Where this module's log lines go (the app sets it; this module has no dependencies): `debug`
    /// lines are per-request detail, the others are worth a line at info (a change of endpoint, a failure).
    nonisolated(unsafe) public static var log: ((_ debug: Bool, _ message: String) -> Void)?

    // MARK: - Transport

    private static let lock = NSLock()
    private static var cached: Endpoint?
    private static var lastTransport = "not tried yet"
    private static var lastCandidates = ""

    enum Endpoint: Equatable {
        case tcp(port: Int, token: String, variant: String)
        case unix(path: String)
        var description: String {
            switch self {
            case .tcp(let port, _, let variant): "LocalAPI on localhost:\(port) (\(variant))"
            case .unix(let path): "LocalAPI on \(path)"
            }
        }
    }

    /// GETs `path` from the LocalAPI (the last endpoint that worked, else each candidate in turn); if
    /// none answers, runs the CLI with `cli`.
    private static func fetch(_ path: String, cli: [String]) throws -> Data {
        lock.lock(); let known = cached; lock.unlock()
        var tried: [String] = []
        // Debug: WISP_TAILSCALE=cli skips the LocalAPI (to test the fallback).
        let endpoints = ProcessInfo.processInfo.environment["WISP_TAILSCALE"] == "cli" ? [] : (known.map { [$0] } ?? []) + discover().filter({ $0 != known })
        let candidates = endpoints.isEmpty ? "none" : endpoints.map(\.description).joined(separator: ", ")
        lock.lock(); let newCandidates = candidates != lastCandidates; lastCandidates = candidates; lock.unlock()
        log?(!newCandidates, "LocalAPI candidates: \(candidates)")
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        for ep in endpoints {
            do {
                let (status, body) = try HTTP.get(ep, path: path)
                guard status == 200 else {
                    // The daemon answered: an error from it is final (e.g. whois of an unknown address).
                    let msg = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    remember(ep)
                    log?(true, "GET \(path) via \(ep.description): HTTP \(status) in \(ms()) ms: \(msg.prefix(200))")
                    throw TailnetError("Tailscale: \(msg.isEmpty ? "HTTP \(status)" : msg)")
                }
                remember(ep)
                log?(true, "GET \(path) via \(ep.description): \(body.count) B in \(ms()) ms")
                return body
            } catch let e as TailnetError {
                throw e
            } catch {
                log?(false, "\(ep.description) didn't answer GET \(path): \(error.localizedDescription)")
                tried.append("\(ep.description): \(error.localizedDescription)")
            }
        }
        lock.lock(); cached = nil; lock.unlock()
        guard let exe = cliPath() else {
            log?(false, "no LocalAPI answered and there's no tailscale CLI")
            throw TailnetError("Tailscale isn't running on this Mac (no LocalAPI, no tailscale CLI)" + (tried.isEmpty ? "" : ": " + tried.joined(separator: "; ")))
        }
        let out: Data
        do { out = try run(exe, cli) } catch {
            log?(false, "tailscale CLI \(exe) \(cli.joined(separator: " ")) failed: \(error.localizedDescription)")
            throw error
        }
        let via = "the tailscale CLI (\(exe))"
        lock.lock(); let changed = lastTransport != via; lastTransport = via; lock.unlock()
        log?(!changed, "\(cli.joined(separator: " ")) via \(via): \(out.count) B in \(ms()) ms")
        return out
    }

    private static func remember(_ ep: Endpoint) {
        lock.lock(); let changed = cached != ep; cached = ep; lastTransport = ep.description; lock.unlock()
        if changed { log?(false, "using \(ep.description)") }
    }

    /// The LocalAPI endpoints worth trying, in Tailscale's own order.
    static func discover() -> [Endpoint] {
        var out: [Endpoint] = []
        if let ep = macosAppStoreEndpoint() { out.append(ep) }
        if let ep = macsysEndpoint() { out.append(ep) }
        for path in ["/var/run/tailscaled.socket", "/var/run/tailscale/tailscaled.sock"] where FileManager.default.fileExists(atPath: path) {
            out.append(.unix(path: path))
        }
        return out
    }

    /// The App Store variant: the port and token are in the name of a file IPNExtension keeps open.
    private static func macosAppStoreEndpoint() -> Endpoint? {
        let out: Data
        do { out = try run("/usr/sbin/lsof", ["-n", "-a", "-u\(getuid())", "-c", "IPNExtension", "-F"], timeout: 2) } catch {
            // lsof exits 1 when no IPNExtension runs: the App Store app isn't in use.
            log?(true, "App Store Tailscale: no IPNExtension found (\(error.localizedDescription))")
            return nil
        }
        let marker = ".tailscale.ipn.macos/sameuserproof-"
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            guard let r = line.range(of: marker) else { continue }
            let f = line[r.upperBound...].split(separator: "-", maxSplits: 1)
            if f.count == 2, let port = Int(f[0]) { return .tcp(port: port, token: String(f[1]), variant: "App Store app") }
        }
        return nil
    }

    /// The standalone variant: /Library/Tailscale/ipnport -> "<port>", token in sameuserproof-<port>.
    private static func macsysEndpoint() -> Endpoint? {
        let dir = "/Library/Tailscale"
        guard let portString = try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/ipnport"), let port = Int(portString),
              let token = try? String(contentsOfFile: dir + "/sameuserproof-\(portString)", encoding: .utf8)
        else { return nil }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : .tcp(port: port, token: t, variant: "standalone app")
    }

    /// The tailscale CLI: inside the app, or on $PATH.
    private static func cliPath() -> String? {
        var candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/tailscale" }
        candidates += ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `exe` and returns its standard output; throws on failure or after `timeout` seconds.
    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TailnetError("\((exe as NSString).lastPathComponent) \(args.first ?? ""): \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, path: String, cli: [String]) throws -> T {
        let data = try fetch(path, cli: cli)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw TailnetError("Tailscale's answer couldn't be read: \(error.localizedDescription)")
        }
    }

    private static func trimDot(_ s: String) -> String { s.hasSuffix(".") ? String(s.dropLast()) : s }

    // MARK: - JSON (the fields we use of ipnstate.Status and apitype.WhoIsResponse)

    private struct Status: Decodable {
        var BackendState: String?
        var Self_: PeerStatus?
        var Peer: [String: PeerStatus]?
        var User: [String: User]?
        enum CodingKeys: String, CodingKey { case BackendState, Self_ = "Self", Peer, User }
        struct PeerStatus: Decodable {
            var HostName: String?
            var DNSName: String?
            var OS: String?
            var TailscaleIPs: [String]?
            var Online: Bool?
            var UserID: Int64?
        }
    }

    private struct User: Decodable {
        var LoginName: String?
        var DisplayName: String?
    }

    private struct WhoIs: Decodable {
        var Node: NodeInfo?
        var UserProfile: User?
        struct NodeInfo: Decodable {
            var Name: String?
            var ComputedName: String?
            var Addresses: [String]?
            var Hostinfo: HostInfo?
        }
        struct HostInfo: Decodable { var OS: String? }
    }
}

// MARK: - A minimal HTTP/1.0 client over a TCP or Unix socket

/// One GET per connection, `Connection: close`, body read to the end. Enough for the LocalAPI, and
/// it works the same over a Unix socket (which URLSession can't use).
private enum HTTP {
    struct SocketError: LocalizedError {
        let errorDescription: String?
        init(_ what: String, _ code: Int32 = errno) { errorDescription = "\(what): \(String(cString: strerror(code)))" }
    }

    static func get(_ ep: Tailnet.Endpoint, path: String, timeout: TimeInterval = 2) throws -> (Int, Data) {
        let fd: Int32
        var auth = ""
        switch ep {
        case .tcp(let port, let token, _):
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError("socket") }
            setTimeouts(fd, timeout)
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(UInt16(port).bigEndian)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard r == 0 else { let e = errno; close(fd); throw SocketError("connect to localhost:\(port)", e) }
            auth = "Authorization: Basic \(Data(":\(token)".utf8).base64EncodedString())\r\n"
        case .unix(let path):
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError("socket") }
            setTimeouts(fd, timeout)
            var a = sockaddr_un()
            a.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { close(fd); throw SocketError("path", ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &a.sun_path) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
                buf[bytes.count] = 0
            }
            a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard r == 0 else { let e = errno; close(fd); throw SocketError("connect to \(path)", e) }
        }
        defer { close(fd) }
        let request = "GET \(path) HTTP/1.0\r\nHost: local-tailscaled.sock\r\n\(auth)Connection: close\r\n\r\n"
        let sent = request.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
        guard sent == request.utf8.count else { throw SocketError("send") }
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 { throw SocketError("receive") }
            if n == 0 { break }
            response.append(buf, count: n)
            if response.count > 32 << 20 { throw SocketError("receive", EMSGSIZE) }
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw SocketError("malformed HTTP response", EPROTO) }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { throw SocketError("malformed HTTP status", EPROTO) }
        var body = Data(response[split.upperBound...])
        if head.lowercased().contains("transfer-encoding: chunked") { body = dechunk(body) }
        return (code, body)
    }

    private static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func dechunk(_ d: Data) -> Data {
        var out = Data(), rest = d[...]
        while let nl = rest.range(of: Data("\r\n".utf8)) {
            guard let size = Int(String(decoding: rest[..<nl.lowerBound], as: UTF8.self).split(separator: ";")[0], radix: 16), size > 0 else { break }
            let start = nl.upperBound
            guard rest.distance(from: start, to: rest.endIndex) >= size else { break }
            let end = rest.index(start, offsetBy: size)
            out.append(rest[start ..< end])
            rest = rest[min(rest.endIndex, rest.index(end, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex)...]
        }
        return out
    }
}
