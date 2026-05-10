#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Ortan Fields
# SPDX-License-Identifier: MIT
# Generated-By: Claude Opus 4.7 (1M Context, 2026-05)

# install.sh — idempotently set up a GTNewHorizons (1.7.10 Forge) server with
# Crucible (Bukkit/Forge hybrid for plugin support).
#
# On every invocation this script (a) refreshes the per-server configuration
# overlay from the config git repo, and (b) re-runs the heavy install
# (download/extract/scrub) only when any of the fingerprinted input variables
# below have changed since the last successful run. Worlds and runtime data
# under SERVER_DIR are preserved across re-installs. Large downloads are
# cached so re-installs don't refetch them.
#
# Heavy install requires curl + unzip; the runtime yolk image lacks them, so
# a fingerprint mismatch on a normal boot causes setup.sh to exit non-zero
# (preventing the server from starting). Resolve via panel Reinstall — version
# bumps and config-baseline review tend to land together anyway.

set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Bash 5.2 introduced patsub_replacement, which makes "&" in the replacement
# string of ${var//pat/repl} mean "the matched text" (sed-style). Disable it
# so render_template can substitute values containing "&" literally without
# escaping. Silently ignored on bash <5.2 where the option doesn't exist.
shopt -u patsub_replacement 2>/dev/null || true

# ============================================================================
# Inputs — edit these to configure the install
# ============================================================================

# GTNH version: must be a key in https://www.gtnewhorizons.com/versions.json
GTNH_VERSION="${GTNH_VERSION:-2.8.4}"

# Java variant of the GTNH server pack: "java8Url" or "java17_2XUrl".
# java17_2XUrl bundles lwjgl3ify and the modern-Java backports — the right
# choice when running modern JREs (which Crucible staging supports).
GTNH_JAVA_VARIANT="java17_2XUrl"

# Crucible release tag, see https://github.com/CrucibleMC/Crucible/releases
# Use "latest" to resolve the most recent staging pre-release at install time.
# (Crucible has had no stable release since 2022, so staging is expected.)
CRUCIBLE_TAG="${CRUCIBLE_TAG:-latest}"

# Server codename. Also used as the branch name in the configuration git repo.
# Changing this on a running server will pull the new branch on next boot
# without triggering a heavy reinstall.
SERVER_CODENAME="${SERVER_CODENAME:-testing}"

# Git repository containing per-server configuration (plugins/, server.properties,
# etc). The branch named SERVER_CODENAME is checked out and overlaid on top
# of the server install — files in the repo win.
CONFIG_GIT_REPO="https://github.com/gregindustri/server-configs.git"

# Where the playable server lives. World saves, logs, and crash-reports under
# this directory are preserved across re-installs.
SERVER_DIR="${SERVER_DIR:-./server}"

# Where to cache large downloads so re-installs don't refetch them.
CACHE_DIR="./.install-cache"

# Where to keep the cloned configuration repo.
CONFIG_REPO_DIR="./.install-config-repo"

# State file used to detect whether a re-install is required.
STATE_FILE="$SERVER_DIR/.install-state.json"

# Env file holding secrets (rcon password, integration tokens, etc) that are
# substituted into *.template files from the config repo. This file lives in
# the server filetree, NOT the (public) config repo. If any *.template files
# are present in the config repo this file is required.
SECRETS_ENV_FILE="$SERVER_DIR/secrets.env"

# Mods shipped with the GTNH pack that conflict with Crucible and must be
# removed after extraction. Entries are filename glob patterns matched against
# $SERVER_DIR/mods/. Add to this list as new conflicts are discovered.
CRUCIBLE_INCOMPATIBLE_MODS=(
	"archaicfix-*.jar"
)

# Files at the root of the GTNH pack that aren't useful on a Crucible server
# (changelogs, the pack's default startup scripts which are replaced by the
# config repo, bundled update notes, etc). Glob patterns relative to $SERVER_DIR.
GTNH_FILES_TO_REMOVE=(
	"changelog*.md"
	"startserver*"
	"updates.html"
)

# Paths to delete from the config repo working tree before overlaying it onto
# the server. Patterns starting with "/" are anchored at the repo root and
# may include shell globs (e.g. "/LICENSE-*"). Other patterns match by
# basename at any depth (e.g. "*.md" removes every Markdown file in the
# tree). Trailing "/" is allowed but ignored — files and directories alike
# are removed recursively.
CONFIG_REPO_EXCLUDES=(
	"*.md"
	".gitignore"
	"/LICENSES/"
	"/LICENSE-*"
	"/COPYRIGHT"
	"/secrets.env.example"
)

