PREFIX  ?= $(HOME)/.local/bin
APPDIR  ?= $(HOME)/Applications
# reverse-DNS of the GitHub handle; override with `make install LABEL=…`
LABEL   ?= com.tangentyh.displaykeep
# set on the command line to retire an older agent label in one shot:
#   make install LEGACY=com.old.handle.displaykeep
LEGACY  ?=
VERSION ?= 1.3.1
LOGPATH ?= $(HOME)/Library/Logs/displaykeep.log
OUT     := .build
APPNAME := DisplayKeep.app
APP     := $(OUT)/$(APPNAME)
PKGNAME := displaykeep-$(VERSION)
# releases are cut from CHANGELOG.md: the section for $(VERSION) is the release body
NOTESFILE := $(OUT)/release-notes.md
BIN     := $(APP)/Contents/MacOS/displaykeep
ICONSET := $(OUT)/AppIcon.iconset
ICNS    := $(APP)/Contents/Resources/AppIcon.icns
INSTALLED := $(APPDIR)/$(APPNAME)
# the throwaway copy `make dev` runs beside an installed app; nothing else reads it
DEVROOT ?= /tmp/displaykeep-dev
DEVAPP  := $(DEVROOT)/$(APPNAME:.app=-dev.app)
DEVBIN  := $(DEVAPP)/Contents/MacOS/displaykeep
DEVPID  := $(DEVROOT)/pid
DEVHOME := $(DEVROOT)/home
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
PLIST   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
INTERVAL ?= 3

build: $(BIN)

# The bundle icon is drawn, not checked in: scripts/make-icon.swift renders every size and
# iconutil packs them. It is a prerequisite of $(BIN) because the signature seals the bundle's
# resources — a new icon without a re-sign is a bundle that fails codesign --verify.
$(ICNS): scripts/make-icon.swift
	mkdir -p $(APP)/Contents/Resources
	rm -rf $(ICONSET)
	swift scripts/make-icon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

$(BIN): DisplayKeep.swift Info.plist displaykeep.plist.in $(ICNS)
	mkdir -p $(APP)/Contents/MacOS
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@VERSION@|$(VERSION)|g' \
	    Info.plist > $(APP)/Contents/Info.plist
	swiftc -O -o $(BIN) DisplayKeep.swift
	codesign --force --sign - $(APP)

# redraw the icon after editing scripts/make-icon.swift; rebuilds and re-signs to match
icon:
	rm -rf $(ICONSET) $(ICNS)
	$(MAKE) build

# run in the foreground, verbose, with the menu bar icon
run: build
	$(BIN) -v

# headless (no menu bar icon) — for ssh/launchd debugging
run-headless: build
	$(BIN) -v -x

# override the poll interval: make install INTERVAL=5
# for a regexp filter, put it in options.json (see below) or edit ProgramArguments in the
# generated plist (add -m <app>)
install: build migrate
	mkdir -p $(APPDIR) $(PREFIX) $(HOME)/Library/LaunchAgents "$(HOME)/Library/Application Support/displaykeep"
	$(LSREGISTER) -u "$(INSTALLED)" 2>/dev/null || true
	rm -rf $(INSTALLED)
	ditto $(APP) $(INSTALLED)
	ln -sfn $(INSTALLED)/Contents/MacOS/displaykeep $(PREFIX)/displaykeep
	sed -e 's|@LABEL@|$(LABEL)|g' \
	    -e 's|@BIN@|$(INSTALLED)/Contents/MacOS/displaykeep|g' \
	    displaykeep.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	# the app reads these when launched with no argv (login items, and this agent)
	printf '{\n  "interval": %s\n}\n' "$(INTERVAL)" \
	    > "$(HOME)/Library/Application Support/displaykeep/options.json"
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl enable gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)
	$(LSREGISTER) -f "$(INSTALLED)" 2>/dev/null || true
	@echo "installed as $(LABEL); icon appears in the menu bar. status: displaykeep status"
	@echo ""
	@echo "this is the launchd agent path: the app's \"Start at login\" switch will show it"
	@echo "as managed and leave it alone. to start at login WITHOUT an agent instead"
	@echo "(no KeepAlive restart), use make uninstall, then the menu's checkbox."

