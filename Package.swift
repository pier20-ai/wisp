// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "wisp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WispCommon"),
        // Tailscale's LocalAPI (peers, whois), with the tailscale CLI as a fallback. No dependencies.
        .target(name: "Tailnet"),
        // Header-only interface to Apple's private CGVirtualDisplay classes (they live in CoreGraphics).
        .target(name: "CGVirtualDisplayPrivate", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "wisp", dependencies: ["WispCommon", "Tailnet", "CGVirtualDisplayPrivate"]),
        // The end-to-end test's host-side app (scripts/bundle-probe.sh makes WispProbe.app; docs/testing.md).
        .executableTarget(name: "WispProbe", dependencies: ["WispCommon"]),
    ]
)
