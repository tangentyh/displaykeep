# displaykeep

![the status item, left to right: holding, armed, paused](docs/menubar.png)

**Keeps the display awake only while some other process is already keeping the Mac awake.**

macOS runs two idle timers apart: **system sleep** (`PreventUserIdleSystemSleep`) and
**display sleep** (`PreventUserIdleDisplaySleep`). Audio players only take the first one, so
music keeps the machine awake while the panel still blanks at `displaysleep`.

Usually that is exactly right. It stops being right when the speakers are the monitor: the
screen blanks, the audio dies, and the machine is wide awake doing nothing about it. There is
no way to ask macOS to "promote" an existing system-sleep assertion into a display one —
assertions are typed and owned per process, and there is no notification API for assertion
changes. So this holds the display assertion itself, driven by polling, and gives it back the
moment the other assertion goes away.

That is the whole tool. One process: poll loop, a menu bar icon showing whether it is
currently in effect, and a pause toggle.

## Why not just…

| Approach | Keys off | Doesn't fit when |
| --- | --- | --- |
| `caffeinate -d -w $(pgrep -x Music)` | the app's **lifetime** | you pause playback — the display stays on anyway; and the app has to be named up front |
| Amphetamine / Keepresso / Jiggler "audio playing" trigger | Now Playing or output-device state | the player has to cooperate with those APIs; behaviour varies by app and OS release |
| `sudo pmset -a displaysleep 0` | nothing | the display then never sleeps again |
| **displaykeep** | the `PreventUserIdleSystemSleep` assertion **itself** | nothing to get wrong — it mirrors what the system already believes |

Because it mirrors assertion state rather than guessing at playback, there is no per-app
configuration: any producer counts — a browser tab, AirPlay, `ffmpeg`, a game, a DJ app — and
it releases the display as soon as the last one stops.

## Install

### Homebrew (tap)

```sh
brew install --cask tangentyh/tap/displaykeep
```

That puts `DisplayKeep.app` in `/Applications` and links the CLI into the Homebrew bin
directory, so `displaykeep status` works without a checkout. It installs the same ad-hoc
signed release zip described below; the tap clears the quarantine flag for you, which is the
one Gatekeeper check `brew` would otherwise leave standing (see the note below).
`brew upgrade --cask displaykeep` follows new releases, `brew uninstall --cask displaykeep`
removes the app, and `--zap` takes the state file and log with it.

### From a release (no Xcode needed)

```sh
unzip -o displaykeep-1.3.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/DisplayKeep.app    # see below
open ~/Applications/DisplayKeep.app
```

Click the menu bar icon and pick **Start at login** if you want it to run from now on.
That registers it with macOS as a login item (`SMAppService`), so it shows up — and can be
turned off — in System Settings → General → **Login Items**. It is an `LSUIElement` app:
menu bar only, no Dock icon, no windows.

> The release zip is **ad-hoc signed** (`codesign -s -`), not notarized — there is no
> Developer ID behind it. macOS will refuse the first launch with "cannot be opened because
> the developer cannot be verified". Right-click → **Open**, or run the `xattr` line above.
> Building from source avoids the prompt entirely, and the Homebrew cask runs that `xattr`
> step itself.

### From source (gets the launchd agent)

```sh
make build                       # -> .build/DisplayKeep.app (ad-hoc signed, LSUIElement)
make icon                        # redraw the app icon, then rebuild and re-sign
make run                         # foreground, verbose, menu bar icon appears
make install                     # ~/Applications/DisplayKeep.app + launchd agent
make uninstall
make dev                         # second copy under /tmp, beside whatever is installed
make dev-clean                   # quit it and delete it
make package                     # -> .build/displaykeep-<version>.zip for a release
```

Needs macOS 13+ and the Xcode Command Line Tools (`swiftc`). No SPM, no dependencies.

