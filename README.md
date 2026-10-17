# displaykeep

macOS keeps two idle timers apart: **system sleep** (`PreventUserIdleSystemSleep`) and
**display sleep** (`PreventUserIdleDisplaySleep`). Audio players only take the first one,
so music keeps the machine awake while the panel still blanks at `displaysleep`.

There is no way to ask macOS to "promote" an existing system-sleep assertion into a display
one — assertions are typed and owned per process, and there is no notification API for
assertion changes. So you hold the display assertion yourself, driven by polling.

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
make build
./displaykeep                    # default: any user-facing holder of a system-sleep assertion
./displaykeep -m NeteaseMusic    # only for matching processes (deterministic, recommended)
./displaykeep -i 5 -v            # poll 5s, verbose
./displaykeep -n                 # dry run: report only
make install                     # launchd agent com.tangentyh.displaykeep, auto-start at login
make status
make uninstall
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
- `proc_name(3)` fails for other users' processes (powerd, coreaudiod → empty name); this
  uses `sysctl(KERN_PROC_PID)` instead.
- `caffeinate` itself is excluded so the two tools can coexist.

## Verified behaviour

```
idle                              PreventUserIdleDisplaySleep  0
/media holds system-sleep        PreventUserIdleDisplaySleep  1   (ours)
/media stops                     PreventUserIdleDisplaySleep  0
```

with a test holder (`/tmp/musicsim`, same IOKit call as an audio player), plus release on
SIGINT/SIGTERM/SIGHUP.
