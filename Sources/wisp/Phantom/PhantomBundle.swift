// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WispCommon

/// A phantom app on disk: one generated app bundle per (host, remote app), the Chrome app-shim
/// pattern (docs/multi-window.md §5.1):
///
///     ~/Library/Application Support/<Brand.name>/Phantoms/<host>/<appKey>/<App Name>.app/Contents/
///       Info.plist        CFBundleIdentifier <Brand.phantomBundleIDPrefix><16 hex of SHA-256(host, appKey)>,
///                         CFBundleName and CFBundleDisplayName = the remote app's name,
///                         <Brand.phantomInfoKey> = {host, appKey, …}
///       MacOS/<Brand.name>  a copy of the app's own binary: main.swift sees the phantom key and runs as a phantom
///       Resources/AppIcon.icns   the remote app's icon with a "remote" badge
///       Resources/RemoteIcon.png the remote icon as received, to rebuild from
///
/// The bundle's file name is the app's name because macOS shows the file name (less ".app") in the
/// Dock tooltip, ⌘Tab, Finder and Activity Monitor. The <appKey> folder keeps two remote apps with the
/// same name apart. (Bundles used to be <host>/<appKey>.app, so the Dock said "dev.zed.Zed";
/// PhantomStore.removeLegacy cleans those up.)
///
/// Signed like the app itself when its identity is in the keychain, else ad-hoc. It's made on this Mac,
/// so it carries no quarantine and Gatekeeper never assesses it. Phantoms need no TCC permissions.
struct PhantomSpec {
    var host: String
    var appKey: String
    var appName: String
    /// The remote app's icon (PNG, ideally 512 px); nil = keep the bundle's, or a generic one.
    var icon: Data?

    var bundleID: String { Brand.phantomBundleIDPrefix + PhantomStore.hash(host + "\n" + appKey, hexChars: 16) }
    /// Phantoms/<host>/<appKey>/, which holds this app's one bundle.
    var folder: URL {
        PhantomPaths.phantoms.appendingPathComponent(PhantomStore.safe(host), isDirectory: true)
            .appendingPathComponent(PhantomStore.safe(appKey), isDirectory: true)
    }
    var url: URL { folder.appendingPathComponent(PhantomStore.fileName(appName) + ".app", isDirectory: true) }
    /// Where the bundle used to be (Phantoms/<host>/<appKey>.app).
    var legacyURL: URL {
        PhantomPaths.phantoms.appendingPathComponent(PhantomStore.safe(host), isDirectory: true)
            .appendingPathComponent(PhantomStore.safe(appKey) + ".app", isDirectory: true)
    }
}

enum PhantomStore {
    /// Bumped when the bundle layout or the badge changes: older phantoms are rebuilt.
    static let format = 3 // 3: bundle IDs moved to com.pier20.Wisp.phantom.*

