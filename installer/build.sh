#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Ortan Fields
# SPDX-License-Identifier: MIT
# Generated-By: Claude Opus 4.7 (1M Context, 2026-05)


# build.sh — assemble dist/egg.yml from egg.yml + stub.sh + setup.sh.
#
# Combines stub.sh and setup.sh into a single installer (setup.sh is embedded
# inside stub.sh as a quoted heredoc), then splices the result into egg.yml
# at the __INSTALLATION_SCRIPT__ marker.

set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

OUT_DIR="dist"
OUT_EGG="$OUT_DIR/egg.yml"

mkdir -p "$OUT_DIR"

COMBINED="$(mktemp)"
INDENTED="$(mktemp)"
trap 'rm -f "$COMBINED" "$INDENTED"' EXIT

# Replace the __SETUP_SH_HEREDOC__ marker line in stub.sh with a heredoc
# that writes setup.sh verbatim to /mnt/server/setup.sh. Quoted EOF prevents
# the outer shell from expanding $VAR references in setup.sh at install time.
awk -v setup_file="setup.sh" '
	/^# __SETUP_SH_HEREDOC__$/ {
		print "cat > /mnt/server/setup.sh <<'\''__SETUP_SH_EOF__'\''"
		while ((getline line < setup_file) > 0) print line
		close(setup_file)
		print "__SETUP_SH_EOF__"
		next
	}
	{ print }
' stub.sh > "$COMBINED"

# Indent for the YAML literal block under scripts.installation.script (|-).
sed 's/^/      /' "$COMBINED" > "$INDENTED"

# Replace the placeholder line in egg.yml with the indented installer.
awk -v inserted_file="$INDENTED" '
	/^      __INSTALLATION_SCRIPT__$/ {
		while ((getline line < inserted_file) > 0) print line
		close(inserted_file)
		next
	}
	{ print }
' egg.yml > "$OUT_EGG"

echo "Wrote $OUT_EGG ($(wc -l < "$OUT_EGG") lines, $(wc -c < "$OUT_EGG") bytes)"
