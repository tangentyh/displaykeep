PREFIX ?= $(HOME)/.local/bin
LABEL  := com.tangentyh.displaykeep
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
INTERVAL ?= 3

build: displaykeep

displaykeep: DisplayKeep.swift
	swiftc -O -o $@ $<

# override the poll interval: make install INTERVAL=5
# for a regexp filter, edit ProgramArguments in the generated plist (add -m <app>)
install: displaykeep
	mkdir -p $(PREFIX) $(HOME)/Library/LaunchAgents
	install -m 755 displaykeep $(PREFIX)/displaykeep
	sed -e 's|@BIN@|$(PREFIX)/displaykeep|g' \
	    -e 's|@INTERVAL@|$(INTERVAL)|g' com.tangentyh.displaykeep.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)
	@echo "installed; status: launchctl print gui/$$(id -u)/$(LABEL) | head -20"

uninstall:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST) $(PREFIX)/displaykeep

status:
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null | rg 'state|pid' || echo "not loaded"
	@pmset -g assertions | rg 'PreventUserIdleDisplaySleep|displaykeep'

clean:
	rm -f displaykeep

.PHONY: build install uninstall status clean
