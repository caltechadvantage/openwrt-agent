#!/bin/sh
# Move LuCI from uhttpd to nginx on OpenWrt, or leave a working nginx alone.
#
# Idempotent. Does not rewrite a custom nginx UCI config when nginx-ssl,
# nginx-mod-luci, and `nginx -t -c` of the live config are already healthy.
# On OpenWrt 24.10 that file is /etc/nginx/uci.conf. Plain `nginx -t` looks
# for /etc/nginx/nginx.conf, which is not there, and must not be used.
# Never starts uhttpd while nginx is installed. Never removes or reinstalls
# packages when nginx is already serving LuCI. Never sets a firewall zone,
# and never edits Bondix's own config. The only nginx change on an
# already-healthy box is adding `conf.d/*.locations` to server `_lan` when
# that include is missing, so /etc/nginx/conf.d/bondix.locations can load,
# and removing OpenWrt's `_redirect2ssl` port-80 redirect so LuCI is
# HTTPS on 443 only. Other servers are left alone. A box that still
# runs uhttpd is not edited.
#
# Skip the whole step with LUCI_USE_NGINX=0 or LUCI_USE_NGINX = False in
# settings.py / local_settings.py.
#
# LUCI_NGINX_RELAX_RESTRICT_LOCALLY=1 (default off) deletes
# nginx._lan.restrict_locally. Some LANs use public addresses and need that.
#
# Source with SETUP_NGINX_LUCI_SOURCE_ONLY=1 to use the functions in tests.

BACKUP_ROOT="${LUCI_NGINX_BACKUP_ROOT:-/root/backup-nginx}"
NGINX_UCI_CONF="${LUCI_NGINX_UCI_CONF:-/etc/nginx/uci.conf}"
NGINX_PLAIN_CONF="${LUCI_NGINX_PLAIN_CONF:-/etc/nginx/nginx.conf}"
INIT_D="${LUCI_NGINX_INIT_D:-/etc/init.d}"

# Ask the init script or nginx-util to render UCI into a config file.
# Does not start or stop nginx.
nginx_generate_conf() {
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD generate nginx config via nginx-util or $INIT_D/nginx reconf" >&2
        return 0
    fi
    if command -v nginx-util >/dev/null 2>&1; then
        nginx-util init_lan >/dev/null 2>&1 || true
    fi
    if [ -x "$INIT_D/nginx" ]; then
        "$INIT_D/nginx" reconf >/dev/null 2>&1 || true
    fi
}

# Print the config file nginx is actually running.
# Prefer uci.conf when UCI management is on or that file exists.
# Otherwise nginx.conf. If neither exists, try to generate uci.conf.
nginx_conf_in_use() {
    if [ -n "${LUCI_NGINX_CONF:-}" ]; then
        printf '%s\n' "$LUCI_NGINX_CONF"
        return 0
    fi
    uci_flag=$(uci -q get nginx.global.uci_enable 2>/dev/null || true)
    case "$uci_flag" in
        1|true|yes|on|True|TRUE)
            if [ ! -f "$NGINX_UCI_CONF" ]; then
                nginx_generate_conf
            fi
            printf '%s\n' "$NGINX_UCI_CONF"
            return 0
            ;;
    esac
    if [ -f "$NGINX_UCI_CONF" ]; then
        printf '%s\n' "$NGINX_UCI_CONF"
        return 0
    fi
    if [ -f "$NGINX_PLAIN_CONF" ]; then
        printf '%s\n' "$NGINX_PLAIN_CONF"
        return 0
    fi
    nginx_generate_conf
    if [ -f "$NGINX_UCI_CONF" ]; then
        printf '%s\n' "$NGINX_UCI_CONF"
        return 0
    fi
    if [ -f "$NGINX_PLAIN_CONF" ]; then
        printf '%s\n' "$NGINX_PLAIN_CONF"
        return 0
    fi
    printf '%s\n' "$NGINX_UCI_CONF"
}

nginx_test_config() {
    conf=$(nginx_conf_in_use)
    if _would "nginx -t -c $conf"; then
        return 0
    fi
    nginx -t -c "$conf"
}

