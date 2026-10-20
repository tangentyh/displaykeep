# Changelog

Newest first. A heading is a git tag (`v1.3`) and the bullets under it are exactly the body of
the GitHub release — `make notes` prints them, `make package` writes them to
`.build/release-notes.md`, and the `release` workflow publishes that file. Loosely
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); no link refs, the headings are read
by a script.

## [Unreleased]

- The bundle finally has an app icon: a display with a sun in it, on an indigo plate. It is
  drawn by `scripts/make-icon.swift` and packed with `iconutil` at build time rather than
  checked in as a `.icns`, so the sizes stay consistent and the repo still has no binary art;
  `make icon` redraws it. Until now the bundle had no `CFBundleIconFile` at all, so Finder,
  Spotlight and System Settings → Login Items showed the generic document icon. The menu bar
  glyph is unchanged.
- Installable from Homebrew: `brew install --cask tangentyh/tap/displaykeep` puts the app in
  `/Applications` and links the CLI, so `displaykeep status` works without a checkout. The
  cask carries the quarantine-clearing step itself, since the release is ad-hoc signed — the
  README and the release trailer now lead with this.
- The build is now visible: a grey `displaykeep 1.3 · macOS 14.2` row at the bottom of the
  menu, `displaykeep --version` (`-V`, or `displaykeep version`), and the version named in
  the startup log line. Before this it appeared only in `state.json`, so an issue about a
  filter that stopped matching on a new macOS could not say which build was being tested —
  and the OS release sits on the same row because that is the other half of the answer.

## [1.3] - 2026-10-20

- **Start at login** is now a switch in the menu bar (and `displaykeep login [on|off|status]`),
  for people who installed a release zip and never see the Makefile. It registers the app as
  a login item through `SMAppService`, so it is visible and removable in System Settings →
  General → Login Items instead of being a plist that outlives the bundle.
- One mechanism at a time, chosen by the app: if a LaunchAgent from `make install` exists the
  switch shows "launchd agent" and refuses to register a second supervisor. Registration is
  refused outright when running from a quarantined download (App Translocation) or from
  `.build/`, where the registered path would not survive a reboot.
- `options.json` in the app support directory supplies `interval` / `match` to a supervised
  launch, which has no argv. `make install` writes it (`INTERVAL=…`), and the LaunchAgent
  plist no longer passes `-i`.
- The app opens `~/Library/Logs/displaykeep.log` itself and redirects stderr into it, instead
  of depending on launchd's `StandardOutPath`. "Open log" now works for a login-item launch.
- `make status` reports the login state; `make login-on` / `make login-off` mirror the switch.
- Releases are cut from this changelog: a `v*` tag runs the `release` workflow, which builds
  the zip with `make package` and publishes the matching section as the release body.

## [1.2] - 2026-10-17

- Log moved from `/tmp/displaykeep.log` to `~/Library/Logs/displaykeep.log` (per-user,
  not world-readable, not reaped by the periodic `/tmp` clean-out). The file is truncated
  at startup once it passes ~1 MiB, so a long-lived launchd instance stays bounded.
- Status item glyphs no longer force `.secondaryLabelColor`: on a dark or translucent
  menu bar the armed/paused cup rendered nearly black. The template tint is left to the
  system and the idle states use `appearsDisabled` instead.
- `make package` builds the release zip; `make status` no longer requires ripgrep.

## [1.1] - 2026-10-17

- Menu bar indicator with four states (holding / armed / paused / failed), self-verified
  against IOKit after every acquisition.
- `state.json` rewritten atomically every tick; `displaykeep status [--json]` returns an
  exit code for scripts.
- Pause toggle, "Pause for…", and a `paused` flag file (`flock`-guarded daemon, one icon).
- Install label moved to `com.tangentyh.displaykeep`.

## [1.0] - 2026-10-17

- Hold `PreventUserIdleDisplaySleep` while another process holds
  `PreventUserIdleSystemSleep`, polled via `IOPMCopyAssertionsByProcess()`.