# Stop the copy we started, and only that: the recorded pid is checked against the dev binary
# first, so a recycled pid cannot take an unrelated process down with it, and the recipe waits
# for the daemon to go (it releases the assertion on TERM) before its bundle is replaced.
# Not a target: it has to run inside `dev` and `dev-clean`, not as a prerequisite in between.
define stop-dev-copy
	@pid=$$(cat $(DEVPID) 2>/dev/null); \
	if [ -n "$$pid" ] && [ "$$(ps -p "$$pid" -o comm= 2>/dev/null)" = "$(DEVBIN)" ]; then \
	    kill "$$pid" 2>/dev/null || true; \
	    n=0; while kill -0 "$$pid" 2>/dev/null && [ $$n -lt 20 ]; do sleep 0.1; n=$$((n+1)); done; \
	fi; \
	rm -f $(DEVPID)
endef

# a second instance beside whatever is installed, without touching it — for watching a build
# hold its own assertion next to the release's one, or for testing a glyph/state change you do
# not want to install. `make dev-clean` undoes it.
#
# Three things make the copy possible, and all three are load-bearing:
#   * the daemon is single-instance (flock in ~/Library/Application Support/displaykeep/lock),
#     so the copy needs a support dir of its own. HOME does NOT redirect Foundation on macOS;
#     CFFIXED_USER_HOME does (support dir, ~/Library/Logs, homeDirectoryForCurrentUser).
#   * it gets its own bundle id: the plist edit breaks the signature, so it is re-signed, and
#     two LaunchServices records with one id make Finder's icon and the "Start at login" switch
#     ambiguous. Turn that switch off from the dev copy's own menu before dev-clean; it is a
#     separate login item, and deleting the bundle would orphan it.
#   * it is not `make install`: that writes options.json into the shared support dir and
#     bootstraps a LaunchAgent, which would fight the installed copy for the same binary.
dev: build
	$(stop-dev-copy)
	@mkdir -p $(DEVROOT)
	@$(LSREGISTER) -u "$(DEVAPP)" 2>/dev/null || true
	@rm -rf "$(DEVAPP)" $(DEVHOME)
	ditto $(APP) "$(DEVAPP)"
	plutil -replace CFBundleIdentifier -string $(LABEL).dev "$(DEVAPP)/Contents/Info.plist"
	codesign --force --sign - "$(DEVAPP)"
	@$(LSREGISTER) -f "$(DEVAPP)" 2>/dev/null || true
	@nohup env CFFIXED_USER_HOME=$(DEVHOME) "$(DEVBIN)" -v >/dev/null 2>&1 & echo $$! > $(DEVPID)
	@sleep 1; if kill -0 "$$(cat $(DEVPID))" 2>/dev/null; then \
	    echo "dev copy running (pid $$(cat $(DEVPID))) as $(LABEL).dev"; \
	    echo "  state:  $(DEVHOME)/Library/Application Support/displaykeep"; \
	    echo "  log:    $(DEVHOME)/Library/Logs/displaykeep.log"; \
	    echo "  status: make dev-status        remove: make dev-clean"; \
	else \
	    echo "dev copy exited at startup — see $(DEVHOME)/Library/Logs/displaykeep.log" >&2; \
	    tail -n 5 "$(DEVHOME)/Library/Logs/displaykeep.log" 2>/dev/null >&2; \
	    exit 1; \
	fi

# the dev copy's own state, from its own env — `displaykeep status` without the env var reads
# the installed app's support dir and answers a different question
dev-status:
	@env CFFIXED_USER_HOME=$(DEVHOME) "$(DEVBIN)" status || true

# quit it, forget its LaunchServices record, drop the whole tree: /tmp, ~/Applications and
# /Applications are not touched
dev-clean:
	$(stop-dev-copy)
	@$(LSREGISTER) -u "$(DEVAPP)" 2>/dev/null || true
	@rm -rf $(DEVROOT)
	@echo "removed $(DEVROOT); the installed copy was not touched"