# Bump this when the install layout itself changes (e.g. directories scrubbed,
# overlay order). Old installs will be considered stale even if user variables
# haven't moved.
SCRIPT_REVISION="2"

# ============================================================================
# Implementation
# ============================================================================

VERSIONS_JSON_URL="https://www.gtnewhorizons.com/versions.json"
CRUCIBLE_API="https://api.github.com/repos/RetroForge/Crucible"

# Stable filename for the Crucible jar so startup scripts don't have to be
# updated every time CRUCIBLE_TAG changes.
CRUCIBLE_JAR_STABLE="Crucible-server.jar"

log() { printf '\033[1;36m[install]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2
	exit 1
}

ensure_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# ----------------------------------------------------------------------------
# Render a *.template file to an output path. Substitutes $VAR / ${VAR}
# references for variable names listed in $allowed_vars (whitespace-separated,
# expected to be set in the caller). Uses bash parameter expansion for
# literal string replacement — no regex, no shell evaluation. Only names in
# $allowed_vars are substituted, so stray $PATH / $HOME-style strings in
# templates are left alone.
# ----------------------------------------------------------------------------

render_template() {
	local tmpl="$1" out="$2"
	local content var value
	# Read the whole template into a string. The trailing-x trick preserves
	# any final newlines that command substitution would otherwise strip.
	content="$(cat "$tmpl"; printf x)"
	content="${content%x}"
	for var in $allowed_vars; do
		value="${!var:-}"
		# Replace ${VAR} before $VAR so the brace form isn't double-substituted.
		content="${content//\$\{$var\}/$value}"
		content="${content//\$$var/$value}"
	done
	mkdir -p "$(dirname "$out")"
	printf '%s' "$content" >"$out"
}

# ----------------------------------------------------------------------------
# Sync the config git repo, render templates, prune developer-only paths, and
# overlay the result onto $SERVER_DIR. Runs on every invocation, regardless
# of whether the heavy install ran.
# ----------------------------------------------------------------------------

