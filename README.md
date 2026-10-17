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

### From a release (no Xcode needed)

```sh
unzip -o displaykeep-1.2.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/DisplayKeep.app    # see below
open ~/Applications/DisplayKeep.app
```

Then add `DisplayKeep.app` to System Settings → General → **Login Items** if you want it to
start at login. It is an `LSUIElement` app: menu bar only, no Dock icon, no windows.

> The release zip is **ad-hoc signed** (`codesign -s -`), not notarized — there is no
> Developer ID behind it. macOS will refuse the first launch with "cannot be opened because
> the developer cannot be verified". Right-click → **Open**, or run the `xattr` line above.
> Building from source avoids the prompt entirely.

### From source (gets the launchd agent)

```sh
make build                       # -> .build/DisplayKeep.app (ad-hoc signed, LSUIElement)
make run                         # foreground, verbose, menu bar icon appears
make install                     # ~/Applications/DisplayKeep.app + launchd agent
make uninstall
make package                     # -> .build/displaykeep-<version>.zip for a release
```

Needs macOS 13+ and the Xcode Command Line Tools (`swiftc`). No SPM, no dependencies.

Build output lives in `.build/`, hidden on purpose: Spotlight/LaunchServices do not index
hidden directories, so a dev build never turns up as a second "displaykeep" in Spotlight or
"Open With" — the only registered copy is `~/Applications/DisplayKeep.app`. `make clean`
also `lsregister -u`s the build copy for the window between build and clean.

Installed layout (the label / bundle id is `com.tangentyh.displaykeep`, reverse-DNS of the
GitHub handle; override with `make install LABEL=…`):

```
~/Applications/DisplayKeep.app                    the app (single binary inside)
~/.local/bin/displaykeep -> .../MacOS/displaykeep CLI, same executable
~/Library/LaunchAgents/com.tangentyh.displaykeep.plist
~/Library/Logs/displaykeep.log                    launchd stdout/stderr
```

`make install` takes `INTERVAL=5` for the poll rate. The launchd path is worth preferring
over Login Items: it restarts on crash, stays quit when you choose Quit, and has one place to
look when something is off (`make status`).

Options (daemon):

```sh
./displaykeep                    # default: any user-facing holder of a system-sleep assertion
./displaykeep -m NeteaseMusic    # only for matching processes (deterministic, recommended)
./displaykeep -i 5 -v            # poll 5s, verbose
./displaykeep -n                 # dry run: report only, never take the assertion
./displaykeep -x                 # headless: no menu bar icon (for ssh/launchd debugging)
```

For a filter under launchd, edit `ProgramArguments` in the generated plist (add `-m <app>`).

## The menu bar icon

Left to right in the image above: **holding**, **armed**, **paused**.

| Glyph | State | Meaning |
| --- | --- | --- |
| filled cup, normal tint | **holding** | we hold `PreventUserIdleDisplaySleep`; the display will not sleep |
| outline cup, dimmed | **armed** | watching, but nothing holds the system awake — the display may sleep |
| pause circle, dimmed | **paused** | you turned it off; the assertion is released |
| orange warning triangle | **failed** | `IOPMAssertionCreateWithName` returned an error — the menu says which |

`holding` is not self-reported: after acquiring, the daemon re-reads
`IOPMCopyAssertionsByProcess()` and checks that *its own* assertion is really there
(`verified` in the state file). If the assertion ever disappears behind its back, it says so
and re-acquires. Hover the icon for the same line plus the trigger that caused it.

Click the icon for the menu: current state, the live trigger list (`app(pid) — assertion`),
**Pause / Resume**, **Pause for…** (15 m / 30 m / 1 h / 4 h), the poll settings, the log, and
Quit. `⌘P` toggles, `⌘Q` quits.

The glyph is a template image, so it follows the menu bar appearance; the two idle states are
dimmed with `appearsDisabled` rather than a hardcoded colour, which is what keeps the icon
legible over both a light and a dark menu bar.

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

The log is `~/Library/Logs/displaykeep.log` (menu → Open log, or `make log`). Under /tmp it
was world-readable and got cleaned out from under launchd; now it is per-user, and it is
truncated at startup once it passes ~1 MiB so a long-lived daemon stays bounded.

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