# one-time: retire the pre-rename agent, its plist and its LaunchServices record
migrate:
	@if [ -n "$(LEGACY)" ] && [ -f "$(HOME)/Library/LaunchAgents/$(LEGACY).plist" ]; then \
	    echo "retiring legacy agent $(LEGACY)"; \
	    launchctl bootout gui/$$(id -u)/$(LEGACY) 2>/dev/null || true; \
	    launchctl disable gui/$$(id -u)/$(LEGACY) 2>/dev/null || true; \
	    rm -f "$(HOME)/Library/LaunchAgents/$(LEGACY).plist"; \
	fi
	@$(LSREGISTER) -u "$(INSTALLED)" 2>/dev/null || true

uninstall:
	launchctl disable gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST) $(PREFIX)/displaykeep
	rm -rf $(INSTALLED)
	rm -f $(HOME)/Library/Application\ Support/displaykeep/state.json

# pause/resume without touching launchd: survives restarts, releases the assertion now
pause:
	$(PREFIX)/displaykeep pause || true
resume:
	$(PREFIX)/displaykeep resume || true
toggle:
	$(PREFIX)/displaykeep toggle || true

# the blunt instrument: unload the agent entirely (persists across login) and back
off:
	$(PREFIX)/displaykeep pause || true
	launchctl disable gui/$$(id -u)/$(LABEL)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
on:
	launchctl enable gui/$$(id -u)/$(LABEL)
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	$(PREFIX)/displaykeep resume || true

# start at login the login-item way (no launchd agent, no crash restart)
login-on:
	$(PREFIX)/displaykeep login on || true
login-off:
	$(PREFIX)/displaykeep login off || true

status:
	@$(PREFIX)/displaykeep status || true
	@printf 'login: '
	@$(PREFIX)/displaykeep login status || true
	@printf 'agent: '
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null \
	    | sed -n 's/^[[:space:]]*state = \(.*\)/\1/p' | head -1 || echo "not loaded"
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null \
	    | sed -n 's/^[[:space:]]*pid = \(.*\)/pid \1/p' | head -1
	@pmset -g assertions | sed -n '/PreventUserIdleDisplaySleep/p' || true

log:
	tail -n 40 -F $(LOGPATH)

# the version the three literals must agree on (Makefile, DisplayKeep.swift, CHANGELOG.md);
# .github/workflows/build.yml asserts that they do
version:
	@echo $(VERSION)

# the changelog section for $(VERSION): the exact body of the GitHub release
notes:
	@scripts/release-notes.sh $(VERSION)

# release artifact: the ad-hoc signed .app, zipped (ditto keeps the bundle intact), plus the
# release body (.build/release-notes.md) and checksum the release workflow uploads.
# Fails, before writing the zip, when CHANGELOG.md has no section for $(VERSION).
package: build
	@scripts/release-notes.sh $(VERSION) > $(NOTESFILE)
	rm -rf $(OUT)/pkg && mkdir -p $(OUT)/pkg
	ditto $(APP) $(OUT)/pkg/$(APPNAME)
	ditto -c -k --norsrc --keepParent $(OUT)/pkg/$(APPNAME) $(OUT)/$(PKGNAME).zip
	# hashed from inside $(OUT) so the checksum names the asset, not the build path —
	# `shasum -a 256 -c displaykeep-<v>.zip.sha256` has to work in a download directory
	@cd $(OUT) && shasum -a 256 $(PKGNAME).zip | tee $(PKGNAME).zip.sha256
	@sed -e 's|@PKGNAME@|$(PKGNAME)|g' \
	     -e "s|@SHA@|$$(cut -d' ' -f1 $(OUT)/$(PKGNAME).zip.sha256)|g" \
	     scripts/release-trailer.md.in >> $(NOTESFILE)
	@echo "body: $(NOTESFILE)"
	@echo "tag:  git tag -a v$(VERSION) -m 'displaykeep v$(VERSION)' && git push --follow-tags"

# unregister the dev build so Spotlight / "Open With" only ever see ~/Applications
# (a hidden build dir is not indexed by mds at all; this covers the rebuild case)
clean:
	-$(LSREGISTER) -u $(APP) 2>/dev/null
	rm -rf $(OUT)

.PHONY: build run run-headless install migrate uninstall pause resume toggle off on status log notes package clean login-on login-off icon dev dev-status dev-clean
