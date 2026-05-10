#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Ortan Fields
# SPDX-License-Identifier: MIT
# Generated-By: Claude Opus 4.7 (1M Context, 2026-05)


# build.sh — assemble dist/egg.yml from egg.yml + stub.sh + setup.sh + icon.png.
#
# Combines stub.sh and setup.sh into a single installer (setup.sh is embedded
# inside stub.sh as a quoted heredoc), then splices the result into egg.yml
# at the __INSTALLATION_SCRIPT__ marker. Also re-encodes icon.png as a
# base64 data URI and substitutes it for the __ICON_DATA_URI__ marker.

set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

OUT_DIR="dist"
OUT_EGG="$OUT_DIR/egg.yml"

mkdir -p "$OUT_DIR"

COMBINED="$(mktemp)"
INDENTED="$(mktemp)"
ICON_URI_FILE="$(mktemp)"
trap 'rm -f "$COMBINED" "$INDENTED" "$ICON_URI_FILE"' EXIT

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

# Encode icon.png to a single-line base64 data URI for the egg's image field.
# Written to a file because the data URI exceeds the awk -v argument limit.
{ printf 'data:image/png;base64,'; base64 -w0 icon.png; } > "$ICON_URI_FILE"

# Replace both placeholder lines in egg.yml: the installer script (multi-line)
# and the icon data URI (single-line, read from $ICON_URI_FILE).
awk \
	-v inserted_file="$INDENTED" \
	-v icon_uri_file="$ICON_URI_FILE" '
	/^      __INSTALLATION_SCRIPT__$/ {
		while ((getline line < inserted_file) > 0) print line
		close(inserted_file)
		next
	}
	/^image: '\''__ICON_DATA_URI__'\''$/ {
		getline uri < icon_uri_file
		close(icon_uri_file)
		printf "image: '\''%s'\''\n", uri
		next
	}
	{ print }
' egg.yml > "$OUT_EGG"

echo "Wrote $OUT_EGG ($(wc -l < "$OUT_EGG") lines, $(wc -c < "$OUT_EGG") bytes)"
