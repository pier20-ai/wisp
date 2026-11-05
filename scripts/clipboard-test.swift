#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Loopback test of clipboard sync, without touching this Mac's real clipboard: a synthetic host and a
// headless viewer, each in its own process with its own private pasteboard (WISP_PASTEBOARD), its own
// log directory and verbose logging. This script plays the user on both ends: it copies to one
// private pasteboard and checks what appears on the other.
//
//   swift build -c release && swift scripts/clipboard-test.swift [.build/release/wisp]
//
// Checks: text, RTF, HTML, PNG and TIFF (arrives as PNG) both ways; a multi-chunk image; concealed,
// transient and auto-generated items are not sent; files are not sent; the size cap (WISP_CLIPBOARD_MAX)
// leaves out what doesn't fit; nothing echoes back (the number of transfers each side logged).
// Needs TCP 7878 / UDP 7879 free (no other Wisp host on this Mac).
import AppKit
import Foundation

let wisp = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/release/wisp"
let tag = "\(getpid())"
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wisp-clipboard-test-\(tag)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let hostPB = NSPasteboard(name: NSPasteboard.Name("wisp-test-host-\(tag)"))
let viewerPB = NSPasteboard(name: NSPasteboard.Name("wisp-test-viewer-\(tag)"))
let cap = 3_000_000

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures += 1 }
}

func launch(_ args: [String], pasteboard: NSPasteboard, logs: String) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: wisp)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["WISP_PASTEBOARD"] = pasteboard.name.rawValue
    env["WISP_LOG_DIR"] = dir.appendingPathComponent(logs).path
    env["WISP_SUPPORT_DIR"] = dir.appendingPathComponent("support").path
    env["WISP_SOCKET"] = dir.appendingPathComponent("s").path
    env["WISP_NO_PROBE"] = "1"
    env["WISP_NO_ALERTS"] = "1"
    env["WISP_VERBOSE"] = "1"
    env["WISP_SECONDS"] = "60"
    env["WISP_CLIPBOARD_MAX"] = "\(cap)"
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    return p
}

func log(_ side: String) -> String { (try? String(contentsOf: dir.appendingPathComponent("\(side)/cli.log"), encoding: .utf8)) ?? "" }
func count(_ s: String, _ needle: String) -> Int { s.components(separatedBy: needle).count - 1 }

/// Copies one item with these representations, as an app would.
func copy(_ pb: NSPasteboard, _ reps: [(NSPasteboard.PasteboardType, Data)]) {
    pb.clearContents()
    let item = NSPasteboardItem()
    for (t, d) in reps { item.setData(d, forType: t) }
    pb.writeObjects([item])
}