apply_config_overlay() {
	log "Syncing config repo branch '$SERVER_CODENAME' from $CONFIG_GIT_REPO"
	if [ -d "$CONFIG_REPO_DIR/.git" ]; then
		git -C "$CONFIG_REPO_DIR" remote set-url origin "$CONFIG_GIT_REPO"
		git -C "$CONFIG_REPO_DIR" fetch --depth=1 origin "$SERVER_CODENAME"
		git -C "$CONFIG_REPO_DIR" reset --hard FETCH_HEAD
		git -C "$CONFIG_REPO_DIR" clean -fdx
	else
		rm -rf "$CONFIG_REPO_DIR"
		git clone --depth=1 --branch "$SERVER_CODENAME" "$CONFIG_GIT_REPO" "$CONFIG_REPO_DIR"
	fi

	# Find templates BEFORE pruning so they're still on disk to render.
	local templates=()
	local tmpl rel out
	while IFS= read -r -d '' tmpl; do
		templates+=("$tmpl")
	done < <(find "$CONFIG_REPO_DIR" -type d -name '.git' -prune -o -type f -name '*.template' -print0)

	if [ "${#templates[@]}" -gt 0 ]; then
		[ -f "$SECRETS_ENV_FILE" ] ||
			die "config repo contains *.template files but $SECRETS_ENV_FILE does not exist"

		local allowed_vars
		allowed_vars="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$SECRETS_ENV_FILE")"
		[ -n "$allowed_vars" ] ||
			die "$SECRETS_ENV_FILE contains no KEY=value entries — nothing to substitute"
		# Iterate longest names first so that e.g. $RCON_PASSWORD wins over
		# $RCON_PASS when both are present in the secrets file. (Edge case:
		# a non-allowed variable whose name starts with an allowed one will
		# still be partially substituted; templates using ${VAR} are safe.)
		allowed_vars="$(printf '%s\n' $allowed_vars | awk '{ print length, $0 }' | sort -k1,1nr | awk '{print $2}')"

		log "Rendering ${#templates[@]} template file(s) using $SECRETS_ENV_FILE"
		(
			set -a
			# shellcheck source=/dev/null
			. "$SECRETS_ENV_FILE"
			set +a
			for tmpl in "${templates[@]}"; do
				rel="${tmpl#"$CONFIG_REPO_DIR/"}"
				out="$SERVER_DIR/${rel%.template}"
				render_template "$tmpl" "$out"
				log "  rendered ${rel%.template}"
			done
		)
	fi

	log "Pruning excluded paths from the config repo working tree"
	rm -rf "$CONFIG_REPO_DIR/.git"
	find "$CONFIG_REPO_DIR" -type f -name '*.template' -delete
	local pat rel match
	for pat in "${CONFIG_REPO_EXCLUDES[@]}"; do
		if [[ "$pat" == /* ]]; then
			# Anchored at repo root. Allow shell globs in $rel.
			rel="${pat#/}"
			rel="${rel%/}"
			shopt -s nullglob
			# shellcheck disable=SC2206  # intentional glob expansion
			local matches=( "$CONFIG_REPO_DIR/"$rel )
			shopt -u nullglob
			for match in "${matches[@]}"; do
				rm -rf "$match"
			done
		else
			# Any-depth basename match.
			find "$CONFIG_REPO_DIR" -name "${pat%/}" -exec rm -rf {} +
		fi
	done

	log "Overlaying configuration onto $SERVER_DIR"
	cp -a "$CONFIG_REPO_DIR/." "$SERVER_DIR/"

	# Make any shell scripts that came from the config repo executable.
	find "$SERVER_DIR" -maxdepth 2 -type f -name '*.sh' -exec chmod +x {} +
}

# ----------------------------------------------------------------------------
# Lightweight tools — required on every invocation, present in both the egg
# installer image and the runtime yolk image.
# ----------------------------------------------------------------------------

for cmd in jq sha256sum awk sed git find cp; do
	ensure_command "$cmd"
done

mkdir -p "$SERVER_DIR"

# ----------------------------------------------------------------------------
# Fingerprint the heavy-install inputs and decide whether to re-install.
# Inputs that affect only the config overlay (SERVER_CODENAME, CONFIG_GIT_REPO,
# SECRETS_ENV_FILE) are deliberately NOT fingerprinted — those changes apply
# automatically on the next boot via apply_config_overlay.
# ----------------------------------------------------------------------------

FINGERPRINT="$(printf '%s\n' \
	"rev=$SCRIPT_REVISION" \
	"gtnh_version=$GTNH_VERSION" \
	"gtnh_java_variant=$GTNH_JAVA_VARIANT" \
	"crucible_tag=$CRUCIBLE_TAG" \
	"server_dir=$SERVER_DIR" |
	sha256sum | awk '{print $1}')"

prior_fp=""
prior_status=""
if [ -f "$STATE_FILE" ]; then
	prior_fp="$(jq -r '.fingerprint // empty' "$STATE_FILE" 2>/dev/null || true)"
	prior_status="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)"
fi

if [ "$prior_status" = "ok" ] && [ "$prior_fp" = "$FINGERPRINT" ]; then
	log "Install is current (fingerprint $FINGERPRINT)"
	apply_config_overlay
	log "Configuration refreshed."
	exit 0
fi

# Heavy install required (first install, recovery, or input change).
if [ -z "$prior_fp" ]; then
	log "Performing first-time install"
else
	log "Re-install required (status=${prior_status:-unset}, fingerprint changed)"
fi

# ----------------------------------------------------------------------------
# Heavy install — only reached on first install, recovery, or input change.
# Tools below are present in the egg installer image but NOT in the runtime
# yolk image. A fingerprint mismatch on a normal yolk boot fails here, which
# is the intended failure mode (panel Reinstall fixes it).
# ----------------------------------------------------------------------------

for cmd in curl unzip; do
	ensure_command "$cmd"
done

mkdir -p "$CACHE_DIR"

# ----------------------------------------------------------------------------
# Resolve GTNH download URL
# ----------------------------------------------------------------------------

log "Fetching GTNH versions manifest"
versions_json="$(curl -fsSL "$VERSIONS_JSON_URL")"
GTNH_URL="$(jq -r --arg v "$GTNH_VERSION" --arg k "$GTNH_JAVA_VARIANT" \
	'.[$v].server[$k] // empty' <<<"$versions_json")"
[ -n "$GTNH_URL" ] ||
	die "no GTNH server pack found for version=$GTNH_VERSION variant=$GTNH_JAVA_VARIANT"

# ----------------------------------------------------------------------------
# Resolve Crucible release
# ----------------------------------------------------------------------------

log "Resolving Crucible release"
if [ "$CRUCIBLE_TAG" = "latest" ]; then
	# Find the newest staging release that ships both a *-server.jar and a
	# libraries.zip. Crucible's CI has occasionally produced releases missing
	# libraries.zip while their build process is in flux; fall back to the
	# next-newest rather than hard-failing.
	staging_releases="$(curl -fsSL "$CRUCIBLE_API/releases?per_page=20" |
		jq '[.[] | select(.tag_name | startswith("staging-"))]')"
	[ "$(jq 'length' <<<"$staging_releases")" -gt 0 ] ||
		die "no staging Crucible release found"

	newest_staging_tag="$(jq -r '.[0].tag_name' <<<"$staging_releases")"
	crucible_release_json="$(jq '[.[] | select(
			any(.assets[]; .name | endswith("-server.jar")) and
			any(.assets[]; .name == "libraries.zip")
		)][0]' <<<"$staging_releases")"
	[ "$crucible_release_json" != "null" ] ||
		die "no staging Crucible release with both -server.jar and libraries.zip in the last 20"
	CRUCIBLE_TAG_RESOLVED="$(jq -r '.tag_name' <<<"$crucible_release_json")"

	if [ "$CRUCIBLE_TAG_RESOLVED" != "$newest_staging_tag" ]; then
		warn "Newest staging release $newest_staging_tag is missing libraries.zip; falling back to $CRUCIBLE_TAG_RESOLVED"
	fi
else
	crucible_release_json="$(curl -fsSL "$CRUCIBLE_API/releases/tags/$CRUCIBLE_TAG")"
	CRUCIBLE_TAG_RESOLVED="$CRUCIBLE_TAG"
fi

CRUCIBLE_JAR_URL="$(jq -r '[.assets[] | select(.name | endswith("-server.jar"))][0].browser_download_url' <<<"$crucible_release_json")"
CRUCIBLE_JAR_NAME="$(jq -r '[.assets[] | select(.name | endswith("-server.jar"))][0].name' <<<"$crucible_release_json")"
CRUCIBLE_LIBS_URL="$(jq -r '[.assets[] | select(.name == "libraries.zip")][0].browser_download_url' <<<"$crucible_release_json")"
[ -n "$CRUCIBLE_JAR_URL" ] && [ "$CRUCIBLE_JAR_URL" != "null" ] ||
	die "Crucible release $CRUCIBLE_TAG_RESOLVED is missing the server jar"
[ -n "$CRUCIBLE_LIBS_URL" ] && [ "$CRUCIBLE_LIBS_URL" != "null" ] ||
	die "Crucible release $CRUCIBLE_TAG_RESOLVED is missing libraries.zip"

write_state() {
	jq -n \
		--arg fingerprint "$FINGERPRINT" \
		--arg status "$1" \
		--arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg gtnh_version "$GTNH_VERSION" \
		--arg gtnh_java_variant "$GTNH_JAVA_VARIANT" \
		--arg crucible_tag "$CRUCIBLE_TAG" \
		--arg crucible_resolved "$CRUCIBLE_TAG_RESOLVED" \
		--arg server_dir "$SERVER_DIR" \
		'{
            fingerprint: $fingerprint,
            status: $status,
            updated_at: $updated_at,
            gtnh_version: $gtnh_version,
            gtnh_java_variant: $gtnh_java_variant,
            crucible_tag: $crucible_tag,
            crucible_tag_resolved: $crucible_resolved,
            server_dir: $server_dir
        }' >"$STATE_FILE"
}

trap 'write_state failed' ERR
write_state in_progress

# ----------------------------------------------------------------------------
# Download (cached by version-keyed filename)
# ----------------------------------------------------------------------------

download_cached() {
	local url="$1" dest="$2"
	if [ -f "$dest" ]; then
		log "Cached: $(basename "$dest")"
		return 0
	fi
	log "Downloading: $(basename "$dest")"
	curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$dest.partial" "$url"
	mv "$dest.partial" "$dest"
}

GTNH_ZIP_PATH="$CACHE_DIR/GTNH_${GTNH_VERSION}_${GTNH_JAVA_VARIANT}.zip"
CRUCIBLE_JAR_PATH="$CACHE_DIR/$CRUCIBLE_JAR_NAME"
CRUCIBLE_LIBS_PATH="$CACHE_DIR/Crucible_${CRUCIBLE_TAG_RESOLVED}_libraries.zip"

download_cached "$GTNH_URL" "$GTNH_ZIP_PATH"
download_cached "$CRUCIBLE_JAR_URL" "$CRUCIBLE_JAR_PATH"
download_cached "$CRUCIBLE_LIBS_URL" "$CRUCIBLE_LIBS_PATH"

# ----------------------------------------------------------------------------
# Scrub pack-owned content from SERVER_DIR.
#
# We only remove things the GTNH/Crucible packs own, so removed entries (e.g. a
# mod dropped between versions) don't linger. World saves, logs, plugin data
# directories created at runtime, and anything else are explicitly preserved.
# ----------------------------------------------------------------------------

log "Scrubbing pack-owned files in $SERVER_DIR (worlds, logs, plugins kept)"
for path in mods libraries config scripts asm coremods journeymap serverutilities; do
	rm -rf "${SERVER_DIR:?}/$path"
done
find "$SERVER_DIR" -maxdepth 1 -type f \( \
	-name 'forge-*.jar' -o \
	-name 'minecraft_server*.jar' -o \
	-name 'Crucible-*.jar' -o \
	-name 'lwjgl3ify-*.jar' -o \
	-name 'startserver.sh' -o \
	-name 'startserver.bat' -o \
	-name 'eula.txt' -o \
	-name 'changelog*.md' \
	\) -delete 2>/dev/null || true
rm -f "$SERVER_DIR/$CRUCIBLE_JAR_STABLE"

# ----------------------------------------------------------------------------
# Extract GTNH server pack, then overlay Crucible libraries
# ----------------------------------------------------------------------------

extract_zip_into() {
	# Extract a zip into target dir. If the zip has a single top-level wrapper
	# directory, descend into it transparently. cp -a preserves attributes
	# and merges with whatever already exists in target.
	local zip="$1" target="$2"
	local tmp src
	tmp="$(mktemp -d)"
	unzip -q -o "$zip" -d "$tmp"
	shopt -s nullglob dotglob
	local entries=("$tmp"/*)
	shopt -u nullglob dotglob
	if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
		src="${entries[0]}"
	else
		src="$tmp"
	fi
	cp -a "$src/." "$target/"
	rm -rf "$tmp"
}

log "Extracting GTNH server pack into $SERVER_DIR"
extract_zip_into "$GTNH_ZIP_PATH" "$SERVER_DIR"

log "Removing Crucible-incompatible mods"
shopt -s nullglob
for pattern in "${CRUCIBLE_INCOMPATIBLE_MODS[@]}"; do
	for match in "$SERVER_DIR/mods/"$pattern; do
		log "  removed mods/$(basename "$match")"
		rm -f "$match"
	done
done

log "Removing useless files from $SERVER_DIR root"
for pattern in "${GTNH_FILES_TO_REMOVE[@]}"; do
	for match in "$SERVER_DIR/"$pattern; do
		[ -f "$match" ] || continue
		log "  removed $(basename "$match")"
		rm -f "$match"
	done
done
shopt -u nullglob

log "Overlaying Crucible libraries into $SERVER_DIR/libraries"
mkdir -p "$SERVER_DIR/libraries"
extract_zip_into "$CRUCIBLE_LIBS_PATH" "$SERVER_DIR/libraries"

log "Installing Crucible server jar"
cp -f "$CRUCIBLE_JAR_PATH" "$SERVER_DIR/$CRUCIBLE_JAR_NAME"
ln -sfn "$CRUCIBLE_JAR_NAME" "$SERVER_DIR/$CRUCIBLE_JAR_STABLE"

# ----------------------------------------------------------------------------
# Apply config overlay AFTER the heavy install so it wins over pack defaults.
# ----------------------------------------------------------------------------

apply_config_overlay

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------

write_state ok
trap - ERR

log "Install complete."
log "  Server dir: $SERVER_DIR"
log "  GTNH:       $GTNH_VERSION ($GTNH_JAVA_VARIANT)"
log "  Crucible:   $CRUCIBLE_TAG_RESOLVED  -> $CRUCIBLE_JAR_STABLE"
log "  Codename:   $SERVER_CODENAME"
