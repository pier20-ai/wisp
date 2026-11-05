# Testing and debugging

Most of Wisp can be tested on one Mac, over loopback, with a synthetic host that needs no
permissions. Commands below use `wisp` for `.build/release/wisp` (after `swift build -c release`)
or `Wisp.app/Contents/MacOS/Wisp`.

## Loopback

```bash
wisp send --synthetic 1600x1000                          # terminal 1: a host with 3 animated test windows
wisp view 127.0.0.1 --snapshot out.png --open 2,3        # terminal 2: decode 3 s, save frames, print stats
```

- `--snapshot out.png` saves the last frame of each stream (`out.png`, `out-2.png`, `out-3.png`)
  and prints per-stream stats. `--close 2@3` closes stream 2 after 3 s while the others keep going.
  `WISP_SECONDS=10` decodes for longer.
- Without `--snapshot`, `wisp view 127.0.0.1` opens the windows on screen (in-process; add
  `--phantoms` for phantom apps).
- The synthetic host offers windows 1, 2 and 3 (800x500, 600x375 and 400x300 pt for `1600x1000`),
  each with its own colours and animation. Windows 1 and 2 belong to a fake app "Synth Alpha",
  window 3 to "Synth Beta", each with its own icon and a fake menu bar. Injected input and menu
  presses are logged (`synthetic input: …`, `synthetic menu: …`) instead of applied.
- Its windows come and go like real ones: closing one (`wisp poke … action close`, or a click on
  its red button) removes it; reopening its app (`reopenApp`, a phantom's Dock icon clicked with
  no windows), its File > New Window or `wisp poke … action new-window` adds one to that window's
  app (IDs 4, 5…, never reused). With a viewer connected, a new window of an app the viewer shows
  opens as a stream by itself (`follow: …` in the host log).
- Its apps open a fake out-of-process Open panel (`wisp poke … action open-panel`, or File > Open…
  from the mirrored menu): owned by "Synth Panel Service (<App>)", it "appears" outside the window,
  is associated with one of the app's streams and moved over it like a sheet (`panel: …` lines,
  category `capture`), and is drawn into that stream's frames: the snapshot PNG shows it. One per
  app. Escape or Return (`poke … key 53` / `key 36`) or a click on its Cancel or Open button closes
  it; other clicks and keys in that window go to it (logged), as with a modal panel. Window 3
  (400x300 pt) is smaller than the panel, so there it overflows to the left, keeping its buttons in view.
- Only one host can listen on TCP 7878 / UDP 7879: a second `wisp send` exits with an error
  naming the process that holds the port.

## End-to-end input and freshness

The synthetic host shows that streams flow and clicks arrive, not what an app actually gets. The
end-to-end test drives the real viewer code with the events a trackpad, a Magic Mouse, a wheel
mouse and a keyboard produce, and checks what the host's test windows received, event by event,
and that their picture keeps moving.

```bash
swift build -c release
scripts/e2e.sh                              # loopback: every scenario in synthetic windows 1, 2, 3 (~1 min)
scripts/e2e.sh --net uk                     # the same over an emulated 150 ms, 1.5 % loss link
scripts/e2e.sh --net uk --soak 10           # 10 minutes of random input across the 3 windows
scripts/e2e.sh --fault focus-stuck          # a host whose windows never come forward: scrolling must not care
scripts/e2e.sh -- --seed 42 -v              # anything after -- goes to `wisp e2e` (-v: a line per gesture)
```

