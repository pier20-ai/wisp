# Multi-window Wisp: remote windows that behave like local apps

The product was called WCast until November 2026; the history below uses its current name, Wisp.

Status: stages 1–3 built (stage 2: §8, stage 3: §9, November 2026), and stage 4's mirrored menu bar (§10); the rest of stage 4 is design. The app around it (menu bar item, tailnet discovery and identity, host window) is §11. Native window controls, Dock reopen and new windows that follow are §12. October–November 2026.

Before stage 2, Wisp shared **one** window from the host to the viewer, in one Wisp window; it now streams several, each remote app in a phantom app of its own on the viewer. The goal is for remote windows to feel like local apps:

- a menu bar list of the host's windows, shown under their app icons; pick one and it opens locally;
- one "phantom" app per remote app in the local Dock and Cmd-Tab, with the remote app's icon plus a mark that says it's remote, owning that app's windows like any other app.

The plan has four stages. Each one ships on its own.

| stage | what the user gets | protocol | status |
|---|---|---|---|
| 1 | Menu bar list of host windows with app icons. Picking one switches the single stream. | v1 + 4 new message types (backward compatible) | **built** (§7) |
| 2 | Several remote windows open at once, each in its own local window (all owned by Wisp). | v2: stream IDs | **built** (§8) |
| 3 | Phantom apps: per-remote-app Dock/Cmd-Tab presence, Dock menu, badged icon. | v2 + local relay socket | **built** (§9) |
| 4 | Child windows (menus, popovers) as real local windows, mirrored menu bar, clipboard, cursor shapes. | v2 additions | menu bar **built** (§10), clipboard **built** (§13); the rest sketched below |

---

## 1. Prior art and what to take from it

**RDP RemoteApp (RAIL, [MS-RDPERP]).** The server runs the app and the client creates one local window per server window. Window metadata travels as "Windowing Alternate Secondary Drawing Orders": new/existing window (window ID, *owner* window ID, style, title, window and client rects, visible region), delete window, window icon and *cached icon* (an icon is sent once into a client-side cache and referenced by index afterwards), and notification-area icons. Client → server PDUs cover activate, system command (minimize/maximize/close), local move/size (the drag happens locally and the server is told at the end) and exec (launch an app). Since RDP 8 the pixels come over the graphics pipeline ([MS-RDPEGFX]): the server creates *surfaces* and `RDPGFX_MAP_SURFACE_TO_WINDOW_PDU` binds a surface to a RAIL window. In other words, one encoded surface per window, multiplexed on one channel, which is exactly a stream ID. A separate "Get Application ID" PDU tells the client which app a window belongs to, so the client's taskbar groups by app rather than by the client process.
*Lessons:* keep window metadata on a reliable channel separate from pixels. Send icons once and cache them. Group windows into apps with an explicit app ID. Owned windows (menus, tooltips, dialogs) carry an owner ID and become separate local windows placed relative to their owner. The classic bugs are z-order and activation fights, so make one side authoritative: the viewer owns local z-order, and the host only follows focus.

**Parallels Desktop Coherence** (and VMware Fusion Unity). These hide the guest desktop and give every guest window its own Mac window. Parallels generates a small `.app` bundle per guest application (under `~/Applications (Parallels)/`), so guest apps launch from the Dock, Launchpad and Spotlight and get their own Dock icon while running.
*Lessons:* per-app shim bundles work in practice and users accept them. The rough edges come from shadows, z-order flicker, multi-monitor DPI, and the menu bar, which the guest app doesn't really drive. That's tolerable for Windows apps, whose menus live inside the window. For Mac → Mac it matters more: a Mac app's menus live in the menu bar, which ScreenCaptureKit doesn't capture as part of the app (§6).

**X11 forwarding (`ssh -X`).** It's per-window by construction, because the X server runs on the viewer and the app speaks the X protocol to it. It is unusable at our 150 ms RTT because toolkits make many synchronous round trips (property reads, `XSync`, font and extension queries), and modern toolkits push uncompressed bitmaps anyway.
*Lesson:* nothing on the input → pixels path may wait for a round trip. Per-stream repair must stay asynchronous, as our NACK/FEC already is.

**xpra** ("screen for X11") is the closest prior art. It runs apps on a server-side virtual display and forwards each window as its own stream. It picks the encoding per window (video for animated windows, lossless for text), sends window metadata (title, class, icon, `transient-for`, modal), and forwards override-redirect windows (menus, tooltips) as separate positioned windows. It also handles tray, clipboard, cursor shapes and audio, and throttles each window adaptively by focus and network conditions.
*Lessons:* use per-window frame-rate and quality policy keyed on focus, and treat transient windows as children positioned relative to their parent. Clipboard and cursor are each separate small channels.

**Chrome installed web apps on macOS (app shims).** Each PWA gets a small app bundle in `~/Applications/Chrome Apps.localized/`, with its own bundle ID (`com.google.Chrome.app.<id>`) and icon, ad-hoc code-signed on the user's machine. When launched, the shim connects to the main Chrome process over Mojo/Mach. Through Chrome's *RemoteCocoa* layer, the `NSWindow`s live in the shim process while the browser process renders the content. That split exists because macOS ties Dock and Cmd-Tab identity, App Exposé grouping and the menu bar to the process that owns the windows.
*Lesson:* a phantom must **own its windows**. Networking can stay in the main app. This is the pattern §5 recommends.

---

## 2. Protocol v2: many windows

### 2.1 Concepts

- **Window**: a host window, identified by its `CGWindowID` (u32), as today in `wisp send --list`.
- **App key**: the window owner's bundle ID, or `pid:<n>` for an app without one. It groups windows into apps and keys icons. (Stage 1 already uses this.)
- **Stream**: one shared window, meaning one capture, one encoder and one frame sequence. The host assigns a **u16 stream ID**, never reused within a session. 0 means "none". The viewer opens and closes streams. The host also opens child streams on its own (§2.7).

### 2.2 Version negotiation

v2 keeps the TCP framing (`[u16 length][u8 type][payload]`), so negotiation is ordinary messages:

1. A v2 viewer sends `hello` as its first TCP message.
2. A v2 host doesn't send anything on a new connection until it sees `hello`, or until 500 ms pass.
   - `hello` with version ≥ 2 → reply `helloAck`, then the v2 conversation.
   - Anything else first, or nothing within 500 ms → **v1 viewer**. A v1 viewer understands only `windowInfo` and v1 video, so the host sends `windowInfo` titled *"Wisp on my-mac-mini is newer (protocol 2): update Wisp on this Mac"* at 640×160 pt, plus one v1-format keyframe that renders the same sentence (the synthetic-source text path already draws text into a pixel buffer). The v1 viewer shows the error in its title bar *and* its window, with no v1 code change. Then the host goes quiet and closes the connection after 30 s. The host does not serve v1 video beyond this. Both Macs update from the same DMG, and a legacy mode would double the test matrix.
3. A v2 viewer talking to a **v1 host**: the v1 `MessageParser` drops the unknown `hello` and sends `windowInfo` straight away. When `windowInfo` arrives before `helloAck`, the viewer falls back to v1 single-window mode (the current client path, kept as is). The stage-1 menu then says the host is too old to list windows.
4. UDP: the viewer's datagram `hello` (kind 1) gains a `u32 session` (from `helloAck`), so the host binds the UDP flow to the right TCP session. v1 hosts check only the first byte, so the longer hello is harmless.

```
hello      13  viewer→host  u16 version(=2), u32 features, str viewerName
helloAck  104  host→viewer  u16 version, u32 features (intersection), u32 session, str hostID (stable UUID), str hostName
features: bit0 multiWindow, bit1 phantomIcons, bit2 clipboard, bit3 cursor, bit4 menuMirror
str = u16 byte length + UTF-8 (Writer.str / Reader.str, added in stage 1)
```

### 2.3 Video datagrams

New datagram kinds, so a v1 viewer's `guard kind == video` ignores them:

```
video2   kind 3: [u8 3][u16 stream][u32 frameNo][u16 chunkIndex][u16 chunkCount][bytes ≤ 1100]
parity2  kind 4: [u8 4][u16 stream][u32 frameNo][u16 group][u16 chunkCount][u8 groupSize][u32 frameLen][xor ≤ 1100]
```

`frameNo` is **per stream**. The header grows from 9 to 11 bytes, which still leaves 1100 B payloads under Tailscale's 1280-byte MTU.

### 2.4 FrameTag v2

```
FrameTag v2 (15 B): [u16 stream][u64 encodedAt µs][u32 inputsApplied][u8 flags: bit0 refinement]
```

There are two reasons to repeat the stream ID inside the frame:
- **Latency matching.** `inputsApplied` becomes a per-stream count of input messages injected *for that stream*. Today one counter is matched against every frame. With two windows, a click in A would be "answered" by B's next animation frame, and click→screen would read short. Per-stream counters fix that.
- **Self-describing frames.** Once reassembled, a frame can be handed on without its datagram header: to a per-stream decoder, or over the local socket to a phantom app (§5.4).

### 2.5 Control messages

Viewer → host:

```
openStream        14  u32 windowID, u8 flags (bit0 focused)          → host replies streamInfo or streamClosed(reason)
closeStream       15  u16 stream
focusStream       16  u16 stream        local window became key: host raises/focuses it (§3), reallocates bitrate (§2.6)
keyframeRequest2  17  u16 stream
nack2             18  u16 stream, u32 frameNo, u16 n, n × u16 chunk  (n = 0xFFFF: whole frame)
resizeStream      19  u16 stream, u16 pointW, u16 pointH            user resized the local window → host sets AX size
iconRequest       21  str appKey, u16 px                             answered by appIcon2
blobChunk         23  (same layout as host→viewer blobChunk)        clipboard, later (built differently: §13)
input (1…6)           v1 payload with a u16 stream prepended         only on a v2-negotiated connection
windowListRequest 11  (stage 1, unchanged)
```

Host → viewer:

```
windowList2       105  u16 count, count × WindowEntry2
windowAdded       106  WindowEntry2
windowRemoved     107  u32 windowID                     if it was streamed, a streamClosed(reason 1) follows
windowChanged     108  u32 windowID, u8 mask, [str title if bit0], [i16 x, i16 y, u16 w, u16 h if bit1]
windowFocused     109  u32 windowID                     host's key window changed by itself (e.g. a dialog opened)
streamInfo        110  u16 stream, u32 windowID, u16 pointW, u16 pointH, u16 pixelW, u16 pixelH
                       sent on open and on every resize; replaces v1 windowInfo per stream
streamClosed      111  u16 stream, u8 reason (0 asked, 1 window closed, 2 minimized/off-screen, 3 stream limit, 4 capture failed)
appIcon2          112  str appKey, u16 px, u32 hash, u32 blob
blobChunk         113  u32 blob, u32 total, u32 offset, bytes (≤ 16 KB)
pong              101  (unchanged)

WindowEntry2: u32 windowID, u32 pid, u32 ownerWindowID (0 = top-level), str appKey, str appName, str title,
              i16 x, i16 y, u16 w, u16 h (host points), u8 layer, u8 flags, u32 iconHash
              flags: bit0 streamed, bit1 focused, bit2 minimized, bit3 on-screen, bit4 sheet/modal
```

**Why blobs:** a control message is capped at 64 KB by the u16 length. A 512 px icon PNG, or a copied image, doesn't fit. Rather than change the framing mid-connection, large payloads go in ≤ 16 KB `blobChunk`s that interleave with other control messages. That way, on a slow uplink, a big clipboard paste never holds a mouse-up behind it for more than about 15 ms. Stage 1 hit this limit already, which is why its icons travel as separate `appIcon` messages instead of inside `windowList` (§7).