Build output lives in `.build/`, hidden on purpose: Spotlight/LaunchServices do not index
hidden directories, so a dev build never turns up as a second "displaykeep" in Spotlight or
"Open With" — the only registered copy is `~/Applications/DisplayKeep.app`. `make clean`
also `lsregister -u`s the build copy for the window between build and clean.

Installed layout (the label / bundle id is `com.tangentyh.displaykeep`, reverse-DNS of the
GitHub handle; override with `make install LABEL=…`). A Homebrew install differs: the app
sits in `/Applications`, the `displaykeep` link is in the Homebrew prefix, and there is no
LaunchAgent — that path uses the login item instead:

```
~/Applications/DisplayKeep.app                    the app (single binary inside)
~/.local/bin/displaykeep -> .../MacOS/displaykeep CLI, same executable
~/Library/LaunchAgents/com.tangentyh.displaykeep.plist
~/Library/Application Support/displaykeep/options.json
~/Library/Logs/displaykeep.log                    app log (the app writes it itself)
```

`make install` takes `INTERVAL=5` for the poll rate; a filter goes in `options.json` (next
section). The launchd path is worth preferring over Login Items: it restarts on crash, stays
quit when you choose Quit, and has one place to look when something is off (`make status`).
The app's `Start at login` switch detects that agent and shows itself as managed rather than
registering a second supervisor.

Options (daemon):

```sh
./displaykeep                    # default: any user-facing holder of a system-sleep assertion
./displaykeep -m NeteaseMusic    # only for matching processes (deterministic, recommended)
./displaykeep -i 5 -v            # poll 5s, verbose
./displaykeep -n                 # dry run: report only, never take the assertion
./displaykeep -x                 # headless: no menu bar icon (for ssh/launchd debugging)
```

For a filter under launchd, put it in `options.json` (below) — argv is only read when you
run the app yourself.

### A dev copy beside the installed one

To see a build hold its own assertion next to an installed release, or to try a glyph or
state change without installing it, `make dev` runs a second copy with its own bundle id,
state and log, all of it under `/tmp/displaykeep-dev`:

```sh
make dev          # build, copy, re-sign as com.tangentyh.displaykeep.dev, start it verbose
make dev-status   # that copy's state, read from its own support dir
make dev-clean    # quit it, forget its LaunchServices record, delete /tmp/displaykeep-dev
```

`~/Applications`, `/Applications` and your real `state.json` are never touched. The two menu
bar icons are the point: pause one and the other keeps its assertion. Two things it cannot do
for you — **do not flip "Start at login" in a dev copy**, because that registers a login item
of its own that outlives the bundle (turn it off from the same menu before `make dev-clean`);
and do not reach for `make install` here, since it writes `options.json` into the shared
support dir and bootstraps an agent that would fight the installed copy.

The redirection is the load-bearing part: the daemon is single-instance per support dir
(`flock` in `~/Library/Application Support/displaykeep/lock`), and `HOME` does not redirect
Foundation on macOS — `CFFIXED_USER_HOME` does, which is what gives the copy its own
`~/Library/Application Support/displaykeep` and `~/Library/Logs/displaykeep.log`. The bundle
id is rewritten too, because two LaunchServices records sharing one id make Finder's icon and
the login-item switch ambiguous, and the copy is re-signed after that edit because an edited
`Info.plist` fails the signature.

## Releases

A tag is the release. `CHANGELOG.md` is the source of truth: the section under a version
heading is copied verbatim into the GitHub release body, then the `release` workflow builds
the zip on a macOS runner and publishes it — the artifact is reproducible from the tag alone.

```sh
# 1. write the section users will read: "## [1.4] - YYYY-MM-DD"
# 2. bump VERSION in the Makefile, then eyeball the body and the artifact
make notes VERSION=1.4            # the changelog section, exactly as published
make package VERSION=1.4          # -> .build/displaykeep-1.4.zip, .zip.sha256, release-notes.md
# 3. tag the commit that has the section; CI does the rest
git tag -a v1.4 -m 'displaykeep v1.4' && git push --follow-tags
```

