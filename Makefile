PREFIX  ?= $(HOME)/.local/bin
APPDIR  ?= $(HOME)/Applications
# reverse-DNS of the GitHub handle; override with `make install LABEL=…`
LABEL   ?= com.tangentyh.displaykeep
# set on the command line to retire an older agent label in one shot:
#   make install LEGACY=com.old.handle.displaykeep
LEGACY  ?=
VERSION ?= 1.1
OUT     := .build
APPNAME := DisplayKeep.app
APP     := $(OUT)/$(APPNAME)
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
# for a regexp filter, edit ProgramArguments in the generated plist (add -m <app>)
install: build migrate
	mkdir -p $(APPDIR) $(PREFIX) $(HOME)/Library/LaunchAgents
	$(LSREGISTER) -u "$(INSTALLED)" 2>/dev/null || true
	rm -rf $(INSTALLED)
	ditto $(APP) $(INSTALLED)
	ln -sfn $(INSTALLED)/Contents/MacOS/displaykeep $(PREFIX)/displaykeep
	sed -e 's|@LABEL@|$(LABEL)|g' \
	    -e 's|@BIN@|$(INSTALLED)/Contents/MacOS/displaykeep|g' \
	    -e 's|@INTERVAL@|$(INTERVAL)|g' displaykeep.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl enable gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)
	$(LSREGISTER) -f "$(INSTALLED)" 2>/dev/null || true
	@echo "installed as $(LABEL); icon appears in the menu bar. status: displaykeep status"

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

status:
	@$(PREFIX)/displaykeep status || true
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null | rg 'state|pid' || echo "agent not loaded"
	@pmset -g assertions | rg 'PreventUserIdleDisplaySleep|displaykeep' || true

log:
	tail -f /tmp/displaykeep.log

# unregister the dev build so Spotlight / "Open With" only ever see ~/Applications
# (a hidden build dir is not indexed by mds at all; this covers the rebuild case)
clean:
	-$(LSREGISTER) -u $(APP) 2>/dev/null
	rm -rf $(OUT)

.PHONY: build run run-headless install migrate uninstall pause resume toggle off on status log clean
