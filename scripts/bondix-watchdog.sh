#!/bin/sh
# Keep management traffic on the WANs, and optionally give the LAN a
# WAN path when the Bondix tunnel is down to every server.
#
# Does not edit Bondix server failover, does not restart bondixclient,
# and does not change the bondix firewall zone.
#
# Source with BONDIX_WATCHDOG_SOURCE_ONLY=1 to use the decision
# functions from tests. `run` is the procd entry.

STATE_FILE="${BONDIX_WATCHDOG_STATE:-/var/run/bondix-watchdog.state}"
ROUTE_FILE="${BONDIX_WATCHDOG_ROUTES:-/var/run/bondix-watchdog.routes}"
HALF_FILE="${BONDIX_WATCHDOG_HALVES:-/var/run/bondix-watchdog.halves}"
RULE_FILE="${BONDIX_WATCHDOG_RULES:-/var/run/bondix-watchdog.rules}"
NFT_COMMENT="${BONDIX_WATCHDOG_NFT_COMMENT:-gigabonding-watchdog-bypass}"

wd_log() {
    logger -t bondix-watchdog "$*" 2>/dev/null || true
    if [ "${BONDIX_WATCHDOG_ECHO_LOG:-0}" = "1" ]; then
        echo "$*"
    fi
}

wd_is_wan_device() {
    case "$1" in
        eth1|eth2|eth3) return 0 ;;
        *) return 1 ;;
    esac
}

wd_is_ipv4() {
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

wd_tunnel_class() {
    word=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t')
    case "$word" in
        connected|up|online|established|active|running) echo up ;;
        disconnected|down|offline|error|failed|closed|inactive|disconnecting) echo down ;;
        *) echo unknown ;;
    esac
}

# Advance the last-resort state machine by one sample.
# Prints: mode down_for up_for
# Unknown does not start, clear, or satisfy either timer.
wd_step_mode() {
    _en="$1"
    _prev="$2"
    _class="$3"
    _down="$4"
    _up="$5"
    _grace="$6"
    _restore="$7"
    _elapsed="$8"
    case "$_class" in
        down)
            _down=$((_down + _elapsed))
            _up=0
            ;;
        up)
            _up=$((_up + _elapsed))
            _down=0
            ;;
    esac
    if [ "$_en" != "1" ]; then
        _mode=normal
    elif [ "$_prev" = "last_resort" ]; then
        if [ "$_class" = "up" ] && [ "$_up" -ge "$_restore" ]; then
            _mode=normal
        else
            _mode=last_resort
        fi
    else
        if [ "$_class" = "down" ] && [ "$_down" -ge "$_grace" ]; then
            _mode=last_resort
        else
            _mode=normal
        fi
    fi
    echo "$_mode $_down $_up"
}

# Lowest metric first. Input words are dev:metric[:gateway].
# Prints the same words, gateway kept when present.
wd_sort_wans() {
    _rest="$*"
    while [ -n "$_rest" ]; do
        _best=""
        _best_m=999999
        for _item in $_rest; do
            _m=$(printf '%s' "$_item" | cut -d: -f2)
            case "$_m" in
                ''|*[!0-9]*) _m=999999 ;;
            esac
            if [ "$_m" -lt "$_best_m" ]; then
                _best="$_item"
                _best_m="$_m"
            fi
        done
        [ -n "$_best" ] || break
        echo "$_best"
        _next=""
        for _item in $_rest; do
            [ "$_item" = "$_best" ] && continue
            _next="$_next $_item"
        done
        _rest=$(echo "$_next" | sed 's/^ *//;s/ *$//')
    done
}

