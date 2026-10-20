PREFIX  ?= $(HOME)/.local/bin
APPDIR  ?= $(HOME)/Applications
# reverse-DNS of the GitHub handle; override with `make install LABEL=…`
LABEL   ?= com.tangentyh.displaykeep
# set on the command line to retire an older agent label in one shot:
#   make install LEGACY=com.old.handle.displaykeep
LEGACY  ?=
VERSION ?= 1.3
LOGPATH ?= $(HOME)/Library/Logs/displaykeep.log
OUT     := .build
APPNAME := DisplayKeep.app
APP     := $(OUT)/$(APPNAME)
PKGNAME := displaykeep-$(VERSION)
# releases are cut from CHANGELOG.md: the section for $(VERSION) is the release body
NOTESFILE := $(OUT)/release-notes.md
BIN     := $(APP)/Contents/MacOS/displaykeep
INSTALLED := $(APPDIR)/$(APPNAME)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
PLIST   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
INTERVAL ?= 3

build: $(BIN)

$(BIN): DisplayKeep.swift Info.plist displaykeep.plist.in
	mkdir -p $(APP)/Contents/MacOS
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@VERSION@|$(VERSION)|g' \
	    Info.plist > $(APP)/Contents/Info.plist
	swiftc -O -o $(BIN) DisplayKeep.swift
	codesign --force --sign - $(APP)

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
	@shasum -a 256 $(OUT)/$(PKGNAME).zip | tee $(OUT)/$(PKGNAME).zip.sha256
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

.PHONY: build run run-headless install migrate uninstall pause resume toggle off on status log notes package clean login-on login-off
