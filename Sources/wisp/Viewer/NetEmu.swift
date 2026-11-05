// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WispCommon

/// A slower, lossier network between this viewer and its host, for tests over loopback: the link to
/// a Mac far away (e.g. ~150 ms round trip, 1–2 % loss) without leaving this Mac. From the
/// environment, read once (phantoms inherit it, but only the main process has the connection):
///
/// - `WISP_NET_DELAY_MS=75`: one-way delay, added to what arrives (TCP and UDP) and to what is sent
///   over TCP, so the round trip grows by twice this.
/// - `WISP_NET_JITTER_MS=10`: up to this much more per datagram (UDP may then arrive out of order, as
///   it does); TCP stays in order, so its jitter only ever delays.
/// - `WISP_NET_LOSS=1.5`: this percentage of incoming datagrams is lost (as WISP_DROP), and as many
///   TCP segments, each way, need a retransmission: that one and everything behind it waits one
///   retransmission timeout (200 ms or twice the delay, whichever is longer): TCP's head-of-line
///   blocking, which is what loss does to input and control messages.
///
/// The UDP hellos the viewer sends aren't delayed. Used on the client's queue only.
final class NetEmu {
    let delay: Double, jitter: Double, loss: Double // seconds, seconds, percent
    private let q: DispatchQueue
    private lazy var tcpIn = DelayLine(q)
    private lazy var tcpOut = DelayLine(q)
    private(set) var stalls = 0, lost = 0

    /// nil unless one of the variables is set.
    init?(queue: DispatchQueue) {
        let env = ProcessInfo.processInfo.environment
        func ms(_ k: String) -> Double { max(0, Double(env[k] ?? "") ?? 0) / 1000 }
        delay = ms("WISP_NET_DELAY_MS"); jitter = ms("WISP_NET_JITTER_MS")
        loss = min(100, max(0, Double(env["WISP_NET_LOSS"] ?? "") ?? 0))
        guard delay > 0 || jitter > 0 || loss > 0 else { return nil }
        q = queue
        Log.warning(.net, String(format: "network emulation on: %.0f ms each way, jitter up to %.0f ms, %.1f %% loss (WISP_NET_*)",
                                 delay * 1000, jitter * 1000, loss))
    }

    private var rto: Double { max(0.2, 2 * delay) }
    private func hit() -> Bool { loss > 0 && Double.random(in: 0 ..< 100) < loss }

    /// An incoming datagram: lost, or handled after the delay plus jitter.
    func datagram(_ work: @escaping () -> Void) {
        if hit() { lost += 1; return }
        let wait = delay + (jitter > 0 ? Double.random(in: 0 ... jitter) : 0)
        if wait <= 0 { work(); return }
        q.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Bytes that arrived over TCP, handled in order after the delay.
    func received(_ work: @escaping () -> Void) { tcpIn.add(after: tcpWait(), work) }
    /// Bytes to send over TCP, sent in order after the delay.
    func sending(_ work: @escaping () -> Void) { tcpOut.add(after: tcpWait(), work) }

    private func tcpWait() -> Double {
        var w = delay + (jitter > 0 ? Double.random(in: 0 ... jitter) : 0)
        if hit() { stalls += 1; w += rto }
        return w
    }
}

/// Runs work in order, each no earlier than its own deadline (and never before the one ahead of it).
private final class DelayLine {
    private let q: DispatchQueue
    private var items: [(due: DispatchTime, work: () -> Void)] = []
    private var last = DispatchTime.now()
    private var scheduled = false
    init(_ q: DispatchQueue) { self.q = q }

    func add(after wait: Double, _ work: @escaping () -> Void) {
        let due = max(DispatchTime.now() + wait, last)
        last = due
        items.append((due, work))
        schedule()
    }

    private func schedule() {
        guard !scheduled, let first = items.first else { return }
        scheduled = true
        q.asyncAfter(deadline: first.due) { [self] in
            scheduled = false
            let now = DispatchTime.now()
            while let f = items.first, f.due <= now {
                items.removeFirst()
                f.work()
            }
            schedule()
        }
    }
}