# Plan /32 management routes for probed-up WANs.
# Args: "ip ip" "server server" "dev:metric:gw ..."
# Prints `replace ...` lines, then `active <dev>` when one exists.
# Skips eth0, bondix, and any IP that is a Bondix server.
wd_plan_routes() {
    _ips="$1"
    _servers="$2"
    _wans="$3"
    _sorted=$(wd_sort_wans $_wans)
    _active=""
    for _wan in $_sorted; do
        _dev=$(printf '%s' "$_wan" | cut -d: -f1)
        _metric=$(printf '%s' "$_wan" | cut -d: -f2)
        _gw=$(printf '%s' "$_wan" | cut -d: -f3-)
        wd_is_wan_device "$_dev" || continue
        case "$_metric" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ -z "$_active" ]; then
            _active="$_dev"
        fi
        for _ip in $_ips; do
            wd_is_ipv4 "$_ip" || continue
            _skip=0
            for _srv in $_servers; do
                [ "$_ip" = "$_srv" ] && _skip=1
            done
            [ "$_skip" = "1" ] && continue
            if [ -n "$_gw" ] && [ "$_gw" != "-" ]; then
                echo "replace $_ip/32 via $_gw dev $_dev metric $_metric"
            else
                echo "replace $_ip/32 dev $_dev metric $_metric"
            fi
        done
    done
    if [ -n "$_active" ]; then
        echo "active $_active"
    fi
}

# Print 0.0.0.0/1 and 128.0.0.0/1 routes that point at the bondix device.
wd_half_lines() {
    _dev="$1"
    while IFS= read -r _line; do
        case "$_line" in
            0.0.0.0/1*|128.0.0.0/1*) ;;
            *) continue ;;
        esac
        echo "$_line" | grep -q "dev $_dev" || continue
        echo "$_line"
    done
}

# Print "<family> <table>" for the first chain named BONDIX.
wd_find_nft_chain() {
    _family=""
    _table=""
    while IFS= read -r _line; do
        _trim=$(echo "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$_trim" in
            "table "*)
                _family=$(echo "$_trim" | awk '{print $2}')
                _table=$(echo "$_trim" | awk '{print $3}')
                _table=${_table%\{}
                ;;
            "chain BONDIX"*|"chain BONDIX {"*)
                if [ -n "$_family" ] && [ -n "$_table" ]; then
                    echo "$_family $_table"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

wd_state_json() {
    _mode="$1"
    _mgmt="$2"
    _tunnel="$3"
    _lr="$4"
    _down="$5"
    _up="$6"
    _now="$7"
    if [ "$_lr" = "1" ]; then
        _lr_json=true
    else
        _lr_json=false
    fi
    cat <<EOF
{
  "mode": "$_mode",
  "mgmt_wan": "$_mgmt",
  "tunnel": "$_tunnel",
  "last_resort_enabled": $_lr_json,
  "down_for": $_down,
  "up_for": $_up,
  "updated_at": $_now
}
EOF
}

# --- runtime below. Tests do not call these. ---

wd_default_config() {
    WD_ENABLED=1
    WD_LAST_RESORT=1
    WD_GRACE=90
    WD_RESTORE=30
    WD_INTERVAL=20
    WD_TIMEOUT=2
    WD_BONDIX_DEV=bondix0
    WD_LAN_DEV=br-lan
    WD_TABLE=120
    WD_TARGETS="1.1.1.1 8.8.8.8"
    WD_HOSTS="137.184.5.176 1.1.1.1 8.8.8.8 162.159.200.123 216.239.35.0 connect.ngrok-agent.com"
    WD_SERVERS=""
    WD_WANS="eth1:10 eth2:20 eth3:30"
}

wd_flush_section() {
    [ "$WD_SEC_TYPE" = "wan" ] || return 0
    [ "$WD_SEC_ENABLED" = "0" ] && return 0
    wd_is_wan_device "$WD_SEC_DEV" || return 0
    _m="$WD_SEC_METRIC"
    case "$_m" in
        ''|*[!0-9]*) _m=10 ;;
    esac
    WD_WANS="$WD_WANS $WD_SEC_DEV:$_m"
}

