// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WispCommon

/// Watches every pipeline once a second for a stream that has stopped reaching the viewer, on its
/// own queue (so a busy main thread doesn't hide it). Logs, per stream:
/// - a STALL when the window keeps changing (ScreenCaptureKit delivers frames) but nothing has been
///   sent for 3 s, with the encoder's in-flight state, skips and the send path;
/// - a STALL when the viewer clicked or typed into the window (3 presses over 3 s) and ScreenCaptureKit
///   delivered no frame since: the capture may have stopped (or the window ignored the input);
/// - every 5 s a health line: at debug always, at info when something looked wrong in those 5 s.
/// The encoder's own lost-frame watchdog is in Pipeline.encode (it acts on the pipeline's queue).
/// Also starts MainThreadWatch. Lines and how to read them: docs/testing.md "Stalls".
final class HostHealth {
    static let shared = HostHealth()
    private let q = DispatchQueue(label: "wisp.health")
    private var timer: DispatchSourceTimer?
    private weak var server: Server?

    private final class Watched {
        weak var pipeline: Pipeline?
        let stream: UInt16
        var prev = Pipeline.Counts()
        var periodStart = Pipeline.Counts()
        var periodNacks = 0, periodMissed = 0
        var unsentSince: Date?
        var pressedSince: (at: Date, presses: UInt32)?
        var noSend: StallEpisode
        var noCapture: StallEpisode
        var odd: [String] = [] // what looked wrong in this 5 s period
        init(_ p: Pipeline) {
            pipeline = p
            stream = p.stream
            noSend = StallEpisode("stream #\(p.stream) host", .host)
            noCapture = StallEpisode("stream #\(p.stream) capture", .capture)
        }
    }
    private var watched: [Watched] = []
    private var ticks = 0
    private var lastSendErrors = 0

    /// A new pipeline (any queue).
    func add(_ p: Pipeline, server: Server) {
        q.async { [self] in
            self.server = server
            watched.append(Watched(p))
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: q)
                t.schedule(deadline: .now() + 1, repeating: 1)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
                MainThreadWatch.start()
            }
        }
    }

    private func tick() {
        ticks += 1
        watched.removeAll { $0.pipeline == nil || $0.pipeline!.isStopped }
        guard let server else { return }
        let report = ticks % 5 == 0
        let net = report ? server.takeNetHealth() : nil
        let now = Date(), us = nowMicros()
        for w in watched {
            guard let p = w.pipeline else { continue }
            let c = p.snapshot
            let enabled = p.enabled
            defer { w.prev = c }

            // Frames captured but none sent.
            if c.sent > w.prev.sent {
                w.unsentSince = nil
                if w.noSend.active { w.noSend.end("frames are being sent again (\(c.sent - w.prev.sent) in the last second)") }
            } else if enabled, c.captured > w.prev.captured || c.submitted > w.prev.submitted {
                w.unsentSince = w.unsentSince ?? now.addingTimeInterval(-1)
            } else if !enabled {
                w.unsentSince = nil
                if w.noSend.active { w.noSend.end("the viewer closed the stream") }
            }
            if let since = w.unsentSince, now.timeIntervalSince(since) >= 3, !w.noSend.active {
                let n = server.streamNet(w.stream)
                w.noSend.begin(String(format: "the window is changing (%d frames captured, %d handed to the encoder in %.0f s) but nothing was sent; ",
                                      c.captured - w.periodStart.captured, c.submitted - w.periodStart.submitted, now.timeIntervalSince(since))
                    + "last frame sent \(ago(n.lastSent, now: us)), skipped as encoder-busy \(c.skippedBusy - w.prev.skippedBusy) in the last second, "
                    + "viewer UDP path \(server.hasViewer ? "open" : "NOT open"); encoder: \(p.encoderSummary)", at: since)
                w.odd.append("nothing sent")
            }

            // Presses with no frame from ScreenCaptureKit.
            let presses = server.pressesReceived(w.stream)
            if c.captured > w.prev.captured || !enabled {
                w.pressedSince = nil
                if w.noCapture.active { w.noCapture.end(enabled ? "ScreenCaptureKit delivered a frame" : "the viewer closed the stream") }
            } else if presses > c.pressesAtLastCapture {
                if w.pressedSince == nil { w.pressedSince = (now, c.pressesAtLastCapture) }
                if let ps = w.pressedSince, presses - ps.presses >= 6, now.timeIntervalSince(ps.at) >= 3, !w.noCapture.active {
                    // 6 = three clicks or key presses (down and up).
                    w.noCapture.begin("\((presses - ps.presses) / 2) clicks or key presses in \(Int(now.timeIntervalSince(ps.at))) s but no frame from "
                        + "ScreenCaptureKit since (last one \(ago(c.lastCaptureAt, now: us))): its capture may have stopped, or the window ignores the input",
                        at: ps.at)
                    w.odd.append("no capture after input")
                }
            }

            if report {
                let n = server.streamNet(w.stream)
                let d = c, s = w.periodStart
                let nacks = n.nacks - w.periodNacks, missed = n.missed - w.periodMissed
                if c.encoderResets > s.encoderResets || c.encoderRebuilds > s.encoderRebuilds { w.odd.append("encoder recovered") }
                if missed > 0 { w.odd.append("\(missed) NACKs for frames no longer cached") }
                if c.skippedBusy - s.skippedBusy > 0, c.sent == s.sent { w.odd.append("every frame skipped as busy") }
                let line = "stream #\(w.stream) health (5 s)\(enabled ? "" : ", not open"): captured \(d.captured - s.captured), encoded \(d.submitted - s.submitted) "
                    + "(refinements \(d.refinements - s.refinements), forced keyframes \(d.forcedKeys - s.forcedKeys)), sent \(d.sent - s.sent), "
                    + "skipped busy \(d.skippedBusy - s.skippedBusy), NACKs served \(nacks)\(missed > 0 ? " (\(missed) too old)" : ""), "
                    + "last capture \(ago(d.lastCaptureAt, now: us)), last send \(ago(n.lastSent, now: us)); encoder: \(p.encoderSummary)"
                    + (c.encoderResets + c.encoderRebuilds > 0 ? "; encoder recoveries \(c.encoderResets) resets, \(c.encoderRebuilds) rebuilt" : "")
                if !w.odd.isEmpty { Log.info(.host, line + " [\(w.odd.joined(separator: ", "))]") } else if enabled || d.captured > s.captured { Log.debug(.host, line) }
                w.odd = []
                w.periodStart = c
                w.periodNacks = n.nacks
                w.periodMissed = n.missed
            }
        }
        if let net {
            let wrong = net.sendErrors > lastSendErrors || net.maxWait > 500_000 || net.peak > 5000
            lastSendErrors = net.sendErrors
            if !watched.isEmpty || wrong {
                let line = "send path (5 s): \(net.description)"
                if wrong { Log.info(.net, line) } else { Log.debug(.net, line) }
            }
        }
    }
}