**A long soak** (`--soak`) takes the Mac over for its length: run it on a Mac nobody is using, with
`scripts/soak.command [minutes=30] [uk|none] [fault]` there (`open scripts/soak.command` or a
double-click in Finder, in the GUI session; stop Wisp's sharing there first). It builds if needed,
runs the scripted pass and then the soak, both over loopback with the UK-link emulation, and writes
`soak-results/<time>/summary.txt` (failures, then a last line `PASS` or `FAIL`) beside the full
results of each part.

Each run leaves everything under `.build/e2e/<time>/` (or `--out <dir>`): `e2e.out` (the runner), `input.jsonl` (what
the host's windows received), `logs/cli.log` (both processes, with pids). It is isolated as the other
tests are (private pasteboard, own log and support directories, the app's `lastHost` put back) and
never touches other Macs. The test windows open on this Mac's screen and the runner comes to the
front: input from this Mac's own mouse and keyboard is ignored while it runs (counted at the end).

**The pieces.**
- *Host side*: `WispProbe.app` on a real host (`scripts/bundle-probe.sh` → `dist/WispProbe.app`, ad-hoc
  signed, no permissions: it only receives). Three windows (800x560, 640x480, 520x400 pt), each a
  scroll view of numbered rows under a frame counter redrawn every display refresh. Everything its
  windows get is appended to `~/Library/Logs/WispProbe/events.jsonl` (`--log <file>`; the file is
  emptied at launch unless `--keep`): scrolls as its scroll view gets them (scrollingDelta, precise,
  phase, momentumPhase, where, how far it scrolled), clicks with their click counts, drags, keys with
  characters and modifiers, resizes, key-window changes. `WispProbe --selftest` checks it on its own.
  Over loopback the synthetic host plays this part: with `WISP_INPUT_LOG=<file>` its injector builds
  every event exactly as it would post it and records the NSEvent an app would get from it.
- *The frame counter* (`FrameCode`, WispCommon/InputProbe.swift): two rows of 8 pt black and white
  squares at (12, 40) pt from the window's top-left; row 1 is white, black, then 16 bits, row 2 the
  inverse. The runner reads it from every frame put on screen: a misread is detected, not decoded.
- *Viewer side*: `wisp e2e <host>` (`Sources/wisp/E2E.swift`). It connects as the viewer, opens the
  test windows in ordinary in-process viewer windows (ViewerController and RemoteView, not snapshot
  mode) and gives them NSEvents as AppKit would: through the window (hit-tested) for clicks, keys and
  scrolls; pointer moves to the view as its tracking area does; momentum scrolls to the view the
  gesture latched onto (AppKit drops made-up momentum events sent through the window, though it
  delivers real ones there). Then it reads the host's log (`--host-log <file>`, or
  `--host-log-cmd "<command>"` for a remote host) and checks.

**Scenarios** (per window; the scripted pass runs them in each window in turn, `--scenarios
scroll,click,key,resize` picks some): a trackpad gesture (mayBegin, began, changed at 120 Hz, ended,
momentum begin/continue/end at 60 Hz), a Magic Mouse gesture (no mayBegin, 90 Hz), a smooth-scrolling
mouse (precise, no phases), a wheel (slow ticks, then a fast spin with accelerated and fractional line
deltas), a fast flick, an extreme flick (more than an i16 per 1/60 s), a diagonal gesture; first in a
background window, then (if this app is active) as the key window. Clicks, a double and a triple
click, a right click, a drag; typing, ⌘A, ⇧⌘Z, ⌥⌘F, ⌃A, shifted letters; then a local resize of each
window. `--soak <minutes>` instead runs rounds of ~20 s of random input across the windows (gestures
of every kind with random sizes and places, clicks, drags, typing, shortcuts, now and then a resize),
each checked on its own; `--seed` replays one.

**What is checked**, per window and round:
- every scroll arrived where it was sent (each gesture is at its own place), with the same kind of
  delta (points or lines), the same total distance (within 1 pt, or 1/16 line, + 0.2 %), the same
  phase boundaries in order, well formed (`[mayBegin] began changed… ended|cancelled`, `momentum
  begin continue… end`) and nothing left mid-gesture;
- clicks, drags and keys exactly as sent and in order: button, click count, place (± 2 pt), key code,
  modifiers; characters too for plain and shifted letters (a mismatch is a warning: it depends on the
  host's keyboard layout);
- the host's window ended at the size asked for, and the viewer shows that size;
- no window was raised while only scrolling was being sent (with `WISP_FAULT=focus-hold|focus-stuck`
  the synthetic host records the raises a real host would do);
- the frame counter advanced, with no freeze longer than `--max-freeze` (1 s); no `STALL` or error
  line in the runner's log, and (scripts/e2e.sh) none in the host's.

The runner exits 0 when everything passed, 1 otherwise; the last line says how many rounds, gestures
and inputs were checked.

**Against a real host** (the Mini, with Wisp sharing there): on the host, in its GUI session, open
`WispProbe.app` (built by `scripts/bundle-probe.sh`, copied over) and share "WispProbe 1" in Wisp.
Then on the viewer:

```bash
scripts/e2e.sh --host <mini> --host-log-cmd "ssh <user>@<mini> cat Library/Logs/WispProbe/events.jsonl"
scripts/e2e.sh --host <mini> --host-log-cmd "…" --soak 10
```

It opens WispProbe's windows (`--app WispProbe`, up to three) and runs the same checks on what the
real app received through Accessibility injection, ScreenCaptureKit and the virtual displays: the
host's own STALL lines are in its `~/Library/Logs/Wisp/wisp.log`. Leave the host alone while it
runs: a click or a key there would be recorded too.

## Clipboard

```bash
swift scripts/clipboard-test.swift [.build/release/wisp]   # needs TCP 7878 / UDP 7879 free
```

Runs `wisp send --synthetic` and `wisp view --snapshot` in two processes, each with a private named
pasteboard (`WISP_PASTEBOARD`), its own log directory and verbose logging, copies to one pasteboard
and checks the other: text, RTF, HTML, PNG (multi-chunk) and TIFF (arrives as PNG) both ways,
concealed / transient / auto-generated items and files not sent, the size cap
(`WISP_CLIPBOARD_MAX`), the last copy winning, no echo (it counts the `#N → host:` / `→ viewer:`
lines in each log) and no contents in the logs. It never touches the real clipboard. To try it by
hand, give both ends a `WISP_PASTEBOARD` and copy with a few lines of Swift
(`NSPasteboard(name: .init("…")).setString(…)`); without one, `--synthetic` and `--snapshot` don't
sync at all.

## Tailscale and access

```bash
wisp tailnet                     # the tailnet's devices, via the LocalAPI (first line says how it was reached)
wisp tailnet --no-probe          # the same without probing anyone
wisp tailnet whois 100.x.y.z     # who an address is, as the host checks each connection
wisp tailnet probe 127.0.0.1     # with a host running: "Sharing" (or "Not sharing")
WISP_TAILSCALE=cli wisp tailnet # skip the LocalAPI: test the `tailscale` CLI fallback
```

Access checks over loopback: loopback is always allowed, so test a refusal from this Mac's **LAN**
address (`ipconfig getifaddr en0`): `wisp tailnet probe <lan ip>` says "Sharing · not allowed for
you" and `wisp view <lan ip> --windows` prints the host's reason; `wisp send --allow-lan` lets it
in. The allow-list (`--allow <login>`) needs a second device on the tailnet: connecting to this
Mac's own 100.x address from this Mac doesn't go through Tailscale. Don't probe other people's
Macs from a test.

## The app (menu bar, host window, Settings)

The UI can't be clicked in an automated test, so the app describes itself:

```bash
S=$PWD/t; mkdir -p $S
export WISP_SUPPORT_DIR=$S WISP_LOG_DIR=$S/logs WISP_SOCKET=$TMPDIR/wisp-test.sock WISP_NO_PROBE=1
WISP_MENU_DUMP=$S/menu.txt WISP_OPEN=host,settings,welcome dist/Wisp.app/Contents/MacOS/Wisp &
sleep 8; kill %1          # SIGTERM quits like Quit
cat $S/menu.txt $S/menu.txt.windows
```

`menu.txt` is the status item's menu as built (header row, sections, items with subtitles,
checkmarks, key equivalents), rewritten every 2 s; `menu.txt.windows` lists the visible windows
after 4 s with their toolbars and top views (the host window's NSSplitView and sidebar, Settings'
tabs, the welcome popover). With a synthetic host running, `… Wisp --connect 127.0.0.1` (add
`WISP_PHANTOMS=0` for windows in the app itself) shows the Windows section, checkmarks and
"N of 3 open". `WISP_TEST_STOP=3` stops sharing after 3 s, as Stop Sharing does, and starts again
2 s later (the ports must come back). The app writes to its real defaults domain (`lastHost`, the
host window's frame): `defaults delete com.pier20.Wisp lastHost` afterwards if that matters.

## Test hooks

| | |
|---|---|
| `wisp view <host> --windows` | Print the host's windows, as in the viewer's menu bar list. |
| `wisp poke <host> [--stream N] click <x>,<y>` | One click at a point (0…1 each) in the primary or Nth stream. Also `key <keycode>`, `action close`, `action new-window` (synthetic host: that window's app opens a new one), `action open-panel` (synthetic host: a fake out-of-process Open panel in that stream), `resize <w>x<h>` (as if resized on the host; the synthetic host fakes a 400x300 pt minimum). A connected viewer stays connected. |
| `wisp view <host> --menus <appKey> [--press "File>New Window"]` | Print an app's menu bar as the host reads it (app keys from `--windows`), then choose an item. |
| `wisp send --max-streams 2` | Try the stream limit. |
| `wisp vdisplay-test 1512x982 5 --count 3` | Create three HiDPI virtual displays one at a time, as the host does, check each (2x, not main, not mirrored, no overlap), wait 5 s, remove them and check none is left. **Adds real displays: windows may jump to them and back. Run it only on a Mac nobody is working on.** |
| `swift scripts/hevc-sessions.swift [w h] [fps]` | How many concurrent low-latency hardware HEVC sessions this Mac sustains. |

## Debug environment variables

All are read at start-up; phantom apps inherit every `WISP_*` variable from the app.

| variable | effect |
|---|---|
| `WISP_SECONDS=10` | `view --snapshot`: decode for this many seconds (default 3). |
| `WISP_DROP=5` | Viewer: drop this percentage of incoming video packets, to exercise FEC and re-requests. |
| `WISP_DROP_WINDOW=2` | With `WISP_DROP`: drop only window 2's packets (repair must stay within its stream). |
| `WISP_NET_DELAY_MS=75` | Viewer: a far-away host over loopback. This much one-way delay on everything received and on what is sent over TCP (the round trip grows by twice this). |
| `WISP_NET_JITTER_MS=8` | Viewer: up to this much more per datagram or TCP read (UDP may reorder; TCP stays in order). |
| `WISP_NET_LOSS=1.5` | Viewer: this percentage of datagrams lost, and of TCP segments (each way) held one retransmission timeout (200 ms or twice the delay) with everything behind them: head-of-line blocking. `scripts/e2e.sh --net uk` = 75 / 8 / 1.5. |
| `WISP_INPUT_LOG=<file>` | `send --synthetic`: record what its windows receive, as the NSEvents an app would get from the injected events (InputRecord JSON lines; see "End-to-end input and freshness"). Also `wisp e2e`'s default `--host-log`. |
| `WISP_TEST_OPEN=2,3@1` | Viewer: open windows 2 and 3 after 1 s, as the menu does. |
| `WISP_TEST_CLOSE=2@4` | Viewer: stop viewing window 2 after 4 s, as Stop Viewing does. |
| `WISP_TEST_RESIZE=900x600@3` | Viewer: resize the viewer window once after 3 s, as a user would; the host should follow. |
| `WISP_PHANTOMS=0` | App: show remote windows in Wisp itself, not in phantom apps (also `defaults write com.pier20.Wisp phantoms -bool false`). |
| `WISP_PHANTOM_TEST_INPUT=4` | Each phantom clicks the middle of its windows and types "a" after 4 s. |
| `WISP_PHANTOM_TEST_MENU=4` | Each phantom logs its menu bar, chooses View > Show Sidebar, refreshes, types ⌘B (which must reach the host as keys) and chooses the remote Quit. |
| `WISP_SOCKET=/tmp/x.sock` | The app's socket for its phantoms (default `~/Library/Application Support/Wisp/run/viewer.sock`; must be under 104 bytes, or the phantoms crash connecting to it). |
| `WISP_SUPPORT_DIR=<dir>` | Instead of `~/Library/Application Support/Wisp` (phantom bundles, socket). Also skips the one-time migration from the app's previous name (App/Migration.swift). |
| `WISP_LOG_DIR=<dir>` | Instead of `~/Library/Logs/Wisp`. |
| `WISP_MENU_DUMP=<file>` | App: write the menu bar item's menu to `<file>`, the windows to `<file>.windows` and, after 5 s, the Copy Diagnostics report to `<file>.diagnostics` (the clipboard is left alone). |
| `WISP_OPEN=host,settings,welcome` | App: open the host window (starts sharing), Settings and/or the welcome popover at launch. |
| `WISP_NO_PROBE=1` | App: list the tailnet's Macs without probing them. |
| `WISP_TEST_STOP=3` | App: stop sharing after 3 s and start again 2 s later. |
| `WISP_TAILSCALE=cli` | Reach Tailscale through its CLI only (skip the LocalAPI). |
| `WISP_VERBOSE=1` | Debug-level logging for this run (`0` turns it off even if the setting is on). |
| `WISP_NO_ALERTS=1` | App: a connection that fails is logged, not shown in an alert (tests can't click OK). |
| `WISP_PASTEBOARD=<name>` | Sync this private named pasteboard instead of the real clipboard (host and viewer; phantoms don't sync). Also turns sync on for `send --synthetic` and `view --snapshot`. |
| `WISP_CLIPBOARD_MAX=<bytes>` | Clipboard size cap for this run (default: the `clipboardMaxBytes` setting, else 10 MB). |
| `WISP_FAULT=<fault>[=<n>],…` | Inject a fault, to prove a stall is logged and recovered from (see "Stalls" below). Host: `encoder-stall`, `encoder-hang`, `encoder-invalid`, and for the synthetic host `focus-hold` (input for a window not "in front" raises it and holds input 60 ms, as on a real host; raises are recorded) and `focus-stuck` (raising never takes); viewer: `udp-drop-all-for=<s>`, `decoder-fail-once`, `main-block=<s>`. Each logs a `FAULT` warning when it fires. |

The last three let a phantom test run beside a copy of Wisp that's in use without touching its
phantoms, socket or logs:

```bash
wisp send --synthetic 1600x1000 &
WISP_SUPPORT_DIR=$PWD/t WISP_LOG_DIR=$PWD/t/logs WISP_SOCKET=$PWD/t/s \
WISP_TEST_OPEN=3@2 WISP_PHANTOM_TEST_INPUT=4 dist/Wisp.app/Contents/MacOS/Wisp --connect 127.0.0.1
```

Two phantom apps start, "Synth Alpha" and "Synth Beta" (`lsappinfo list` shows them as regular
apps with `com.pier20.Wisp.phantom.*` bundle IDs, their bundles in
`t/Phantoms/127.0.0.1/<appKey>/<App Name>.app`). Quit one (`osascript -e 'quit app "Synth Alpha"'`)
and only its streams close. Keep `WISP_SOCKET` short (under 104 bytes): a path deep in a temporary
directory is too long, and the phantoms then can't connect.

New windows and Dock reopen, with the app connected as above (stream IDs are the host's, in its log):

```bash
wisp poke 127.0.0.1 --stream 2 action close         # window 3 closes: Synth Beta has no windows anywhere
open "t/Phantoms/127.0.0.1/com.pier20.Wisp.synthetic.beta/Synth Beta.app"   # a Dock click: LaunchServices sends reopen
#   → host: "reopen", "synthetic: Synth Beta opened window 4 (reopened)", "follow: streaming …"; the phantom shows it
wisp poke 127.0.0.1 --stream 3 action new-window    # window 5 follows by itself
wisp poke 127.0.0.1 --stream 1 action new-window    # 3 open already: the Alpha phantom says so (phantom-Synth Alpha.log)
WISP_TEST_CLOSE=5@<s>                                # (set on the app) stop viewing window 5: the held window opens, 5 stays closed
``` Afterwards, `lsregister -u` the test bundles (the tool is in
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`)
before deleting them.

## Logs

Every process writes its own file in `~/Library/Logs/Wisp/` (or `WISP_LOG_DIR`): `wisp.log` (the
app: viewer, host and UI), `phantom-<App>.log` (each phantom), `cli.log` (`wisp send`, `view`,
`poke`, `tailnet`…; every line has the pid, so concurrent commands can be told apart),
`latency.log` and `stats.csv`. Lines: `2026-11-04 14:09:41.413 [49288] INFO  net       TCP …`.
Logging is `Log.debug/info/warning/error(.category, "…")` (`Sources/WispCommon/Log.swift`); the
old `log("…")` still works (info, in the category of the file it's called from). Info is for
lifecycle (one line per connection, stream, display, state change); per-event detail is debug
(on with `WISP_VERBOSE=1` or the Verbose logging setting); nothing per frame, and never a key's
code. Everything is mirrored to the unified log:

```bash
log stream --level debug --predicate 'subsystem == "com.pier20.Wisp"'   # every process, every category
```

A connection that can't be made, isolated (the app gives up after 15 s; `WISP_NO_ALERTS=1`
logs it instead of showing an alert):

```bash
WISP_SUPPORT_DIR=/tmp/wsp-x/s WISP_LOG_DIR=/tmp/wsp-x/logs WISP_SOCKET=/tmp/wsp-x/v.sock WISP_NO_PROBE=1 WISP_NO_ALERTS=1 \
  dist/Wisp.app/Contents/MacOS/Wisp --connect no-such-mac.invalid &
sleep 18; kill %1; cat /tmp/wsp-x/logs/wisp.log
#   viewer  connecting to no-such-mac.invalid (DNS name) …
#   net     TCP no-such-mac.invalid:7878 waiting (DNS error -65554: no such record) after 0.0 s; path: …
#   net     TCP no-such-mac.invalid still waiting (…) after 3 s / 8 s / 14 s
#   WARN viewer giving up on no-such-mac.invalid after 15 s of waiting: …
```

`wisp diagnostics` prints the Copy Diagnostics report (without probing anyone). Note that the app
(even isolated) saves the Mac it connected to as `lastHost` in the real defaults.

## Stalls

"The window stopped updating" has many possible causes on either Mac; each is watched, and each
stall is told in the log as one episode: a `WARN … STALL <what>: <what's stuck and the evidence>`
line when it starts, an `INFO … STALL <what>: recovering: <step>` line per recovery step, and an
`INFO … STALL <what>: over after N s: <what ended it> (steps taken: …)` line when it ends. At most
one start line per thing every 10 s (a flapping stall says how many it didn't log). So
`grep STALL wisp.log` tells the story; details are at debug (`WISP_VERBOSE=1`).

| subject | where | starts when | recovers by |
|---|---|---|---|
| `stream #N encoder` | host | VideoToolbox hasn't answered for frames in flight for 1 s (every later frame would be skipped as "busy"), or its session is broken (kVTInvalidSessionErr, 10 failures in a row) | forgetting the lost frames + a keyframe; a new encoder if it happens again within 30 s or the session is broken |
| `stream #N host` | host | the window keeps changing (frames captured or encoded) but nothing has been sent for 3 s | (the encoder's own recovery; the line says why: encoder state, UDP path) |
| `stream #N capture` | host | three clicks or key presses over 3 s and no frame from ScreenCaptureKit since | nothing (logged only: the window may simply ignore the input) |
| `video path from <host>` | viewer | the host echoes our UDP hellos, and nothing at all has come over UDP for 3 s while TCP answers | the UDP hello again at once; after 6 s a new UDP flow (new source port; the host follows the latest hello and logs `video path (UDP) moved`) |
| `stream #N viewer` | viewer | no frame decoded (or relayed to a phantom) for 2 s while video for it keeps arriving, a frame is incomplete or a keyframe is awaited | after 3 s: flush reassembly, a new decoder if it failed, a keyframe request; again every 3 s |
| `stream #N display` | viewer, phantoms | a decoded frame has waited 2 s to be shown | the show scheduled again if the main thread answers |
| `input to window N` | host | input has been held 1 s for a window being brought forward (a click or key for an app not in front) and the activation hasn't finished | the held input is replayed without waiting any longer |
| `main thread` | every process | the main thread hasn't answered for 1 s | nothing (it says when it answers again) |
| `stream #N phantom relay` | viewer | 60 frames queued to a phantom that isn't reading them | frames dropped until it catches up, then a keyframe |

Also, without a STALL: the host logs a health line per stream every 5 s (`stream #N health (5 s):
captured, encoded, sent, skipped busy, NACKs served, last capture/send, encoder in flight`) and a
`send path` line (UDP peer, pacer backlog and longest wait, send errors): at debug, or at info with
`[…what looked wrong…]` appended. UDP send errors are a warning at most every 5 s; a failed video
flow is a warning on both sides. The viewer logs `decoder session #2 made … (after a failure:
OSStatus …)` when it replaces a broken decoder, and `the host echoes our hellos` once per
connection (an older host doesn't, and then the video path isn't judged).

Fault injection, on loopback (`WISP_FAULT` on `wisp send` for host faults, on `wisp view` for
viewer faults; times count from the first frame or from the session start, 4 s by default):

```bash
WISP_FAULT=encoder-stall wisp send --synthetic 1600x1000     # two encoder callbacks lost once
#   WARN  encode  STALL stream #1 encoder: 2 frames in flight for 1.0 s, every new frame skipped as busy; in flight 2 (waiting 1.01 s, 1.00 s), …
#   INFO  encode  STALL stream #1 encoder: recovering: forgot the lost frames (in-flight count reset), keyframe forced
#   INFO  encode  STALL stream #1 encoder: over after 1.0 s: the encoder's output resumed with a keyframe (steps taken: …)
WISP_FAULT=encoder-hang …       # every encoder silent for 5 s: resets, then new encoders, and `STALL stream #1 host: … nothing was sent`
WISP_FAULT=encoder-invalid …    # kVTInvalidSessionErr for 1 s: `recovering: made a new encoder (the old session is broken)`
WISP_SECONDS=14 WISP_FAULT=udp-drop-all-for=5 wisp view 127.0.0.1 --snapshot out.png
#   WARN  net     STALL video path from 127.0.0.1: no UDP from the host for 3.0 s (no video, no hello echo) while TCP answers …
#   INFO  net     STALL video path from 127.0.0.1: over after 5.0 s: UDP from the host arrives again (flow #1) (steps taken: sent the UDP hello again at once)
#   WARN  viewer  STALL stream #1 viewer: no frame decoded for 5.2 s while video for it keeps arriving; next frame #220, highest seen #493, …
#   INFO  viewer  STALL stream #1 viewer: over after 5.2 s: frame #496 (a keyframe) decoded (steps taken: flushed reassembly …)
WISP_FAULT=udp-drop-all-for=10 …   # also `recovering: no UDP for 6 s: new UDP flow`; the host logs `video path (UDP) moved: … → …`
WISP_FAULT=decoder-fail-once …     # the decoder session breaks: `decoder session #2 made … (after a failure: OSStatus -12903)`
WISP_FAULT=main-block=3 wisp view 127.0.0.1     # windows on screen: `STALL main thread`, `STALL stream #1 display`
```

## Latency stats

The viewer measures latency and reports it to the host every 5 s. The host logs a line and appends
a row to `~/Library/Logs/Wisp/stats.csv`:

- **rtt:** network round trip, from a ping every second over the control connection.
- **video delay:** from the host handing a frame to the encoder until the viewer has decoded it,
  using a clock offset estimated from the pings. It leaves out about one frame of capture delay and
  one display refresh.
- **click→screen:** from a click or key press on the viewer until the first frame encoded after the
  host applied it: the delay a person actually feels. A lower bound when something else in the
  window is animating.

The viewer's `latency.log` breaks the on-viewer part down further (complete → on screen, relay,
decode, display, in µs). The host log shows the average encode time, so codecs can be compared on
the real machine.

## What needs a real host

Loopback can't exercise Screen Recording, Accessibility (input injection, window moves, menu
reading) or virtual displays with real windows. Those need two Macs; see the "Needs a real host"
notes in [multi-window.md](multi-window.md).
