# displaykeep

macOS keeps two idle timers apart: **system sleep** (`PreventUserIdleSystemSleep`) and
**display sleep** (`PreventUserIdleDisplaySleep`). Audio players only take the first one,
so music keeps the machine awake while the panel still blanks at `displaysleep`.

There is no way to ask macOS to "promote" an existing system-sleep assertion into a display
one — assertions are typed and owned per process, and there is no notification API for
assertion changes. So you hold the display assertion yourself, driven by polling.

One process does it all: the poll loop, a **menu bar icon** showing whether it is currently
in effect, and a **pause toggle**.

## tl;dr without building anything

```sh
caffeinate -d -w $(pgrep -x NeteaseMusic)     # display stays on while the app runs
caffeinate -d                                 # just keep the display on, until ^C
sudo pmset -a displaysleep 0                  # no software at all: never sleep the display
```

`caffeinate -d -w` is tied to process lifetime, not playback, so it also keeps the screen on
while the app is paused. The tool below keys off the actual assertion.

## Build / run

```sh
make build                       # -> .build/DisplayKeep.app (ad-hoc signed, LSUIElement)
make run                         # foreground, verbose, menu bar icon appears
make install                     # ~/Applications/DisplayKeep.app + launchd agent
make uninstall
```

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
.build/                                           build output, gitignored, not installed
```

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

| Glyph | State | Meaning |
| --- | --- | --- |
| filled cup | **holding** | we hold `PreventUserIdleDisplaySleep`; the display will not sleep |
| outline cup (dim) | **armed** | watching, but nothing holds the system awake — the display may sleep |
| pause circle | **paused** | you turned it off; the assertion is released |
| warning triangle | **failed** | `IOPMAssertionCreateWithName` returned an error — the menu says which |

`holding` is not self-reported: after acquiring, the daemon re-reads
`IOPMCopyAssertionsByProcess()` and checks that *its own* assertion is really there
(`verified` in the state file). If the assertion ever disappears behind its back, it says so
and re-acquires. Hover the icon for the same line plus the trigger that caused it.

Click the icon for the menu: current state, the live trigger list (`app(pid) — assertion`),
**Pause / Resume**, **Pause for…** (15 m / 30 m / 1 h / 4 h), the poll settings, the log, and
Quit. `⌘P` toggles, `⌘Q` quits.

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

Logs go to `/tmp/displaykeep.log` under launchd (menu → Open log).

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
