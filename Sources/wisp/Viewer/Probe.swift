// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import WispCommon

/// What a probe found on a Mac (see MsgType.probe).
enum ProbeResult: Equatable {
    /// The host answered: it's sharing.
    case sharing(ProbeReply)
    /// It's sharing, but won't take us (its allow-list, or we're not on Tailscale): the reason.
    case refused(String)
    /// Something listens, but it's an older version that doesn't know probes.
    case olderVersion
    /// Nothing listens on the port (the app isn't sharing), or no answer in time.
    case notSharing

    var isSharing: Bool { if case .notSharing = self { return false }; return true }

    /// "Sharing · 2 of 3 windows open", "Not sharing"…
    var summary: String {
        switch self {
        case .sharing(let r):
            if r.viewerConnected { return "Sharing · in use (\(r.openStreams) of \(r.maxStreams) open)" }
            return r.hasPrimary ? "Sharing" : "Sharing · no window chosen"
        case .refused: return "Sharing · not allowed for you"
        case .olderVersion: return "Sharing · older version"
        case .notSharing: return "Not sharing"
        }
    }
}

/// Asks a Mac whether it's sharing, without becoming its viewer: a TCP connect to 7878 and one `probe`
/// message, with a short timeout. A refused connection (nothing listening) answers at once.
enum Probe {
    /// `completion` runs once, on the main queue.
    static func run(host: String, timeout: TimeInterval = 2, completion: @escaping (ProbeResult) -> Void) {
        let q = DispatchQueue(label: "wisp.probe")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(ceil(timeout))
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Wire.tcpPort)!, using: NWParameters(tls: nil, tcp: tcp))
        let parser = MessageParser()
        var done = false
        let started = Date()
        var lastState = "setup"
        func finish(_ r: ProbeResult, _ why: String = "") {
            guard !done else { return }
            done = true
            Log.debug(.discovery, "probe \(host): \(r.summary)\(why.isEmpty ? "" : " (\(why))") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            c.cancel()
            DispatchQueue.main.async { completion(r) }
        }
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isDone, err in
                if let data {
                    for (t, p) in parser.feed(data) {
                        switch t {
                        case .probeAck: finish(ProbeReply.decode(p).map(ProbeResult.sharing) ?? .olderVersion)
                        case .refused: var r = Reader(p); finish(.refused(r.str() ?? "refused"), "refused")
                        case .windowInfo, .helloAck: finish(.olderVersion, "answered \(t)") // a host that took us for a viewer
                        default: break
                        }
                    }
                }
                if isDone || err != nil { finish(.olderVersion, "closed without answering: \(err?.logDescription ?? "EOF")"); return } // it listened, then closed without answering
                receive()
            }
        }
        c.stateUpdateHandler = { st in
            lastState = st.logDescription
            switch st {
            case .ready:
                c.send(content: message(.probe) { $0.u16(Wire.protocolVersion) }, completion: .idempotent)
                receive()
            case .waiting, .failed: finish(.notSharing, "TCP \(st.logDescription)") // e.g. connection refused: nothing listens
            default: break
            }
        }
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { finish(.notSharing, "no answer in \(timeout) s, TCP \(lastState)") }
    }
}