wd_parse_uci_show() {
    wd_default_config
    WD_WANS=""
    WD_HOSTS=""
    WD_TARGETS=""
    WD_SERVERS=""
    WD_SEC=""
    WD_SEC_TYPE=""
    WD_SEC_DEV=""
    WD_SEC_METRIC=""
    WD_SEC_ENABLED=1
    while IFS= read -r _line; do
        _line=$(echo "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$_line" ] || continue
        case "$_line" in
            \#*) continue ;;
        esac
        _key=${_line%%=*}
        _raw=${_line#*=}
        _words=$(printf '%s' "$_raw" | tr "'" ' ' | tr '"' ' ')
        _name=${_key#bondix-watchdog.}
        _sec=${_name%%.*}
        _opt=${_name#*.}
        if [ "$_name" = "$_sec" ]; then
            wd_flush_section
            WD_SEC="$_sec"
            WD_SEC_TYPE=$(echo "$_words" | awk '{print $1}')
            WD_SEC_DEV=""
            WD_SEC_METRIC=""
            WD_SEC_ENABLED=1
            continue
        fi
        [ "$_sec" = "$WD_SEC" ] || continue
        case "$WD_SEC_TYPE" in
            watchdog)
                case "$_opt" in
                    enabled) WD_ENABLED=$(echo "$_words" | awk '{print $1}') ;;
                    last_resort) WD_LAST_RESORT=$(echo "$_words" | awk '{print $1}') ;;
                    grace_sec) WD_GRACE=$(echo "$_words" | awk '{print $1}') ;;
                    restore_grace_sec) WD_RESTORE=$(echo "$_words" | awk '{print $1}') ;;
                    probe_interval) WD_INTERVAL=$(echo "$_words" | awk '{print $1}') ;;
                    probe_timeout) WD_TIMEOUT=$(echo "$_words" | awk '{print $1}') ;;
                    bondix_dev) WD_BONDIX_DEV=$(echo "$_words" | awk '{print $1}') ;;
                    lan_device) WD_LAN_DEV=$(echo "$_words" | awk '{print $1}') ;;
                    route_table) WD_TABLE=$(echo "$_words" | awk '{print $1}') ;;
                    probe_target) WD_TARGETS="$WD_TARGETS $_words" ;;
                esac
                ;;
            mgmt|server)
                case "$_opt" in
                    host|address)
                        if [ "$WD_SEC_TYPE" = "server" ]; then
                            WD_SERVERS="$WD_SERVERS $_words"
                        else
                            WD_HOSTS="$WD_HOSTS $_words"
                        fi
                        ;;
                esac
                ;;
            wan)
                case "$_opt" in
                    device|iface) WD_SEC_DEV=$(echo "$_words" | awk '{print $1}') ;;
                    metric) WD_SEC_METRIC=$(echo "$_words" | awk '{print $1}') ;;
                    enabled) WD_SEC_ENABLED=$(echo "$_words" | awk '{print $1}') ;;
                esac
                ;;
        esac
    done
    wd_flush_section
    if [ -z "$(echo "$WD_WANS" | tr -d ' ')" ]; then
        WD_WANS="eth1:10 eth2:20 eth3:30"
    fi
    if [ -z "$(echo "$WD_TARGETS" | tr -d ' ')" ]; then
        WD_TARGETS="1.1.1.1 8.8.8.8"
    fi
    if [ -z "$(echo "$WD_HOSTS" | tr -d ' ')" ]; then
        WD_HOSTS="137.184.5.176 1.1.1.1 8.8.8.8 162.159.200.123 216.239.35.0 connect.ngrok-agent.com"
    fi
    case "$WD_INTERVAL" in
        ''|*[!0-9]*) WD_INTERVAL=20 ;;
    esac
    [ "$WD_INTERVAL" -lt 10 ] && WD_INTERVAL=10
    case "$WD_GRACE" in
        ''|*[!0-9]*) WD_GRACE=90 ;;
    esac
    case "$WD_RESTORE" in
        ''|*[!0-9]*) WD_RESTORE=30 ;;
    esac
    case "$WD_TIMEOUT" in
        ''|*[!0-9]*) WD_TIMEOUT=2 ;;
    esac
    case "$WD_TABLE" in
        ''|*[!0-9]*) WD_TABLE=120 ;;
    esac
}

