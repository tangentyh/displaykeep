<!--
Title: start with the type of change, e.g. "Add ...", "Fix ...", "Refactor ...".
Keep it concise and descriptive.
-->

## Summary

<!-- What changed, and why? One or two sentences. -->

## Changes

<!--
Bullet the notable edits. Call out files explicitly — DisplayKeep.swift,
Makefile, Info.plist, displaykeep.plist.in, README.md, CHANGELOG.md.
-->

-

## Context

<!-- Background, linked issues, prior attempts, related PRs. -->

## Type of change

<!-- Keep the one that applies and delete the rest. -->

- Feature (new behavior or capability)
- Fix (incorrect or broken behavior)
- Refactor (no behavior change)
- Docs
- Build / release tooling (Makefile, packaging, CI)

## Verification

<!-- How was this validated? Paste the commands used and the observed result. -->

- [ ] `make clean build` compiles without warnings
- [ ] `make run` — menu bar icon reflects the new behavior (describe below)
- [ ] `make status` still reports login state, agent state, and the `PreventUserIdleDisplaySleep` assertion
- [ ] Exercised end-to-end: playback playing → display stays awake; playback stopped → assertion released
- [ ] If packaging changed: `make package` produces a launchable zip (note the sha256)

## Checklist

- [ ] Change is scoped to the stated intent; unrelated edits are split out
- [ ] `README.md` / `CHANGELOG.md` describe the behavior change (and `VERSION` in the Makefile, if releasing)
- [ ] No secrets, tokens, or machine-specific paths committed
- [ ] Commit messages follow the repo convention: one logical change per commit, imperative subject
