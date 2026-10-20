#!/bin/sh
# Print the CHANGELOG section for one version — the body of the GitHub release.
#
#   scripts/release-notes.sh 1.3      # bullets under "## [1.3] - …"
#
# Exits non-zero when the section is missing or empty, so a tag cannot be published with no
# notes. Accepts both "## [1.3] - date" and the older bare "## 1.3".
set -eu

version=${1:?usage: release-notes.sh <version, e.g. 1.3>}

notes=$(awk -v v="$version" '
	$0 ~ "^## \\[?" v "\\]?( |$)" { inside = 1; next }
	/^## / && inside             { exit }
	inside                       { print }
' CHANGELOG.md)

# Trim the blank line after the heading and any trailing blanks, so the body starts at the
# first bullet and the file ends cleanly after the last one.
notes=$(printf '%s\n' "$notes" | awk '
	{ line[NR] = $0 }
	NF { if (!first) first = NR; last = NR }
	END { for (i = first; i <= last; i++) print line[i] }
')

if [ -z "$notes" ]; then
	printf 'release-notes: no changelog section for %s\n' "$version" >&2
	printf 'release-notes: expected a "## [%s] - YYYY-MM-DD" heading in CHANGELOG.md\n' "$version" >&2
	exit 1
fi

printf '%s\n' "$notes"
