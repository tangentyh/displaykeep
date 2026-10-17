# Changelog

## 1.2

- Log moved from `/tmp/displaykeep.log` to `~/Library/Logs/displaykeep.log` (per-user,
  not world-readable, not reaped by the periodic `/tmp` clean-out). The file is truncated
  at startup once it passes ~1 MiB, so a long-lived launchd instance stays bounded.
- Status item glyphs no longer force `.secondaryLabelColor`: on a dark or translucent
  menu bar the armed/paused cup rendered nearly black. The template tint is left to the
  system and the idle states use `appearsDisabled` instead.
- `make package` builds the release zip; `make status` no longer requires ripgrep.

## 1.1

- Menu bar indicator with four states (holding / armed / paused / failed), self-verified
  against IOKit after every acquisition.
- `state.json` rewritten atomically every tick; `displaykeep status [--json]` returns an
  exit code for scripts.
- Pause toggle, "Pause for…", and a `paused` flag file (`flock`-guarded daemon, one icon).
- Install label moved to `com.tangentyh.displaykeep`.

## 1.0

- Hold `PreventUserIdleDisplaySleep` while another process holds
  `PreventUserIdleSystemSleep`, polled via `IOPMCopyAssertionsByProcess()`.