wd_load_uci() {
    if ! command -v uci >/dev/null 2>&1; then
        wd_default_config
        return 0
    fi
    _show=$(uci -q show bondix-watchdog 2>/dev/null || true)
    wd_parse_uci_show <<EOF
$_show
EOF
}

wd_gateway_for() {
    _dev="$1"
    ip route show dev "$_dev" 2>/dev/null | awk '/^default / {
        for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }
    }'
}

wd_link_up() {
    _dev="$1"
    [ -d "/sys/class/net/$_dev" ] || return 1
    _op=$(cat "/sys/class/net/$_dev/operstate" 2>/dev/null || echo down)
    [ "$_op" = "up" ] || return 1
    if [ -f "/sys/class/net/$_dev/carrier" ]; then
        _car=$(cat "/sys/class/net/$_dev/carrier" 2>/dev/null || echo 0)
        [ "$_car" = "1" ] || return 1
    fi
    return 0
}

wd_probe_wan() {
    _dev="$1"
    wd_link_up "$_dev" || return 1
    for _tgt in $WD_TARGETS; do
        wd_is_ipv4 "$_tgt" || continue
        if ping -I "$_dev" -c 1 -W "$WD_TIMEOUT" -s 8 "$_tgt" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

wd_parse_tunnel_json() {
    # Top-level status only. A channel status further down the document
    # must not decide the tunnel. Prints: status newline endpoint.
    printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    obj = json.loads(raw)
except Exception:
    obj = {}
if not isinstance(obj, dict):
    obj = {}
print(obj.get("status") or "")
print(obj.get("endpoint") or "")
' 2>/dev/null || printf '\n\n'
}

wd_socket_tunnel_json() {
    python3 - <<'PY' 2>/dev/null || true
import socket
try:
    s = socket.create_connection(("127.0.0.1", 5113), 2)
except Exception:
    raise SystemExit(0)
s.sendall(b'{"target":"tunnel","action":"status"}\n')
s.settimeout(2)
data = b""
try:
    while len(data) < 65536:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
except Exception:
    pass
s.close()
sys_out = data.decode("utf-8", "replace")
print(sys_out)
PY
}

wd_read_tunnel() {
    _raw=""
    if command -v ubus >/dev/null 2>&1; then
        _raw=$(ubus call bondix status 2>/dev/null || true)
    fi
    if [ -z "$_raw" ]; then
        _raw=$(wd_socket_tunnel_json)
    fi
    _parsed=$(wd_parse_tunnel_json "$_raw")
    _status=$(printf '%s\n' "$_parsed" | sed -n '1p')
    _endpoint=$(printf '%s\n' "$_parsed" | sed -n '2p')
    _server=$(printf '%s' "$_endpoint" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
    echo "$(wd_tunnel_class "$_status") ${_server}"
}

wd_resolve_host() {
    _host="$1"
    if wd_is_ipv4 "$_host"; then
        echo "$_host"
        return 0
    fi
    nslookup "$_host" 1.1.1.1 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^1\.1\.1\.1$' | head -n 4
}

wd_apply_route_line() {
    # shellcheck disable=SC2086
    ip route "$@"
}

wd_sync_routes() {
    _plan="$1"
    _desired=$(printf '%s\n' "$_plan" | grep '^replace ' | sed 's/^replace //')
    if [ -f "$ROUTE_FILE" ]; then
        while IFS= read -r _old; do
            [ -n "$_old" ] || continue
            if ! printf '%s\n' "$_desired" | grep -qxF "$_old"; then
                # shellcheck disable=SC2086
                ip route del $_old 2>/dev/null || true
            fi
        done < "$ROUTE_FILE"
    fi
    _tmp="${ROUTE_FILE}.tmp"
    : > "$_tmp"
    printf '%s\n' "$_desired" | while IFS= read -r _spec; do
        [ -n "$_spec" ] || continue
        # shellcheck disable=SC2086
        ip route replace $_spec 2>/dev/null || wd_log "route replace failed: $_spec"
        echo "$_spec"
    done > "$_tmp"
    mv "$_tmp" "$ROUTE_FILE"
}

wd_clear_routes() {
    if [ -f "$ROUTE_FILE" ]; then
        while IFS= read -r _old; do
            [ -n "$_old" ] || continue
            # shellcheck disable=SC2086
            ip route del $_old 2>/dev/null || true
        done < "$ROUTE_FILE"
        rm -f "$ROUTE_FILE"
    fi
}

wd_nft_loc() {
    nft list ruleset 2>/dev/null | wd_find_nft_chain
}

wd_nft_add() {
    _loc=$(wd_nft_loc) || return 0
    _fam=$(echo "$_loc" | awk '{print $1}')
    _tab=$(echo "$_loc" | awk '{print $2}')
    if nft list chain "$_fam" "$_tab" BONDIX 2>/dev/null | grep -q "$NFT_COMMENT"; then
        return 0
    fi
    nft insert rule "$_fam" "$_tab" BONDIX counter return comment "\"$NFT_COMMENT\"" \
        || wd_log "nft bypass insert failed"
}

wd_nft_del() {
    _loc=$(wd_nft_loc) || return 0
    _fam=$(echo "$_loc" | awk '{print $1}')
    _tab=$(echo "$_loc" | awk '{print $2}')
    nft -a list chain "$_fam" "$_tab" BONDIX 2>/dev/null | while IFS= read -r _line; do
        echo "$_line" | grep -q "$NFT_COMMENT" || continue
        _handle=$(echo "$_line" | sed -n 's/.*handle \([0-9][0-9]*\).*/\1/p')
        [ -n "$_handle" ] || continue
        nft delete rule "$_fam" "$_tab" BONDIX handle "$_handle" 2>/dev/null || true
    done
}

wd_delete_halves() {
    _found=$(ip route show 2>/dev/null | wd_half_lines "$WD_BONDIX_DEV" || true)
    if [ -n "$_found" ]; then
        mkdir -p "$(dirname "$HALF_FILE")"
        printf '%s\n' "$_found" >> "$HALF_FILE"
        sort -u "$HALF_FILE" -o "$HALF_FILE" 2>/dev/null || true
    fi
    ip route del 0.0.0.0/1 dev "$WD_BONDIX_DEV" 2>/dev/null || true
    ip route del 128.0.0.0/1 dev "$WD_BONDIX_DEV" 2>/dev/null || true
}

wd_restore_halves() {
    [ -f "$HALF_FILE" ] || return 0
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        # shellcheck disable=SC2086
        ip route replace $_line 2>/dev/null || wd_log "could not restore $_line"
    done < "$HALF_FILE"
    rm -f "$HALF_FILE"
}

wd_lan_rule_on() {
    _dev="$1"
    _gw="$2"
    [ -n "$_dev" ] || return 0
    if [ -n "$_gw" ] && [ "$_gw" != "-" ]; then
        ip route replace default via "$_gw" dev "$_dev" table "$WD_TABLE" 2>/dev/null || return 1
    else
        ip route replace default dev "$_dev" table "$WD_TABLE" 2>/dev/null || return 1
    fi
    ip rule del iif "$WD_LAN_DEV" lookup "$WD_TABLE" pref 1000 2>/dev/null || true
    ip rule add iif "$WD_LAN_DEV" lookup "$WD_TABLE" pref 1000 2>/dev/null || true
    echo "iif $WD_LAN_DEV lookup $WD_TABLE pref 1000" > "$RULE_FILE"
    # Bondix server addresses keep the main table, ahead of the LAN rule,
    # so tunnel packets are not pulled into the last-resort default.
    for _srv in $WD_SERVERS; do
        wd_is_ipv4 "$_srv" || continue
        ip rule del to "$_srv/32" lookup main pref 400 2>/dev/null || true
        ip rule add to "$_srv/32" lookup main pref 400 2>/dev/null || true
    done
}

wd_lan_rule_off() {
    ip rule del iif "$WD_LAN_DEV" lookup "$WD_TABLE" pref 1000 2>/dev/null || true
    for _srv in $WD_SERVERS; do
        wd_is_ipv4 "$_srv" || continue
        ip rule del to "$_srv/32" lookup main pref 400 2>/dev/null || true
    done
    ip route flush table "$WD_TABLE" 2>/dev/null || true
    rm -f "$RULE_FILE"
}

wd_write_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    _tmp="${STATE_FILE}.tmp"
    wd_state_json "$WD_MODE" "$WD_MGMT" "$WD_TUNNEL" "$WD_LAST_RESORT" \
        "$WD_DOWN_FOR" "$WD_UP_FOR" "$WD_NOW" > "$_tmp"
    mv "$_tmp" "$STATE_FILE"
}

wd_load_state() {
    WD_MODE=normal
    WD_DOWN_FOR=0
    WD_UP_FOR=0
    [ -f "$STATE_FILE" ] || return 0
    _m=$(sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1)
    _d=$(sed -n 's/.*"down_for"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1)
    _u=$(sed -n 's/.*"up_for"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1)
    case "$_m" in
        normal|last_resort) WD_MODE="$_m" ;;
    esac
    case "$_d" in
        ''|*[!0-9]*) ;;
        *) WD_DOWN_FOR="$_d" ;;
    esac
    case "$_u" in
        ''|*[!0-9]*) ;;
        *) WD_UP_FOR="$_u" ;;
    esac
    _tick=$(sed -n 's/.*"updated_at"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1)
    case "$_tick" in
        ''|*[!0-9]*) ;;
        *) WD_LAST_TICK="$_tick" ;;
    esac
}

