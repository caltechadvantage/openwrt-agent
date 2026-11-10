#!/bin/sh

# Update Script for OpenWrt Monitoring Service
# Usage: ./update.sh          - update to latest main
#        ./update.sh v2.16.0  - update to a specific tag/branch/commit
#
# The agent is fetched as a tarball, not `git clone`/`git fetch`: a stock
# BusyBox image has no git, and installing git-http drags in a libcurl
# chain that fails on constrained devices. uclient-fetch + BusyBox tar/gzip
# are base-system, so update needs zero extra packages.

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENWRT_DIR="${OPENWRT_DIR:-/root/openwrt}"
REPO="caltechadvantage/openwrt-agent"

# The shell that is already running may be an older update.sh. As soon
# as the new tree is in place, exec that tree's post-update instead of
# reading the rest of the file we just overwrote.
if [ "${1:-}" = "--post-update" ]; then
    if [ "${UPDATE_SKIP_RESTART:-0}" != "1" ]; then
        /etc/init.d/openwrt-main stop 2>/dev/null || true
        sleep 1
        killall python3 2>/dev/null || true
        killall run_main.sh 2>/dev/null || true
        /etc/init.d/openwrt-main start 2>/dev/null || true
    fi
    exec sh "$OPENWRT_DIR/scripts/post_update.sh"
fi

cd "$OPENWRT_DIR" || { echo -e "${RED}ERROR: $OPENWRT_DIR not found${NC}"; exit 1; }

# ---- Dashboard status reporter ----------------------------------------------
# Publish an update-progress telemetry frame straight to ThingsBoard's HTTP
# telemetry endpoint. We don't go through the python agent for this because
# the agent is about to be killed. uclient-fetch is the stock OpenWrt HTTPS
# client — curl is NOT installed on a base image, which is why the old
# curl-based reporter here silently never delivered.
TB_URL="$(python3 -c 'import sys; sys.path.insert(0,"/root/openwrt"); from settings import TB_SERVER_URL; print(TB_SERVER_URL)' 2>/dev/null)"
TB_TOKEN="$(python3 -c 'import json; print(json.load(open("/root/.openwrt/config.json")).get("tb_token",""))' 2>/dev/null)"

publish_status() {
    [ -z "$TB_URL" ] && return 0
    [ -z "$TB_TOKEN" ] && return 0
    uclient-fetch -q -T 5 -O /dev/null \
        --post-data="$1" \
        "$TB_URL/api/v1/$TB_TOKEN/telemetry" >/dev/null 2>&1
}

die() {
    echo -e "${RED}ERROR: $1${NC}"
    publish_status "{\"update_status\":\"failed\",\"update_error\":\"$1\"}"
    exit 1
}

# Current version comes from the CI-stamped VERSION file (a dev checkout
# may lack it — fall back to "unknown").
current_version="$( [ -f "$OPENWRT_DIR/VERSION" ] && cat "$OPENWRT_DIR/VERSION" || echo unknown )"
echo -e "${CYAN}Current:${NC} ${current_version}"

# Step 1: Download the target tarball and swap files in place.
#
# codeload accepts a branch, tag, or commit as the ref and unpacks to a
# single top-level <repo>-<ref> directory, which we copy over the existing
# install. No .git, so nothing to diverge or force-reset.
echo -e "${GREEN}[1/4]${NC} Downloading code..."
publish_status '{"update_status":"pulling"}'
if [ -n "${UPDATE_SRC_DIR:-}" ]; then
    src="$UPDATE_SRC_DIR"
else
    target="${1:-main}"
    url="https://codeload.github.com/$REPO/tar.gz/$target"
    tmp_tgz="/tmp/openwrt-agent-update.tar.gz"
    tmp_dir="/tmp/openwrt-agent-update"
    rm -rf "$tmp_tgz" "$tmp_dir"
    mkdir -p "$tmp_dir"
    uclient-fetch -q -T 60 -O "$tmp_tgz" "$url" || die "download_failed"
    tar xzf "$tmp_tgz" -C "$tmp_dir" || die "extract_failed"
    src="$(echo "$tmp_dir"/*/)"
    rm -rf "$tmp_tgz"
fi
[ -d "$src" ] || die "extract_empty"
src="${src%/}"
cp -r "$src"/. "$OPENWRT_DIR/" || die "copy_failed"
if [ -n "${tmp_dir:-}" ]; then
    rm -rf "$tmp_dir"
fi

# Do not keep reading this file: the copy above may have replaced it.
# The tree just installed finishes the restart and the migrations.
if [ "${UPDATE_DRY_RUN:-0}" = "1" ]; then
    echo "EXEC $OPENWRT_DIR/update.sh --post-update"
    exit 0
fi
exec sh "$OPENWRT_DIR/update.sh" --post-update
