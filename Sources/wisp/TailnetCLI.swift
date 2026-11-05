// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Tailnet
import WispCommon

/// `wisp tailnet [peers]`: the tailnet as Tailscale sees it, and whether each Mac is sharing.
/// `wisp tailnet whois <ip>`: who an address belongs to (what the host checks for each viewer).
func runTailnet(_ args: [String]) -> Never {
    switch args.first ?? "peers" {
    case "peers":
        let peers: [TailnetPeer]
        do { peers = try Tailnet.peers() } catch { fail("error: \(error.localizedDescription)", code: 1) }
        print("via \(Tailnet.transport)")
        let probe = !args.contains("--no-probe")
        var results: [String: ProbeResult] = [:]
        if probe {
            // Probe every online Mac but this one, all at once.
            let group = DispatchGroup()
            let lock = NSLock()
            for p in peers where p.isMac && p.online && !p.isSelf {
                group.enter()
                Probe.run(host: p.address) { r in lock.lock(); results[p.address] = r; lock.unlock(); group.leave() }
            }
            while group.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        func row(_ cols: [String]) -> String {
            zip(cols, [28, 8, 7, 16, 30, 0]).map { c, w in w == 0 ? c : c.padding(toLength: max(w, c.count), withPad: " ", startingAt: 0) }.joined(separator: " ")
        }
        print(row(["NAME", "OS", "ONLINE", "ADDRESS", "USER", probe ? Brand.name.uppercased() : ""]))
        for p in peers {
            let r = results[p.address].map(\.summary) ?? (p.isSelf ? "(this Mac)" : (!p.isMac || !p.online || !probe) ? "" : "?")
            print(row([p.shortName, p.os, p.online ? "yes" : "no", p.address, p.userLoginName, r]))
        }
        exit(0)
    case "whois":
        guard args.count >= 2 else { fail("usage: \(Brand.cli) tailnet whois <ip>") }
        do {
            let id = try Tailnet.whois(args[1])
            print("via \(Tailnet.transport)")
            print("user:    \(id.userDisplayName) <\(id.userLoginName)>")
            print("device:  \(id.deviceName) (\(id.os.isEmpty ? "?" : id.os))")
            print("address: \(id.addresses.joined(separator: ", "))")
            print("shown as \"\(id.label)\"")
        } catch { fail("error: \(error.localizedDescription)", code: 1) }
        exit(0)
    case "probe":
        guard args.count >= 2 else { fail("usage: \(Brand.cli) tailnet probe <host>") }
        Probe.run(host: args[1]) { r in print(r.summary); exit(0) }
        RunLoop.main.run()
        exit(0)
    default:
        fail("usage: \(Brand.cli) tailnet [peers [--no-probe] | whois <ip> | probe <host>]")
    }
}
