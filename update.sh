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
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENWRT_DIR="/root/openwrt"
REPO="caltechadvantage/openwrt-agent"

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
target="${1:-main}"
url="https://codeload.github.com/$REPO/tar.gz/$target"

tmp_tgz="/tmp/openwrt-agent-update.tar.gz"
tmp_dir="/tmp/openwrt-agent-update"
rm -rf "$tmp_tgz" "$tmp_dir"
mkdir -p "$tmp_dir"
uclient-fetch -q -T 60 -O "$tmp_tgz" "$url" || die "download_failed"
tar xzf "$tmp_tgz" -C "$tmp_dir" || die "extract_failed"
src="$(echo "$tmp_dir"/*/)"
[ -d "$src" ] || die "extract_empty"
cp -r "$src". "$OPENWRT_DIR/" || die "copy_failed"
rm -rf "$tmp_tgz" "$tmp_dir"

new_version="$( [ -f "$OPENWRT_DIR/VERSION" ] && cat "$OPENWRT_DIR/VERSION" || echo unknown )"
echo -e "${CYAN}       Updated to: ${new_version}${NC}"

# Step 2: Stop service and kill stale processes
echo -e "${GREEN}[2/4]${NC} Stopping service..."
publish_status '{"update_status":"restarting"}'
/etc/init.d/openwrt-main stop 2>/dev/null
sleep 2
killall python3 2>/dev/null
killall run_main.sh 2>/dev/null
sleep 1

if ps | grep "main.py" | grep -qv grep; then
    echo -e "${YELLOW}WARNING: Process still running, force killing...${NC}"
    killall -9 python3 2>/dev/null
    sleep 1
fi

# Step 3: Start service
echo -e "${GREEN}[3/4]${NC} Starting service..."
/etc/init.d/openwrt-main start
sleep 3

# Step 4: Verify
echo -e "${GREEN}[4/4]${NC} Verifying..."
if ps | grep "main.py" | grep -qv grep; then
    version="$new_version"
    [ -z "$version" ] && version="unknown"
    echo -e "${GREEN}OK${NC} - Service running (${version})"
    echo -e "${CYAN}Logs:${NC} tail -f /var/log/openwrt.log"
    publish_status "{\"update_status\":\"completed\",\"update_new_version\":\"${version}\"}"
else
    echo -e "${RED}ERROR: Service failed to start${NC}"
    echo -e "${CYAN}Check:${NC} tail -f /var/log/openwrt.log"
    publish_status '{"update_status":"failed","update_error":"service_start_failed"}'
    exit 1
fi
