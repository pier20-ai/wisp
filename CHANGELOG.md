# Changelog

## 1.0.4 — 2026-11-05

- Wisp updates itself: it checks this repository's latest release once a day (Check for Updates… in
  its menu checks now; Settings › Troubleshooting turns the daily check off). Updates are verified
  with an EdDSA signature as well as Apple's notarization.
- Fixed: closing a remote window with its red button (or Close Window on <host>) could crash the
  phantom app.
- Fixed: the Settings window was titled "Untitled".
- Releases are now built, signed and notarized by GitHub Actions.

## 1.0.3 — 2026-11-05

- A new app icon: the painted "Trail" art, fitted to Apple's icon grid, from 64 px up (16 and 32 px
  stay drawn on the pixel grid so they read in lists and menus).

## 1.0.2 — 2026-11-05

- The bundle ID is now `com.pier20.Wisp` (was `app.wisp.Wisp`). Settings carry over on first launch;
  macOS treats it as a new app, so Screen Recording and Accessibility must be granted once more, and
  phantom apps are rebuilt (re-pin any you had in the Dock).

## 1.0.1 — 2026-11-05

Scrolling and input fixes found by a new end-to-end test (an 8-hour soak over an emulated UK link:
16,448 scroll gestures and 61,257 clicks and keys with no input errors).

- Scrolling a window that isn't the focused one now scrolls the spot under the pointer (it used to go
  wherever the host's pointer last was: the wrong pane, or nothing).
- Wheel mice scroll by lines again, as they do locally, instead of arriving as trackpad pixels.
- Scrolling never brings a window forward: each wheel tick used to be able to raise the window and
  pause input for 60 ms, which made wheel scrolling stutter.
- Very fast flicks no longer end the gesture several times over.
- The host Mac's own modifier keys no longer leak into injected scrolls and clicks; ⌘-click from the
  viewer arrives as one.
- A gesture left open when a window closes is ended; a focus raise that never completes no longer
  holds input forever.
- New: WispProbe and `wisp e2e`, an end-to-end input and freshness test, and `scripts/soak.command`.

## 1.0.0 — 2026-11-04

The first public release.

Wisp streams individual windows from one Mac to another over Tailscale, so that remote apps behave
like apps on your own Mac: their own Dock icon and ⌘Tab entry, their menu bar, native window
controls, and full mouse and keyboard control.

**Remote apps as local apps**
- Each remote app becomes a "phantom" app on the viewer: the real app icon with a remote badge,
  its own Dock icon, ⌘Tab entry, Window menu and Dock menu listing its windows.
- The remote app's menu bar is mirrored, with live enabled/checked state; choosing an item presses
  it on the host. Keyboard shortcuts go to the remote app.
- Native traffic lights, drawn at the remote window's button size. Red closes the window on the host
  (⌥-red stops viewing it here); yellow and green act on the local window.
- Windows resize both ways: resize locally and the remote window follows, and the other way round.
- New windows follow: ⌘N, a menu item or a Dock click on the host opens them here automatically.
  Clicking a phantom's Dock icon with no windows asks the remote app to open one.
- Up to 3 windows at once (the hardware encoder limit on an M4 Mac mini).

**Picture and latency**
- Hardware HEVC, low-latency mode; UDP video with forward error correction and selective resends;
  adaptive bitrate; typically 15–20 ms from the host's screen to yours on a fast link.
- A HiDPI (2×) virtual display per shared window on the host, sized to the viewer's screen, so text is
  sharp even on a headless Mac. Removed 30 s after the last viewer leaves.
- Per-stage latency statistics in `~/Library/Logs/Wisp/`.

**Tailscale**
- The menu bar app lists the Macs on your tailnet and which of them are sharing.
- The host sees who connected by their Tailscale identity, and can restrict access to an allow-list of
  tailnet users. Connections from outside Tailscale are refused by default.

**Also**
- A command-line tool (`Wisp.app/Contents/MacOS/Wisp`, or `wisp` from a source build) with test
  and debugging commands: a synthetic host, headless snapshots, input injection, Tailscale probes.
- GPL-3.0-or-later. Provided as-is.

**Known limits**
- The host must be unlocked and its user session on screen; input stops while it is locked.
- Uses a private macOS API (`CGVirtualDisplay`) that a macOS update could break.
- One host account at a time per Mac; one viewer per host.