    static func hash(_ s: String, hexChars: Int) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(hexChars).description
    }
    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(16).description }

    /// A file name from a host name or app key.
    static func safe(_ s: String) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let out = String(s.unicodeScalars.map { ok.contains($0) ? Character($0) : "_" })
        return out.isEmpty || out.hasPrefix(".") ? "_" + out : out
    }

    /// A bundle file name from an app's display name: as readable as possible (spaces and non-ASCII
    /// stay), without path separators, a leading dot or an unreasonable length.
    static func fileName(_ appName: String) -> String {
        var s = appName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 100 { s = String(s.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Remote App" : s
    }

    /// LaunchServices' command-line tool; its -u forgets a bundle (there's no public API for that).
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Unregisters a bundle from LaunchServices, then deletes it, so no stale name or icon lingers
    /// in the Dock, Spotlight or "Open With".
    static func remove(_ bundle: URL) {
        run(lsregister, ["-u", bundle.path])
        do { try FileManager.default.removeItem(at: bundle); Log.debug(.phantom, "removed \(bundle.path)") } catch {
            Log.failed(.phantom, "removing \(bundle.path)", error)
        }
    }

    /// Removes bundles in the old layout (Phantoms/<host>/<appKey>.app) for every host. Cheap; call it
    /// before phantoms are made or started.
    static func removeLegacy() {
        let fm = FileManager.default
        guard let hosts = try? fm.contentsOfDirectory(at: PhantomPaths.phantoms, includingPropertiesForKeys: nil) else { return }
        // Never pull a bundle from under a running phantom (e.g. one of another copy of the app).
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        for host in hosts {
            for item in (try? fm.contentsOfDirectory(at: host, includingPropertiesForKeys: nil)) ?? []
            where item.pathExtension == "app" && !running.contains(item.standardizedFileURL.path) {
                log("removing phantom app in the old layout: \(item.lastPathComponent)")
                remove(item)
            }
        }
    }

    /// Identifies the binary the phantom copies, so a new Wisp build rebuilds its phantoms.
    static var binaryStamp: String {
        guard let exe = Bundle.main.executableURL,
              let a = try? FileManager.default.attributesOfItem(atPath: exe.resolvingSymlinksInPath().path) else { return "?" }
        let size = (a[.size] as? NSNumber)?.intValue ?? 0
        let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(date))"
    }

    /// The WispPhantom dictionary of an existing bundle.
    static func info(at url: URL) -> [String: Any]? {
        guard let d = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
        return d[Brand.phantomInfoKey] as? [String: Any]
    }

    /// The remote icon a bundle was built from.
    static func storedIcon(at url: URL) -> Data? { try? Data(contentsOf: url.appendingPathComponent("Contents/Resources/RemoteIcon.png")) }

    /// Whether the bundle at spec.url is current: same name, icon (when spec has one), binary and format.
    static func isCurrent(_ spec: PhantomSpec) -> Bool {
        guard let i = info(at: spec.url),
              FileManager.default.isExecutableFile(atPath: spec.url.appendingPathComponent("Contents/MacOS/\(Brand.name)").path) else { return false }
        return i["appName"] as? String == spec.appName
            && i["binary"] as? String == binaryStamp
            && i["format"] as? Int == format
            && (spec.icon == nil || i["iconHash"] as? String == hash(spec.icon!))
    }

    /// Builds (or rebuilds) the bundle; slow (copies the binary and signs it), so off the main thread.
    static func make(_ spec: PhantomSpec) throws -> URL {
        let fm = FileManager.default
        let dest = spec.url
        // Other bundles of this app: in the old layout, or under an earlier name of the app.
        let others = [spec.legacyURL] + ((try? fm.contentsOfDirectory(at: spec.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" && $0.lastPathComponent != dest.lastPathComponent }
        let icon = spec.icon ?? ([dest] + others).lazy.compactMap(storedIcon(at:)).first
        try fm.createDirectory(at: spec.folder, withIntermediateDirectories: true)
        let tmp = spec.folder.appendingPathComponent(".\(dest.lastPathComponent).\(getpid()).tmp", isDirectory: true)
        try? fm.removeItem(at: tmp)
        let contents = tmp.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { throw HostError("\(Brand.name)'s own binary wasn't found") }
        // A copy, not a link: the signature covers this bundle's Info.plist.
        try fm.copyItem(at: exe, to: contents.appendingPathComponent("MacOS/\(Brand.name)"))

        let base = icon.flatMap(NSImage.init(data:)) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let badged = phantomIcon(base)
        try writeICNS(badged, to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        if let icon { try icon.write(to: contents.appendingPathComponent("Resources/RemoteIcon.png")) }

        let main = Bundle.main.infoDictionary ?? [:]
        let plist: [String: Any] = [
            "CFBundleName": spec.appName,
            "CFBundleDisplayName": spec.appName,
            "CFBundleIdentifier": spec.bundleID,
            "CFBundleExecutable": Brand.name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": main["CFBundleShortVersionString"] as? String ?? "0.1.0",
            "CFBundleVersion": main["CFBundleVersion"] as? String ?? "1",
            "CFBundleGetInfoString": "\(spec.appName) on \(spec.host), shown by \(Brand.name)",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "NSHumanReadableCopyright": "\(spec.appName) runs on \(spec.host). This is a \(Brand.name) view of it.",
            Brand.phantomInfoKey: [
                "host": spec.host,
                "appKey": spec.appKey,
                "appName": spec.appName,
                "iconHash": icon.map(hash) ?? "",
                "binary": binaryStamp,
                "format": format,
                // To start the app when the phantom is opened from the Dock or Spotlight on its own.
                "wisp": Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : exe.path,
            ] as [String: Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        try sign(tmp, identifier: spec.bundleID)
        // Swap it in whole, so a half-made bundle is never launched.
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
        // Shown as "Safari", not "Safari.app", in Finder and wherever the file's display name is used.
        var hidden = URLResourceValues()
        hidden.hasHiddenExtension = true
        var named = dest
        do { try named.setResourceValues(hidden) } catch { Log.failed(.phantom, "hiding the extension of \(dest.path)", error) }
        // A rebuilt bundle at the same path: make LaunchServices read the new name and icon.
        let ls = LSRegisterURL(dest as CFURL, true)
        if ls != noErr { Log.warning(.phantom, "LSRegisterURL \(dest.path): OSStatus \(ls)") }
        for other in others where fm.fileExists(atPath: other.path) { remove(other) }
        return dest
    }

    // MARK: Signing

    /// Wisp's own signing identity, if this Mac has it (e.g. "Wisp Dev" or a Developer ID); else ad-hoc.
    static let identity: String = {
        let path = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : Bundle.main.executablePath ?? ""
        let (_, details) = run("/usr/bin/codesign", ["-dvv", path])
        guard let authority = details.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") })?.dropFirst("Authority=".count) else { return "-" }
        let (_, ids) = run("/usr/bin/security", ["find-identity", "-p", "codesigning"])
        return ids.contains("\"\(authority)\"") ? String(authority) : "-"
    }()

    private static func sign(_ bundle: URL, identifier: String) throws {
        var args = ["--force", "--sign", identity, "--identifier", identifier, "--options", "runtime"]
        args.append(identity.hasPrefix("Developer ID Application") ? "--timestamp" : "--timestamp=none")
        let (status, out) = run("/usr/bin/codesign", args + [bundle.path])
        Log.debug(.phantom, "codesign \(bundle.lastPathComponent) with \(identity == "-" ? "an ad-hoc signature" : identity): exit \(status)")
        guard status == 0 else { throw HostError("codesign failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { Log.failed(.phantom, "running \(tool)", error); return (-1, error.localizedDescription) }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    // MARK: Icon

    /// The remote app's icon with the remote badge (RemoteBadge.swift) in the bottom-right corner, 40 % of
    /// the icon, so a phantom is never mistaken for a local app.
    static func phantomIcon(_ base: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
            base.draw(in: r)
            let d = r.width * 0.40
            drawRemoteBadge(in: NSRect(x: r.maxX - d - r.width * 0.035, y: r.minY + r.width * 0.035, width: d, height: d))
            return true
        }
    }

    /// Writes `image` as an .icns with the usual sizes, 16 to 512 px.
    static func writeICNS(_ image: NSImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 6, nil) else {
            throw HostError("can't write an icns")
        }
        for px in [16, 32, 64, 128, 256, 512] {
            guard let cg = bitmap(image, px: px) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw HostError("can't write \(url.lastPathComponent)") }
    }

    static func bitmap(_ image: NSImage, px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The badged icon as PNG (for a running phantom's Dock tile).
    static func phantomIconPNG(_ base: Data?) -> Data? {
        let img = phantomIcon(base.flatMap(NSImage.init(data:)) ?? NSWorkspace.shared.icon(for: .applicationBundle))
        guard let cg = bitmap(img, px: 512) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
