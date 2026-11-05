# Development

Everything for working on Wisp: building, signing, the command line, testing, releasing and
renaming. [AGENTS.md](../AGENTS.md) is the map of the code (architecture, wire protocol,
conventions); [multi-window.md](multi-window.md) the design; [testing.md](testing.md) the test tools.

## Building

You need Xcode 26 or later (or its command-line tools), on macOS 14 or later.

```bash
git clone https://github.com/pier20-ai/wisp.git && cd wisp
swift build -c release            # .build/release/wisp: the CLI
scripts/bundle-app.sh             # dist/Wisp.app, universal, signed ad-hoc
cp -R dist/Wisp.app /Applications/
```

Both Macs must speak the same protocol version; an older peer is told to update.

### Signing

macOS ties the host's Screen Recording and Accessibility permissions to the app's code signature.
An ad-hoc signature changes with every build, so each rebuild must be granted again. To keep the
grants, sign with a stable identity:

- `scripts/make-dev-cert.sh` (once, in a GUI Terminal) creates a self-signed "Wisp Dev" identity
  that only this Mac trusts. Then `scripts/bundle-app.sh --identity "Wisp Dev"`, or
  `scripts/host-build.command`, which picks the best identity it finds.
- With a Developer ID you can also notarize, so the app opens on any Mac:

  ```bash
  scripts/bundle-app.sh --identity "Developer ID Application: Your Name (TEAMID)" \
      --notarize --notary-profile <notarytool profile>
  scripts/make-dmg.sh --identity "Developer ID Application: Your Name (TEAMID)" \
      --notarize --notary-profile <notarytool profile>     # dist/Wisp-<version>.dmg
  ```

  Both read `BRAND_SIGN_IDENTITY` and `BRAND_NOTARY_PROFILE` from the environment or from
  `scripts/brand.local.env` (not tracked). Create a profile with `xcrun notarytool store-credentials`.

The keychain holding a signing key is locked to SSH sessions: sign in the Mac's GUI session
(`.command` files open in Terminal there).

### Updates (Sparkle)

Developer ID builds embed [Sparkle](https://sparkle-project.org) (pinned and checksummed in
`scripts/brand.env`, fetched by `scripts/fetch-sparkle.sh`) and check the feed in
`BRAND_FEED_URL`: the `appcast.xml` attached to the latest GitHub release. Every update is checked
against `BRAND_SPARKLE_PUBLIC_KEY` (EdDSA). Sparkle is loaded at run time, not linked, because the
same binary runs as the CLI and inside phantom apps (`Sources/wisp/App/Updates.swift`). Builds
without a public key, and ad-hoc builds, have no updater. `scripts/bundle-app.sh --updates` embeds
it anyway, to test (signed without the hardened runtime, whose library validation needs a team ID).

To test an update end to end on one Mac: make a key pair, build twice (a minute apart, so the build
numbers differ), serve the newer zip and an appcast from `localhost`, and open the older build:

```bash
export BRAND_FEED_URL=http://localhost:8765/appcast.xml BRAND_SPARKLE_PUBLIC_KEY=<public key>
scripts/bundle-app.sh --updates --output /tmp/old; sleep 60; scripts/bundle-app.sh --updates --output /tmp/new
ditto -c -k --keepParent /tmp/new/Wisp.app /tmp/www/Wisp.zip
SPARKLE_KEY_FILE=<private key file> scripts/make-appcast.sh /tmp/www/Wisp.zip http://localhost:8765/Wisp.zip /tmp/www/appcast.xml
(cd /tmp/www && python3 -m http.server 8765) & open /tmp/old/Wisp.app   # then Check for Updates…
```

## Command line

The app's binary is also the CLI: `Wisp.app/Contents/MacOS/Wisp`, or `.build/release/wisp`. Run
`wisp help` for the full list.

```
wisp                                   open the app
wisp send --list                       list shareable windows
wisp send --window <id | app or title> share a window from this Mac
wisp send --synthetic 1600x1000        share 3 animated test windows (needs no permissions)
wisp view <host>                       view and control <host>'s windows (add --phantoms for phantom apps)
wisp view <host> --windows             print the host's windows
wisp view <host> --snapshot out.png    headless: decode a few seconds, save a frame, print stats
wisp view <host> --menus <appKey>      print an app's menu bar as the host reads it
wisp poke <host> click|key|resize|action …   send one test input to a shared window
wisp tailnet [peers]                   the Macs on your tailnet and whether each is sharing
wisp tailnet whois <ip>                who a Tailscale address belongs to (as the host checks it)
wisp tailnet probe <host>              ask one Mac whether it's sharing
wisp diagnostics                       the Copy Diagnostics report
wisp vdisplay-test <w>x<h> [s] [--count N]   create and remove virtual displays (see the Risks)
wisp --connect <host>                  open the app connected to <host>
```

Options for `wisp send`; the app reads the same keys from its defaults (e.g.
`defaults write com.pier20.Wisp codec h264`):

