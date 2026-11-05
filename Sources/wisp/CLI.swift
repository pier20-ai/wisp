// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ScreenCaptureKit
import WispCommon

let usage = """
usage:
  \(Brand.cli)                                   open the app (a menu bar item: view other Macs, or share this one)
  \(Brand.cli) send --list                       list shareable windows
  \(Brand.cli) send --window <id | app or title> share a window
             [--kbps 2500] [--fps 60] [--scale 2] [--codec hevc|h264] [--refine 3] [--pace-mbps 20] [--fec 8]
             [--no-virtual-display]       don't put the window on a HiDPI virtual display sized to the viewer
             [--max-streams 3]            how many windows a viewer may stream at once
             [--no-clipboard]             don't sync the clipboard with the viewer (on by default; setting \(ClipboardSync.hostKey))
             [--allow <login>]…           only these tailnet users may connect (default: the app's allow-list; empty = anyone)
             [--allow-lan]                also accept connections from outside Tailscale (unencrypted; loopback always works)
  \(Brand.cli) send --synthetic 1600x1000        test patterns instead of real windows: 3 test windows (no input injected)
                                          (clipboard sync only with --clipboard or WISP_PASTEBOARD=<private pasteboard>)
  \(Brand.cli) view <host>                       view and control the window shared from <host>; its menu bar list opens more
             [--phantoms]                 each remote app in a phantom app of its own, as \(Brand.name).app does
  \(Brand.cli) --connect <host>                  open the app connected to <host> (phantom apps use this to start \(Brand.name))
  \(Brand.cli) view <host> --snapshot out.png    headless test: decode a few seconds, save the last frame
             [--open <id>,<id>…]          also open these windows (ids from --windows); window N's frame goes to out-N.png
             [--close <id>@<seconds>]     close that window's stream after that long; the others keep going
  \(Brand.cli) poke <host> [--stream N] click <x>,<y>  debug: one click at a point in a streamed window (0…1 each)
  \(Brand.cli) poke <host> [--stream N] action close   debug: close the window (as the viewer's red button does)
  \(Brand.cli) poke <host> [--stream N] action new-window  debug: the synthetic host gives that window's app a new window
  \(Brand.cli) poke <host> [--stream N] action open-panel  debug: the synthetic host shows a fake out-of-process Open panel in it
  \(Brand.cli) poke <host> [--stream N] key <keycode>  debug: one key press (macOS virtual keycode, e.g. 56 = shift)
  \(Brand.cli) poke <host> [--stream N] resize <w>x<h> debug: resize the window to w x h points, as if done on the host
                                          (default: the host's primary stream; poke keeps any connected viewer connected)
  \(Brand.cli) e2e <host> [--windows 1,2,3 | --app WispProbe] [--soak <minutes>] [--seed N] [--scenarios scroll,click,key,resize]
             (--host-log <file> | --host-log-cmd "<command printing the host's input log>") [--max-freeze 1.0] [-v]
                                          end-to-end test: drive the viewer with scripted input, check what the host's
                                          test windows received and that their frame counters keep moving (docs/testing.md)
  \(Brand.cli) view <host> --windows             print the host's shareable windows (the viewer's menu bar list)
  \(Brand.cli) view <host> --menus <appKey>      print that app's menu bar as the host reads it (appKey from --windows)
             [--press "File>New Window"]  then choose that item there
  \(Brand.cli) tailnet [peers]                    the Macs on your tailnet and whether each is sharing (via Tailscale's LocalAPI)
  \(Brand.cli) tailnet whois <ip>               who a Tailscale address belongs to (what the host checks for each viewer)
  \(Brand.cli) tailnet probe <host>             ask one Mac whether it's sharing, without connecting as its viewer
  \(Brand.cli) vdisplay-test <w>x<h> [seconds] [--count N]
                                          debug: create N (default 1, at most 3) HiDPI virtual displays of w x h points
                                          side by side, check them, list displays, then remove them one by one
  \(Brand.cli) diagnostics                      print a report for an issue: versions, permissions, settings, Tailscale
                                          (other people's logins hashed) and the end of wisp.log (no Mac is probed)

Logs: \(LogFile.dir.path) (wisp.log, phantom-<App>.log, cli.log, latency.log, stats.csv).
Verbose (debug) logging: WISP_VERBOSE=1, or `defaults write \(Brand.defaultsDomain) \(Log.verboseKey) -bool YES`.
"""

