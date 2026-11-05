// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Tailnet
import WispCommon

/// The Macs on the tailnet and whether each is sharing, for the menu bar item: Tailscale's peer list
/// (Tailnet.peers, off the main thread), then a probe of every online Mac (Probe: a TCP connect and
/// one message, no viewer connection). Refreshed on demand and every few seconds while the menu is
/// open. Main queue.
final class TailnetDiscovery {
    struct Mac: Equatable {
        var peer: TailnetPeer
        /// nil: not probed yet (or offline).
        var probe: ProbeResult?
    }

    /// The other Macs on the tailnet (not this one), online first, then by name.
    private(set) var macs: [Mac] = []
    /// This Mac as Tailscale knows it.
    private(set) var me: TailnetPeer?
    /// Everyone on the tailnet (login, display name), for the allow-list editor.
    private(set) var users: [(login: String, name: String)] = []
    /// Why there's no list (Tailscale not running…); nil when it worked.
    private(set) var error: String?
    private(set) var loaded = false
    var onChange: (() -> Void)?
    /// Probe the Macs that are online (off for tests that mustn't touch other Macs: WISP_NO_PROBE=1).
    var probes = ProcessInfo.processInfo.environment["WISP_NO_PROBE"] != "1"

    private var timer: Timer?
    private var busy = false
    private var lastSummary = "" // logged when it changes
    private let q = DispatchQueue(label: "wisp.discovery")

    func refresh() {
        guard !busy else { return }
        busy = true
        q.async { [weak self] in
            let started = Date()
            let result = Result { try Tailnet.peers() }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.debug(.discovery, "Tailnet.peers via \(Tailnet.transport): \((try? result.get().count).map { "\($0) devices" } ?? "failed") in \(ms) ms")
            DispatchQueue.main.async { self?.received(result) }
        }
    }

    private func received(_ result: Result<[TailnetPeer], Error>) {
        busy = false
        loaded = true
        switch result {
        case .failure(let e):
            if error != e.localizedDescription { Log.warning(.discovery, "no tailnet peers: \(e.localizedDescription)") }
            error = e.localizedDescription
            macs = []
        case .success(let peers):
            error = nil
            me = peers.first { $0.isSelf }
            var seen = Set<String>()
            users = peers.compactMap { p in
                guard !p.userLoginName.isEmpty, seen.insert(p.userLoginName).inserted else { return nil }
                return (p.userLoginName, p.userDisplayName)
            }
            let old = Dictionary(macs.map { ($0.peer.address, $0.probe) }, uniquingKeysWith: { a, _ in a })
            macs = peers.filter { $0.isMac && !$0.isSelf }
                .map { Mac(peer: $0, probe: $0.online ? old[$0.address] ?? nil : nil) }
                .sorted { a, b in a.peer.online != b.peer.online ? a.peer.online : a.peer.shortName.localizedCaseInsensitiveCompare(b.peer.shortName) == .orderedAscending }
            let summary = "\(peers.count) devices via \(Tailnet.transport): this Mac \(me.map { "\($0.shortName) \($0.address)" } ?? "?"), "
                + "\(macs.count) other Macs (\(macs.filter(\.peer.online).count) online)" + (probes ? "" : ", not probing (WISP_NO_PROBE)")
            if summary != lastSummary { Log.info(.discovery, summary); lastSummary = summary }
            if probes {
                for m in macs where m.peer.online {
                    let address = m.peer.address
                    Probe.run(host: address, timeout: 2) { [weak self] r in
                        guard let self, let i = macs.firstIndex(where: { $0.peer.address == address }), macs[i].probe != r else { return }
                        Log.info(.discovery, "\(macs[i].peer.shortName) (\(address)): \(r.summary)" + (macs[i].probe.map { ", was \($0.summary)" } ?? ""))
                        macs[i].probe = r
                        onChange?()
                    }
                }
            }
        }
        onChange?()
    }

    /// Refreshes now and every `interval` seconds until stop() (the menu is open). The timer runs in
    /// the common modes, so it fires while the menu is tracking.
    func start(interval: TimeInterval = 5) {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The Mac that `host` (a name or address the user connected to) is, if it's on the tailnet.
    func mac(matching host: String) -> Mac? {
        let h = host.lowercased()
        return macs.first { m in
            m.peer.address == h || m.peer.tailscaleIPs.contains(h) || m.peer.shortName.lowercased() == h
                || m.peer.dnsName.lowercased() == h || m.peer.hostName.lowercased() == h
        }
    }
}
