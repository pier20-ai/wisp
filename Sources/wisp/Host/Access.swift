// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Tailnet
import WispCommon

/// Who may connect to the host. Tailscale is the transport security and tailnet membership the access
/// control; on top of that, an optional allow-list of tailnet users (by login name), checked with
/// Tailscale's whois for each connection. Loopback is always allowed (the synthetic tests, a viewer on
/// the same Mac); other non-Tailscale addresses (LAN) only if `allowLAN` is on.
struct AccessPolicy: Equatable {
    /// Tailnet login names (e.g. "alex@example.com"), compared case-insensitively. Empty: anyone on the tailnet.
    var allowedViewers: [String] = []
    /// Accept connections from addresses outside Tailscale (a LAN). Off by default: those aren't encrypted.
    var allowLAN = false

    static let allowedViewersKey = "allowedViewers"
    static let allowLANKey = "allowLAN"

    /// What the settings say now (the host reads it for every connection, so edits apply at once).
    static func fromDefaults() -> AccessPolicy {
        let d = Brand.defaults
        return AccessPolicy(allowedViewers: (d.stringArray(forKey: allowedViewersKey) ?? []).filter { !$0.isEmpty },
                            allowLAN: d.bool(forKey: allowLANKey))
    }

    func allows(login: String) -> Bool {
        allowedViewers.isEmpty || allowedViewers.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }
}

/// The person and device behind a connection, as the host shows and logs them.
struct PeerIdentity: Equatable {
    enum Kind { case loopback, tailnet, lan }
    var kind: Kind
    var address: String
    /// From Tailscale's whois (tailnet connections that could be identified).
    var tailnet: TailnetIdentity?

    /// "Alex Doe · alex-mbp", "this Mac (loopback)", "192.168.1.20 (LAN)".
    var label: String {
        switch kind {
        case .loopback: "this Mac (\(address))"
        case .lan: "\(address) (outside Tailscale)"
        case .tailnet: tailnet.map(\.label) ?? "\(address) (unidentified)"
        }
    }
    var userName: String { tailnet.map { $0.userDisplayName.isEmpty ? $0.userLoginName : $0.userDisplayName } ?? label }
    var deviceName: String { tailnet?.deviceName ?? address }
    /// Two letters for an avatar: the person's initials.
    var initials: String { Self.initials(of: userName) }

    static func initials(of name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let s = words.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }
}

enum AccessDecision {
    case allow(PeerIdentity)
    case refuse(String, PeerIdentity)
}

/// Decides each connection (whois results cached for a minute). Its own queue; answers on it.
final class AccessControl {
    private let q = DispatchQueue(label: "wisp.access")
    private var cache: [String: (id: TailnetIdentity?, error: String?, at: Date)] = [:]
    var policy: () -> AccessPolicy = AccessPolicy.fromDefaults
    let hostName: String

    init(hostName: String) { self.hostName = hostName }

    func check(_ ip: String, completion: @escaping (AccessDecision) -> Void) {
        q.async { [self] in
            let started = Date()
            let d = decide(ip)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch d {
            case .allow(let who): Log.debug(.access, "allowed \(who.label)\(who.kind == .tailnet ? " at \(ip)" : "") in \(ms) ms")
            case .refuse(_, let who): Log.info(.access, "refusing \(who.label)\(who.kind == .tailnet ? " at \(ip)" : "") after \(ms) ms")
            }
            completion(d)
        }
    }

    private func decide(_ ip: String) -> AccessDecision {
        let p = policy()
        Log.debug(.access, "deciding on \(ip): allow-list \(p.allowedViewers.isEmpty ? "empty (anyone on the tailnet)" : "of \(p.allowedViewers.count)"), LAN \(p.allowLAN ? "allowed" : "refused")")
        if Tailnet.isLoopback(ip) { return .allow(PeerIdentity(kind: .loopback, address: ip)) }
        guard Tailnet.isTailscaleAddress(ip) else {
            let id = PeerIdentity(kind: .lan, address: ip)
            if p.allowLAN { return .allow(id) }
            Log.info(.access, "\(ip) isn't a Tailscale or loopback address and LAN connections are off")
            return .refuse("\(hostName) only accepts connections over Tailscale. Connect to its Tailscale name or 100.x address "
                           + "(both Macs must be on the same tailnet).", id)
        }
        let (who, error) = whois(ip)
        let id = PeerIdentity(kind: .tailnet, address: ip, tailnet: who)
        if p.allowedViewers.isEmpty {
            if who == nil { Log.warning(.access, "couldn't identify \(ip) through Tailscale (\(error ?? "?")); allowed: the allow-list is empty") }
            return .allow(id)
        }
        guard let who else {
            Log.warning(.access, "couldn't identify \(ip) through Tailscale (\(error ?? "no answer")); refused: there's an allow-list")
            return .refuse("\(hostName) couldn't identify you through Tailscale (\(error ?? "no answer")), and it only accepts people on its list.", id)
        }
        guard p.allows(login: who.userLoginName) else {
            Log.info(.access, "\(who.userLoginName.isEmpty ? "(no login)" : who.userLoginName) on \(who.deviceName) isn't on the allow-list")
            return .refuse("\(who.userLoginName.isEmpty ? "This device" : who.userLoginName) isn't on \(hostName)'s list of allowed viewers. "
                           + "Ask its owner to add you in \(Brand.name) › Settings › Allowed Viewers.", id)
        }
        return .allow(id)
    }

    private func whois(_ ip: String) -> (TailnetIdentity?, String?) {
        if let c = cache[ip], Date().timeIntervalSince(c.at) < (c.id == nil ? 5 : 60) { return (c.id, c.error) }
        let started = Date()
        do {
            let id = try Tailnet.whois(ip)
            cache[ip] = (id, nil, Date())
            Log.info(.access, "whois \(ip): \(id.userLoginName.isEmpty ? "(no login)" : id.userLoginName) on \(id.deviceName) (\(id.os)) via \(Tailnet.transport), "
                     + "\(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return (id, nil)
        } catch {
            Log.warning(.access, "whois \(ip) failed via \(Tailnet.transport) after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(error.localizedDescription)")
            cache[ip] = (nil, error.localizedDescription, Date())
            return (nil, error.localizedDescription)
        }
    }
}