func fail(_ s: String, code: Int32 = 2) -> Never {
    Log.echoToStderr = false // said once, below
    Log.error(.cli, s.hasPrefix("usage:") ? "usage error: \(arguments.joined(separator: " "))" : s)
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(code)
}

// MARK: - send

func runSend(_ arguments: [String]) -> Never {
    var opts = HostOptions()
    var list = false, window: String?, synthetic: CGSize?
    var clipboard: Bool?
    var access = AccessPolicy.fromDefaults()
    var allow: [String] = []
    var args = arguments.makeIterator()
    func next(_ flag: String) -> String {
        guard let v = args.next() else { fail("missing value for \(flag)\n\(usage)") }
        return v
    }
    while let a = args.next() {
        switch a {
        case "--list": list = true
        case "--window": window = next(a)
        case "--kbps": opts.kbps = Int(next(a)) ?? opts.kbps
        case "--fps": opts.fps = Int(next(a)) ?? opts.fps
        case "--scale": opts.scale = Double(next(a))
        case "--codec": opts.hevc = next(a).lowercased() != "h264"
        case "--refine": opts.refine = Int(next(a)) ?? opts.refine
        case "--pace-mbps": opts.paceMbps = Double(next(a)) ?? opts.paceMbps
        case "--fec": opts.fec = Int(next(a)) ?? opts.fec
        case "--no-virtual-display": opts.virtualDisplay = false
        case "--max-streams": opts.maxStreams = max(1, Int(next(a)) ?? opts.maxStreams)
        case "--no-clipboard": clipboard = false
        case "--clipboard": clipboard = true
        case "--allow": allow.append(next(a))
        case "--allow-lan": access.allowLAN = true
        case "--synthetic":
            let p = next(a).split(separator: "x").compactMap { Double($0) }
            guard p.count == 2 else { fail(usage) }
            synthetic = CGSize(width: p[0], height: p[1])
        default: fail(usage)
        }
    }
    guard list || window != nil || synthetic != nil else { fail(usage) }

    if !allow.isEmpty { access.allowedViewers = allow }
    // A test host doesn't touch this Mac's clipboard unless asked (or given a private pasteboard).
    opts.clipboard = clipboard ?? (synthetic == nil || ClipboardSync.isTestPasteboard)
    let host = Host(opts: opts)
    host.server.access.policy = { access }
    log((access.allowedViewers.isEmpty ? "access: anyone on the tailnet" : "access: only \(access.allowedViewers.joined(separator: ", "))")
        + (access.allowLAN ? ", and connections from outside Tailscale" : ""))
    Task { @MainActor in
        if let synthetic {
            host.shareSynthetic(size: synthetic)
        } else {
            guard Host.ensureScreenRecording() else {
                fail("Screen Recording permission missing: System Settings > Privacy & Security > Screen Recording > enable your terminal app, then rerun.", code: 1)
            }
            let windows: [SCWindow]
            do { windows = try await Host.windows() } catch { fail("could not list windows: \(error.localizedDescription)", code: 1) }
            if list {
                print(String(format: "%-8@ %-24@ %-11@ %@", "ID", "APP", "SIZE", "TITLE"))
                for w in windows {
                    let app = w.owningApplication?.applicationName ?? "?"
                    print(String(format: "%-8d %-24@ %-11@ %@", w.windowID, String(app.prefix(24)) as NSString,
                                 "\(Int(w.frame.width))x\(Int(w.frame.height))" as NSString, (w.title ?? "") as NSString))
                }
                exit(0)
            }
            if !Host.ensureAccessibility() {
                log("WARNING: Accessibility permission missing, so the viewer can watch but not control. Enable your terminal app in System Settings > Privacy & Security > Accessibility, then rerun.")
            }
            guard let w = Host.findWindow(window!, in: windows) else { fail("no window matches \"\(window!)\". Try --list.", code: 1) }
            do { try await host.share(w) } catch { fail("capture failed: \(error.localizedDescription)", code: 1) }
        }
        do { try host.start() } catch { host.stop(); fail("could not start sharing: \(error.localizedDescription)", code: 1) }
    }
    // A real event loop (not a bare run loop): launched as Wisp.app it must answer LaunchServices,
    // or opening the app again reports it as "not responding". Accessory = no Dock icon.
    // Ctrl-C / kill: put the shared window back and remove the virtual display before exiting.
    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { host.stop(); exit(0) }
        s.resume()
        return s
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    withExtendedLifetime((host, signals)) { app.run() }
    exit(0)
}