Window events on the host come from an `AXObserver` per app with a listed window (`kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXTitleChangedNotification`, `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, `kAXFocusedWindowChangedNotification`). A 1 s `CGWindowListCopyWindowInfo` diff backs them up. Mapping an `AXUIElement` to a `CGWindowID` needs the private `_AXUIElementGetWindow`, which yabai, Hammerspoon and Rectangle all use. The fallback is matching by pid, frame and title.

### 2.6 Per stream: capture, encoder, repair

**Capture.** Today's filter is the whole app on the display, cropped to the window, so a second shared window that overlaps would appear inside the first. v2 captures each stream with `SCContentFilter(display:including: [SCWindow])`: the window itself plus that app's transient windows that intersect it (layer > 0: menus, popovers, tooltips). Only the listed windows are composited, so other windows can't occlude it. The included set is refreshed (`SCStream.updateContentFilter`) after mouse-downs and every 250 ms while a transient window exists. Stage 4 moves transient windows into their own streams.

**Encoder.** There is one `VTCompressionSession` per stream, created lazily on the first frame and torn down on close. SCK only delivers changed frames, so an idle stream costs nothing.

How many concurrent sessions does the media engine take? Measured with `scripts/hevc-sessions.swift`. It runs N sessions configured exactly like `Encoder` (hardware-only, low-latency rate control, no reordering), each fed 90 frames that all change (a moving noise texture):

On the **M1 Pro (this viewer-side machine)**, 1920×1080 HEVC:

| sessions | 60 fps target: p50 / p95 encode ms | verdict | 30 fps target: p50 / p95 ms | verdict |
|---|---|---|---|---|
| 1 | 8.2 / 12.3 | ok | 8.0 / 12.7 | ok |
| 2 | 11.6 / 15.7 | ok | 10.1 / 15.0 | ok |
| 3 | 43 / 53 | falls behind | — | — |
| 4 | 110 / 113 | falls behind | 14.8 / 24.1 | ok |
| 6 | — | — | 70 / 87 | falls behind |
| 8 | 225 / 227 | falls behind | 226 / 229 | falls behind |
| 12–15 | 349–455 | falls behind | | |
| 16 | **hangs**: sessions are created, no frame ever comes out | | **hangs** | |

The engine's ceiling is aggregate throughput, about **175 changing 1080p frames/s in total** (360 frames in 2.04 s with 4 sessions, 720 in 4.13 s with 8). The session count itself isn't the limit, except that 16 concurrent 1080p sessions deadlock inside VideoToolbox's rate control: `VTRateControlSessionBeforeEncodeFrame` blocks waiting for a Mach reply. 16 sessions at 1280×800 still worked. **An M4 host was measured later (§8: at most 3 low-latency sessions).** Run `swift scripts/hevc-sessions.swift` there (and `… 3200 2000 60` for Retina-size windows) before fixing the numbers below.

A second run on the same M1 Pro during stage 2 (November 2026; p50 / p95 encode ms, "ok" = every frame out within 1/fps at p95):

| size @ target | 1 session | 2 | 3 | 4 | 6 | 8 |
|---|---|---|---|---|---|---|
| 1920×1080 @ 60 | 9.0 / 12.9 ok | 11.3 / 16.4 ok | 32.6 / 44.1 behind | 110 / 112 behind | 166 / 167 behind | 223 / 226 behind |
| 1600×1000 @ 60 (an 800×500 pt window at 2x) | 8.0 / 19.5 (one spike) | 9.3 / 13.6 ok | 11.7 / 18.1 borderline | 90 / 92 behind | 136 / 138 behind | |
| 3200×2000 @ 60 (1600×1000 pt at 2x) | 17.3 / 19.0, 2 dropped | 30.5 / 32.6 behind | 46 / 48 behind | 61 / 63 behind | | |
| 1920×1080 @ 30 | 8.9 / 11.0 ok | 11.0 / 15.4 ok | 13.9 / 19.5 ok | 15.6 / 24.8 ok | 63 / 77 behind | 223 / 226 behind |

So the M1 Pro sustains about **two 60 fps 1080p streams, or four at 30 fps** (~120–130 changing 1080p frames/s), and only about **one 3200×2000 stream at ~55 fps**: a full-size Retina window is the expensive case. Every session was created; nothing hung up to 8. Stage 2 does not lower the frame rate of unfocused windows yet (below); instead each pipeline skips frames while its encoder is behind (§8), which keeps latency bounded when the engine saturates.

Policy that follows from this:
- **Cap at 8 streams** per host. Opening a 9th returns `streamClosed(reason 3)`, and the viewer says so.
- **Focus gets the frames.** The focused stream gets `--fps` (60) and full `--kbps`. Other visible streams get 15 fps (SCK `minimumFrameInterval`) and kbps/3. Off-screen or minimized local windows get `closeStream`, or 1 fps if reopening has to be instant. `focusStream` flips this live with `VTSessionSetProperty(AverageBitRate)` and `SCStream.updateConfiguration`. That keeps the worst case at 60 + 7×15 = 165 1080p frames/s, inside the M1 Pro's ceiling. Note that a Retina capture of a 1600×1000 pt window is 3200×2000 px, about 3× a 1080p frame, so unfocused streams should also drop to scale 1.
- In practice most windows are idle most of the time, and the budget only matters when several animate at once.

**Repair, per stream:**
- *Viewer.* `Client`'s reassembly state (`pending`, `next`, `highest`, `wholeNacked`, `stuckSince`, `lastKeyRequest`) and its `Decoder` move into a `StreamRx` keyed by stream ID. The 30 ms repair timer walks all streams. A stuck stream asks for `keyframeRequest2(stream)`, so **a lost packet in one window never costs a keyframe in the others**. Today it would be all of them.
- *Host.* The resend cache is keyed by (stream, frameNo), bounded by total bytes (64 MB) rather than by 240 frames. FEC parity is computed per stream frame, as now.
- *Pacing.* Keep **one pacer** for all streams, because they share one bottleneck link. Give it two queues: the focused stream and all resends first, everything else after. Then a background window's 200 KB keyframe can't delay the focused window's 3 KB delta.

### 2.7 Child streams (stage 4)

When a streamed window gets a transient child (`ownerWindowID` = a streamed window: menu, popover, completion list), the host **opens a child stream on its own** and announces it with `windowAdded` + `streamInfo`. Waiting for the viewer to ask would add a round trip to every menu. The viewer shows it as a borderless child `NSWindow` at the reported offset from its parent (§5.6).

---

## 3. Host-side input with several overlapping windows

Facts that don't change: injection posts at the HID tap in global coordinates, mouse events land on whatever is topmost at that point, and keys go to the key window of the frontmost app. On a headless host every shared window sits on one (dummy or virtual) display and can overlap.

**Plan:**

1. **Don't let streamed windows overlap.** Nobody looks at the host's screen, so the host lays out what it streams. On `openStream`, if the window intersects another streamed window, the host moves it to free space via AX (`kAXPositionAttribute`). Give the host a large virtual display (BetterDisplay, or the private `CGVirtualDisplay` API; 5120×2880 fits 4–6 windows) so tiling is possible. Since nothing overlaps, clicks and scrolls land where they should without raising anything, and capture is clean anyway (§2.6).
2. **Raise on focus change, not per event.** When a local window becomes key, the viewer sends `focusStream`. TCP keeps it ordered ahead of the mouse-down that caused it. The host then:
   - `AXUIElementPerformAction(window, kAXRaiseAction)`
   - `AXUIElementSetAttributeValue(window, kAXMainAttribute, true)`
   - `AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute, true)`. The AX route works from a background process, where `NSRunningApplication.activate()` (today's `Injector.activateTarget`) can be refused silently under macOS 14+ cooperative activation.
   - Then it **waits until the window really is in front**: it polls `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` order for up to 100 ms and holds that stream's queued input meanwhile. Otherwise the first keystrokes after a switch land in the old window.
3. Every input message carries its stream ID. The injector maps coordinates with *that* stream's window frame, not one global `frame`. Moves and scrolls for a non-focused stream are injected without raising. macOS scrolls background windows under the pointer, and the layout guarantees nothing is on top.

**What breaks or gets worse:**
- *Transient UI dismissal.* Raising window B closes A's open menus, popovers and autocomplete lists, as on a real Mac when focus moves.
- *Hover follows the single host cursor.* Moving over local window B moves the host's one cursor onto B, so A's hover states and tooltips vanish. The viewer has many pointers' worth of windows, but the host has one cursor.
- *Same-app windows.* Raising Safari window 2 makes window 1 resign key. That's correct, but any app-level "current document" state follows.
- *Floating panels* (inspectors, palettes, layer > 0) float above every window of their app, so they can cover another streamed window of the same app. Treat them as children of the window they belong to.
- *Full-screen windows* each live in their own Space and can't coexist on screen. Refuse them, or take them out of full screen with the `AXFullScreen` attribute. *Minimized windows* can't be captured, so unminimize them (`kAXMinimizedAttribute` = false) on `openStream`. Windows on other Spaces aren't on screen, and there is no public API to move them, so the list shows only on-screen windows, as today.
- *App-modal dialogs* are separate windows. Clicks on the blocked parent go nowhere, so the host sends `windowFocused(dialog)` and the viewer opens it (as a child in stage 4).
- *Drag between two shared windows* works on the host side (global coordinates, non-overlapping), but the viewer would have to carry one drag across two local windows. Out of scope.
- *Alternative worth an experiment:* `CGEvent.postToPid` with `kCGMouseEventWindowUnderMousePointer` / `…ThatCanHandleThisEvent` set to the target window delivers mouse events to a background window without raising it. It works for many AppKit apps and unreliably for Chromium/Electron, and it never makes the window key. It might help hover and scroll, but not typing.

---

## 4. App vs window on the viewer

macOS gives each *process* one Dock icon, one Cmd-Tab entry, one menu bar and one App Exposé group, and its windows belong to it. Remote windows therefore have to be grouped into local processes on purpose.

**Model:** each `(host, appKey)` gets one **phantom app**, which owns N local windows, one per stream of that app's windows. Example: Safari on my-mac-mini with two windows open gives one "Safari" phantom in the Dock with two windows.

Options for separate Dock and Cmd-Tab presence:

| | (a) generated app-shim bundle per remote app | (b) one Wisp app swapping `NSApp.applicationIconImage` | (c) stage 2 baseline: Wisp owns all windows |
|---|---|---|---|
| Dock icons | one per remote app, its own icon + remote mark | one, icon changes with the focused remote app | one (Wisp) |
| Cmd-Tab | one entry per remote app | one entry | one entry |
| App Exposé, Window menu, Dock window list | per remote app (free: AppKit lists an app's windows) | all remote apps mixed | mixed |
| Menu bar app name | "Safari" (`CFBundleName`) | "Wisp" (can't change at runtime) | "Wisp" |
| Pin to Dock / Spotlight / Launchpad | yes: launches Wisp + opens the remote app | no | no |
| Two remote apps at once | distinguishable | indistinguishable; the icon flips on every focus change | indistinguishable |
| Cost | bundle generation, ad-hoc signing, IPC, lifecycle | trivial | none |

**Recommendation: (a).** (b) can't give two remote apps two Dock icons or two Cmd-Tab entries, which is the whole point, and an icon that flips with focus looks broken. Its only use is as a cheap hint during stage 2 (Wisp's Dock icon shows the focused remote app's icon).

## 5. Phantom apps (stage 3)

The design as written before building it. What was built, and where it differs, is in §9.

### 5.1 The bundle

Path: `~/Library/Application Support/Wisp/Phantoms/<hostID>/<appKey>/<App Name>.app` (as built, §9.2), out of the way, and the Dock can still pin it. An opt-in "show remote apps in Launchpad" setting could symlink into `~/Applications/Wisp Apps.localized/`, which is the Chrome pattern.

```
Safari.app/Contents/
  Info.plist   CFBundleIdentifier   <bundle ID>.phantom.<hostID8>.<sanitised appKey>
               CFBundleName         Safari                     (menu bar)
               CFBundleDisplayName  Safari (my-mac-mini)     (Dock tooltip, Finder)
               CFBundleIconFile     AppIcon
               CFBundleExecutable   Wisp
               LSMinimumSystemVersion, NSHighResolutionCapable
               WispPhantom         { hostID, hostAddress, appKey, iconHash }
  MacOS/Wisp  copy of Wisp's own binary (one binary, many modes: main.swift sees WispPhantom in
               Bundle.main.infoDictionary and runs as a phantom)
  Resources/AppIcon.icns
