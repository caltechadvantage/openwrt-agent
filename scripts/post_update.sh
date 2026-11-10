#!/bin/sh
# Migrations that must run from the tree that was just installed.
#
# update.sh execs this after it swaps files. A router whose updater is
# still the old 2.17 script never execs it, so main.py also starts this
# once per BUILD_SHA. It does not stop the agent and does not kill
# python or MQTT. nginx may reload itself.

OPENWRT_DIR="${OPENWRT_DIR:-/root/openwrt}"
STAMP="${POST_UPDATE_STAMP:-/root/.openwrt/post_update_done}"
LOCK="${POST_UPDATE_LOCK:-/root/.openwrt/post_update.lock}"
LOG="${POST_UPDATE_LOG:-/root/.openwrt/post_update.log}"

mkdir -p "$(dirname "$STAMP")" "$(dirname "$LOG")"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$*" >> "$LOG"
}

if [ -n "${POST_UPDATE_SHA:-}" ]; then
    sha="$POST_UPDATE_SHA"
elif [ -f "$OPENWRT_DIR/BUILD_SHA" ]; then
    sha=$(sed -n '1p' "$OPENWRT_DIR/BUILD_SHA" | tr -d ' \t\r\n')
else
    sha=$(sed -n 's/^PROJECT_VERSION = "//p; s/"$//p' "$OPENWRT_DIR/utils/thingsboard.py" 2>/dev/null | head -n 1)
    [ -n "$sha" ] || sha="source"
fi

if ! mkdir "$LOCK" 2>/dev/null; then
    holder=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$LOCK"
    fi
    if ! mkdir "$LOCK" 2>/dev/null; then
        log "locked, another post_update is running"
        exit 0
    fi
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT INT TERM

if [ -f "$STAMP" ]; then
    done=$(sed -n '1p' "$STAMP" | tr -d ' \t\r\n')
    if [ "$done" = "$sha" ]; then
        log "already applied $sha"
        exit 0
    fi
fi

log "start $sha"
rc=0
if [ -f "$OPENWRT_DIR/scripts/setup_nginx_luci.sh" ]; then
    log "nginx luci (migrate, or drop restrict_locally when nginx is already installed)"
    sh "$OPENWRT_DIR/scripts/setup_nginx_luci.sh" >> "$LOG" 2>&1 || rc=$?
else
    log "no setup_nginx_luci.sh"
fi
if [ "$rc" -ne 0 ]; then
    log "nginx luci failed rc=$rc; uhttpd was left on 443 if the cutover rolled back; continuing; stamp not written"
fi
if [ -f "$OPENWRT_DIR/scripts/lib_ngrok_config.sh" ]; then
    log "ngrok https-ui upstream"
    # shellcheck disable=SC1091
    . "$OPENWRT_DIR/scripts/lib_ngrok_config.sh"
    NGROK_CONFIG="${NGROK_CONFIG:-/root/.config/ngrok/ngrok.yml}" migrate_ngrok_luci_upstream >> "$LOG" 2>&1 || \
        log "ngrok upstream migration failed; continuing"
fi
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi
printf '%s\n' "$sha" > "$STAMP"
log "done $sha"
exit 0