_py_assignment() {
    # $1 file, $2 name. Prints the raw right-hand side, or nothing.
    _file="$1"
    _name="$2"
    [ -f "$_file" ] || return 0
    sed -n "s/^${_name}[[:space:]]*=[[:space:]]*//p" "$_file" | tail -n 1 | tr -d "\"' "
}

_flag_on() {
    # $1 env value or python literal. Empty means "unset".
    case "$1" in
        1|true|True|yes|on|YES|ON) return 0 ;;
        0|false|False|no|off|NO|OFF) return 1 ;;
        *) return 2 ;;
    esac
}

_settings_files() {
    if [ -n "${LUCI_NGINX_SETTINGS_DIR:-}" ]; then
        echo "$LUCI_NGINX_SETTINGS_DIR/settings.py"
        echo "$LUCI_NGINX_SETTINGS_DIR/local_settings.py"
        return 0
    fi
    here=$(CDPATH= cd "$(dirname "$0")" && pwd)
    echo "$here/../settings.py"
    echo "$here/../local_settings.py"
    echo "${HOME:-/root}/.openwrt/local_settings.py"
}

_apply_flag() {
    # $1 explicit value, possibly empty. Echoes on/off/unset.
    _flag_on "$1"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        echo on
    elif [ "$_rc" -eq 1 ]; then
        echo off
    else
        echo unset
    fi
}

luci_nginx_enabled() {
    state=$(_apply_flag "${LUCI_USE_NGINX:-}")
    if [ "$state" = "on" ]; then
        return 0
    fi
    if [ "$state" = "off" ]; then
        return 1
    fi
    value=""
    for f in $(_settings_files); do
        got=$(_py_assignment "$f" LUCI_USE_NGINX)
        [ -n "$got" ] && value="$got"
    done
    state=$(_apply_flag "$value")
    [ "$state" = "off" ] && return 1
    return 0
}

luci_relax_restrict_locally() {
    state=$(_apply_flag "${LUCI_NGINX_RELAX_RESTRICT_LOCALLY:-}")
    if [ "$state" = "on" ]; then
        return 0
    fi
    if [ "$state" = "off" ]; then
        return 1
    fi
    value=""
    for f in $(_settings_files); do
        got=$(_py_assignment "$f" LUCI_NGINX_RELAX_RESTRICT_LOCALLY)
        [ -n "$got" ] && value="$got"
    done
    state=$(_apply_flag "$value")
    [ "$state" = "on" ]
}

nginx_packages_installed() {
    opkg list-installed 2>/dev/null | grep -q '^nginx-ssl '
    opkg list-installed 2>/dev/null | grep -q '^nginx-mod-luci '
}

nginx_luci_healthy() {
    nginx_packages_installed || return 1
    [ -x "$INIT_D/nginx" ] || return 1
    nginx_test_config >/dev/null 2>&1 || return 1
    uci -q get nginx._lan >/dev/null 2>&1 || return 1
}

luci_plan() {
    if ! luci_nginx_enabled; then
        echo skip
        return 0
    fi
    if nginx_packages_installed; then
        if nginx_luci_healthy; then
            echo leave
        else
            echo broken
        fi
        return 0
    fi
    echo migrate
}

_would() {
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD $*"
        return 0
    fi
    return 1
}

ensure_bondix_locations_include() {
    # Additive only. Does not delete or rewrite other nginx options.
    includes=$(uci -q get nginx._lan.include 2>/dev/null || true)
    echo "$includes" | grep -q 'conf.d/\*\.locations' && return 0
    echo "$includes" | grep -q 'conf.d/bondix.locations' && return 0
    if _would uci add_list nginx._lan.include='conf.d/*.locations'; then
        return 0
    fi
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci commit nginx
}

maybe_relax_restrict_locally() {
    luci_relax_restrict_locally || return 0
    if _would uci delete nginx._lan.restrict_locally; then
        return 0
    fi
    uci -q delete nginx._lan.restrict_locally
    uci commit nginx
}