/// Waits up to `timeout` for `pb` to change from `since`; true if it did.
func waitChange(_ pb: NSPasteboard, since: Int, timeout: Double = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if pb.changeCount != since { Thread.sleep(forTimeInterval: 0.1); return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

func png(_ w: Int, _ h: Int, noise: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let p = rep.bitmapData!
    for i in 0 ..< rep.bytesPerRow * h { p[i] = noise ? UInt8.random(in: 0 ... 255) : UInt8(i % 251) }
    return rep.representation(using: .png, properties: [:])!
}

let host = launch(["send", "--synthetic", "800x500"], pasteboard: hostPB, logs: "host")
Thread.sleep(forTimeInterval: 1.5)
guard host.isRunning else { print("the host exited: are the ports taken? (\(dir.path)/host/cli.log)"); exit(2) }
let viewer = launch(["view", "127.0.0.1", "--snapshot", dir.appendingPathComponent("out.png").path], pasteboard: viewerPB, logs: "viewer")
defer {}
func finish() -> Never {
    viewer.terminate(); host.terminate()
    viewer.waitUntilExit(); host.waitUntilExit()
    hostPB.releaseGlobally(); viewerPB.releaseGlobally()
    print(failures == 0 ? "all passed (logs: \(dir.path))" : "\(failures) failed (logs: \(dir.path))")
    exit(failures == 0 ? 0 : 1)
}
// Both sides say the other is on.
let ready = Date().addingTimeInterval(8)
while Date() < ready, !(log("host").contains("the viewer shares its clipboard") && log("viewer").contains("the host shares its clipboard")) {
    Thread.sleep(forTimeInterval: 0.2)
}
check(log("host").contains("the viewer shares its clipboard") && log("viewer").contains("the host shares its clipboard"), "both sides announce clipboard sync")

// 1. Plain text, viewer -> host.
var c = hostPB.changeCount
let text = "Hello from the viewer \(tag) ✓"
copy(viewerPB, [(.string, Data(text.utf8))])
check(waitChange(hostPB, since: c) && hostPB.string(forType: .string) == text, "text viewer → host")

// 2. RTF + text + HTML, host -> viewer.
c = viewerPB.changeCount
let attr = NSAttributedString(string: "Bold remote text", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
let rtf = try! attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
let html = Data("<b>Bold remote text</b>".utf8)
copy(hostPB, [(.string, Data("Bold remote text".utf8)), (.rtf, rtf), (.html, html)])
check(waitChange(viewerPB, since: c) && viewerPB.data(forType: .rtf) == rtf && viewerPB.data(forType: .html) == html
      && viewerPB.string(forType: .string) == "Bold remote text", "RTF + HTML + text host → viewer")

// 3. PNG, viewer -> host (several chunks: ~1.2 MB of noise).
c = hostPB.changeCount
let big = png(600, 500, noise: true)
copy(viewerPB, [(.png, big)])
check(waitChange(hostPB, since: c, timeout: 5) && hostPB.data(forType: .png) == big, "PNG viewer → host (\(big.count) B, \((big.count + 59999) / 60000) chunks)")

// 4. TIFF, host -> viewer: arrives as PNG.
c = viewerPB.changeCount
let tiff = NSBitmapImageRep(data: png(200, 100, noise: false))!.tiffRepresentation!
copy(hostPB, [(.tiff, tiff)])
let gotPNG = waitChange(viewerPB, since: c) ? viewerPB.data(forType: .png) : nil
check(gotPNG.flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide == 200 && $0.pixelsHigh == 100 } ?? false,
      "TIFF host → viewer arrives as PNG (\(tiff.count) B TIFF → \(gotPNG?.count ?? 0) B PNG)")

// 5. Concealed / transient / auto-generated: never sent.
for t in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
    c = hostPB.changeCount
    copy(viewerPB, [(.string, Data("secret-\(t)".utf8)), (NSPasteboard.PasteboardType(t), Data())])
    check(!waitChange(hostPB, since: c, timeout: 1.5), "\(t.split(separator: ".").last!) item not sent")
}

// 6. Files: not sent.
c = viewerPB.changeCount
copy(hostPB, [(.fileURL, Data("file:///tmp/x.txt".utf8)), (.string, Data("x.txt".utf8))])
check(!waitChange(viewerPB, since: c, timeout: 1.5), "file URL not sent")

// 7. Over the cap: text goes, the image that doesn't fit is left out.
c = hostPB.changeCount
let huge = png(1000, 1000, noise: true) // ~4 MB
copy(viewerPB, [(.string, Data("caption".utf8)), (.png, huge)])
check(waitChange(hostPB, since: c, timeout: 4) && hostPB.string(forType: .string) == "caption" && hostPB.data(forType: .png) == nil,
      "over the \(cap) B cap: text sent, \(huge.count) B PNG left out")
c = hostPB.changeCount
copy(viewerPB, [(.png, huge)])
check(!waitChange(hostPB, since: c, timeout: 1.5), "over the cap with nothing that fits: nothing sent")

// 8. URL: as text too.
c = viewerPB.changeCount
copy(hostPB, [(.URL, Data("https://example.com/a".utf8))])
check(waitChange(viewerPB, since: c) && viewerPB.string(forType: .string) == "https://example.com/a", "URL host → viewer, as text")

// 9. A newer copy replaces one in flight: two copies in a row, the last one wins.
c = hostPB.changeCount
copy(viewerPB, [(.png, png(700, 700, noise: true))])
Thread.sleep(forTimeInterval: 0.45)
copy(viewerPB, [(.string, Data("last one".utf8))])
Thread.sleep(forTimeInterval: 2.5)
check(hostPB.string(forType: .string) == "last one", "last copy wins")

// No echo: wait, then count the transfers each side started. Sent by the viewer: 1, 3, 7a, 9a, 9b (5);
// by the host: 2, 4, 8 (3). Each side applied what the other sent and sent nothing back.
Thread.sleep(forTimeInterval: 2)
let hl = log("host"), vl = log("viewer")
let hostSent = count(hl, "→ viewer:"), viewerSent = count(vl, "→ host:")
let hostGot = count(hl, "← viewer:"), viewerGot = count(vl, "← host:")
print("      host sent \(hostSent), received \(hostGot); viewer sent \(viewerSent), received \(viewerGot)")
check(hostSent == 3 && viewerSent == 5, "no echo: host sent 3, viewer sent 5")
check(viewerGot == 3 && (hostGot == 4 || hostGot == 5), "each copy applied once on the other side")
check(!hl.contains("Hello from the viewer") && !vl.contains("Bold remote text") && !hl.contains("secret-"), "no clipboard contents in the logs")
finish()