```

- **Signing.** Apple silicon won't run unsigned code, and a code signature binds the bundle's Info.plist, so each phantom gets a *copy* of the binary (not a hard link) and is re-signed ad-hoc with `codesign --force --sign - <bundle>`, as Chrome does with its shims. The bundle is created locally, so it carries no quarantine attribute and Gatekeeper never assesses it. Phantoms need **no TCC permissions**: they don't capture or inject on the viewer side. The cost is about 5 MB per phantom. If that matters, a tiny second SwiftPM executable can serve as the stub.
- **Updates.** When Wisp updates, or a phantom's `iconHash` differs from the host's, regenerate the bundle next time it's launched.

### 5.2 Icon transfer and the "remote" mark

- Stage 1 sends a 32×32 PNG per app key once per connection (`appIcon`), enough for the menu.
- v2: `windowList2` carries a `u32 iconHash` per window. The viewer keeps `~/Library/Caches/Wisp/icons/<hostID>/<appKey>-<hash>-<px>.png`, and only on a cache miss sends `iconRequest(appKey, 512)`. The host renders `NSRunningApplication.icon` at 512 px, about 50–250 KB as PNG, and sends it as `appIcon2` + `blobChunk`s. In practice each app's icon crosses the network once, ever.
- **Mark.** The phantom icon is the remote icon at full size plus a badge in the bottom-right quarter. (As built, §9.2: one teal disc with a white rim and a white up-right swoosh arrow, the same for every host.) Write it out as `AppIcon.icns` (ImageIO can write `com.apple.icns`), and also set `NSApp.applicationIconImage` at launch so a running phantom is right even before the file is refreshed. The mark matters: the person at the viewer should always know a click goes to the other Mac, both for latency and for where files are saved. `dockTile.badgeLabel` stays free for forwarding the remote app's own Dock badge later.

### 5.3 Lifecycle

- **From the Wisp menu bar list** (stage 1's menu, grouped by app): picking a window ensures the phantom bundle exists and is current. If it isn't running, Wisp launches it with `NSWorkspace.openApplication(at:configuration:)` and the window ID as an argument. If it's already running, Wisp tells it over the socket to open that window.
- **From the Dock or Spotlight**, with Wisp not running: the phantom launches Wisp in the background (`--connect <host>`), waits for the socket, then opens that app's front-most remote window. If the app has no windows on the host, it shows "Safari isn't open on my-mac-mini".
- **Close button** of a phantom window: stop viewing (`closeStream`). Cmd-W and every other key is forwarded as today, so it closes the *remote* window. A "Close on my-mac-mini" menu item makes that explicit.
- **Cmd-Q** goes to the phantom's own app menu ("Quit Safari (remote view)"), which stops viewing all of its windows. It does not quit the remote app. To make that possible, the local key monitor lets Cmd-Q and Cmd-H through instead of forwarding them, and the remote app's own Quit is in the mirrored menus (§6).
- **Remote app quits**: the host sends `windowRemoved` for each window. The phantom closes those windows and terminates after the last one.
- **Wisp main process dies**: phantoms see the socket close, overlay "Reconnecting…", and relaunch Wisp.

### 5.4 IPC: phantoms talk to Wisp, Wisp talks to the host

Wisp keeps **one** TCP+UDP session per host. That gives one pacer, one NACK/FEC engine and one clock-offset estimate, and it means the host never sees more than one viewer. Each phantom connects to Wisp over a Unix domain socket at `~/Library/Application Support/Wisp/run/<hostID>.sock`, using the same message types with **u32** length framing, since this is a private channel with no compatibility concerns:

- phantom → Wisp: `openStream`, `closeStream`, `focusStream`, `resizeStream`, stream-tagged input. Wisp passes them to the host unchanged; stream IDs are global per session.
- Wisp → phantom: `streamInfo`, `windowChanged`, `streamClosed`, and **complete reassembled frames** (`[u16 stream][FrameTag v2][flags][param sets][AVCC]`, exactly what the decoder takes today).

Each phantom decodes its own streams with its own `VTDecompressionSession` (about 1–2 ms per frame) onto its window's `CALayer`. Forwarding compressed frames costs a few Mbps through a local socket and about 50 µs. The zero-copy alternatives are worse fits: passing decoded IOSurfaces needs XPC (`IOSurfaceCreateXPCObject`), so Wisp would have to be registered as a launch agent with a Mach service; remote `CALayerHost` layers are private API. Chrome's RemoteCocoa uses the latter, but it doesn't need to here.

### 5.5 Dock menu

AppKit already puts a running app's own windows at the top of its Dock menu. `applicationDockMenu(_:)` adds:
- **Other windows on my-mac-mini**: windows of this app from `windowList2` that aren't open locally. Picking one sends `openStream`.
- **Show All Remote Windows…**: opens Wisp's menu bar list.

### 5.6 Child windows: menus, sheets, popovers

| kind | stage 2–3 (inside the parent stream) | stage 4 (own stream) |
|---|---|---|
| sheets | fine: drawn inside the parent's frame | stay in the parent |
| context menus, popup buttons | captured if they overlap the parent (§2.6); **clipped** at the parent's edge | child stream → borderless `NSWindow` at `.popUpMenu` level, `parent.addChildWindow(_:ordered:)` at the host-reported offset, local shadow |
| popovers, autocomplete, tooltips | clipped at the parent's edge | same as menus, normal or floating level |
| app-modal dialogs, separate panels | listed as their own windows; the user opens them | auto-opened as children when `windowFocused` points at them |

Child streams follow RAIL owned windows and xpra `transient-for` windows. The host opens them proactively (§2.7), so a menu appears one RTT plus one encode after the click, the same as today. Input inside a child window is just input for that stream.

---

## 6. Later stages, briefly

**Menu bar mirroring (stage 4).** Built; what was built, and how it differs from this sketch, is in §10. The sketch: on `focusStream`, the host walks the app's `kAXMenuBarAttribute` → `AXMenuBarItem` → `AXMenu` → `AXMenuItem` tree. For each item it reads `AXTitle`, `AXEnabled`, `kAXMenuItemCmdCharAttribute`, `kAXMenuItemCmdModifiersAttribute` and `kAXMenuItemMarkCharAttribute`, and gives it a path-based node ID. To keep slow apps like Xcode cheap, it walks lazily, one top-level menu at a time, and sends the result as a `menuTree` blob. The phantom builds a real `NSMenu`. `menuNeedsUpdate:` shows the cached submenu immediately and asks for a refresh, which lands about one RTT later and updates in place (titles like "Undo Typing" and enabled states change). Choosing an item sends `menuPick(nodeID)` → `AXUIElementPerformAction(item, kAXPressAction)`. Shortcuts are displayed but still reach the remote as keystrokes, because the local key monitor runs before menu key equivalents. Apps without AX menus (some Electron) just get the phantom's minimal menu.

**Clipboard sync.** Viewer → host: when a phantom or Wisp window becomes key and `NSPasteboard.changeCount` has moved, send `clipboard` (plain text, RTF, PNG; no file URLs) as a blob before the next input. Host → viewer: poll the host's `changeCount` every 500 ms while a viewer is connected (there's no notification API) and send changes up to 1 MB eagerly; larger ones only on request. Skip pasteboards marked `org.nspasteboard.ConcealedType` or `TransientType` (password managers). Make it opt-in, since it moves data across machines. *(Built in §13: both sides poll, eager up to 10 MB, on by default with a setting on each side.)*

**Cursor shape forwarding.** While the pointer is over a streamed window, the host samples `NSCursor.currentSystem` at 30 Hz and hashes the image. On change it sends `cursor(u32 hash, hotspot)`, and the PNG once per hash, like RDP's pointer cache. The viewer sets `NSCursor(image:hotSpot:)` on its view. The shape arrives one RTT late (the arrow becomes an I-beam about 150 ms after crossing into a text field), which is acceptable. `showsCursor` stays false: the local arrow stays the one the viewer's user moves, with no lag.

---

## 7. Stage 1: what was built

A menu bar item on the viewer lists the host's shareable windows under their apps' icons. Choosing one switches the single existing stream to that window, using the existing `Host.share` switch path. There is no multi-stream yet, and the v1 single-window path is unchanged. (Stage 2 replaced switching with opening, and dropped `shareWindow`; see §8.)

Wire additions (backward compatible: unknown types are dropped by `MessageParser` on both sides):

```
windowListRequest 11  viewer→host  (empty)
shareWindow       12  viewer→host  u32 windowID
windowList       102  host→viewer  u16 count, count × ([u32 id][str appKey][str appName][str title][u16 pointW][u16 pointH][u8 flags: bit0 shared])
appIcon          103  host→viewer  str appKey, PNG 32×32 px. Once per app per connection, before the windowList that first lists it
```

- The design called for a "windowList including a small PNG icon per app". Icons travel as separate `appIcon` messages because a control message can't exceed 64 KB, and twenty 32 px icons plus titles can. `WindowEntry.encode` also stops adding entries before the limit.
- After a viewer has asked once, the host re-sends `windowList` whenever the shared window changes, so the checkmark moves. Viewers that never ask (v1) never get one.
- `wisp send --synthetic` offers two test windows (`synthetic test 1` at the given size, `2` at 75%), so switching can be tested on loopback without Screen Recording or Accessibility.
- The viewer (`Sources/wisp/Viewer/WindowsMenu.swift`) requests the list when it connects and again on every menu open, and updates the open menu in place when the answer arrives. If a host never answers, the menu says its Wisp may be too old.
- CLI test hooks: `wisp view <host> --windows` prints the list, and `wisp view <host> --snapshot out.png --share <id>` switches, then saves a frame.

---

## 8. Stage 2: what was built

Several host windows stream at once, each into a Wisp window of its own, over one TCP and one UDP connection per host. Protocol 2 is a clean break: both Macs must run the same version, and a mismatch is reported in plain words on both sides.

**Wire format (as built; `Sources/WispCommon/Protocol.swift`).** Message type numbers differ from §2.5 where §2.5 collided with numbers stage 1 had already used.

```
hello          20  viewer→host  u16 version(=2), u32 features(0), str viewerName      first message on a viewer connection
helloAck      110  host→viewer  u16 version, u32 features, u32 session, str hostName
openStream     21  viewer→host  u32 windowID (0 = the host's primary window)          → streamOpened, or streamClosed(0, reason, windowID)
closeStream    22  viewer→host  u16 stream
streamOpened  111  host→viewer  u16 stream, u32 windowID                              then windowInfo, windowChrome, a keyframe; also unasked
streamClosed  112  host→viewer  u16 stream, u8 reason (0 asked, 1 window gone, 2 replaced, 3 limit, 4 failed), u32 windowID
sideChannel    15  poke→host    u16 version                                           answered with helloAck; stream 0 = primary
per stream: windowInfo 100, windowChrome 105, windowGone 106, resizeWindow 14, windowAction 16, input 1…6,
            keyframeRequest 7, nack 8: the v1 payload with a u16 stream ID first (same type numbers)
video    kind 3: [u8 3][u16 stream][u32 frameNo][u16 chunk][u16 count][≤1100 B]   frameNo per stream
parity   kind 4: [u8 4][u16 stream][u32 frameNo][u16 group][u16 count][u8 k][u32 frameLen][xor]
UDP hello kind 1: [u8 1][u32 session]
helloEcho kind 5: [u8 5][u32 session]   host→viewer, the answer to each UDP hello (added in §14; older viewers ignore it)
FrameTag (27 B): [u16 stream][u64 encodedAt][u32 inputsApplied (per stream)][u8 refinement][u32 captureLag][u32 encodeTime][u32 appRender]
stats      10: + u8 n, n × (u16 stream, u16 fps, u16 videoP50)                    per-stream detail after the stages
```

**Version mismatch.** A protocol-1 viewer sends `viewerScreen` (not `hello`) first: the host logs that the viewer runs an older Wisp and must be updated, sends it a v1 `windowInfo` titled *"Wisp on <host> is newer (protocol 2): update Wisp on this Mac"* (640×160 pt) and, once its 1-byte UDP hello arrives, a v1 H.264 keyframe that draws that sentence (`LegacyNotice`); it never becomes the viewer and is disconnected after 30 s. A protocol-2 viewer that meets a protocol-1 host sees `windowInfo` before `helloAck` and stops with *"<host> runs an older Wisp (protocol 1). Update Wisp there…"*; anything that doesn't answer `hello` within 3 s is reported too. `wisp poke` waits for the host's ack before sending, so it never injects misread input into an old host. Verified on loopback against a build of the previous commit, both ways.

**Host.** `HostStream` = one window: its `WindowCapture` (or `SyntheticSource`), its `Pipeline` (own queue and `VTCompressionSession`, refinement, keyframes) and its `WindowTarget` for input and Accessibility. `Server` keeps frame numbers, FEC and a 240-frame resend cache per stream, and one pacer for all. The rate controller (loss → ×0.7 back-off, as before) splits `--kbps` evenly between the open streams whose window changed in the last second; idle ones send nothing. The operator's window (CLI `--window`, the app's picker) is the **primary** stream, captured even with no viewer so the next one sees it at once; `openStream(0)` opens it. Choosing another window in the host app makes that the primary: the viewer gets it as a new window (an unasked `streamOpened`), then `streamClosed(replaced)` for the old one. When a viewer disconnects or is replaced, every non-primary stream ends and its window is put back where it was.

- Every streamed window goes onto a HiDPI virtual display of its own (§8.1; first built as one shared display with a 40 pt cascade). Pinning, resize (with its request IDs), chrome reading and the close button via Accessibility run per stream.
- Each capture is the window's app on that display, cropped to the window (so menus and sheets come along), **minus the app's other streamed windows** (`exceptingWindows`, refreshed when one opens or closes), so two windows of one app never appear inside each other.
- Input carries its stream: coordinates map through that window's frame, scrolls go where the pointer last was in that window, and `Injector.ensureTarget` now checks that the topmost window at the point is that very window (not just its app: another streamed window of the same app counts as covering it; a sheet or panel of its app lying within it doesn't) before raising it. Keys check the app's focused window against the stream's window at once when typing moves to another stream (else every 0.5 s).
- A window closed on the host (or its app quitting) sends `windowGone` for its stream only, and the stream ends.
- **Frames are skipped while an encoder is busy** (two frames in flight), keyframes excepted. Without this, three 60 fps synthetic streams plus local decoding on the M1 Pro queued up to ~105 ms in VideoToolbox (video delay p50 108 ms); with it, 37 ms at ~46 fps per stream.

**Viewer.** `ViewerSession` owns the `Client` (one connection), the menu bar list and one `ViewerController` per stream; `RemoteStream` holds each stream's reassembly, repair timer pass, decoder and the last info/chrome (replayed to a window that attaches late). The first window shows "connecting…" before any stream exists and binds to stream 1's answer. The menu opens a window per choice (checkmark = open here; choosing an open one brings it to front); new windows cascade from the front one. Red closes the remote window (`windowAction`); ⌥-red and Window > Stop Viewing This Window close the local window only (`closeStream`). Closing the last window ends the session, as before. Latency: input→frame matching uses per-stream counters (the host stamps each stream's frames with the inputs injected into that window), fps and video delay are reported per stream, and the host's existing log line is the aggregate.

**Deviations from §2.**
- Message numbers (above). `focusStream`, `resizeStream`, `windowList2`/`windowAdded`/`windowRemoved`/`windowChanged`/`windowFocused`, icon blobs and `features` bits are not built: the stage-1 `windowList` (re-sent when the set of streamed windows changes) and per-stream `resizeWindow`/`windowGone` cover stage 2. Focus is handled per input event (`ensureTarget`), not by a `focusStream` message.
- No v1 fallback in the viewer: a v1 host is reported, not served (§2.2 kept the old client path).
- §2.6's capture filter `SCContentFilter(display:including:[SCWindow])` was not used: the stage-1 app filter (which brings menus and popovers along) plus `exceptingWindows` gives the same isolation between streamed windows.
- No per-focus policy yet (focused 60 fps / others 15 fps, priority pacer queues); instead an even bitrate split between changing windows and frame skipping under encoder saturation. The stream cap is `maxStreams` (default 3, the M4's low-latency HEVC encoder limit; `defaults write com.pier20.Wisp maxStreams -int N`).
- Instead of tiling one large display (§3, option 1), each window gets a display of its own, the size of the viewer's screen (§8.1). Clicks, scrolls and keys still raise the target window first; hover relies on there being no overlap.
- The resend cache is 240 frames per stream, not a byte budget.

**Testing.** `wisp send --synthetic 1600x1000` offers three test windows (800×500, 600×375, 400×300 pt), each with its own background and animation. `wisp view <host> --snapshot out.png --open 2,3 [--close 2@3]` opens them headlessly, prints per-stream stats each second and saves `out.png`, `out-2.png`, `out-3.png`. `WISP_DROP=5 [WISP_DROP_WINDOW=2]` simulates loss (on one window's stream only). `WISP_TEST_OPEN=2,3@1` and `WISP_TEST_CLOSE=2@4` drive the GUI viewer through the menu's open path and Stop Viewing. `wisp poke <host> --stream N …` addresses one stream. Loopback results on the M1 Pro: three streams at 1600×1000, 1200×750 and 800×600 px decoded at 60 fps each; closing one left the others at 60 fps; 5% loss on all streams was repaired per stream with no keyframe requests, and loss on stream 2 alone was repaired on stream 2 with zero NACKs or FEC rebuilds on the others; the GUI viewer showed two windows of 800×500 and 600×375 pt (CGWindowList), followed a host-side resize of the second (700×450) and closed only it on a host-side close.

**Needs a real host.** Real windows (Screen Recording and Accessibility weren't available on the test Mac): placement on the virtual displays (§8.1), the `exceptingWindows` filter with two windows of one app, raising the right window before clicks and keys, close via Accessibility per window, and restoring windows when streams end. And the M4's encoder throughput, which sets `maxStreams` and whether unfocused windows need a lower frame rate.

### 8.1 A virtual display per window

**Why.** On a headless Mac mini host, two Zed windows were streamed. Each was nearly as big as the one 1728×1010 pt virtual display, so the 40 pt cascade collapsed and both were placed at the same spot (1536×890 pt at 96,30). Clicks and keys raise the target window first and landed correctly, but mouse moves don't raise anything, so hover meant for window 2 went to window 1, which was on top.

**What.** Each stream gets a HiDPI virtual display of its own, sized to the viewer's screen (`viewerScreen`), and its window goes to the top-left of that display's usable area (shrunk only if it doesn't fit), pinned there as before. Streamed windows never overlap, so hover reaches the right window without raising it, and each window can be as large as the viewer's screen. Raising on click, scroll and key is unchanged. Input maps through each window's own global frame (read every 0.2 s from CGWindowList), which lies on its own display.

- **Lifetime.** A stream's display is made when the stream opens and the viewer's screen size is known (the primary stream, captured before any viewer, gets its display when the viewer's `viewerScreen` arrives). It is removed when the stream closes, after the window is moved back to where it was. When the viewer leaves, the non-primary streams end and their displays go at once; 30 s later the primary window goes back and its display is removed, as before. At most one display per stream, so at most `maxStreams` (3). While the viewer's screen size changes there can briefly be one more: per stream, the new display is made, the window moves onto it, then the old display is removed.
- **Arrangement.** Each new display goes to the right of every other display, top edges level with the main display's (`CGConfigureDisplayOrigin`), and is never mirrored. If it took over as main, the old main display is put back at the origin. On a headless host the first virtual display is unavoidably the main one, and when it is removed another one becomes main; both are logged.
- **Displays moving.** Removing a display can rearrange the others (macOS keeps them touching, and a new main display moves to the origin), which moves every window on them in global coordinates. The follow timer works relative to the display: it reads the display's current origin for the capture region, and pinning compares the window's position relative to its display, so such a move is followed rather than undone.
- **No virtual display** (`--no-virtual-display`, `defaults write com.pier20.Wisp virtualDisplay -bool false`, the synthetic host, or after a failure): windows are shared on their own display as before, where they may overlap.

**WindowServer safety.** An earlier version deadlocked WindowServer on the host Mac, which took down every logged-in session: the display's callbacks ran on the main queue while the main thread was blocked in a CGWindowListCopyWindowInfo that WindowServer, itself waiting for that acknowledgement, never answered. Now:
- The `CGVirtualDisplay` callback queue is a private serial queue, never the main queue.
- Every create and remove runs on one serial `lifecycleQueue` (`autoreleaseFrequency: .workItem`), never on the main thread; the host only awaits it. All of the host's display changes also run in its `serially` chain, so there is never more than one in flight, and none starts while another is under way.
- `DisplayGate` marks a change in flight, plus 0.3 s to settle. Meanwhile the main thread makes no WindowServer or Accessibility calls: the 0.2 s follow timers skip their turn, the 2 s session check (`CGSessionCopyCurrentDictionary`) is skipped, and input, viewer resizes, the close button, chrome re-reads and the injector's delayed focus check are held and then run in order.
- **Watchdog.** A display that isn't online with its 2x mode active within 5 s is removed again. If the create call itself doesn't return within 6 s, the host stops waiting, and the display is removed whenever the call does return. Either way the host logs why, stops making virtual displays for the session, and shares windows where they are. Nothing is ever force-killed.
- Quitting (`stop()`) removes each display and waits at most 1 s for each, on a semaphore, not in a WindowServer call.

**Testing.** `wisp vdisplay-test 1512x982 5 --count 3` makes N displays one at a time through the same code, prints the arrangement, checks each is 2x, not main (unless nothing else is left), not mirrored and overlaps no other display, then removes them one by one and checks nothing is left behind. On an M1 Pro MacBook Pro (built-in display 1728×1117 pt), `--count 2` (run once) placed them at 1728,0 and 3240,0, each 1512×982 pt at 3024×1964 px, made in 0.8 s and 1.0 s, and removed both. Each removal waited the full 3 s for the display to drop out of the online list, though it was gone as soon as that work item ended. The likely cause is that the released display sat in the queue's autorelease pool; release and creation now run in pools of their own (not yet run again). The loopback tests (`wisp send --synthetic 1600x1000` + `wisp view 127.0.0.1 --snapshot out.png --open 2,3 [--close 2@2]`) pass unchanged; they make no virtual displays.

**Needs a real host.** Two or three real windows (e.g. two Zed windows): each on its own display at the top-left, hover reaching the right window, nothing overlapping. Removing a display when its stream closes, including the main one on a headless host (the others shift and should be followed, not dragged back). A change of the viewer's screen size, made one display at a time. The 30 s teardown. And the watchdog never firing in normal use; if it does, the log says why.

## 9. Stage 3: what was built

Each remote app is a **phantom app** on the viewer: a generated app bundle with its own bundle ID, name and badged icon, running as a process of its own that owns that app's windows. So the Dock, ⌘Tab, Mission Control/App Exposé, the Window menu and the menu bar treat it as that app. Wisp itself becomes a menu bar helper while connected. November 2026.

### 9.1 Architecture: who owns the windows, who decodes

macOS gives Dock, ⌘Tab and App Exposé identity to the **process that owns the windows**, so a phantom must own its `NSWindow`s. That rules out the "tiny launcher" option (a) of the brief, where the shim asks Wisp to host its windows: they would still be Wisp's windows, grouped under Wisp. (Chrome's shims face the same constraint, which is why RemoteCocoa puts the `NSWindow`s in the shim process.) So the phantom is **option (b)**: a copy of Wisp's own binary, started in phantom mode, that owns its windows, while the main Wisp process keeps the one TCP/UDP connection to the host (the host still takes a single viewer) and relays over local IPC.

What crosses the IPC is the remaining choice:

| | relay **complete compressed frames**, phantom decodes (built) | decode in Wisp, share the **IOSurface** with the phantom |
|---|---|---|
| bytes per frame over IPC | the encoded frame: ~2–60 KB, a keyframe 100–300 KB | a 4-byte surface ID or a Mach port (zero copy) |
| hop cost (measured / expected) | **~0.2 ms p50** through a Unix socket (6 MB copy test: 1.9 µs/KB) | a Mach message, ~0.05 ms, plus a release message back |
| decode | in the phantom, same VideoToolbox session code as in-process, same cost | in Wisp, same cost |
| transport | a Unix domain socket in `~/Library/Application Support/Wisp/run/` (Network.framework, no registration) | Mach ports can't travel over a Unix socket: needs XPC with a launchd-registered Mach service (Wisp as a launch agent), or the deprecated global surfaces (`kIOSurfaceIsGlobal` + `IOSurfaceLookup`, readable by any process) |
| buffer lifetime | each process owns its own buffers | Wisp's decoder pool recycles a surface as soon as Wisp releases it; it must hold every frame until the phantom says it's shown it (a second round trip per frame), or the phantom shows a frame being overwritten |
| failure isolation | a phantom crash loses its own decoder only | a stuck phantom pins Wisp's decoder pool |

The IOSurface path would save at most ~0.15 ms of a ~4 ms on-viewer pipeline and costs a launch agent (or world-readable surfaces) and a cross-process buffer-release protocol. The compressed-frame relay keeps the latency within 0.3 ms of in-process (measured below), so it was chosen. Frames are relayed **from the network queue the moment reassembly completes them** (no main-thread hop in Wisp), and the phantom decodes on its socket queue as soon as a frame arrives, exactly as the in-process viewer decodes on its network queue. NACK/FEC repair, the clock offset, pacing feedback and keyframe requests all stay in Wisp.

### 9.2 The phantom bundle (`Sources/wisp/Phantom/PhantomBundle.swift`)

```
~/Library/Application Support/Wisp/Phantoms/<host>/<appKey>/<App Name>.app/Contents/
  Info.plist   CFBundleIdentifier  <bundle ID>.phantom.<first 16 hex of SHA-256(host \n appKey)>
               CFBundleName, CFBundleDisplayName  the remote app's name ("Synth Alpha")
               CFBundleExecutable Wisp, CFBundleIconFile AppIcon, LSMinimumSystemVersion 14.0, NSHighResolutionCapable
               WispPhantom  { host, appKey, appName, iconHash, binary (size-mtime of Wisp's binary), format, wisp (path to start Wisp) }
  MacOS/Wisp  a copy of Wisp's binary (main.swift sees WispPhantom and runs the phantom)
  Resources/AppIcon.icns     16–512 px: the remote icon with the badge
  Resources/RemoteIcon.png   the icon as the host sent it, to rebuild from
```

- **Signing.** `codesign --force --sign <identity> --identifier <bundle ID> --options runtime`. The identity is Wisp's own when its certificate is in the keychain (read from `codesign -dvv` of Wisp.app and checked against `security find-identity`), else ad-hoc. The bundle is written on this Mac, so it has no quarantine attribute and Gatekeeper doesn't assess it. Phantoms need no TCC permissions. Built in a temporary directory, signed, then swapped in whole (`replaceItemAt`) and re-registered with `LSRegisterURL`. About 70–90 ms; 3.7 MB each (universal binary).
- **Regeneration.** A bundle is current when its app name, Wisp binary stamp, format and (when the host's icon is known) icon hash match. A current bundle starts at once; the host's 512 px icon is still fetched, and if it differs the running phantom gets the new icon at once (`NSApp.applicationIconImage`) and the bundle is rebuilt after it quits (rebuilding a running app would rewrite the binary it runs from). A stale or missing bundle waits up to 1.5 s for the large icon (falling back to the 32 px menu icon, then a generic app icon) and is built before launch.
- **Badge.** Bottom-right, 40 % of the icon (`Sources/wisp/Phantom/RemoteBadge.swift`): one teal disc with a white rim and a white up-right swoosh arrow, in the app icon's family. It is the same for every host.
- **File name.** The bundle is named after the app (`Zed.app`, extension hidden) in a folder named after its app key, because macOS takes the name in the Dock tooltip, Finder and Activity Monitor from the file name. Until November 2026 bundles were `<host>/<appKey>.app`, so the Dock showed "dev.zed.Zed"; those are unregistered from LaunchServices (`lsregister -u`) and deleted when the viewer starts, unless one is running. A bundle left under an app's earlier name is removed the same way when the new one is made. Bundle IDs use the prefix `Brand.phantomBundleIDPrefix`.

### 9.3 Protocol additions (host, still protocol 2)

```
iconRequest   17  viewer→host  str appKey, u16 px                                  → appIconLarge chunks (an older host ignores it)
appIconLarge 107  host→viewer  str appKey, u16 px, u32 total, u32 offset, ≤60000 B PNG   in order; one icon ≈ 30–250 KB
streamOpened 111  … u32 windowID, + str appKey, str appName                            trailing; older viewers ignore them
```

An older host (no app fields) still works: the viewer looks the window up in a fresh window list (2 s), else puts it in a "Remote Window" phantom.

### 9.4 Local IPC (`Sources/wisp/Phantom/IPC.swift`)

`~/Library/Application Support/Wisp/run/viewer.sock`, one connection per phantom, `[u32 length][u8 type][payload]`. Phantom → Wisp: `hello(host, appKey, pid)`, `input(stream, discrete, host input message)` (passed to the host as is), `resize`, `closeStream`, `closeRemote`, `openWindow(id | 0 = frontmost)`, `screen(displayID)`, `frameTiming(tag, reassembled, relayed, decodeStart, decoded, displayed)`, `decodeFailed`, `bye`. Wisp → phantom: `helloAck(ok, host, why)`, `streamOpen(stream, windowID)`, `host(windowInfo | windowChrome | windowGone | streamClosed, as the host sent them)`, `frame(stream, reassembled µs, FrameTag + frame)`, `stats(stream, title line)`, `connection`, `hostStatus`, `windows(this app's windowList)`, `notice`, `focus`, `stopViewing`, `icon`, `quit`, `expect`.

- Input and frame timings are handled on the socket's queue in Wisp (no main-thread hop); `Latency` takes the phantom's timestamps directly (CLOCK_UPTIME_RAW is the same in every process), so click→screen and the stage breakdown cover phantoms too, plus a new **relay** stage.
- A phantom's decoder starts empty: Wisp asks the host for a keyframe when it starts relaying a stream; the phantom skips frames until a keyframe and asks again (`decodeFailed`) if none comes within a second or a frame fails to decode. A new stream is registered on the socket's queue before its window is made, so that first keyframe isn't dropped while the main thread builds the window (found in testing: the second phantom's first keyframe arrived before its window existed, and it never showed a frame).
- Both Wisp (while connected) and phantoms (while showing windows) hold a `latencyCritical` activity, so App Nap and timer coalescing never delay frames.

### 9.5 Behaviour

- **Opening** a remote window (menu bar list, the host's initial window, a phantom's Dock or Window menu): if its app's phantom runs and is connected, the window goes there and the phantom is activated (`NSWorkspace.openApplication`, `activates`; Wisp sends `expect` first so the reopen event this causes isn't taken for a Dock click). Otherwise the bundle is made current and launched; the stream waits until the phantom says hello. Measured: bundle made in 65–90 ms, phantom started and connected 0.57–0.67 s after the stream opened.
- **Dock click**: AppKit brings the windows forward (minimized ones are restored); with no windows open, the phantom asks Wisp for the app's frontmost window on the host (the host lists front to back), or says the app has no windows there. *(Since §12: from a fresh window list, and with no window there the remote app is reopened instead.)*
- **Opened from the Dock/Spotlight with Wisp not running**: the phantom finds no socket, starts Wisp with `--connect <host>` (path from its Info.plist) and retries for 20 s; Wisp connects and opens the app's frontmost window in it. If Wisp is connected to another host, the phantom says so and quits.
- **Dock menu**: AppKit's list of the open windows, then "Windows on <host>": every window of this app on the host, open ones checked; choosing one opens it (or brings it forward). The same list is in Window > Windows on <host>.
- **Menu bar**: the app menu (About <app> (remote on <host>), Hide <app>, Hide Others, Show All, Quit <app>) and Window (Minimize, Zoom, Full Screen, Close Window on <host>, Stop Viewing This Window, Windows on <host>, Bring All to Front, and AppKit's window list). The remote app's own menus join them since §10.
- **⌘Q** (or Quit in the Dock menu, or `NSRunningApplication.terminate()`): the phantom closes its windows (each sends `closeStream`; the remote windows stay open and the remote app keeps running), says `bye` and quits. If a phantom crashes, Wisp closes its streams when the socket closes.
- **Keys.** As before, while a remote window is key every key goes to the remote, with one exception in phantoms: **⌘Q, ⌘H and ⌥⌘H** (exactly those modifiers, matched by the character typed, as menu key equivalents are) go to the phantom's own menu. The ⌘ press itself has already gone to the remote; its release follows when the window loses focus, as for any focus change. ⌘W, ⌘M, ⌘\` and everything else go to the remote (⌘W closes the remote window). ⌘Tab never reaches an app: the system switches apps.
- **Wisp** is an accessory app (no Dock icon) while connected in phantom mode. Its menu bar list shows the connection state, the host's last refusal, the windows by app, **Disconnect from <host>** and Quit Wisp. Closing the last window keeps the connection. Disconnect or quitting Wisp tells every phantom to quit; a connection that never comes up returns to the chooser with the reason; one lost later shows in every phantom window's status pill. *(Since §11 the app is always a menu bar item and there is no chooser: a connection that never comes up shows an alert with the reason.)*
- **The 3-stream limit**: when the host refuses an `openStream` with `limit`, the menu bar icon becomes a warning triangle with the reason as tooltip, the list shows "<host> streams at most N windows at once: close one to open another" at the top until a window opens, and the phantom of the refused window's app shows it in its key window's status pill for 5 s (an alert if it has no windows) and at the top of its Dock menu.
- **In-process mode** stays: `defaults write com.pier20.Wisp phantoms -bool false` (or `WISP_PHANTOMS=0`) for the app; `wisp view <host>` is in-process unless `--phantoms`.

### 9.6 Testing (loopback, M1 Pro, synthetic host)

`wisp send --synthetic 1600x1000`: windows 1 and 2 belong to "Synth Alpha" (`com.pier20.Wisp.synthetic.alpha`, a blue "A" icon), window 3 to "Synth Beta" (orange "B"). `WISP_TEST_OPEN=3@2 WISP_PHANTOM_TEST_INPUT=4 Wisp.app/Contents/MacOS/Wisp --connect 127.0.0.1`:

- Two bundles were made (then `…/Phantoms/127.0.0.1/<appKey>.app`; now `…/Phantoms/127.0.0.1/<appKey>/Synth Alpha.app` and `…/Synth Beta.app`), bundle IDs `<prefix>.phantom.<16 hex>`, names "Synth Alpha"/"Synth Beta", ad-hoc signed, `codesign --verify --strict` passes, badged icons with the host's 512 px icon (30 KB PNG each).
- `lsappinfo list`: both `type="Foreground"` with their bundle IDs and executables in the bundles; `NSWorkspace.runningApplications`: both `.regular`, Wisp `.accessory`.
- `CGWindowListCopyWindowInfo`: an 800×500 pt window owned by Synth Alpha's pid and a 400×300 pt window owned by Synth Beta's pid, on screen. With `WISP_TEST_OPEN=2,3`, Synth Alpha owned two windows (800×500 and a cascaded 600×375).
- Frames: 60 fps per stream, 120 fps total, for 45 s; the host's per-stream report showed `#1 60 fps · #2 60 fps`.
- Input: the phantoms' posted click and "a" reached the host: `synthetic input: stream #1 (window 1) mouse down … at 0.50,0.53`, `… key 0 down`, and the same for window 3; click→screen 13–32 ms.
- `NSRunningApplication.terminate()` on Synth Alpha: the host logged `stream #1: the viewer closed it (… stays shared)`; Synth Beta kept running at 60 fps.
- Limit (`--max-streams 2`, opening windows 3 and 2): the second was refused and Synth Alpha logged "127.0.0.1 streams at most 2 windows at once: close one to open another".
- Stop Viewing window 3, then `open -b <Synth Beta>` (a Dock click with no windows): window 3 reopened in Synth Beta.
- Terminating Wisp: both phantoms closed their streams and quit. Then `open -b <Synth Alpha>` with Wisp not running: the phantom started Wisp `--connect 127.0.0.1`, which connected, and window 1 appeared in Synth Alpha. `open -b <Synth Beta>` then opened window 3 there.
- 5 % simulated loss (`WISP_DROP=5`) with three streams in two phantoms: repaired in Wisp, frames kept flowing in both phantoms.

**Latency of the cross-process path.** viewer.log's µs breakdown, windows 1 (1600×1000 px) and 3 (800×600 px), steady state, p50/p95 per 5 s window. Both viewers were started through LaunchServices in the background (`open -g`), as a user starts them; a viewer started from a shell gets a higher scheduling role and is faster in every stage (2.2 ms complete→on screen p50), so it isn't a fair baseline.

| | complete → on screen | relay hop | decode | decoded → on screen |
|---|---|---|---|---|
| in-process (stage 2) | 3.48–3.75 / 4.7–5.6 ms | – | 2.8–3.0 ms | 0.59–0.66 ms |
| phantom apps | 3.93–4.08 / 5.1–6.4 ms | **0.21–0.31** / 0.8–1.6 ms | 2.82–2.86 ms | 0.69–0.74 ms |

So the phantom path adds **~0.3 ms p50 (≈0.4 ms p95)** on the viewer: the socket hop, plus ~0.08 ms more to get the decoded frame onto the phantom's main thread. Glass-to-glass this is under 2 % of the loopback total (~20 ms, dominated by the host's encoder).

**Needs a real interactive test** (a person at the viewer, against a real host):
- Dock and ⌘Tab look and feel: icon and badge at Dock sizes, the name in ⌘Tab, App Exposé grouping, pinning a phantom to the Dock and starting it from there.
- Activation: windows coming to the front when chosen from the menu bar list while another app is active (macOS 14+ cooperative activation; LaunchServices' `activates` is used), focus moving between phantoms and local apps, and keys going to the right window afterwards.
- ⌘Q/⌘H/⌥⌘H typed by hand (the local rule), ⌘W and other shortcuts reaching the remote, and the ⌘ release after ⌘Tab.
- Dock menu contents and the Window menu with real titles; the limit notice with real apps; Mission Control and full screen with phantom windows.
- Real app icons from the host (e.g. Safari, Zed) and an icon change triggering a rebuild after the phantom quits (not exercised: the synthetic icons never change).
- Signing with the "Wisp Dev" or Developer ID identity (only ad-hoc was available here).

### 9.7 Deviations from §5

- One socket for all phantoms (`run/viewer.sock`), not one per host: Wisp holds one session at a time.
- No `windowList2`/icon hashes on the wire and no disk icon cache: the host sends the 512 px icon once per app per connection on request, and the bundle keeps the icon it was built from.
- Remote app quitting: its windows' streams end (`windowGone`) and their windows close; the phantom stays open with no windows (like an app whose last document closed) rather than quitting.
- Wisp going away: phantoms quit instead of relaunching Wisp (a phantom opened later starts it).
- No `~/Applications/Wisp Apps` (Launchpad) symlinks.

## 10. Stage 4, part 1: the mirrored menu bar (what was built)

A phantom app's menu bar is the remote app's: its menus, in its order, with their items, shortcuts, checkmarks and enabled states, and choosing an item chooses it on the host. November 2026.

### 10.1 Protocol (host, still protocol 2)

```
menuRequest  18  viewer→host  str appKey, u16 menu        0xFFFF = the whole bar, else one top-level menu (its AX index)
menuPress    19  viewer→host  str appKey, u16 stream, u8 n, n × (u16 AX index, str title)   stream 0 = no window in particular
menuTree    108  host→viewer  str appKey, u8 kind, then:
                   0 bar   u16 count, count × (u16 AX index, str title)    the top-level menus, the Apple menu left out
                   1 menu  MenuNode                                         one top-level menu with its items, ≤ 60000 B
                   2 none  str why                                          not running, no AX menu bar, no Accessibility

MenuNode: u16 AX index, u8 flags (bit0 enabled, bit1 separator, bit2 submenu), then unless a separator:
          str title (≤120 B), str mark, str key, u8 mods (bit0 ⌘, bit1 ⇧, bit2 ⌥, bit3 ⌃), [u16 count, count × MenuNode]
```

Keyed by app like `appIcon`. A whole-bar request is answered by one `bar` message and then one `menu` message per menu, so each fits the 64 KB control message limit on its own (a bigger menu is cut at 60000 B, ~1500 items; Finder's whole bar is 222 items, Zed's 199). `key` is already an `NSMenuItem.keyEquivalent`: a lowercase letter (shift is in `mods`), another character, or a function-key character. An older host ignores the requests and the phantom keeps its minimal menu (§9.5). Types are in `Sources/WispCommon/Menus.swift`.

### 10.2 Host (`Sources/wisp/Host/Menus.swift`)

- **Reading** happens only when asked, on a queue of its own (never blocking input injection on main), with a 1 s AX messaging timeout per app. For each `AXMenuItem` one `AXUIElementCopyMultipleAttributeValues` call reads `AXTitle`, `AXEnabled`, `AXMenuItemMarkChar`, `AXMenuItemCmdChar`, `…CmdModifiers`, `…CmdVirtualKey`, `…CmdGlyph` and `AXChildren`; submenus are followed to depth 5, at most 400 items per menu. An item with no title and no submenu is a separator; one with no title and a submenu (the Help menu's search field) is left out. The shortcut is the character, else the Carbon menu glyph (`kMenu…Glyph`: arrows, F-keys, ⌫, ⎋, ↩, page up/down…), else the virtual key; a bare letter with `kAXMenuItemModifierNoCommand` is a fn/🌐 shortcut (fn-F: Enter Full Screen), which a key equivalent can't express, so it's left out. Measured here: Finder's whole bar (222 items) in 44–93 ms, Zed's (199 items) in 169 ms.
- **The app** is a streamed window's app with that key, else the running app with that bundle ID (or `pid:<n>`).
- **Pressing**: the stream's window is brought forward exactly as before a key press (the Injector's AX raise/frontmost, then LaunchServices if that didn't take), and the item is pressed once the window is there (`Injector.bringToFront(_:then:)`); with stream 0 the app is only made frontmost. The item is found by AX index at each level, its title checked; if the title differs (the menu changed), by title among its siblings; else the press fails. `AXPress` runs on the menu queue: for an item that opens a modal panel it may not return until the 1 s timeout (`cannotComplete`), which counts as delivered. Every press and every failure is logged (`menu: chose File > Save in TextEdit (for stream #2)`, `menu: couldn't choose …: no item "Save" at level 2 (the menu changed)`).
- **Synthetic apps** (`--synthetic`) get a fake menu bar instead (`SyntheticMenus`): app menu (Settings… ⌘,, a disabled Check for Updates…, Services, Hide, Hide Others, Show All, Quit ⌘Q), File (Open Recent submenu, Close ⌘W with its alternate Close All ⌥⌘W, ⇧⌘S, a disabled item), Edit (⌃⌘⌫, and the system AutoFill/Dictation/Emoji items), View (Show Sidebar ⌘B, checked; Show Toolbar, mixed; F5; ⌘←; Enter Full Screen), Window, Help (⌘?). Choosing Show Sidebar toggles both marks; every press is logged as `synthetic menu: Synth Alpha: pressed View > Show Sidebar (stream #1), sidebar now off`.

### 10.3 Phantom (`Sources/wisp/Phantom/PhantomMenus.swift`)

- **When**: the whole bar when the phantom connects, and again when it becomes active (at most every 5 s). Each time a menu opens (`menuWillOpen`, for every top-level menu and submenu), it shows the cached items at once and asks for a fresh copy of its top-level menu; a request isn't repeated while one is out (1.5 s). The reply, one round trip later, updates the menu in place, open or not: same shape → titles, shortcuts, marks and enabled states are set on the existing items (an open menu just changes); otherwise its items are replaced. Choosing an item also asks for its menu again 0.4 s later. `menuWillOpen` rather than `menuNeedsUpdate`: AppKit also calls the latter while matching key equivalents.
- **App menu**: About <App> (remote on <host>) (local), then the remote app menu's own items (Settings…, Check for Updates…, Extensions…), then the local Hide <App> ⌘H, Hide Others ⌥⌘H, Show All, then **Quit <App> on <host>…** and the local **Quit <App> ⌘Q**. The remote About, Services, Hide, Hide Others, Show All and Quit are left out (recognised by title or by their ⌘H/⌥⌘H/⌘Q shortcuts).
- **Remote Quit.** It is shown as "Quit <App> on <host>…", with no shortcut, and asks first ("Quit Zed on my-mac-mini? … If it has unsaved changes, it asks about them in one of its windows on my-mac-mini. To stop viewing it here and leave it running, use Quit Zed (⌘Q) instead."). ⌘Q stays local and only stops viewing, as in §9.5: a remote quit can lose work and can't be undone from here, so it must never be one keystroke away, and the two have to look different. When the remote app has quit, its windows' streams end and the phantom stays with no windows (§9.7).
- **Window menu**: the local one (it acts on the viewer windows: Minimize, Zoom, Full Screen, Stop Viewing…) plus, under a "<App> on <host>" header before Bring All to Front, the remote Window menu's own items (Safari's tab commands, say). The remote Minimize, Zoom, Fill, Center, Move & Resize, Full Screen Tile, Enter Full Screen, tab-bar items and Bring All to Front are left out, and so is its window list (everything after its Bring All to Front): Windows on <host> has those windows.
- **Other menus** are mirrored as they are. Help becomes `NSApp.helpMenu`, so its search field (local) searches the mirrored menus and can choose remote items. The system's AutoFill, Start Dictation and Emoji & Symbols items are left out of the remote Edit menu, and AppKit's own Dictation and Emoji items are turned off in phantoms (`NSDisabledDictationMenuItem`, `NSDisabledCharacterPaletteMenuItem`): they would act on the host's or on a view that takes no text. A remote Enter/Exit Full Screen item acts on the viewer window (local full screen; the remote window follows its size). An item with the previous item's shortcut plus more modifiers (Close / Close All ⌥⌘W) becomes its `isAlternate`, as in the remote app.
- **Marks**: "✓" → on, "-" → mixed, anything else → on. Enabled states are the host's (remote menus don't auto-enable; in the auto-enabling app and Window menus, `validateMenuItem` returns the host's state).
- **Choosing** sends `menuPress` for the stream whose window is key (else the one that was key last, else stream 0).
- **The Window and Help menus are recognised by their English titles**: AX gives nothing else to go by. A remote app in another language gets its Window menu mirrored as an ordinary menu next to the local one.

### 10.4 Shortcuts: shown, not taken

The remote shortcuts appear in the menus, but keys work exactly as before: while a remote window is key, ViewerController's local key monitor sends every key to the remote app (except ⌘Q, ⌘H and ⌥⌘H), which runs its own shortcut there; a local key monitor runs before AppKit looks for key equivalents, so the menus never see those keys. Two more guards cover the times no remote window is key (e.g. the About panel, or no window open), so that a shortcut never presses a remote item by itself: remote menus answer `menuHasKeyEquivalent` with false, and in the mixed app and Window menus (which keep AppKit's matching for their local ⌘Q/⌘H/⌥⌘H/⌘M) a remote item chosen by a key-down that matches its own shortcut does nothing.

### 10.5 Local IPC

Phantom → Wisp `toHost` (11): a complete host message, passed on as is; Wisp lets through only `menuRequest` and `menuPress` naming that phantom's own app. Wisp → phantom `menu` (114): the host's `menuTree`, routed by app key. In-process mode (`phantoms` off) has no mirrored menus: Wisp's own menu bar serves windows of several apps.

### 10.6 Testing (loopback, synthetic host)

- `wisp view <host> --menus <appKey>` prints an app's menu bar as the host reads it, `--press "View>Show Sidebar"` then chooses that item. (It connects as a viewer, so it takes over the host from any other viewer.) Against the synthetic host it printed the fake tree and the host logged `synthetic menu: Synth Alpha: pressed View > Show Sidebar (stream #0), sidebar now off`. The synthetic host runs on a real Mac, so it reads real apps too: `--menus com.apple.finder` and `--menus dev.zed.Zed` printed this Mac's Finder and Zed menu bars (titles, ⇧⌘⌫, ⌘↑, ⌃⌥⌘1 shortcuts, marks, submenus, alternates as separate items, disabled states).
- `WISP_PHANTOM_TEST_MENU=4 WISP_TEST_OPEN=3@2 Wisp.app/Contents/MacOS/Wisp --connect 127.0.0.1` (add `WISP_SOCKET=/tmp/x.sock` to run beside a Wisp in use): 4 s after each phantom starts it logs its menu bar to `phantom.log`, chooses View > Show Sidebar as a click does, reopens View, types ⌘B into its remote window, reopens View again, and chooses the remote Quit (without the confirmation). Result, for both phantoms:
  - the dump matched the fake tree: Synth Alpha's app menu was About (local), Settings… ⌘, and the disabled Check for Updates… (remote), Hide/Hide Others/Show All (local), "Quit Synth Alpha on 127.0.0.1…" (remote, no shortcut), Quit Synth Alpha ⌘Q (local); File with the Open Recent submenu and Close All ⌥⌘W as Close's alternate; Edit without AutoFill/Dictation/Emoji; View with [✓] Show Sidebar ⌘B and [-] Show Toolbar ⌥⌘T, F5, ⌘←; the local Window menu with "Synth Alpha on 127.0.0.1: Tile Synth Windows ⌃⇧⌘T" before Bring All to Front; Help with ⌘?;
  - choosing Show Sidebar reached the host (`synthetic menu: Synth Alpha: pressed View > Show Sidebar (stream #1), sidebar now off`) and the refreshed View menu showed it unchecked and Show Toolbar checked;
  - ⌘B reached the host as keys (`synthetic input: stream #1 (window 1) key 11 down flags 0x100000`, then up), no menu press was logged, and View stayed as it was;
  - the remote Quit reached the host as `pressed Synth Alpha > Quit Synth Alpha (stream #1)`.

**Needs a real test** against a real host, with Zed, TextEdit and Safari:
- Enabled states and titles as the user sees them. They are read as the app reports them at that moment, which depends on its focus and may lag until its menu really opens on the host (seen here: Zed in the background reports most Edit and Selection items disabled). If that's common, the host could bring the stream's window forward before a refresh.
- Shortcut rendering for real apps (uppercase-letter key equivalents, glyph keys, fn shortcuts), and alternates (Safari's Close Tab/Close Window, TextEdit's ⌥ items).
- `AXPress` on items that open sheets, panels or new windows (Save As…, Settings…, New Window): a new window on the host isn't opened here by itself; it must be opened from Windows on <host> (as for ⌘N today).
- Help search on the mirrored menus; the remote Quit with unsaved changes (Zed, TextEdit); round-trip time of a refresh over the real link (the cached menu shows first; the update lands about one RTT, ~150 ms, later).
- Electron and other non-AppKit apps (Zed is GPUI on NSMenu and reads fine locally).

## 11. The app on the tailnet: menu bar, identity, host window (what was built)

November 2026. The chooser window (share or connect, then type an address) is gone; the app is a menu bar item, finds the Macs itself, and the host knows who is connected.

### 11.1 Tailscale as the identity provider (`Sources/Tailnet/Tailnet.swift`)

No pairing and no certificates: Tailscale's WireGuard is the transport security, tailnet membership the access control. Wisp asks the local Tailscale for the tailnet (`/localapi/v0/status`) and for who an address is (`/localapi/v0/whois?addr=<ip>`). The LocalAPI is found the way Tailscale's CLI finds it on macOS (`safesocket_darwin.go`), in its order:

1. Mac App Store app: `lsof -n -a -u<uid> -c IPNExtension -F`, then the port and token from the open file named `…/.tailscale.ipn.macos/sameuserproof-<port>-<token>`.
2. Standalone app (System Extension, "macsys"): `/Library/Tailscale/ipnport` is a symlink to the port; `/Library/Tailscale/sameuserproof-<port>` (0640, group admin) holds the token.
3. Open-source `tailscaled`: `/var/run/tailscaled.socket`.

Over TCP the token is HTTP basic auth with an empty user name. The client is a tiny HTTP/1.0 GET over a POSIX socket (the same code for the Unix socket, which URLSession can't use). If no endpoint answers, `tailscale status --json` / `whois --json <ip>` (the app bundle's CLI or `$PATH`) print the same JSON. Measured on the development Mac (standalone Tailscale 1.104): `wisp tailnet whois` takes 0.10 s as a fresh process through the LocalAPI (including the `lsof` look for the App Store app; the endpoint is then cached), 0.17 s through the CLI fallback (`WISP_TAILSCALE=cli`). `whois` of a node gives the user (login, display name) and the device's name; its `Hostinfo.OS` can be empty.

### 11.2 Access (`Host/Access.swift`, `Server.accept`)

Every TCP connection is decided before it's served: loopback always (the synthetic tests, a viewer on the same Mac); a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48) is identified with whois (cached a minute; failures 5 s) and checked against the allow-list (defaults `allowedViewers`, tailnet logins, case-insensitive; empty = anyone on the tailnet); any other address is refused unless `allowLAN`. A refused connection gets the new `refused` message (a reason the viewer shows: "… isn't on <host>'s list of allowed viewers…", "… only accepts connections over Tailscale…") and is closed. With an allow-list, a Tailscale address that can't be identified is refused; without one it's let in and logged. The host logs and shows the viewer as "Name · device". The viewer's connect timeout went from 3 s to 6 s, since whois may run first. UDP isn't checked separately: a datagram hello must carry the session number from the accepted TCP connection's `helloAck`.

### 11.3 Probe

The menu wants to say which Macs are sharing without becoming anyone's viewer (that would kick the current one). New additive messages: `probe` (u16 version, first message) answered by `probeAck` (version, flags: primary window chosen, viewer connected; open and max streams; host name), or by `refused`; the host then closes. An older host takes a probe for a protocol-1 viewer and answers with its v1 `windowInfo`: the viewer reports "older version". A Mac where nothing listens refuses the TCP connection at once ("Not sharing"); offline peers aren't probed. While the menu is open, the list and the probes refresh every 5 s.

### 11.4 The menu bar item (`App/StatusMenu.swift`, `App/Discovery.swift`)

An `NSStatusItem` with an 18 pt template glyph drawn from the Trail icon (the trail as one stroke, the tilted window with a cleared gap so the trail passes under it), and a plain `NSMenu`, so macOS 26+ draws the glass itself. The first item is a custom view (the Mac, its state and live round trip, an `NSSwitch`); then the host's windows (app icons, checkmarks, "N of 3 open" with the limit from a probe of the connected host); the tailnet's other Macs (status dot, "Sharing" / "Not sharing" / "Offline" as the item's subtitle on macOS 14.4+); Connect to Address…; Share Windows from This Mac… (or Sharing from This Mac… and Stop Sharing); Settings… ⌘,; Quit ⌘Q. Choosing a Mac connects to its MagicDNS short name (the name phantom apps are filed under when typed by hand), else its IP. `ViewerSession` gained `ownMenu: false`: it keeps its state (status, notice, window list, open windows) and calls `onChange`, and the app draws the menu; `wisp view` keeps `RemoteWindowsMenu`. A host with no primary window no longer makes the viewer show "couldn't open that window" for the default `openStream(0)`.

The app is `LSUIElement` and switches to a regular app (Dock icon, main menu) only while the host window, Settings or in-process remote windows are open. First launch with nothing set up shows a welcome popover under the item.

### 11.5 Host window and Settings (`App/HostWindow.swift`, `App/SettingsWindow.swift`)

SwiftUI in AppKit windows: `NSHostingController` with `sceneBridgingOptions` so the SwiftUI toolbar becomes the window's unified toolbar, a `NavigationSplitView` with the system sidebar (glass on macOS 26+), and grouped `Form`s for the System Settings look. Liquid Glass is used where Apple uses it, on controls floating over content: the Disconnect capsule (`.buttonStyle(.glass)`) and the fps badge over each thumbnail (`.glassEffect`), with materials and bordered buttons before macOS 26. Thumbnails are the pipeline's last captured frame scaled with Core Image on the stream's queue, every 2 s while the window is visible. Live numbers come from the viewer's 5 s stats report (RTT, click→screen) and the server's byte and per-stream frame totals (`Counter.total`). Permission rows read state without prompting (`CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`) and their Open Settings buttons first register the app (macOS only lists apps that asked) then open `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture` / `?Privacy_Accessibility`. On macOS 27 Accessibility moved under Device Control and Data Access, but the Privacy & Security extension still answers to `Privacy_Accessibility` (its binary lists the anchor). The screen-lock warning comes from `sysadminctl -screenLock status` (no root needed).

Closing the host window leaves sharing on; Stop Sharing calls `Host.shutdown()`: the server stops listening and drops the viewer, and every stream closes the normal way (window back, its virtual display removed on the lifecycle queue), so a new `Host` can start on the same ports (verified: stop, then listening again 2 s later). Quitting still uses the synchronous `stop()`.

### 11.6 Testing

Loopback test unchanged (3 streams, 0 re-requested). `wisp tailnet` on the development Mac listed its tailnet through the LocalAPI and the CLI; `whois` of its own address named its user and device. Refusal tested from the Mac's own LAN address (probe: "Sharing · not allowed for you"; `view`: the host's reason). The bundled app was launched with `WISP_MENU_DUMP` / `WISP_OPEN`: the status item (18×18 template), the menu tree, the host window (split view, sidebar, two toolbar items), Settings (three tabs) and the welcome popover were built without errors; connected to the synthetic host both in-process and with phantom apps (two windows open, checkmarks, "2 of 3 open", 1 ms). No screenshots: the development session had no Screen Recording permission.

**Needs a real host and eyes:** the menu's and windows' look on macOS 26/27 (glass, spacing, the glyph at 18 pt in light and dark menu bars), the switch's behaviour inside the menu, probes of real hosts on the tailnet, the allow-list with a second tailnet user, thumbnails of real windows, the Open Settings links on macOS 27, and "Share this Mac at login" (`SMAppService`, may need approval in Login Items).

## 12. Native window controls, Dock reopen, new windows that follow (what was built)

From real-world use of stage 3. November 2026.

### 12.1 Native traffic lights

Before, the window's own traffic lights were moved onto the remote ones (the title bar container made taller and each button re-centred after every layout, as Electron's `trafficLightPosition` does), with a patch in the remote title bar's colour (`badgeCover`) hiding macOS 27's purple screen-sharing badge around them. They kept the plain title bar's size, which looked too small next to a toolbar window, and the moving was fragile.

Now AppKit places and sizes them, as for any window. A remote title bar of 40 pt or more (a toolbar window: Finder, Safari, Claude) gets an empty unified toolbar locally, so AppKit gives our buttons the toolbar-window size and placement, which is about where the remote's are. Not always: on a plain 28 pt title bar (Terminal, TextEdit) a unified toolbar would put our buttons below the remote title bar, over its content. The cover now hides the remote traffic lights too: the union of the three remote button rects, padded 14 pt on the sides, 6 above and 10 below (the badge's extent), in the colour sampled right of the remote zoom button. Our buttons are drawn above it (they live in the title bar container, above the content view), wherever AppKit put them.

- Presses on the covered area act like the title bar (a drag moves the window, a double-click does the Desktop & Dock action) but are never sent to the remote: there they would hit the badge. Pointer moves there aren't sent either.
- Red is taken over from AppKit (its ⌥-click on a close button closes every window of the app): a click closes the remote window through `windowAction(close)` (Accessibility on the host), ⌥-click stops viewing. Yellow and green stay AppKit's: minimize here, full screen here, ⌥-green zooms. Hover glyphs are AppKit's own.
- The buttons show whenever the chrome is known, and in full screen; without chrome, on hover over the top strip, as before.
- Removed: `placeStandardButtons`, `restoreStandardButtons`, `savedButtonLayout`, and the local yellow/green handling in `RemoteView`.

### 12.2 Dock reopen with no windows

Seen in a real test: the user closed every Finder window with red (which closes them on the host), clicked the Finder phantom in the Dock, and got "Finder has no windows open on <host>". A local app opens a window then (Finder a new one). Now:

- The phantom (no windows, not expecting one) sends `openWindow(0)` as before. Wisp asks the host for a **fresh** window list first (windows closed a moment ago could still be in the last one) and decides when it arrives: the app's frontmost window if the host has one, else `reopenApp(appKey)` (new viewer → host message 24).
- The host does what a Dock click there would: `NSWorkspace.openApplication(at: bundleURL, activates: true)` on the running app, which makes LaunchServices send it the reopen (`'rapp'`) Apple event; an app that isn't running is launched. No Automation permission is needed, unlike sending the Apple event ourselves. The app's new window then follows (12.3).
- If no window of the app arrives within 5 s (an app that opens none on reopen, or an older host that ignores the message), the phantom says "<App> has no windows open on <host>", as before.

### 12.3 New windows follow

While the viewer shows an app, a new window of it on the host (⌘N, a reopen, a menu item that opens one) opens as a stream by itself, announced with `streamOpened` like any other, so it appears in the phantom like a native new window.

- **Opt-in.** The viewer sets bit 0 of hello's `features` (`Wire.Feature.followsNewWindows`); an older viewer never gets streams it didn't expect from this.
- **Which apps.** Those with a stream the viewer has open, plus those *armed* for 10 s by a `reopenApp` or a `menuPress` for them. Arming lists the app's windows *before* the reopen or the menu press goes out, so the window it makes is new even when the app had no stream (a phantom with no windows, using its menu bar).
- **Detecting new windows.** Polling, every 0.5 s and only while some app is followed: ScreenCaptureKit's on-screen layer-0 windows (`Host.windows()`, async, off the main thread), compared with each followed app's known windows. A window not seen before is checked through Accessibility (the app's `AXWindows`, matched by `_AXUIElementGetWindow`): only `AXWindow` / `AXStandardWindow` opens. Panels, dialogs and floating windows are left alone; sheets aren't in `AXWindows` at all, so after 4 looks (2 s) they're given up on. Chosen over an `AXObserver` (`kAXWindowCreatedNotification`) because the poll works the same for every app, including ones whose AX notifications are unreliable, needs no per-app observer to set up and tear down, and keeps WindowServer and AX calls on the main thread to one gated place: the poll skips while `DisplayGate.busy`, and the AX check runs in `DisplayGate.whenIdle`.
- **Never twice, never back.** Every window seen goes into the known set, whatever happened to it. A window the user stopped viewing (⌥-red, Stop Viewing) was known while it was streamed, so it doesn't come back; an app that stops being followed forgets its set, and when it is followed again everything it has then counts as known.
- **The limit.** With `maxStreams` (3) streamed already, the host keeps the window aside and sends `newWindowHeld` (host → viewer 115: window ID, app key and name, open, max). The viewer shows "<App> opened a new window on <host>; 3 windows are already open — close one to see it" in the menu bar notice and the app's phantom (its key window's status pill, or an alert with no window open), and beeps. When a stream closes, held windows open in order while there's room.
- A new viewer, or none, forgets everything followed and held.

### 12.4 A window that isn't there yet

"couldn't open window 1507: the window isn't available on the host" happened once in a real test, and the same window opened fine 30 s later: most likely ScreenCaptureKit's list was a moment behind (the window just made, or just back from another Space). `startStream` now looks the window up again every 250 ms for up to 1.5 s before refusing (it runs in the `serially` chain, so other opens wait that long at most).

### 12.5 Synthetic host and testing

The synthetic host's windows now come and go: closing one removes it; reopening its app, its File > New Window, or `wisp poke … action new-window` (`windowAction` 2, synthetic host only) adds one to that app (IDs from 4, never reused). Loopback, with the bundled app in phantom mode and the `WISP_*` isolation variables:

- Window 3 (Synth Beta) closed with `poke action close`; `open "…/Synth Beta.app"` (LaunchServices' reopen, as a Dock click) → "Synth Beta has no windows on 127.0.0.1: asking it to open one" → host "synthetic: Synth Beta opened window 4 (reopened)", "follow: streaming …" → the Beta phantom showed stream #3 about 1 s after the click.
- `poke --stream 3 action new-window` → window 5 opened in the Beta phantom by itself, within one poll.
- With 3 open, `poke --stream 1 action new-window` → Alpha's window 6 held; the Alpha phantom logged the notice. Stopping viewing window 5 (`WISP_TEST_CLOSE=5`) opened window 6 at once; window 5 didn't come back.
- In-process (`wisp view --snapshot`), a new window followed as stream #2; `wisp view --menus … --press "File>New Window"` made and streamed one too.
- Loopback regression test unchanged: 3 streams, 0 re-requested.

**Needs a real host and eyes:** the native buttons' size and place against real remote title bars (Finder, Safari, Terminal; host and viewer on different macOS versions), the cover over the remote lights and badge, drags and double-clicks next to our buttons; Finder (and other apps) actually opening a window on the LaunchServices reopen; which real "new windows" pass the standard-window check (Safari's ⌘N, Finder's ⌘N, a Settings window, Open/Save panels, which shouldn't); and whether the 1.5 s retry is enough for the window that wasn't found.

### 12.6 Logs that explain a failure (what was built)

A viewer on a Mac shared in from another tailnet sat on "Connecting…" with nothing in the log: it connected by a MagicDNS short name that only resolves in the sharer's tailnet (fixed in 1.0: connect by IP, give up after 15 s), and the only file the app wrote was `host.log`, on the viewer too. Now:

- `Log` (WispCommon/Log.swift): levels and categories, `<date time.ms> [pid] LEVEL category message`, one file per kind of process (`wisp.log`, `phantom-<App>.log`, `cli.log`; `viewer.log` became `latency.log`), rotated at 5 MB × 3, mirrored to the unified log (subsystem = the bundle ID). Debug only with Verbose logging / `WISP_VERBOSE=1`. A file per phantom rather than one shared `phantom.log`: each phantom is its own process, so separate files don't interleave and rotate independently, and a misbehaving app's log is found by its name; writes use O_APPEND, so two phantoms of one app name (two hosts) can still share a file safely.
- The viewer logs how the address will be reached, each TCP/UDP state with its path (interface: utun for Tailscale), DNS errors decoded, a line at 3, 8 and 14 s while it waits, hello/helloAck with versions and feature bits, and the give-up. The host logs listeners, connections, access decisions with whois results and timings, virtual display, capture and encoder lifecycles. Probes and loopback connections are debug: a host sees one per viewer menu every 5 s.
- Copy Diagnostics / `wisp diagnostics`: versions, permissions, settings, Tailscale peers with what the menu last probed, the end of `wisp.log`; other people's logins hashed.

The stuck connection of `--connect no-such-mac.invalid` now reads: `TCP no-such-mac.invalid:7878 waiting (DNS error -65554: no such record) after 0.0 s; path: satisfied via en0 (Wi-Fi), → no-such-mac.invalid:7878`, the same at 3, 8 and 14 s, then `WARN viewer giving up … after 15 s`.

## 13. Clipboard sync (what was built)

Copy on the viewer and paste in a remote window; copy in a remote app and paste anywhere on the viewer. `Sources/wisp/Clipboard.swift` (`ClipboardSync`, main queue), one instance per connection on each side: in `Host` (the app's host and `wisp send`) and in `Client` (made by `syncClipboard()`: the app's `ViewerSession`, `wisp view`). Phantoms need nothing: they share the viewer's system pasteboard, and the main process syncs it.

**Protocol** (still protocol 2, additive). Opt-in both ways with hello's `Wire.Feature.clipboard` (bit 1): the viewer sets it in hello, the host in helloAck (`Server.hostFeatures`); each side sends clipboard messages only to a peer that announced it, so an older peer never sees one. Viewer → host 30–32, host → viewer 130–132, the same layouts:

```
clipboardBegin   30/130  u32 id, u32 total, u8 n, n × (str UTI, u32 bytes)   one item's representations, in order
clipboardChunk   31/131  u32 id, u32 offset, ≤ 60000 B                       the next bytes of transfer id
clipboardState   32/132  u8 on                                               this side's setting; after hello and on change
```

A begin with a newer id replaces any transfer in flight on the receiver; a chunk out of step drops it. Nothing is sent to a side that said `on = 0`, and a side that is off ignores what arrives. The host takes clipboard messages only from the current, admitted viewer (`Server.handle`: not a side channel, not a replaced viewer), so the allow-list and access rules apply as for input.

**Sending.** While connected, each side polls `changeCount` every 0.4 s (there is no notification). A change it didn't make is read from the first item: `public.utf8-plain-text`, `public.rtf`, `public.html`, `public.png` (or `public.tiff` converted to PNG: 83 KB of TIFF became 3.8 KB in the test), and `public.url` (not file URLs), also as text if there's none. Never sent: anything with `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType` on the pasteboard (what password managers set), files (`public.file-url`: not in this version), and representations past the cap (10 MB, defaults key `clipboardMaxBytes`; kept in order, so text goes and a large image is left out; logged). Chunks are queued at most two at a time on the connection (`sendControl(_:done:)`, completion `.contentProcessed`), so a 10 MB copy doesn't put megabytes in front of a mouse-up; a newer copy abandons the old transfer. Nothing on the clipboard at connect time is sent, only new copies.

**No echo loop.** The receiver writes the item with an extra empty type, `app.wisp.clipboard-sync`, and remembers the `changeCount` its write produced. A change with that count, or with the marker type on the pasteboard, is never sent. The marker matters on loopback with both ends on one pasteboard: the host's write is a change the viewer didn't make. Last writer wins: an item that arrives also stops a copy of ours still going out.

**Settings.** Viewer: "Share clipboard with remote Macs" (Settings › Viewing, `shareClipboardWithHosts`); host: "Share clipboard with viewers" (Settings › Sharing, `shareClipboardWithViewers`); both on by default, read on every poll and told to the peer at once. `wisp send --no-clipboard`; `wisp send --synthetic` and `wisp view --snapshot` sync only with `WISP_PASTEBOARD` (or `--clipboard` for send), so loopback tests never touch the real clipboard. `wisp view --windows / --menus` and `wisp poke` never sync.

**Logging** (category `clipboard`): info when sync starts and ends (with counts), when a side turns on or off, and when something is left out for files or size; debug for each copy (`#3 → host: public.utf8-plain-text 7 B (7 B in 1 chunk)`, `#2 ← viewer: public.png 986193 B`) and each skip for privacy. Types and sizes only, never contents.

**Testing** (loopback, M1 Pro): `swift scripts/clipboard-test.swift` runs a synthetic host and a headless viewer in two processes with private named pasteboards (`WISP_PASTEBOARD`), copies on each and checks the other: text viewer → host; text + RTF + HTML host → viewer; a 986 KB PNG (17 chunks) viewer → host; TIFF host → viewer arriving as a 200×100 PNG; concealed, transient and auto-generated items not sent; a file URL not sent; with `WISP_CLIPBOARD_MAX=3000000`, text + a 3.3 MB PNG → the text only, the PNG alone → nothing; a URL arriving as text; two copies 0.45 s apart → the last one wins. Then it counts the transfers in both logs: host sent 3, viewer sent 5, each applied once on the other side, nothing echoed; no contents in either log. The app as viewer (`--connect`, private pasteboards) synced both ways too. Loopback video regression unchanged (3 streams, 0 re-requested).

**Needs a real host:** paste in real apps on both sides (TextEdit RTF, Safari HTML, Preview images, Terminal), password managers (1Password, Bitwarden, the Passwords app) actually marking their items, a big image on a slow tailnet link (click latency while 10 MB goes up: the socket buffer, not just our two chunks, is the queue), apps that put promised (lazy) data on the pasteboard, and clipboard history apps on either side (they see each synced item as a new copy).

## 14. Open and Save panels, dialogs: shown in their window's stream (what was built)

From real use, November 2026: in Claude (Electron), "Open Folder…" showed an Open panel on the host that the viewer never saw.

### 14.1 What macOS does

Probed on macOS 27.2 with a small test app (an NSOpenPanel on its own and as a sheet, an NSSavePanel, the colour and font panels, an alert sheet, the print panel), reading the window list, Accessibility and the processes:

- **Open and Save panels run out of process, but their window is the app's.** The window is in the app's own `CGWindowList` entries (owner = the app, layer 0); Accessibility lists it as an `AXWindow` / `AXStandardWindow` with `AXIdentifier` `open-panel` or `save-panel` and no close, minimize or zoom button. Its contents are drawn by an XPC service launched for that app, `com.apple.appkit.xpc.openAndSavePanelService`, named "Open and Save Panel Service (<App>)", with a `QuickLookUIService` named "QuickLookUIService (Open and Save Panel Service (<App>))" for previews. Neither had an on-screen window of its own. Both are *responsible* to the app (`responsibility_get_pid_responsible_for_pid`, what TCC uses to attribute an XPC service's requests); system-wide UI (AutoFillPanelService, ViewBridgeAuxiliary, UserNotificationCenter with the permission prompts) is responsible for itself.
- **On its own** (`NSOpenPanel.begin`, Electron's `dialog.showOpenDialog` without a window) the panel is centred on the main display, so it is outside the crop of a window on its virtual display: the viewer never sees it. Being an `AXStandardWindow`, it also passed §12.3's new-window check, so a viewer that follows new windows could get it as a stream of its own, using one of the three slots.
- **As a sheet** it is an `AXSheet` child of the window (identifier `open-panel`), positioned under the title bar and centred, and wider than a small window (880 pt for a 500 pt window): the overflow is outside the crop.
- The **colour and font panels** are in-process `AXFloatingWindow`s (layer 3) at their own remembered places, shared by all of the app's windows. **Alerts and the print panel** are in-process sheets. The share sheet is an in-process menu; a share extension's UI is hosted in the app the same way the Open panel is (not probed).

### 14.2 What the host does (`Host/Panels.swift`)

- **Detection.** `PanelTracker.tick`, every 0.25 s on the main queue while a real window is streamed, never while a virtual display is being added or removed: lists the on-screen windows (`CGWindowListCopyWindowInfo`, layers 0–19, so not menus, pop-ups or tooltips; at least 60x40 pt) and takes as a stream's panel any window that isn't streamed and is either owned by a process responsible to the stream's app (an out-of-process panel or preview, whatever service it is), or owned by the app and, per Accessibility, an Open/Save panel (identifier), a dialog (`AXDialog`, `AXSystemDialog`), a modal window, or an `AXFloatingWindow` that wasn't there when the app was first streamed (the colour panel just opened, not an inspector the app always shows). Each window is classified once (sheets and popovers aren't AX windows: given up on after 4 looks). Without the private responsibility call, a service is matched by the "(<App>)" its name ends with.
- **Association.** With the app's only stream; else the one its frame lies over; else the one that got the last click, key, scroll or menu item (within 15 s); else the app's first. Logged with the reason and the app that had focus, e.g. `panel: Open panel 9639 of Claude appeared at 424,174 880x448 (layer 0); with stream #2 (it got input 310 ms before); focused: Claude`. A window is only ever taken for the app that owns it or that its owner works for: never another app's.
- **Placement.** If it isn't inside the window already (a sheet, a dialog the app put there), it is moved through Accessibility over the window like a sheet: centred horizontally, its top at the bottom of the title bar (the stream's chrome, 28 pt at least). If it's larger than the window it is first asked to shrink to fit (an Open panel accepts down to its minimum); what still doesn't fit overflows to the left (right edges aligned) and upwards (bottom edges aligned), so the Open/Cancel buttons stay in view. **The window is not grown for it**: that would resize the viewer's window too, would have to be undone when the panel closes, and the window may already be as large as its display. It is moved again if something moves it out (at most 4 times, then logged and left). Nothing is undone when it closes; the closing is logged.
- **Capture.** The filter of each stream now includes, besides its app, the processes responsible to it that ScreenCaptureKit lists (`stream #2: capturing Claude with Open and Save Panel Service (Claude) (pid …)`), less the app's other streamed windows, as before. The panel's window itself is the app's, so it was always in the filter; the services are included in case their layers or windows (a Quick Look preview) need it. When a panel of a service not yet in a stream's filter appears, that app's filters are refreshed.
- **No stream slot.** §12.3's follow logic skips windows that are panels (and `isStandardWindow` says no to an Open/Save identifier), and the viewer's window list leaves them out.
- **Input.** `WindowTarget.panels` (window ID → owning process) is kept up to date. The injector treats a panel as part of its window: a click on it doesn't count as "covered by another window" (so the window isn't raised over its own panel); a key press while the panel has focus doesn't pull focus back to the window; a process showing one of its panels counts as the app being frontmost; and when the window does have to be brought forward, its panel is raised instead of the window (raising the window and making it main could put it over its modal panel). Keys then go where the window server sends them: the key window, which is the panel.

### 14.3 Synthetic host

`wisp poke … action open-panel` (`windowAction` 3, synthetic host only; Protocol.swift's comment only, no new message) or File > Open… from the mirrored menu: the stream's app opens a fake Open panel "owned" by "Synth Panel Service (<App>)". It appears where a standalone panel would (right of the window), goes through the same `PanelTracker.associate` and `PanelPlacement`, is drawn into the stream's frames by `SyntheticSource`, and logs the same `panel:` lines. One per app, as an app-modal panel. Escape or Return, or a click on its Cancel or Open button, closes it; other clicks and keys in that window go to it (logged). Loopback, 3 streams: panels opened on window 3 (400x300 pt, smaller than the 560x340 pt panel: shrunk to its 440 pt minimum width and overflowing 40 pt to the left, buttons in view), closed with Escape; on window 2, a click outside it ignored, a click on Cancel closed it; on window 1 (association by "it got input 0 ms before"), a key routed to it. The snapshot PNGs show each panel composited into its stream; 0 re-requested. (The frame rate on the development MacBook dropped from 60 to about 46 fps after 3 s in every run, with or without panels: encoder contention there, not this change. Drawing a 40 px shadow under the fake panel every frame did cost ~10 fps, so it has an outline instead.)

**Needs a real host and eyes** (the development Mac has no Screen Recording):
1. Claude: File > Open Folder… with Claude streamed on its virtual display. The host log should show `panel: Open panel … of Claude appeared …; with stream #N (…)` and `panel: moved …`; the viewer should see the panel over the window, with its **contents** (not a blank or transparent rectangle: if the remote-drawn contents are missing from an app-filtered capture, the filter has to become display-based while a panel is open). Then pick a folder by click and by typing (⇧⌘G, a path, Return): keys must reach the panel, and the Claude window must not come over it.
2. The same as a sheet (TextEdit: File > Open… with a small window, or Save): the sheet is captured; a sheet wider than the window is cropped (not moved: sheets move with their window).
3. Two streamed windows of one app (two TextEdit documents): Open from the second one's menu: the panel goes with stream #2.
4. The colour panel (TextEdit: Format > Font > Show Colors) moves over the window; an app's inspector open before streaming stays where it is.
5. Quick Look in the Open panel (space on a file): whether the preview has a window of its own (`QuickLookUIService` owner) and shows.
6. With the viewer following new windows, an Open panel must not open as a stream (`follow: … is a panel` or `isn't a standard window`).
7. A permission prompt ("<App> would like to access files in your Documents folder"): system-wide (UserNotificationCenter), so not shown; the user has to answer it on the host. Worth seeing how often that bites.

## 15. Stalls: seen, told and recovered from (what was built)

Reported from real use: "the stream gets stuck after a while": the window stops updating on the
viewer while the connection otherwise seems alive, and nothing in the log says why. Every place a
stream can stop was instrumented, and the causes that could be confirmed by reading the code were
fixed. One shape for all of them (`StallEpisode`, `Sources/wisp/Stall.swift`): a `WARN STALL <what>:`
line when it starts (what is stuck, the evidence), an info line per recovery step, an info line
when it ends (`over after N s: <what ended it> (steps taken: …)`); at most one start line per thing
every 10 s. Details at debug. Table of subjects: docs/testing.md "Stalls".

**Bugs found by reading, fixed:**
- *A broken decoder session was kept for good* (`Decoder`, viewer and phantoms). The session was
  remade only when the parameter sets changed; one invalidated by VideoToolbox (sleep, a GPU or
  media-engine reset: kVTInvalidSessionErr) failed every frame, every keyframe asked for failed
  too, and the window froze until the connection ended. Now any failed frame drops the session, and
  the next keyframe makes a new one (`decoder session #2 made … (after a failure: OSStatus -12903)`).
- *A broken encoder session too* (host). It was remade only on a size change; now a session that
  returns kVTInvalidSessionErr or fails 10 frames in a row is replaced (`STALL stream #N encoder`).
- *The encoder's in-flight count could stick.* `pending` went up per frame and down per callback
  (or error return). A frame VideoToolbox never answered for left it high for good, and with two
  stuck every later frame was skipped as "busy": nothing sent again. Now each frame has a sequence
  number; its callback or error removes it exactly once (so an error return that also calls back
  can't count twice); frames waiting over 1 s are given up on (their late outputs dropped, a
  keyframe forced), and if that happens again within 30 s the encoder is replaced (without waiting
  for its frames in deinit). Frames VideoToolbox reports dropped are counted; a dropped forced
  keyframe is forced again.
- *The viewer's UDP flow, once failed, was never replaced*: a receive error ended the receive loop
  ("video stops") for the rest of the session. Now a failed flow or receive error makes a new flow.
- *A frame the host no longer has* (NACK for a frame out of the 240-frame resend cache, e.g. after a
  long gap) waited for the viewer's 1 s timeout before a keyframe; the host now sends one at once
  (at most one a second per stream).

**Host.** `HostHealth` (`Host/Health.swift`, own queue, 1 s): per stream, "the window is changing
(frames captured or encoded) but nothing sent for 3 s" with the encoder's in-flight state, skips and
the UDP path; "three clicks or key presses over 3 s and no frame from ScreenCaptureKit" (logged only:
the window may ignore the input; Capture.swift was left alone); a health line every 5 s (captured,
encoded, refinements, forced keyframes, sent, skipped busy, NACKs served and those too old, last
capture and send, encoder in flight) at debug, at info when something looked wrong; a send-path line
(UDP peer and state, pacer backlog and longest wait, send errors). UDP sends now have a completion:
errors are a warning at most every 5 s (they were invisible with `.idempotent`). The video flow's
state changes are logged, and a hello from a new flow of the same session (new source port, NAT
rebinding) moves the video there: `video path (UDP) moved: A → B`, the old flow cancelled, keyframes.

**Viewer.** Per stream (`RemoteStream.checkStall`, every 0.5 s on the client's queue): no frame
decoded (or relayed to a phantom) for 2 s while video for it keeps arriving, a frame is half-received
or a keyframe is awaited, is a stall, logged with next/highest frame, incomplete frames and their
missing chunks, keyframe asks, NACKs, FEC, decoder state. After 3 s (and every 3 s after): flush
reassembly, a new decoder if it failed, a keyframe request. An idle window (nothing arriving, nothing
pending) is not a stall. The video path (`Client.checkVideoPath`, 1 s): the host now echoes each UDP
hello (`helloEcho`, datagram kind 5, additive: older viewers ignore it); with echoes seen, nothing
over UDP for 3 s while pongs arrive is "video path silent": the hello is sent again at once, after
6 s a new UDP flow. Without echoes (an older host) the path isn't judged, since idle windows send
nothing. The hello timer is checked too (restarted if it stopped for 3 s). Display
(`DisplayWatch`): a decoded frame waiting 2 s to be shown, with whether the main thread answers
(`MainThreadWatch` pings it every 0.25 s from a background queue, in every process); if it does,
the show is scheduled again. Phantom relay: over 60 frames queued to a phantom that isn't reading,
frames are dropped until it catches up, then it restarts from a keyframe.

**Fault injection** (`WISP_FAULT`, `Fault` in Stall.swift): host `encoder-stall` (two callbacks
lost), `encoder-hang` (every encoder silent for 5 s), `encoder-invalid` (kVTInvalidSessionErr for
1 s); viewer `udp-drop-all-for=<s>`, `decoder-fail-once` (the session fails every frame until it
is replaced: the old code never replaced it), `main-block=<s>`. Each says `FAULT` in the log.

**Tested** (loopback, synthetic host, this Mac): each fault produces its STALL lines and recovers:
encoder-stall in ~1 s (in-flight reset, keyframe); encoder-hang: reset, then a new encoder each
second, `STALL stream #1 host: … nothing was sent` at 3 s, over at 5.2 s; encoder-invalid: a new
encoder in 20 ms; udp-drop 5 s: video path silent at 3 s, over at 5 s, both streams flushed and
back on a keyframe within 50 ms; udp-drop 10 s: a new flow at 6 s, the host logs the move, back at
10 s; decoder-fail-once: a new session 42 ms later (also in a phantom); main-block 3 s: main-thread
and display stalls, over when it answers. The loopback regression is unchanged (3 streams ~60 fps,
0 re-requested; `WISP_DROP=5` repaired by FEC and NACKs, 0 keyframe requests), clipboard test passes.

**Needs a real host:** which of these the reported freeze actually is. The log of the next one
should say: a `STALL` line names the side and the stage. Sleep/wake of either Mac (the decoder and
encoder fixes), Wi-Fi changes on the viewer (the UDP flow), and a ScreenCaptureKit capture that
stops without `didStopWithError` (logged as `STALL stream #N capture`, not recovered yet: it would
need the host to restart that capture).

## 16. Input fidelity: scrolling, and an end-to-end test (what was built)

Reported from real use: "scroll breaks" on a MacBook viewer over the ~150 ms link to the UK (the
device unknown: trackpad, Magic Mouse or wheel). Every test so far used the synthetic host, which
logs clicks but can't show what an app receives. So first a harness that can (docs/testing.md
"End-to-end input and freshness"), then the scroll path read end to end and fixed against it.

**The harness.** Host side: `WispProbe.app` (a SwiftPM target of its own, `scripts/bundle-probe.sh`,
ad-hoc signed, no permissions): three windows, each a scroll view of numbered rows under a frame
counter redrawn every display refresh, recording everything they receive (InputRecord JSON lines:
what the scroll view got, clicks with click counts, drags, keys with characters and modifiers,
resizes). Over loopback the synthetic host plays it: with `WISP_INPUT_LOG` its injector builds every
event as it would post it and records the NSEvent an app would get (so the injector's event building
is under test even without Accessibility). The counter is also drawn as `FrameCode` squares (two rows,
the second inverted, so a misread is caught) that the viewer reads back from each frame it shows.
Viewer side: `wisp e2e` opens the windows in ordinary viewer windows and gives RemoteView the
NSEvents AppKit would (trackpad and Magic Mouse gestures with phases and momentum, smooth-scrolling
mice, wheel ticks in lines, flicks, clicks, drags, keys, resizes; in a background window and as the
key window; a soak mode of random rounds across three windows), then compares, per window and
gesture, what the host's app received. `WISP_NET_DELAY_MS`/`_JITTER_MS`/`_LOSS` (Viewer/NetEmu.swift)
emulate the UK link over loopback, TCP head-of-line blocking included; `WISP_FAULT=focus-hold` /
`focus-stuck` make the synthetic host raise windows and hold input as a real host does.

Two things the harness had to learn: AppKit drops made-up momentum scroll events sent through a
window (real ones reach the view the gesture latched onto), so those go to the view directly; and
pointer moves reach a view through its tracking area, not sendEvent. Input from the test Mac's own
mouse and keyboard (someone using it, or Screen Sharing) is dropped by the runner's NSApplication:
before that, a keys-only run on this Mac, in use at the time, "received" scrolls nobody sent.

**Bugs found, fixed** (first run of the scripted pass on the old code: 30 failures in 27 gestures;
after: 0, also over `--net uk` and with `focus-stuck`):
- *Scrolls landed where the pointer last was, not under it.* The scroll message carried no position:
  the host scrolled at the last injected pointer position. A viewer window sends pointer moves only
  while it is key, so scrolling a window beside the one being worked in (or any window, if the viewer
  app wasn't active) scrolled whatever was at its centre or at the last click: the sidebar instead of
  the list, nothing at all over a static area. Even in the key window a gesture's first message could
  beat the coalesced move to the host. Every scroll in a background window failed this. Now each
  message says where the pointer is and the host moves its pointer there first.
- *A wheel mouse arrived as a trackpad.* Line deltas were sent ×16 as points, posted as a precise,
  phaseless pixel scroll: the app saw "trackpad, 16 pt a line" instead of a wheel (15.25 lines sent,
  244 precise points received): apps that scroll a wheel by their own line height, or treat precise
  phaseless scrolls differently (terminals, editors, Chrome), scrolled too little or oddly. Now a
  flag says "1/16 lines" and the host posts a line scroll (whole lines in the integer field, the
  fraction in the fixed-point field, points from the source's pixels-per-line), as a local wheel does.
- *An extreme flick ended a dozen times.* More than an i16 piled up in one 1/60 s was clamped and the
  rest kept for the next flush, which went out after the gesture's "ended" with the ended phase again:
  12 extra ends. Now a flush sends everything, in as many messages as it takes, the boundary phase on
  the first (a start) or the last (an end).
- *Every wheel tick could raise the window and hold input.* Before a plain wheel tick (and at a
  gesture's start) the injector checked "is this window's app frontmost and on top" and if not
  brought it forward, holding input 60 ms (longer through LaunchServices). Scrolls go to the window
  under the pointer whether its app is in front or not, so this only stole focus (scrolling one
  streamed app's window activated it), cost a window list and an AX query per tick, and with an app
  that can't come forward held every tick: `focus-stuck` raised windows 96 times in 27 gestures, a
  stutter of 60 ms holds. Now scrolls check only that no other window covers the spot (none does with
  a virtual display per window), once per gesture or burst of ticks; never a raise for focus.
- *A held raise could hold input for good.* If the activation never finished (LaunchServices not
  calling back), every later click, key and scroll was queued forever. The hold now ends after 1 s
  with a `STALL input to window N` episode.
- *Gestures left open.* A stream closed or a viewer gone mid-gesture left the app mid-scroll
  (rubber-banded, waiting for momentum); now the host ends it. A "changed" whose "began" never came
  (a window opened mid-gesture) gets a began first.
- *The host's own keyboard leaked into injected scrolls and clicks.* Events made from the HID state
  source take that Mac's physical modifiers: a Shift held on the host (in the soak: on this Mac,
  in use) turned the viewer's wheel scroll sideways (3 failures in a 10-minute soak, all "Σdy
  received as Σdx"). Mouse and scroll events now carry the viewer's modifiers, from its last key
  message, so a ⌘-click from the viewer is a ⌘-click and nothing from the host's keyboard gets in.
- The viewer's coalescing timer ran only in the default run-loop mode: during any tracking loop its
  pending moves and scrolls waited. Now in common modes.

Checked and fine: phase and momentum mapping NSEvent → CGEvent (began 1, changed 2, ended 4,
cancelled 8, mayBegin 128; momentum begin 1, continue 2, end 3); natural scrolling (the viewer's
scrollingDelta already has the viewer's direction; a posted event isn't inverted again); fractions
carried between flushes (now never mixed between points and lines); a 60 ms hold mid-gesture keeps
the gesture whole (held events are replayed in order); stall recovery (the video path, decoders)
doesn't touch input, which is on TCP. What the link does: 1–2 % loss stalls TCP for a retransmission
timeout now and then, so input arrives in bursts behind it (the emulation reproduces this); totals
and phases survive, the picture of a gesture is jerkier. Not fixed here (it would need input over a
path without head-of-line blocking).

**Wire.** `scroll` gains, after the momentum phase, `u8 flags` (bit 0: 1/16 lines) and `u16 x, u16 y`
(as in mouseMove). Additive: an older host ignores them (and scrolls lines as 16 pt points, as
before); from an older viewer the host scrolls points at the last pointer position, as before.

**Tested** (loopback, synthetic host, this Mac): scripted pass, all scenarios in three windows, 27
gestures and 201 clicks/keys: PASS; the same with `--net uk` (rtt 156–160 ms, 1.5 % loss): PASS;
`focus-stuck`: 0 raises while scrolling (96 before). Soak, `--net uk --fault focus-hold`, 10 min:
28 rounds, 366 gestures, 1427 clicks/keys, 3 failures, all wheel scrolls turned sideways by this
Mac's own Shift (fixed: the modifiers bullet above); after the fix, a second soak passed its first
two rounds before it was stopped (this Mac was in use: long soaks belong on the Mini,
`scripts/soak.command`). Freshness held throughout (longest freeze under 1 s, every frame's counter
read) except when this Mac's own main thread stalled under load.
`WispProbe --selftest`: counter read back in all three windows, events recorded.

**Needs a real host** (WispProbe on the Mini, the viewer here; docs/testing.md): that injected line
scrolls, momentum and click counts reach a real app as recorded here (posted events go through the
window server, which the synthetic host skips), that moving the host's pointer for a scroll is
harmless, and the soak over the real link.

## 17. Open questions

- The M4's real session and throughput limits (§2.6). They set the stream cap and the unfocused-stream policy.
- Whether a headless host makes several virtual displays reliably (§8.1). Non-overlapping layout (§3) depends on them, and BetterDisplay's virtual screens survive reboots, but `CGVirtualDisplay` is private.
- `_AXUIElementGetWindow` is private API. It has been stable for years, but a fallback is needed (§2.5).
- Phantom ⌘Q is "stop viewing and quit the phantom" (§9.5); quitting the remote app is the separate, confirmed "Quit <App> on <host>…" (§10.3). Whether people find that split natural needs real users.