# OpenWrt nginx-mod-luci adds server `_redirect2ssl`, which listens on
# port 80 and returns 302 to HTTPS. v2.19 drops that server. Bondix's
# UI is the `conf.d/*.locations` include on `_lan` (443), not this
# redirect, so the include is not removed. No other server is deleted,
# and the firewall is not edited.
_http_redirect_present() {
    uci -q show nginx._redirect2ssl 2>/dev/null | grep -q .
}

_lan_has_plain_80() {
    listens=$(uci -q get nginx._lan.listen 2>/dev/null || true)
    listens=$(printf '%s' "$listens" | tr -d "'\"")
    for item in $listens; do
        case "$item" in
            80|[::]:80|0.0.0.0:80|*:80) return 0 ;;
        esac
    done
    return 1
}

_backup_nginx_uci() {
    mkdir -p "$BACKUP_ROOT"
    stamp=$(date +%Y%m%d%H%M%S)
    dest="$BACKUP_ROOT/nginx-uci-${stamp}.uci"
    if _would "uci export nginx > $dest"; then
        echo "$dest"
        return 0
    fi
    uci export nginx > "$dest"
    echo "$dest"
}

_restore_nginx_uci() {
    saved="$1"
    [ -n "$saved" ] && [ -f "$saved" ] || return 1
    uci import nginx < "$saved"
    uci commit nginx
    nginx_generate_conf
    if [ -x "$INIT_D/nginx" ]; then
        "$INIT_D/nginx" reload >/dev/null 2>&1 || "$INIT_D/nginx" restart >/dev/null 2>&1 || true
    fi
}

disable_http_redirect() {
    present=0
    plain80=0
    _http_redirect_present && present=1
    _lan_has_plain_80 && plain80=1
    if [ "$present" = "0" ] && [ "$plain80" = "0" ]; then
        echo "luci_http_redirect=absent"
        return 0
    fi
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD uci export nginx before removing the port 80 redirect"
        [ "$present" = "1" ] && echo "WOULD uci delete nginx._redirect2ssl"
        [ "$plain80" = "1" ] && echo "WOULD uci del_list nginx._lan.listen 80"
        echo "WOULD $INIT_D/nginx reload"
        return 0
    fi
    saved=$(_backup_nginx_uci) || return 1
    if [ "$present" = "1" ]; then
        uci -q delete nginx._redirect2ssl
    fi
    if [ "$plain80" = "1" ]; then
        for item in 80 '[::]:80' '0.0.0.0:80' '*:80'; do
            uci -q del_list nginx._lan.listen "$item"
        done
    fi
    uci commit nginx
    nginx_generate_conf
    if ! nginx_test_config; then
        echo "nginx -t failed after removing the port 80 redirect; restoring nginx UCI from $saved" >&2
        _restore_nginx_uci "$saved" || true
        echo "port 80 redirect was restored; nginx was left running; uhttpd was not started" >&2
        return 1
    fi
    if [ -x "$INIT_D/nginx" ]; then
        if ! "$INIT_D/nginx" reload; then
            "$INIT_D/nginx" restart || {
                echo "nginx reload failed; restoring nginx UCI from $saved" >&2
                _restore_nginx_uci "$saved" || true
                echo "port 80 redirect was restored; nginx was left running; uhttpd was not started" >&2
                return 1
            }
        fi
    fi
    if ! nginx_test_config; then
        echo "nginx -t failed after reload; restoring nginx UCI from $saved" >&2
        _restore_nginx_uci "$saved" || true
        echo "port 80 redirect was restored; nginx was left running; uhttpd was not started" >&2
        return 1
    fi
    echo "luci_http_redirect=removed"
    return 0
}

_backup_for_rollback() {
    stamp=$(date +%Y%m%d%H%M%S)
    mkdir -p "$BACKUP_ROOT/ipk"
    _tarball="$BACKUP_ROOT/config-${stamp}.tar.gz"
    _installed="$BACKUP_ROOT/installed-${stamp}.txt"
    if _would "tar czf $_tarball /etc/config"; then
        echo "$_tarball"
        return 0
    fi
    tar czf "$_tarball" -C / etc/config
    opkg list-installed > "$_installed"
    echo "$_tarball"
}

