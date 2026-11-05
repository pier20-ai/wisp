// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Tailnet
import WispCommon

// Descriptions of Network.framework states, paths and endpoints for the log: enough to tell a name
// that didn't resolve from a route that doesn't exist, or a tunnel (utun) from Wi-Fi.

extension NWConnection.State {
    var logDescription: String {
        switch self {
        case .setup: return "setup"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .waiting(let e): return "waiting (\(e.logDescription))"
        case .failed(let e): return "failed (\(e.logDescription))"
        case .cancelled: return "cancelled"
        @unknown default: return "\(self)"
        }
    }
}

extension NWListener.State {
    var logDescription: String {
        switch self {
        case .setup: return "setup"
        case .waiting(let e): return "waiting (\(e.logDescription))"
        case .ready: return "ready"
        case .failed(let e): return "failed (\(e.logDescription))"
        case .cancelled: return "cancelled"
        @unknown default: return "\(self)"
        }
    }
}

extension NWError {
    /// "POSIXErrorCode(rawValue: 61): Connection refused" → "Connection refused (POSIX 61)"; DNS
    /// errors with their DNSServiceErrorType (-65538: no such name).
    var logDescription: String {
        switch self {
        case .posix(let c): return "\(String(cString: strerror(c.rawValue))) (POSIX \(c.rawValue))"
        case .dns(let c): return "DNS error \(c)\(c == -65538 ? ": no such name" : c == -65554 ? ": no such record" : c == -65568 ? ": timed out" : "")"
        case .tls(let s): return "TLS error \(s)"
        default: return "\(self)"
        }
    }
}

extension NWPath {
    /// "satisfied via utun4 (other), 100.101.1.2:52044 → 100.101.1.9:7878", "unsatisfied (no route)".
    var logDescription: String {
        var s: String
        switch status {
        case .satisfied: s = "satisfied"
        case .unsatisfied:
            s = "unsatisfied"
            switch unsatisfiedReason {
            case .notAvailable: break
            case .cellularDenied: s += " (cellular denied)"
            case .wifiDenied: s += " (Wi-Fi denied)"
            case .localNetworkDenied: s += " (local network denied)"
            case .vpnInactive: s += " (VPN inactive)"
            @unknown default: break
            }
        case .requiresConnection: s = "requires connection"
        @unknown default: s = "\(status)"
        }
        var seen = Set<String>()
        let interfaces = availableInterfaces.filter { seen.insert($0.name).inserted }.map { "\($0.name) (\($0.type.logName))" }
        if !interfaces.isEmpty { s += " via " + interfaces.joined(separator: ", ") }
        if let l = localEndpoint, let r = remoteEndpoint { s += ", \(l) → \(r)" } else if let r = remoteEndpoint { s += ", → \(r)" }
        if isExpensive { s += ", expensive" }
        return s
    }
}

extension NWInterface.InterfaceType {
    /// utun (Tailscale and other VPN tunnels) is "other".
    var logName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "\(self)"
        }
    }
}

/// How an address the user typed or chose will be reached: an IP literal, or a name to resolve
/// (and which kind: a MagicDNS short name only resolves with MagicDNS on, and only on the same tailnet).
func describeAddress(_ host: String) -> String {
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 {
        if Tailnet.isLoopback(host) { return "\(host) (loopback IP)" }
        if Tailnet.isTailscaleAddress(host) { return "\(host) (Tailscale IP)" }
        return "\(host) (IP address)"
    }
    if host == "localhost" { return "localhost (loopback name)" }
    if host.hasSuffix(".ts.net") || host.hasSuffix(".ts.net.") { return "\(host) (MagicDNS name, resolved by Tailscale's DNS)" }
    if !host.contains(".") { return "\(host) (short name: needs MagicDNS or a search domain to resolve)" }
    return "\(host) (DNS name)"
}