`make package` fails before writing the zip when `CHANGELOG.md` has no section for that
version, and the workflow additionally refuses a tag that is not an ancestor of `main` or
whose bundle `CFBundleShortVersionString` disagrees with it. The published body is the
changelog section plus a fixed install/checksum trailer (`scripts/release-trailer.md.in`), so
hand-cut and CI releases read the same.

The cask in [`tangentyh/homebrew-tap`](https://github.com/tangentyh/homebrew-tap) follows a
release on its own: the tap's `brew bump` workflow looks for the newest GitHub release daily
and opens a version-plus-sha256 pull request, so tagging is still the only publish step.

Versions are semver-ish: **minor** when the set of assertions that count changes (a new
filter or exclusion) or the CLI/state-file surface grows, **patch** for the rest — the
filters are the part that has to keep up with macOS, so minors are the normal bump. Nothing
the release body would want to say may sit under `## [Unreleased]` at tag time.

## The menu bar icon

Left to right in the image above: **holding**, **armed**, **paused**.

| Glyph | State | Meaning |
| --- | --- | --- |
| display, normal tint | **holding** | we hold `PreventUserIdleDisplaySleep`; the display will not sleep |
| display, dimmed | **armed** | watching, but nothing holds the system awake — the display may sleep |
| pause circle, dimmed | **paused** | you turned it off; the assertion is released |
| orange warning triangle | **failed** | `IOPMAssertionCreateWithName` returned an error — the menu says which |

The glyph is a display, not a coffee cup: this app holds a display assertion, and the cup was
inherited from the caffeine tools — it said "keep the computer awake" and disagreed with the
app icon, which is the same monitor with a sun in it. `holding` and `armed` are that one glyph
at two opacities, which is also how the state reads: a bright screen that is being held awake,
and a dim one that may sleep.

`holding` is not self-reported: after acquiring, the daemon re-reads
`IOPMCopyAssertionsByProcess()` and checks that *its own* assertion is really there
(`verified` in the state file). If the assertion ever disappears behind its back, it says so
and re-acquires. Hover the icon for the same line plus the trigger that caused it.

Click the icon for the menu: current state, the live trigger list (`app(pid) — assertion`),
**Pause / Resume**, **Pause for…** (15 m / 30 m / 1 h / 4 h), **Start at login**, the poll
settings, the log, the version, and Quit. `⌘P` toggles, `⌘Q` quits.

The last grey row is `displaykeep 1.3 · macOS 14.2`. There is no About window — this app has
none — and a version number is nearly all an About box would have to say. The OS release sits
beside it because that is the other half of any report about the filters, which track IOKit
internals that move between macOS releases.

As every menu bar item is, it is a template image, so it follows the bar's appearance; the two
idle states are dimmed with `appearsDisabled` rather than a hardcoded colour, which is what
keeps the icon legible over both a light and a dark menu bar.

All four glyphs are drawn into a canvas as wide as the widest of them (19pt, the display's
width), because a variable-length status item takes its width from its image and the symbols
are not all the same width: `pause.circle` is 15pt and the warning triangle 17pt, so before
this the item — and every menu bar item to its left — shifted 4 points whenever you paused.
The ink is centred inside the symbol's own bounds already, so padding it costs nothing
visually and the item keeps one width in every state. The picture above is rendered by
`scripts/menubar-sheet.swift` rather than screenshotted, so it is regenerated when a glyph
changes.

The **app icon** is the same idea in colour: a display on an indigo plate with a sun in it,
because keeping the display awake is the whole job. It is drawn rather than checked in —
`scripts/make-icon.swift` renders the ten sizes `iconutil` wants and `make build` packs them
into `Contents/Resources/AppIcon.icns`, so there is no binary art in the repo and the icon is
readable as Swift. `make icon` redraws and re-signs after you edit it. You will see it in
Finder, Spotlight and System Settings → Login Items; the app is `LSUIElement`, so it never
shows up in the Dock. LaunchServices caches a bundle's icon, so right after a rebuild Finder
can still show the old (or generic) picture until it re-scans the bundle.

## Start at login

One switch in the menu, **Start at login**. There is deliberately no choice of mechanism:
which supervisor runs the app is an implementation detail, and two of them at once is how
you get a "Quit" that sometimes comes back.

| Menu item | Means |
| --- | --- |
| `Start at login` unchecked | nothing starts it — you launched it by hand |
| `Start at login` checked | registered as a login item via `SMAppService` |
| `Start at login — approve in System Settings…` | registered, but a human has to say yes; clicking opens the Login Items pane |
| `Start at login — launchd agent` (greyed) | `make install` set up a LaunchAgent; the switch defers to it |
| `Start at login — move it to Applications first` (greyed) | running from a quarantined download (App Translocation) or the dev build in `.build/` |

```sh
displaykeep login             # on / off / unavailable, exit 0 when on
make login-on                 # same, through the installed CLI
make login-off
```

What the login-item path gives up against the launchd agent: `KeepAlive` (no restart after a
crash) and `Nice`. What it gains: the app is visible in System Settings → Login Items where
the user already looks, instead of a plist in `~/Library/LaunchAgents` that outlives the app.
In both cases a clean **Quit** stays quit until the next login. Registering from inside the
app also survives being moved to `/Applications` — a `SMAppService.agent` plist could not,
because its path has to be baked in at build time.

## Toggling without the mouse

```sh
displaykeep pause                # pause indefinitely (releases the assertion immediately)
displaykeep pause 30             # 30 minutes (bare number = minutes)
displaykeep pause 45s            # 45 seconds; 1h, 1h30m also work
displaykeep resume
displaykeep toggle
```

The switch is a file, so it survives restarts of the daemon and works from anything that can
run a command — Shortcuts, a Stream Deck, ssh, cron:

```sh
touch ~/Library/Application\ Support/displaykeep/paused      # pause
rm    ~/Library/Application\ Support/displaykeep/paused      # resume
echo $(( $(date +%s) + 1800 )) > …/paused                    # pause 30 minutes
```

A deadline resumes by itself. `make pause / resume / toggle` are thin wrappers;
`make off / on` additionally `launchctl disable/enable` the agent (which is what persists
across login — `bootout` alone comes back at the next login).

## Scripting against it

```sh
displaykeep --version       # displaykeep 1.3 (also -V, or `displaykeep version`)
displaykeep status          # human line + exit code
displaykeep status --json   # raw state file
```

| Exit | State |
| --- | --- |
| 0 | holding the display assertion |
| 1 | armed, nothing to hold (display free to sleep) |
| 2 | paused |
| 3 | not running / stale (state older than 3×interval, or pid gone) |
| 4 | last acquisition failed |

`displaykeep status` reads the state file and cross-checks liveness, so it reports a wedged
daemon as `stalled` rather than trusting a stale "holding".

## Files

All under `~/Library/Application Support/displaykeep/`:

| File | Purpose |
| --- | --- |
| `state.json` | pid, holding, verified, paused, triggers, tick counter, last error — rewritten every tick (atomic) |
| `paused` | present = paused; contents = epoch deadline or `forever` |
| `lock` | `flock`, so a second instance exits instead of adding a second menu bar icon |
| `options.json` | `interval` and `match`, read at startup — the only way settings survive a login-item launch, which has no argv |

The log is `~/Library/Logs/displaykeep.log` (menu → Open log, or `make log`). The app opens
it itself (and `dup2`s stderr into it) instead of relying on launchd's `StandardOutPath`, so
a login-item launch logs to the same file as an agent launch. Under /tmp it was
world-readable and got cleaned out from under launchd; now it is per-user, and it is
truncated at startup once it passes ~1 MiB so a long-lived daemon stays bounded.

`options.json` is what a supervisor launch sees, since `SMAppService` and launchd start the
app without arguments; explicit flags still win when you run it yourself:

```json
{ "interval": 5, "match": "NeteaseMusic" }
```

## How it works

Every `-i` seconds (default 3) the process calls `IOPMCopyAssertionsByProcess()` (cheap,
no fork/exec), collects `kIOPMAssertionTypePreventUserIdleSystemSleep` assertions, and then

- holds `kIOPMAssertionTypePreventUserIdleDisplaySleep` while the set is non-empty,
- calls `IOPMAssertionRelease()` as soon as it becomes empty.

Filters that matter (all discovered the hard way):

- `powerd` holds `Prevent sleep while display is on` — a *consequence* of our own assertion.
  Counting it latches the tool on forever.
- `runningboardd` relays xpc/extension/service assertions (`com.apple.CFNetwork.StorageDB`,
  dataaccess, Time Machine intents, ...) that hold `PreventUserIdleSystemSleep` almost
  constantly; in default mode those are filtered, otherwise the display never sleeps.
- `usernoted` holds a system-sleep assertion while a notification banner is pending —
  counting it flashes the display on for every notification.
- `proc_name(3)` fails for other users' processes (powerd, coreaudiod → empty name); this
  uses `sysctl(KERN_PROC_PID)` instead.
- `caffeinate` itself is excluded so the two tools can coexist.

## Verified behaviour

```
idle                              PreventUserIdleDisplaySleep  0   status: armed        (1)
/media holds system-sleep        PreventUserIdleDisplaySleep  1   status: holding      (0)
                                  ... verified: assertion visible in IOKit
displaykeep pause                 PreventUserIdleDisplaySleep  0   status: paused       (2)
displaykeep resume                PreventUserIdleDisplaySleep  1   status: holding      (0)
/media stops                      PreventUserIdleDisplaySleep  0   status: armed        (1)
kill -TERM                        assertion released, state.json removed, agent stays down
kill -SEGV                        restarted by launchd after ThrottleInterval (10 s)
```

with a test holder (`/tmp/dksim`, the same IOKit call an audio player makes), plus release on
SIGINT/SIGTERM/SIGHUP, and the menu bar icon present as an `LSUIElement` app under launchd.

The login item path was verified the same way, from an ad-hoc signed copy in `~/Applications`
(not `/Applications`):

```
displaykeep login status          off — not registered            (exit 1)
displaykeep login on              on  — login item, registered     (exit 0)
sfltool dumpbtm                   Identifier: 2.<bundle id>, Disposition: [enabled, allowed, notified]
displaykeep login off             off                              (exit 1)
make install                      Start at login — launchd agent   (switch defers to the plist)
```

If `SMAppService.mainApp.status` reads `.notFound`, that just means "not registered yet" on a
fresh unsigned-by-anyone bundle — `register()` still succeeds; do not treat it as an error.

## Gotchas

- The plist uses `KeepAlive → SuccessfulExit: false`, so "Quit" from the menu stays quit and
  crashes still restart. Don't implement pause as `exit()` — the daemon would be restarted.
- `ProcessType` is `Interactive`: a status-item host under `Background` gets App Nap and the
  icon falls behind the timer. `NSAppSleepDisabled` in `Info.plist` belt-and-braces it.
- If the icon goes missing, the menu bar may be full (macOS hides the newest status items),
  or check System Settings → Control Center → "Allow in the Menu Bar".
- Upgrading from an older label: `make install LEGACY=com.old.handle.displaykeep` retires the
  old agent, its plist and its LaunchServices record (the old bundle id would otherwise keep a
  second "displaykeep" in Spotlight / Open With).
- `selfSustaining` matches on process name, and `p_comm` truncates at 16 chars — that matters
  for both the self-exclusion and `-m` patterns.

## Status

A personal tool that turned out to be worth keeping installed, published in case the IOKit
notes above save someone else the afternoon. It reads power-management internals that Apple
changes without notice: treat "works on my macOS" as the honest warranty. Issues and
corrections welcome; the filters are the part most likely to need updating on a new release.

## License

MIT — see [LICENSE](LICENSE). Changes in [CHANGELOG.md](CHANGELOG.md).