_download_rollback_ipks() {
    if _would "opkg download uhttpd uhttpd-mod-ubus luci-light luci-ssl luci into $BACKUP_ROOT/ipk"; then
        return 0
    fi
    mkdir -p "$BACKUP_ROOT/ipk"
    (
        cd "$BACKUP_ROOT/ipk" || exit 1
        opkg download uhttpd uhttpd-mod-ubus luci-light luci-ssl luci
    )
}

_rollback_to_uhttpd() {
    tarball="$1"
    echo "LuCI nginx step failed; restoring uhttpd from $BACKUP_ROOT" >&2
    if _would "rollback uhttpd from $tarball"; then
        return 0
    fi
    "$INIT_D/nginx" stop 2>/dev/null || true
    "$INIT_D/nginx" disable 2>/dev/null || true
    if [ -d "$BACKUP_ROOT/ipk" ]; then
        opkg install "$BACKUP_ROOT"/ipk/*.ipk
    fi
    if [ -n "$tarball" ] && [ -f "$tarball" ]; then
        tar xzf "$tarball" -C /
    fi
    if [ -x "$INIT_D/uhttpd" ]; then
        "$INIT_D/uhttpd" enable 2>/dev/null || true
        "$INIT_D/uhttpd" start 2>/dev/null || true
    fi
}

_nginx_test_and_restart() {
    # Same config detection as the already-healthy check. A failed test
    # does not start nginx; the caller rolls back.
    if ! nginx_test_config; then
        return 1
    fi
    if _would "$INIT_D/nginx enable"; then
        echo "WOULD $INIT_D/nginx restart"
        echo "WOULD nginx -t -c $(nginx_conf_in_use)"
        return 0
    fi
    "$INIT_D/nginx" enable || return 1
    "$INIT_D/nginx" restart || return 1
    nginx_test_config || return 1
}

migrate_to_nginx() {
    tarball=$(_backup_for_rollback) || return 1
    if ! _download_rollback_ipks; then
        echo "opkg download failed; uhttpd was not removed" >&2
        return 1
    fi
    if _would "$INIT_D/uhttpd stop"; then
        echo "WOULD $INIT_D/uhttpd disable"
        echo "WOULD opkg remove luci luci-ssl luci-light uhttpd-mod-ubus uhttpd"
        echo "WOULD opkg install nginx-ssl nginx-mod-luci"
        ensure_bondix_locations_include
        maybe_relax_restrict_locally
        disable_http_redirect
        _nginx_test_and_restart
        return 0
    fi
    "$INIT_D/uhttpd" stop 2>/dev/null || true
    "$INIT_D/uhttpd" disable 2>/dev/null || true
    # No --autoremove: LuCI apps stay installed.
    opkg remove luci luci-ssl luci-light uhttpd-mod-ubus uhttpd || {
        _rollback_to_uhttpd "$tarball"
        return 1
    }
    if ! opkg install nginx-ssl nginx-mod-luci; then
        _rollback_to_uhttpd "$tarball"
        return 1
    fi
    ensure_bondix_locations_include
    maybe_relax_restrict_locally
    disable_http_redirect || true
    if ! _nginx_test_and_restart; then
        _rollback_to_uhttpd "$tarball"
        return 1
    fi
    return 0
}

setup_nginx_luci_main() {
    plan=$(luci_plan)
    echo "luci_plan=$plan"
    case "$plan" in
        skip)
            return 0
            ;;
        broken)
            echo "nginx LuCI is installed but nginx -t failed; not changing it and not starting uhttpd" >&2
            return 1
            ;;
        leave)
            ensure_bondix_locations_include
            maybe_relax_restrict_locally
            disable_http_redirect
            return $?
            ;;
        migrate)
            migrate_to_nginx
            return $?
            ;;
        *)
            echo "unknown luci plan $plan" >&2
            return 1
            ;;
    esac
}

if [ "${SETUP_NGINX_LUCI_SOURCE_ONLY:-0}" != "1" ]; then
    setup_nginx_luci_main
fi