wd_dump_config() {
    echo "enabled=$WD_ENABLED"
    echo "last_resort=$WD_LAST_RESORT"
    echo "grace=$WD_GRACE"
    echo "restore=$WD_RESTORE"
    echo "interval=$WD_INTERVAL"
    echo "bondix_dev=$WD_BONDIX_DEV"
    echo "wans=$(echo $WD_WANS | sed 's/^ *//;s/ *$//')"
    echo "hosts=$(echo $WD_HOSTS | sed 's/^ *//;s/ *$//')"
    echo "servers=$(echo $WD_SERVERS | sed 's/^ *//;s/ *$//')"
}

wd_cleanup() {
    wd_load_uci
    wd_load_state
    wd_nft_del
    wd_lan_rule_off
    wd_restore_halves
    wd_clear_routes
    WD_MODE=normal
    WD_MGMT=""
    WD_TUNNEL=unknown
    WD_NOW=$(date +%s 2>/dev/null || echo 0)
    wd_write_state
    wd_log "cleanup: management routes removed, tunnel routes restored"
}

wd_cycle() {
    wd_load_uci
    WD_NOW=$(date +%s)
    if [ -z "$WD_LAST_TICK" ]; then
        _elapsed="$WD_INTERVAL"
    else
        _elapsed=$((WD_NOW - WD_LAST_TICK))
        [ "$_elapsed" -lt 1 ] && _elapsed=1
    fi
    WD_LAST_TICK=$WD_NOW

    if [ "$WD_ENABLED" != "1" ]; then
        wd_nft_del
        wd_lan_rule_off
        wd_restore_halves
        wd_clear_routes
        WD_MODE=normal
        WD_MGMT=""
        WD_TUNNEL=unknown
        WD_DOWN_FOR=0
        WD_UP_FOR=0
        wd_write_state
        return 0
    fi

    _tun=$(wd_read_tunnel)
    WD_TUNNEL=$(echo "$_tun" | awk '{print $1}')
    _live_server=$(echo "$_tun" | awk '{print $2}')
    if wd_is_ipv4 "$_live_server"; then
        WD_SERVERS="$WD_SERVERS $_live_server"
    fi

    _step=$(wd_step_mode "$WD_LAST_RESORT" "$WD_MODE" "$WD_TUNNEL" \
        "$WD_DOWN_FOR" "$WD_UP_FOR" "$WD_GRACE" "$WD_RESTORE" "$_elapsed")
    _new_mode=$(echo "$_step" | awk '{print $1}')
    WD_DOWN_FOR=$(echo "$_step" | awk '{print $2}')
    WD_UP_FOR=$(echo "$_step" | awk '{print $3}')

    _up_wans=""
    for _spec in $WD_WANS; do
        _dev=$(printf '%s' "$_spec" | cut -d: -f1)
        _metric=$(printf '%s' "$_spec" | cut -d: -f2)
        wd_is_wan_device "$_dev" || continue
        [ -d "/sys/class/net/$_dev" ] || continue
        if wd_probe_wan "$_dev"; then
            _gw=$(wd_gateway_for "$_dev")
            [ -n "$_gw" ] || _gw="-"
            _up_wans="$_up_wans $_dev:$_metric:$_gw"
        fi
    done

    # Numeric hosts first so hostname lookup can use the WAN DNS route.
    _ips=""
    _names=""
    for _host in $WD_HOSTS; do
        if wd_is_ipv4 "$_host"; then
            _ips="$_ips $_host"
        else
            _names="$_names $_host"
        fi
    done
    _plan=$(wd_plan_routes "$_ips" "$WD_SERVERS" "$_up_wans")
    wd_sync_routes "$_plan"
    for _name in $_names; do
        _ips="$_ips $(wd_resolve_host "$_name")"
    done
    _plan=$(wd_plan_routes "$_ips" "$WD_SERVERS" "$_up_wans")
    wd_sync_routes "$_plan"
    WD_MGMT=$(printf '%s\n' "$_plan" | sed -n 's/^active //p' | head -n 1)

    if [ "$_new_mode" = "last_resort" ] && [ "$WD_MODE" != "last_resort" ]; then
        wd_log "tunnel down for ${WD_DOWN_FOR}s, entering last-resort"
    fi
    if [ "$_new_mode" = "normal" ] && [ "$WD_MODE" = "last_resort" ]; then
        wd_log "tunnel healthy, leaving last-resort"
    fi
    WD_MODE="$_new_mode"

    if [ "$WD_MODE" = "last_resort" ]; then
        wd_delete_halves
        wd_nft_add
        _best=$(echo "$_up_wans" | tr ' ' '\n' | head -n 1)
        # sorted later by the plan; pick the active device's gateway
        _best_dev="$WD_MGMT"
        _best_gw=""
        for _spec in $_up_wans; do
            _d=$(printf '%s' "$_spec" | cut -d: -f1)
            if [ "$_d" = "$_best_dev" ]; then
                _best_gw=$(printf '%s' "$_spec" | cut -d: -f3-)
            fi
        done
        if [ -n "$_best_dev" ]; then
            wd_lan_rule_on "$_best_dev" "$_best_gw"
        else
            wd_log "last-resort: no probed-up WAN, LAN override not installed"
            wd_lan_rule_off
        fi
    else
        wd_nft_del
        wd_lan_rule_off
        wd_restore_halves
    fi
    wd_write_state
}

wd_run() {
    wd_log "starting"
    wd_load_uci
    wd_load_state
    trap 'wd_cleanup; exit 0' TERM INT
    while true; do
        wd_cycle || wd_log "cycle error"
        sleep "$WD_INTERVAL"
    done
}

if [ "${BONDIX_WATCHDOG_SOURCE_ONLY:-0}" != "1" ]; then
    case "${1:-run}" in
        run) wd_run ;;
        cleanup) wd_cleanup ;;
        once) wd_load_state; wd_cycle ;;
        *) echo "usage: $0 run|once|cleanup" >&2; exit 1 ;;
    esac
fi