| flag | default | meaning |
|---|---|---|
| `--kbps` | 10000 | Video bitrate ceiling for all windows together, split between the windows that are changing (an idle window sends nothing). Backs off while the viewer reports loss. Key `kbps`. |
| `--fps` | 60 | Maximum frame rate. Key `fps`. |
| `--scale` | display's | `1` sends half resolution from a Retina display: 4× fewer pixels, softer text. Key `scale`. |
| `--codec` | hevc | `h264` if HEVC misbehaves. Key `codec`. |
| `--refine` | 3 | Sharpening passes after the window goes still; `0` disables. Key `refine`. |
| `--pace-mbps` | 60 | Ceiling for the rate at which large frames are spread out. Key `paceMbps`. |
| `--fec` | 8 | One XOR parity packet per this many video packets; `0` turns it off. Key `fec`. |
| `--no-virtual-display` | (on) | Don't put shared windows on virtual displays; windows may then overlap. Key `virtualDisplay` (bool). |
| `--max-streams` | 3 | Windows a viewer may stream at once. Key `maxStreams`. |
| `--allow <login>` | (anyone) | Only this tailnet user may connect; repeat for more. Default: the app's allow-list, key `allowedViewers` (an array; empty = anyone on the tailnet). |
| `--allow-lan` | (off) | Also accept connections from outside Tailscale (unencrypted, unidentified). Key `allowLAN`. Loopback is always accepted. |
| `--no-clipboard` | (on) | Don't sync the clipboard with the viewer. Key `shareClipboardWithViewers` (bool, read live). `--synthetic` leaves it off unless `--clipboard` or `WISP_PASTEBOARD` is given. |

The viewer's clipboard keys are `shareClipboardWithHosts` and `clipboardMaxBytes` (10 MB).

## Testing

There are no unit tests; the loopback test is the regression test, and `scripts/e2e.sh` the
end-to-end input and freshness test. Both, and the debugging hooks (packet loss and delay
emulation, fault injection, input logs), are in [testing.md](testing.md).

`WISP_DEMO_NAMES="real=shown,other="` shows tailnet devices and logins under other names in the
UI (a device mapped to nothing is left out), for screenshots without real names.
`WISP_DEMO_WINDOWS="Safari,Zed"` lists only those apps' windows in the menu, and
`WISP_DEMO_FAKE_WINDOWS="Xcode|Package.swift;Notes|Groceries"` adds made-up entries that do nothing.

## Releasing

Releases are built with **Xcode 27** (the macOS 27 SDK: AppKit's window chrome follows the SDK an app
is built with). GitHub's Mac runners only have Xcode 26 so far, so for now a release is built on a
Mac, from a clean checkout of the tagged commit:

1. Set `BRAND_VERSION` in `scripts/brand.env`, add a `## <version> — <date>` section to
   `CHANGELOG.md` (it becomes the release notes and the update's notes), commit, tag `v<version>`,
   push both.
2. `scripts/release.sh --draft`: builds the app, signs it with the Developer ID, notarizes app and
   DMG, checks them with Gatekeeper, writes the signed appcast and creates a **draft** release with
   `Wisp-<version>.dmg`, `.zip`, `.sha256` and `appcast.xml` (`scripts/draft-release.sh`).
3. Check the draft, install its DMG and try it, then **publish** it: only then do existing installs
   see the update (the feed is `releases/latest/download/appcast.xml`; drafts are never "latest").

The Mac needs, once: the Developer ID identity in its login keychain (double-click the exported
`.p12`), a notarytool profile (`xcrun notarytool store-credentials <name> --apple-id <id> --team-id
<team>`, which asks for an app-specific password), the Sparkle update key in its login keychain
(`generate_keys`, or `generate_keys -f <file>` to import it), and in `scripts/brand.local.env`:

```bash
BRAND_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
BRAND_NOTARY_PROFILE="<name>"
```

The keychain is locked to SSH sessions: run it in the Mac's own Terminal.

### On GitHub Actions

[.github/workflows/release.yml](../.github/workflows/release.yml) does the same on a GitHub-hosted
Mac, started by hand on a tag (`gh workflow run release.yml --ref v<version>`). It refuses to build
until the runners have Xcode 27; then its trigger goes back to pushing a `v*` tag. Its secrets come
from `scripts/setup-release-secrets.sh <DeveloperID.p12>` (run it yourself; it prompts for the
passwords and never prints them):

| secret | what |
|---|---|
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | the "Developer ID Application" certificate and private key, exported from Keychain Access (login keychain › My Certificates) as a .p12 |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | an Apple ID on the developer team, the team ID, and an app-specific password made under that Apple ID |
| `SPARKLE_PRIVATE_KEY` | the update signing key; the script makes it with Sparkle's `generate_keys` (kept in the login keychain) and writes its public half to `scripts/brand.env` |

Keep the Sparkle private key backed up: installed copies only accept updates signed with it.

## Renaming

The product's name lives in two files, kept in step:

- `Sources/WispCommon/Brand.swift`: the display name, CLI name, bundle ID and copyright line, from
  which the code derives the phantom bundle-ID prefix, the defaults domain, the log directory
  (`~/Library/Logs/<name>`) and the Application Support directory.
- `scripts/brand.env`: the same values for the build scripts (Info.plist, app and DMG names, the dev
  certificate's name), plus the version and the update feed. `scripts/bundle-app.sh` refuses to build
  if the two disagree.

Change both, rebuild, and everything follows, so a renamed app never shares state with the old one.
Optionally also rename the SwiftPM executable target and module (`Package.swift`, `Sources/wisp`,
`Sources/WispCommon`), the `WISP_*` debug variables and the `wisp.*` dispatch-queue labels, and
search-and-replace the name in the docs.

**A fork should use its own bundle ID** (reverse-DNS under a domain it controls, e.g.
`com.example.Wisp`), its own `BRAND_FEED_URL` and its own update key, or leave
`BRAND_SPARKLE_PUBLIC_KEY` empty for builds without updates.

**Changing the bundle ID makes macOS treat the app as a new one**: Screen Recording and
Accessibility must be granted again, its defaults start empty, and existing phantom apps are
replaced. The old app's grants and files stay behind unless the new build carries them over, as
`App/Migration.swift` does for the earlier names (settings copied once, old phantoms removed).
