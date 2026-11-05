// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WispCommon

/// Notices decoded frames that never reach the screen: once a second, on its own queue, each window
/// whose newest frame has waited over 2 s to be shown gets a STALL line (with whether the main
/// thread answers, see MainThreadWatch). If the main thread does answer, the show is scheduled again
/// (it can only have been lost). Runs in the app and in each phantom (RemoteView.enqueue adds a view).
enum DisplayWatch {
    private static let q = DispatchQueue(label: "wisp.displaywatch")
    private final class Watched {
        weak var view: RemoteView?
        var episode: StallEpisode
        init(_ v: RemoteView, _ label: String) { view = v; episode = StallEpisode("\(label) display", .viewer) }
    }
    nonisolated(unsafe) private static var views: [Watched] = [] // q
    nonisolated(unsafe) private static var timer: DispatchSourceTimer? // q

    /// Fault `main-block[=<s>]`: block the main thread that long (default 3 s), 4 s after the first frame.
    private static let faultBlock = Fault.number("main-block", default: 3)

    /// Any queue.
    static func add(_ v: RemoteView) {
        let label = v.streamLabel
        q.async {
            views.append(Watched(v, label))
            guard timer == nil else { return }
            MainThreadWatch.start()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { tick() }
            t.resume()
            timer = t
            if let s = faultBlock {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    Log.warning(.viewer, "FAULT main-block: blocking the main thread for \(s) s")
                    Thread.sleep(forTimeInterval: s)
                    Log.warning(.viewer, "FAULT main-block: main thread released")
                }
            }
        }
    }

    private static func tick() {
        views.removeAll { $0.view == nil }
        for w in views {
            guard let v = w.view else { continue }
            let st = v.displayState
            if st.waiting > 2 {
                let blocked = MainThreadWatch.blockedFor
                if !w.episode.active {
                    w.episode.begin(String(format: "a decoded frame has waited %.1f s to be shown (%d frames decoded, %d shown, last shown %@); ",
                                           st.waiting, st.enqueued, st.shown, ago(st.lastShown))
                        + (blocked > 0 ? String(format: "the main thread hasn't answered for %.1f s", blocked)
                                       : "the main thread answers (show \(st.scheduled ? "scheduled" : "NOT scheduled"))"),
                        at: Date(timeIntervalSinceNow: -st.waiting))
                }
                if blocked == 0 {
                    w.episode.act("scheduled the show again")
                    v.rescheduleShow()
                }
            } else if w.episode.active, st.waiting == 0 {
                w.episode.end("frames reach the screen again (\(st.shown) shown in all)")
            }
        }
    }
}
