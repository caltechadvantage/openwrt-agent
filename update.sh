#!/bin/sh

# Update Script for OpenWrt Monitoring Service
# Usage: ./update.sh          - pull latest from current branch
#        ./update.sh main     - checkout and pull specific branch
#        ./update.sh abc123   - checkout specific commit/tag

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENWRT_DIR="/root/openwrt"

cd "$OPENWRT_DIR" || { echo -e "${RED}ERROR: $OPENWRT_DIR not found${NC}"; exit 1; }

# ---- Dashboard status reporter ----------------------------------------------
# Publish an update-progress telemetry frame straight to ThingsBoard's HTTP
# telemetry endpoint. We don't go through the python agent for this because
# the agent is about to be killed. Uses the same tb_token the agent uses.
TB_URL="$(python3 -c 'import sys; sys.path.insert(0,"/root/openwrt"); from settings import TB_SERVER_URL; print(TB_SERVER_URL)' 2>/dev/null)"
TB_TOKEN="$(python3 -c 'import json; print(json.load(open("/root/.openwrt/config.json")).get("tb_token",""))' 2>/dev/null)"

publish_status() {
    [ -z "$TB_URL" ] && return 0
    [ -z "$TB_TOKEN" ] && return 0
    curl -sS -m 5 -X POST \
        -H 'Content-Type: application/json' \
        --data "$1" \
        "$TB_URL/api/v1/$TB_TOKEN/telemetry" >/dev/null 2>&1
}

die() {
    echo -e "${RED}ERROR: $1${NC}"
    publish_status "{\"update_status\":\"failed\",\"update_error\":\"$1\"}"
    exit 1
}

# Show current state
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
current_commit=$(git rev-parse --short HEAD 2>/dev/null)
echo -e "${CYAN}Current:${NC} branch=${current_branch} commit=${current_commit}"

# Step 1: Fetch and hard-align to remote.
#
# We used to `git checkout -- . && git pull`. That breaks on git 2.27+
# whenever origin/main is force-pushed (branch tags rewritten during a
# release) — pull sees divergent history and refuses without an explicit
# reconcile policy. On a router the working tree is disposable; origin is
# the source of truth. So fetch, then reset --hard to the target ref.
echo -e "${GREEN}[1/4]${NC} Updating code..."
publish_status '{"update_status":"pulling"}'
git fetch origin --prune --tags || die "git_fetch_failed"

target="${1:-main}"

if git show-ref --verify --quiet "refs/remotes/origin/$target"; then
    echo -e "${CYAN}       Aligning to origin/${target}${NC}"
    git checkout -B "$target" "origin/$target" 2>/dev/null || die "git_checkout_failed"
    git reset --hard "origin/$target" || die "git_reset_failed"
else
    # Not a branch — treat as tag or commit, detach so we don't clobber a branch ref.
    echo -e "${CYAN}       Checking out ref: $target${NC}"
    git checkout --force --detach "$target" || die "git_checkout_ref_failed"
fi

new_commit=$(git rev-parse --short HEAD 2>/dev/null)
echo -e "${CYAN}       Updated to: ${new_commit}${NC}"

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
    # Prefer the CI-stamped VERSION file (compiled dist). Fall back to
    # grepping the source file — dev-checkout routers only.
    if [ -f "$OPENWRT_DIR/VERSION" ]; then
        version=$(cat "$OPENWRT_DIR/VERSION")
    else
        version=$(grep 'PROJECT_VERSION' "$OPENWRT_DIR/utils/thingsboard.py" 2>/dev/null | head -1 | cut -d'"' -f2)
    fi
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
