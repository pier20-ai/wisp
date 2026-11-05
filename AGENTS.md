# AGENTS.md: working on Wisp

For people, and their coding agents, adapting this code. (CLAUDE.md points here; this file is
the one to edit.) What the product does and how to use it: [README.md](README.md). The design
record, with the reasoning and measurements behind every stage:
[docs/multi-window.md](docs/multi-window.md). Test tools: [docs/testing.md](docs/testing.md).
Building, signing, the CLI, releasing, renaming: [docs/development.md](docs/development.md). For
users: [docs/troubleshooting.md](docs/troubleshooting.md).

## Architecture map

One SwiftPM package, macOS 14+, no dependencies. **One binary** is the app, the CLI and every
phantom app: `main.swift` dispatches on the arguments, and on the `WispPhantom` key
(`Brand.phantomInfoKey`) in a phantom bundle's Info.plist.

| target | what |
|---|---|
| `WispCommon` | Shared by host and viewer: the wire protocol, menu-tree encoding, logging, branding. |
| `Tailnet` | Tailscale's LocalAPI (`Tailnet.peers()`, `Tailnet.whois(ip)`), with the `tailscale` CLI as a fallback. Foundation only. |
| `CGVirtualDisplayPrivate` | Header-only declarations of Apple's private `CGVirtualDisplay` classes (see THIRD-PARTY-NOTICES.md). |
| `wisp` (executable) | Everything else: the app, CLI, host, viewer and phantom apps. Built as `wisp`; `scripts/bundle-app.sh` puts it in `Wisp.app` as `Contents/MacOS/Wisp`. |
| `WispProbe` (executable) | The end-to-end test's host-side app (`Sources/WispProbe/main.swift`): windows of numbered rows under a frame counter, recording every event they receive. `scripts/bundle-probe.sh` makes `WispProbe.app` (ad-hoc, no permissions). Never part of Wisp.app. |

