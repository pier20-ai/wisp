# Troubleshooting

## Reporting a problem

Menu bar › **Troubleshooting** › **Copy Diagnostics** (also in the Help menu and Settings ›
Troubleshooting) puts a report on the clipboard to paste into an issue: version, macOS, hardware,
permissions, settings, Tailscale (this Mac, every Mac on the tailnet and whether it was sharing when
the menu last looked), what the viewer and host are doing, and the last 300 lines of `wisp.log`.
Other people's Tailscale logins are replaced by a short hash (`user-1a2b3c4d`, the same login always
the same hash); only yours is shown. `wisp diagnostics` prints the same report in a terminal. Read it
before you post it: it has your Mac's and your peers' Tailscale names and addresses.

## Common problems

- **Stuck on "Connecting…"**: `wisp.log` says why: a name that didn't resolve (`DNS error -65538:
  no such name`), a path that's unsatisfied, a TCP connection that stays in `preparing` (no route to
  that address: is Tailscale up on both Macs?), or no `helloAck` (Wisp isn't running there, or is an
  older version). The viewer gives up after 15 s.
- **The viewer can't connect**: check that both Macs are on the same tailnet (`tailscale status`),
  that your ACLs allow TCP 7878 and UDP 7879 to the host, and that the host is sharing (its menu
  says "Sharing from This Mac").
- **"… isn't on <host>'s list of allowed viewers"** or **"only accepts connections over
  Tailscale"**: the host refused you, and says why. Ask its owner to add your Tailscale login under
  Allowed Viewers, or connect to its Tailscale name or 100.x address rather than a LAN address.
- **A Mac shows "Not sharing"**: Wisp isn't sharing there, or isn't running. "Sharing · older
  version": it runs a Wisp without the menu's probe; you can still connect.
- **"<host> is newer / older"**: both Macs must run the same protocol version. Update the older one
  (Check for Updates… in its menu).
- **Clicks do nothing**: Accessibility isn't granted on the host (Privacy & Security ›
  Accessibility; on macOS 27, Privacy & Security › Device Control and Data Access), or the host's
  screen is locked.
- **Nothing to see, or "Screen Recording is off"**: grant Screen & System Audio Recording on the
  host, then quit and reopen Wisp there.
- **"TCP port 7878 is already in use"**: another Wisp or `wisp send` is still sharing on this Mac.
  The message names the process; quit it and try again.
- **Paste doesn't bring what was copied on the other Mac**: both Macs need clipboard sharing on;
  the `clipboard` lines in `wisp.log` say when sync started and, with verbose logging, each copy sent
  or received (types and sizes, never the contents), or why one was left out (a password manager's
  item, files, over the size limit).
- **Permissions keep disappearing** after a rebuild: a source build signed ad-hoc is a new app to
  macOS each time. See [Signing](development.md#signing).

## The host

- **Headless Macs** (no monitor) work: shared windows go on HiDPI virtual displays, so they render
  at 2× without a display attached. A headless Mac still needs a logged-in GUI session: log in once
  with Screen Sharing or a monitor, and set it to stay logged in.
- **The lock screen stops input.** While the host's screen is locked, every click and key goes to
  the lock screen; the viewer shows a "screen is locked" warning. While a viewer is connected, Wisp
  keeps the host from idling into the lock, but it can't unlock it. **Disconnecting a Screen Sharing
  session locks the host's session**: if you set up the host over Screen Sharing, unlock it (or leave
  Screen Sharing connected) before using Wisp.
- **Don't work on the host while someone drives it**: input moves the host's real cursor and brings
  the target window forward.
- The host window (menu › **Sharing from This Mac…**) shows who is connected (their Tailscale name
  and device), round trip, latency and bandwidth, each shared window with a live thumbnail, the
  permissions and the log. Closing it leaves sharing on; **Stop Sharing** ends it and puts every
  window back.

## Phantom apps

Phantom apps live in `~/Library/Application Support/Wisp/Phantoms/<host>/` and are rebuilt when Wisp
updates. Delete that folder to remove them. `defaults write com.pier20.Wisp phantoms -bool false`
(or Settings › Viewing) shows remote windows in Wisp itself instead.

## Logs

The logs are in `~/Library/Logs/Wisp/` (menu bar › Troubleshooting › Reveal Logs in Finder):

- `wisp.log`: the app, both as viewer and as host: launch (version, macOS, permissions, settings),
  every connection step (address, DNS, TCP/UDP states and the network path, hello, refusals and their
  reasons), streams, virtual displays, capture, encoders, access decisions, updates.
- `phantom-<App>.log`: one per phantom app (its connection to Wisp, its windows and menus).
- `cli.log`: the `wisp` commands. `latency.log`: the viewer's latency breakdown every 5 s.
  `stats.csv` (host): the viewer's latency reports, one row every 5 s.

Each line has the time to the millisecond, the process ID, a level (ERROR, WARN, INFO, DEBUG) and a
category (`viewer`, `host`, `net`, `tailnet`, `access`, `phantom`, `ipc`, `menu`, `capture`,
`encode`, `vdisplay`, `input`, `discovery`, `clipboard`, `app`, `cli`). Files rotate at 5 MB,
keeping three old ones (`wisp.log.1` … `.3`).

**Verbose logging** adds per-event detail (every connection state and path change, each message,
each probe, IPC with the phantoms): Settings › Troubleshooting › Verbose logging, or `defaults write
com.pier20.Wisp verboseLogging -bool YES` (phantoms pick it up when they next open), or
`WISP_VERBOSE=1` for one run.

**Live, in Console or a terminal**: the same lines go to the unified log, subsystem
`com.pier20.Wisp`, with the categories above:

```bash
log stream --level info --predicate 'subsystem == "com.pier20.Wisp"'
log stream --level debug --predicate 'subsystem == "com.pier20.Wisp" && category == "net"'
log show --last 10m --info --predicate 'subsystem == "com.pier20.Wisp"'
```
