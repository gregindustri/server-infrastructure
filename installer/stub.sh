#!/bin/bash
# SPDX-FileCopyrightText: 2026 Ortan Fields
# SPDX-License-Identifier: MIT
# Generated-By: Claude Opus 4.7 (1M Context, 2026-05)

# GTNH Installation
#
# stub.sh: egg-specific bootstrap. Installs tools, drops setup.sh into
# /mnt/server, and runs it. Egg variables (GTNH_VERSION, CRUCIBLE_TAG,
# SERVER_CODENAME) flow through the environment into setup.sh.
#
# This file is consumed by build.sh, which substitutes __SETUP_SH_HEREDOC__
# with the full contents of setup.sh as a quoted heredoc. The result is
# spliced into egg.yml.
#
# Server Files: /mnt/server

set -e

apt update
apt install -y curl jq unzip git rsync gettext-base

mkdir -p /mnt/server
cd /mnt/server

# In the egg, /mnt/server is the persistent volume that becomes
# /home/container at runtime. setup.sh's default of ./server would put the
# Crucible jar one level too deep for the egg's startup command.
export SERVER_DIR=.

# __SETUP_SH_HEREDOC__

chmod +x /mnt/server/setup.sh
/mnt/server/setup.sh