**`Sources/WispCommon/`**
- `Log.swift`: `Log` (levels, categories, the per-process file, the unified log, `Log.hook` for the host window's log view), `LogFile` (rotating files shared by processes).
- `Brand.swift`: names and identifiers: display name, CLI name, bundle ID, copyright; derived phantom bundle-ID prefix, defaults domain (`Brand.defaults`), log and Application Support directories.
- `Protocol.swift`: **the wire protocol** (ports, datagram formats, `MsgType` with every control message and its payload, `WindowInfo`, `WindowChrome`, `WindowEntry`, `ViewerStats`, `FrameTag`, message framing and parsing), plus `Samples`, `Counter`.
- `Menus.swift`: `MenuTree` / `MenuPress`, the encoding of a mirrored menu bar.
- `InputProbe.swift`: the end-to-end test's shared parts: `FrameCode` (a frame counter drawn as squares and read back from decoded frames), `InputRecord` / `InputLog` (what a test window received, as JSON lines).

**`Sources/wisp/`**
- `main.swift`: dispatch: phantom, `send`, `view`, `poke`, `vdisplay-test`, `tailnet`, `diagnostics`, or the app; picks the log file.
- `NetLog.swift`: log descriptions of Network.framework states, errors and paths, and of an address to connect to.
- `Stall.swift`: `StallEpisode` (one STALL story per stall: start, recovery steps, end), `MainThreadWatch`, `Fault` (`WISP_FAULT` fault injection).
- `Clipboard.swift`: `ClipboardSync`, clipboard sync both ways over the control connection (one per connection: in `Host` and in `Client`; phantoms share the viewer's pasteboard). What is sent, the privacy rules and the echo guard are in its header and docs/multi-window.md §13.
- `E2E.swift`: `wisp e2e`, the end-to-end input and freshness test's viewer side (`E2ERunner`; docs/testing.md).
- `CLI.swift`: usage text and `wisp send`. `ViewCLI.swift`: `wisp view` (incl. `--snapshot`, `--windows`, `--menus`), `wisp poke`, `wisp vdisplay-test`. `TailnetCLI.swift`: `wisp tailnet [peers | whois <ip> | probe <host>]`.

**`Sources/Tailnet/Tailnet.swift`**: how Wisp reaches Tailscale. In Tailscale's own order
(`safesocket_darwin.go`): the App Store app's `IPNExtension` (port and token in the name of its open
`…/io.tailscale.ipn.macos/sameuserproof-<port>-<token>` file, via `lsof`), the standalone app
(`/Library/Tailscale/ipnport` → port, `/Library/Tailscale/sameuserproof-<port>` → token), then
tailscaled's Unix socket; HTTP basic auth with an empty user and the token. Else `tailscale status
--json` / `whois --json`. Blocking: call it off the main thread. `WISP_TAILSCALE=cli` forces the CLI.

**`App/`** (the app: a menu bar item; a Dock icon only while one of its windows is open)
- `App.swift`: `AppDelegate` (the viewer session, the host controller, Settings, the welcome popover, activation policy, debug hooks), `Prefs` (settings keys), the main menu.
- `StatusMenu.swift`: the menu bar item and its NSMenu (header row with an NSSwitch, the host's windows, the tailnet's Macs, share/settings/quit), the template glyph drawn from the Trail icon.
- `Updates.swift`: Sparkle updates for release builds, loaded at run time (Check for Updates…, the automatic-checks setting).
- `Discovery.swift`: `TailnetDiscovery`: the tailnet's Macs (Tailnet.peers) and a probe of each online one.
- `HostWindow.swift`: `HostController` (owns the `Host` while sharing, the window picker, the once-a-second refresh), `HostModel`, the SwiftUI views (NavigationSplitView: Sharing, Allowed Viewers, Permissions, Log), `AccessSettings`, `LogStore`.
- `SettingsWindow.swift`: Settings (toolbar tabs of grouped Forms; SMAppService for "Share this Mac at login") and the welcome popover. `Permissions.swift`: permission state without prompting, System Settings deep links, the screen-lock check.
- `Diagnostics.swift`: the Copy Diagnostics / `wisp diagnostics` report (other people's logins hashed).
- `Migration.swift`: `LegacyMigration`, run once at launch: copies the settings of the app's previous bundle ID and removes its old phantom apps.

**`Host/`** (the Mac being controlled)
- `Host.swift`: `Host` owns everything on the host: the `Server`, one `HostStream` (capture → encoder → send pipeline) per streamed window, window lists and icons, resizing, following new windows of the apps the viewer shows and reopening apps (`reopenApp`), the synthetic test host, virtual-display placement and teardown, screen-lock and session checks. Main queue.
- `Server.swift`: `HostOptions` (flags and defaults), `Server` (TCP 7878 / UDP 7879 listeners, access check of every connection, one viewer at a time, probes, per-stream framing, FEC, resend cache, pacing), `LegacyNotice` (protocol-1 viewers), `Pipeline` (incl. thumbnails for the host window), the stats CSV.
- `Access.swift`: `AccessPolicy` (allow-list of tailnet logins, allow LAN), `PeerIdentity`, `AccessControl` (loopback always; Tailscale addresses identified with whois; others refused unless allowLAN).
- `Capture.swift`: `WindowCapture` (ScreenCaptureKit, one window) and `SyntheticSource` (test patterns).
- `Encoder.swift`: VideoToolbox HEVC/H.264 in low-latency mode, with per-frame in-flight tracking (lost callbacks, broken sessions); also the older global `log()` (maps to `Log.info` by file).
- `Health.swift`: `HostHealth`: once a second per pipeline, on its own queue: frames captured but none sent, input with no capture, the 5 s health and send-path lines.
- `Injector.swift`: replays the viewer's mouse, scrolls and keys with CGEvent (a wheel as line scrolls, gestures with their phases, at the pointer each scroll message names; scrolls never raise a window for focus); raises, moves, resizes and closes windows through Accessibility. In the synthetic host it builds the same events for a `sink` (`WISP_INPUT_LOG`) instead of posting them.
- `Panels.swift`: `PanelTracker`: a streamed app's Open/Save panels (drawn out of process by the panel service), dialogs and new floating panels: found every 0.25 s, associated with one of its streams, moved over that window like a sheet, its service processes added to the capture filter, treated by the injector as part of the window. Never a stream of their own. `responsiblePID(of:)`, `PanelPlacement`.
- `Menus.swift`: `MenuReader` reads and presses a shared app's menu bar through Accessibility; `SyntheticMenus` for the test host.
- `VirtualDisplay.swift`: one HiDPI `CGVirtualDisplay` per streamed window; `DisplayGate`. **Read its header before touching it** (see Safety rules).

**`Viewer/`** (the Mac you sit at)
- `Client.swift`: one connection to a host: TCP + UDP, reassembly, NACK/FEC repair, `RemoteStream` per window.
- `ViewerController.swift`: `ViewerSession` (connection, menu bar list, in-process or phantom mode) and `ViewerController` (one window per stream, decoding).
- `ViewerWindow.swift`: `RemoteView` (shows frames, sends input, the remote title bar; the cover over the remote traffic lights and the screen-sharing badge; the window's own traffic lights are AppKit's, at AppKit's place) and `StatusPill`.
- `WindowsMenu.swift`: the menu bar list of the host's windows for `wisp view` (the app has its own, `App/StatusMenu.swift`). `Latency.swift`: latency measurement. `StreamLink.swift`: what a window needs from whatever carries its stream (the client in-process, or the relay in a phantom). `Probe.swift`: asks a Mac whether it's sharing (`probe` message) without becoming its viewer. `DisplayWatch.swift`: decoded frames that don't reach the screen. `NetEmu.swift`: `WISP_NET_*`, a far-away host emulated over loopback.

**`Phantom/`** (one generated app per remote app, on the viewer)
- `PhantomHub.swift`: the main process's side: makes and launches phantoms, routes streams to them, relays frames.
- `PhantomBundle.swift`: `PhantomSpec` / `PhantomStore`: bundle layout (`Phantoms/<host>/<appKey>/<App Name>.app`), building, signing, migration, icons.
- `PhantomApp.swift`: the phantom process: its windows, Dock menu, app and Window menus, decoding.
- `PhantomMenus.swift`: the mirrored remote menu bar. `IPC.swift`: the Unix-socket protocol between the main process and phantoms. `RemoteBadge.swift`: the "remote" badge on phantom icons.

## The wire protocol

Defined in `Sources/WispCommon/Protocol.swift` (header comment, `Wire`, `MsgType`), designed in
docs/multi-window.md §2, with stage additions in §9.3 and §10.1. In short:

- **TCP 7878**: control and input. Each message `[u16 length][u8 type][payload]`. The viewer sends
  `hello`, the host answers `helloAck`. Messages about one window start with its u16 stream ID.
  Types below 100 go viewer → host, 100 and up host → viewer.
- **UDP 7879**: video only. Datagrams ≤ 1100 B (under Tailscale's MTU), per stream, with XOR
  parity (FEC); lost packets are re-requested over TCP (`nack`), or a keyframe of that stream.
  The viewer's UDP hello (kind 1, every second) opens and keeps the path; the host answers each one
  with `helloEcho` (kind 5), which lets the viewer tell a dead video path from idle windows. The host
  sends video to the flow of the newest hello (a viewer that makes a new UDP flow is followed).
- Before anything else the host checks who connected (`Host/Access.swift`): a refused connection
  gets `refused` (a reason) and is closed. A first message of `probe` gets `probeAck` (host name,
  open/max streams) and is closed, without disturbing the viewer.
- Protocol **version 2** (`Wire.protocolVersion`). Both sides must match; a mismatch is reported, not
  served. New messages in v2 are additive: an older peer ignores what it doesn't know. Bump the
  version only for incompatible changes, and update §2 of the design record. Optional behaviour a
  viewer opts into goes in hello's `features` bits (`Wire.Feature`, e.g. `followsNewWindows`); the
  host announces its own in helloAck's (`Server.hostFeatures`, e.g. `clipboard`).
- Input (types 1–6) is per stream. `scroll` carries NSEvent phase and momentum raw values, then
  (additive) a flags byte (bit 0: deltas in 1/16 lines, from a wheel) and the pointer position; the
  host posts line scrolls for a wheel and scrolls where the message says (§16).
- Clipboard sync (§13): `clipboardBegin/Chunk/State` 30–32 viewer → host, 130–132 host → viewer,
  only between peers that both announced `Wire.Feature.clipboard`. Tests use a private pasteboard
  (`WISP_PASTEBOARD`); **never write the real general pasteboard from a test**.
- **Local IPC** to phantoms: `Sources/wisp/Phantom/IPC.swift` (`[u32 length][u8 type][payload]`
  on a Unix socket).

## Build and test

```bash
swift build -c release                        # .build/release/wisp
scripts/bundle-app.sh                         # dist/Wisp.app, universal, signed ad-hoc
scripts/bundle-app.sh --identity "Wisp Dev"  # after scripts/make-dev-cert.sh: grants survive rebuilds
scripts/host-build.command                    # on a host: best available identity, in the GUI session
```

The app icon (`scripts/assets/AppIcon.icns`, committed) comes from `swift scripts/make-icon.swift`: the
painted art in `scripts/assets/icon-art.png` from 64 px up, code-drawn 16 and 32 px. New art (a 1024 px
render on any rounded tile) is fitted to Apple's grid with `python3 scripts/prepare-icon-art.py`.

There are no unit tests; the loopback test is the regression test. Run it after every change:

```bash
.build/release/wisp send --synthetic 1600x1000                              # terminal 1
.build/release/wisp view 127.0.0.1 --snapshot out.png --open 2,3            # terminal 2: 3 frames + stats
```

Expect ~60 fps per stream, `0 re-requested`, and three PNGs. **For anything touching input (the
viewer's RemoteView, the wire's input messages, the Injector) or the picture's freshness, also run
`scripts/e2e.sh`** (~1 min, loopback, no permissions; `--net uk` emulates the 150 ms link, `--soak N`
runs N minutes of random input; a long soak only on a Mac nobody uses: `scripts/soak.command`): it drives the real viewer with trackpad, Magic Mouse, wheel, click
and key events and checks what the host's windows received, event by event. It puts its windows on
screen and comes to the front. Against a real host it uses WispProbe.app there (docs/testing.md
"End-to-end input and freshness"); don't run that against someone else's Mac. Clipboard sync: `swift scripts/clipboard-test.swift`
(private pasteboards on both ends; all PASS). Then `wisp tailnet` (peers via the
LocalAPI) and `wisp tailnet probe 127.0.0.1` with the host running (`Sharing`). The app's UI can't be
clicked in a test: launch the bundled app with `WISP_MENU_DUMP=<file>` (the menu tree, and
`<file>.windows`: its windows and views) and `WISP_OPEN=host,settings,welcome` (docs/testing.md).
More tools in docs/testing.md:
`wisp poke <host> click|key|resize|action close|new-window|open-panel`, `wisp view <host> --windows | --menus <appKey>`,
`wisp vdisplay-test 1512x982 5 --count 3` (makes real displays: see Safety rules),
`swift scripts/hevc-sessions.swift`.

Debug environment variables (all read at start-up; phantoms inherit `WISP_*`):
`WISP_SECONDS`, `WISP_DROP`, `WISP_DROP_WINDOW`, `WISP_NET_DELAY_MS`, `WISP_NET_JITTER_MS`, `WISP_NET_LOSS`, `WISP_INPUT_LOG`, `WISP_TEST_OPEN`, `WISP_TEST_CLOSE`,
`WISP_TEST_RESIZE`, `WISP_PHANTOMS`, `WISP_PHANTOM_TEST_INPUT`, `WISP_PHANTOM_TEST_MENU`,
`WISP_SOCKET`, `WISP_SUPPORT_DIR`, `WISP_LOG_DIR`, `WISP_MENU_DUMP`, `WISP_OPEN`, `WISP_NO_PROBE`,
`WISP_TEST_STOP`, `WISP_TAILSCALE`, `WISP_VERBOSE`, `WISP_NO_ALERTS`, `WISP_PASTEBOARD`, `WISP_CLIPBOARD_MAX`, `WISP_FAULT`. Build scripts: `BRAND_SIGN_IDENTITY`,
`BRAND_NOTARY_PROFILE`, `HOST_BUILD_PULL`. Each is described in docs/testing.md and
scripts/brand.env.

To test phantom apps on a Mac where Wisp is in use, set `WISP_SUPPORT_DIR`, `WISP_LOG_DIR` and
`WISP_SOCKET` (docs/testing.md), or your test will relaunch, rebuild or migrate the real phantoms.

Logs: `~/Library/Logs/Wisp/`: `wisp.log` (the app, viewer and host), `phantom-<App>.log`, `cli.log`,
`latency.log`, `stats.csv`; rotated at 5 MB, mirrored to the unified log (subsystem = the bundle
ID). Log with `Log.info(.category, "…")` (WispCommon/Log.swift): info for lifecycle, debug for
per-event detail (`WISP_VERBOSE=1`), nothing per frame at info, never key codes; a `try?` that hides
a useful failure should log it. `wisp diagnostics` / Copy Diagnostics: docs/testing.md "Logs".

Stalls ("the window stopped updating"): every place a stream can get stuck is watched and logged as
one `STALL <what>` episode (start with the evidence, each recovery step, end with how long and what
fixed it): `StallEpisode` and `MainThreadWatch` in `Stall.swift`, the host's checks in
`Host/Health.swift` and `Pipeline.encode`, the viewer's in `RemoteStream.checkStall` /
`Client.checkVideoPath` and `Viewer/DisplayWatch.swift`. A new way to get stuck gets an episode
too, and a `WISP_FAULT` to prove it. Table and fault recipes: docs/testing.md "Stalls".

## Safety rules (learned the hard way)

WindowServer is **shared by every logged-in user** on a Mac. Hang it and every session on that Mac
goes down, not just yours. An earlier version did exactly that.

- **Never block the main thread on WindowServer calls while a virtual display is being added or
  removed.** Adding a display makes WindowServer wait for every client to acknowledge; a main thread
  stuck in `CGWindowListCopyWindowInfo` (or any CG/AX call) never does. Gate main-thread
  WindowServer and Accessibility calls on `DisplayGate`.
- **`CGVirtualDisplay` callbacks never on the main queue.** Use the private serial
  `callbackQueue`.
- **Create and destroy displays one at a time**, on the serial `lifecycleQueue`, never on the main
  thread, and keep the watchdog. Never force-kill anything.
- **Test virtual displays only on a Mac nobody is working on**: windows jump between displays and
  a mistake can take WindowServer down for everyone.
- **Don't probe or connect to other people's Macs from tests.** The app's menu probes every online
  Mac on the tailnet while it's open; tests set `WISP_NO_PROBE=1` and use loopback.
- Don't run a second host on the same Mac: the ports are exclusive by design, and the second one
  exits.
- The private API can change in any macOS update. Check `VirtualDisplay.isAvailable` and keep the
  fallback (share windows where they are) working.

## Signing and TCC (permissions)

- TCC keys Screen Recording and Accessibility grants to the code signature. **An ad-hoc signature
  (the default) changes on every build, so every rebuild loses the grants.** Use the self-signed
  identity from `scripts/make-dev-cert.sh`, or a Developer ID, for a host you rebuild.
- **Launching the app over SSH with an ad-hoc signature fails the Screen Recording check.** Launch
  it in the GUI session (`open`), or use a stable identity. The login keychain (with the signing
  key) is also locked to SSH sessions, which is why `scripts/host-build.command` is meant to be
  double-clicked or `open`ed.
- Changing the bundle ID is a new app to TCC: grants, defaults and phantoms start over.
- Phantoms are signed with the app's own identity if the keychain has it, else ad-hoc. They need no
  TCC permissions; they're made locally, so Gatekeeper never assesses them.
- Notarization needs a Developer ID and a notarytool keychain profile, both passed in
  (`--identity`, `--notary-profile`, or `BRAND_*` env); nothing is hard-coded.
- **Releases are built with Xcode 27**, locally with `scripts/release.sh --draft` (Developer ID
  signing, notarization, the Sparkle appcast, a draft release) until GitHub's runners have Xcode 27;
  `.github/workflows/release.yml` does the same and is manual until then. Its secrets come from
  `scripts/setup-release-secrets.sh`; never add a key, password or identity to the tree.
- **Code must still compile with Swift 6.3 (Xcode 26)**: the CI runners have it, and they will build
  releases again later.
- **Updates (Sparkle)** are embedded only in Developer ID builds with `BRAND_SPARKLE_PUBLIC_KEY` set,
  and loaded at run time (`App/Updates.swift`), never linked: the same binary runs as the CLI and in
  phantom apps, which have no Frameworks folder. A change that links Sparkle breaks phantoms.

## Renaming

Change `Sources/WispCommon/Brand.swift` and `scripts/brand.env` together (bundle-app.sh checks they
agree). Everything else derives from them: the app and DMG names, Info.plist, the defaults domain,
log and support directories, phantom bundle IDs. User-facing strings use `Brand.name`; code
comments and docs say "Wisp" and need a search-and-replace. Optional: the SwiftPM target and
directory (`wisp`, `Sources/wisp`), the `WispCommon` module, the `WISP_*` variables and the
`wisp.*` dispatch-queue labels. The bundle ID is `com.pier20.Wisp`: a fork should use a
domain it controls. Changing the bundle ID resets macOS permissions; `App/Migration.swift`
(`LegacyMigration`) shows how the last rename carried settings over and removed the old phantoms.
Details: "Renaming" in docs/development.md.

## Conventions

- Commits: Conventional Commits with a scope, imperative and specific:
  `feat(viewer): …`, `fix(host): …`, `perf(host): …`, `docs: …`, `build: …`, `chore: …`. The body
  says why, and what was measured or tested.
- **docs/multi-window.md is the design record.** When you build or change a stage, add or update
  its "what was built" section: what it does, why this way, the numbers, what still needs a real
  host. Don't delete history from it; mark what changed.
- Every source file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` (after the shebang
  or `swift-tools-version` line).
- Threading is part of the design: each type's doc comment says which queue it lives on (most host
  and viewer state is main-queue only; network on its own queues). Keep it that way.
- No secrets, signing identities, host names or personal paths in the tree. Per-machine settings go
  in `scripts/brand.local.env` (not tracked) or the environment.
