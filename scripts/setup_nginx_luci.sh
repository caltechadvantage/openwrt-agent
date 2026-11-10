#!/bin/sh
# Move LuCI from uhttpd to nginx on OpenWrt, or leave a working nginx alone.
#
# Idempotent. Does not rewrite a custom nginx UCI config when nginx-ssl,
# nginx-mod-luci, and `nginx -t -c` of the live config are already healthy.
# On OpenWrt 24.10 that file is /etc/nginx/uci.conf. Plain `nginx -t` looks
# for /etc/nginx/nginx.conf, which is not there, and must not be used.
# A box that already serves LuCI with nginx is not reinstalled. The only
# edits then are adding `conf.d/*.locations` on `_lan` when it is missing,
# removing `_redirect2ssl` so LuCI is HTTPS on 443 only, and removing
# `restrict_locally`. A box still on uhttpd is migrated in place: packages
# are installed while uhttpd keeps 443, uhttpd is stopped only so nginx
# can bind, and uhttpd is removed only after https://127.0.0.1/cgi-bin/luci/
# returns 200 or 302. Never sets a firewall zone, and never edits Bondix's
# own config.
#
# Skip the whole step with LUCI_USE_NGINX=0 or LUCI_USE_NGINX = False in
# settings.py / local_settings.py.
#
# OpenWrt's nginx-ssl-util adds `restrict_locally` to nginx._lan.include.
# That file allows RFC1918 and 127.0.0.0/8, then `deny all`, so a WAN
# client gets 403 "access forbidden by rule". uhttpd did not do that.
# The include is removed by default. Set LUCI_NGINX_KEEP_RESTRICT_LOCALLY=1
# to leave it. conf.d/*.locations stays.
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

luci_keep_restrict_locally() {
    # Default is to remove the include. Only an explicit on keeps it.
    # The old LUCI_NGINX_RELAX_RESTRICT_LOCALLY flag is not consulted:
    # settings.py used to set it false, which would have kept the 403.
    state=$(_apply_flag "${LUCI_NGINX_KEEP_RESTRICT_LOCALLY:-}")
    if [ "$state" = "on" ]; then
        return 0
    fi
    if [ "$state" = "off" ]; then
        return 1
    fi
    value=""
    for f in $(_settings_files); do
        got=$(_py_assignment "$f" LUCI_NGINX_KEEP_RESTRICT_LOCALLY)
        [ -n "$got" ] && value="$got"
    done
    state=$(_apply_flag "$value")
    [ "$state" = "on" ]
}

_lan_include_has() {
    needle="$1"
    got=$(uci -q get nginx._lan.include 2>/dev/null || true)
    printf '%s' "$got" | tr -d "'\"" | tr ' ' '\n' | grep -Fxq "$needle"
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
    # uhttpd still installed means nginx is not the LuCI server yet, even
    # if the nginx packages are already on disk from a partial run.
    if nginx_packages_installed && ! _uhttpd_still_installed; then
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
    # Returns 0 when the include was added, 1 when it was already there.
    includes=$(uci -q get nginx._lan.include 2>/dev/null || true)
    echo "$includes" | grep -q 'conf.d/\*\.locations' && return 1
    echo "$includes" | grep -q 'conf.d/bondix.locations' && return 1
    if _would uci add_list nginx._lan.include='conf.d/*.locations'; then
        return 0
    fi
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci commit nginx
    return 0
}

reload_nginx_after_include() {
    # The locations include is already committed. Prove the config and
    # reload so Bondix pages are served without waiting for another edit.
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD nginx -t after bondix locations include"
        echo "WOULD $INIT_D/nginx reload"
        return 0
    fi
    nginx_generate_conf
    if ! nginx_test_config; then
        echo "nginx -t failed after adding conf.d/*.locations; removing that include" >&2
        uci -q del_list nginx._lan.include='conf.d/*.locations'
        uci commit nginx
        nginx_generate_conf
        return 1
    fi
    if [ -x "$INIT_D/nginx" ]; then
        "$INIT_D/nginx" reload || "$INIT_D/nginx" restart || return 1
    fi
    nginx_test_config
}

drop_restrict_locally() {
    # Idempotent. Removes the include list entry, not a separate option.
    # Keeps conf.d/*.locations. Backs up UCI first. Restores that backup
    # if nginx -t or the reload fails. Does not start uhttpd.
    if luci_keep_restrict_locally; then
        _migrate_log "keeping restrict_locally (LUCI_NGINX_KEEP_RESTRICT_LOCALLY)"
        return 0
    fi
    if ! _lan_include_has restrict_locally; then
        _migrate_log "restrict_locally already absent; conf.d/*.locations kept"
        return 0
    fi
    _migrate_log "remove nginx._lan.include restrict_locally; keep conf.d/*.locations"
    if _would "uci del_list nginx._lan.include=restrict_locally"; then
        echo "WOULD uci commit nginx"
        echo "WOULD $INIT_D/nginx reload"
        return 0
    fi
    saved=$(_backup_nginx_uci) || return 1
    _migrate_log "backed up nginx uci to $saved"
    uci -q del_list nginx._lan.include 'restrict_locally'
    uci commit nginx
    if [ "${LUCI_NGINX_DEFER_RELOAD:-0}" = "1" ]; then
        _migrate_log "restrict_locally removed from uci; nginx reload deferred until uhttpd releases 443"
        if _lan_include_has 'conf.d/*.locations' || _lan_include_has 'conf.d/bondix.locations'; then
            _migrate_log "conf.d locations include still present"
        fi
        return 0
    fi
    nginx_generate_conf
    if ! nginx_test_config; then
        _migrate_log "nginx -t failed after removing restrict_locally; restoring $saved"
        _restore_nginx_uci "$saved" || true
        return 1
    fi
    if [ -x "$INIT_D/nginx" ]; then
        if ! "$INIT_D/nginx" reload; then
            "$INIT_D/nginx" restart || {
                _migrate_log "nginx reload failed; restoring $saved"
                _restore_nginx_uci "$saved" || true
                return 1
            }
        fi
    fi
    if ! nginx_test_config; then
        _migrate_log "nginx -t failed after reload; restoring $saved"
        _restore_nginx_uci "$saved" || true
        return 1
    fi
    if _lan_include_has 'conf.d/*.locations' || _lan_include_has 'conf.d/bondix.locations'; then
        _migrate_log "conf.d locations include still present"
    fi
    _migrate_log "restrict_locally removed"
    return 0
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
            80|'[::]:80'|'0.0.0.0:80'|'*:80') return 0 ;;
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
    if [ "${LUCI_NGINX_DEFER_RELOAD:-0}" = "1" ]; then
        _migrate_log "https-only uci written; nginx start deferred until uhttpd releases 443"
        echo "luci_http_redirect=removed"
        return 0
    fi
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

_migrate_log() {
    mkdir -p "$BACKUP_ROOT"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$*" >> "$BACKUP_ROOT/migrate.log"
    echo "$*"
    if command -v logger >/dev/null 2>&1; then
        logger -t luci-nginx -- "$*" 2>/dev/null || true
    fi
}

_pkg_installed() {
    opkg list-installed 2>/dev/null | grep -q "^$1 "
}

_uhttpd_still_installed() {
    _pkg_installed uhttpd && return 0
    _pkg_installed uhttpd-mod-ubus && return 0
    return 1
}

_install_if_missing() {
    pkg="$1"
    if _pkg_installed "$pkg"; then
        _migrate_log "$pkg already installed"
        return 0
    fi
    _migrate_log "opkg install $pkg"
    if _would "opkg install $pkg"; then
        return 0
    fi
    opkg install "$pkg"
}

_install_nginx_packages() {
    # All four, while uhttpd is still the process on 443. opkg pulls deps
    # (including nginx-ssl-util's certificate helper). Already installed
    # is success. Any failure aborts before uhttpd is stopped.
    _migrate_log "opkg install luci-nginx nginx-ssl nginx-mod-luci nginx-ssl-util"
    for pkg in luci-nginx nginx-ssl nginx-mod-luci nginx-ssl-util; do
        _install_if_missing "$pkg" || return 1
    done
    return 0
}

_install_default_packages() {
    _migrate_log "opkg install iptables-nft ttyd luci-app-ttyd iputils-ping iputils-tracepath git-http iperf3 luci-lua-runtime luci-compat"
    for pkg in iptables-nft ttyd luci-app-ttyd iputils-ping iputils-tracepath git-http iperf3 luci-lua-runtime luci-compat; do
        _install_if_missing "$pkg" || return 1
    done
    return 0
}

_warn_expected_packages() {
    for pkg in bondix-client-universal luci-app-ifspeedtest; do
        if _pkg_installed "$pkg"; then
            _migrate_log "$pkg is installed"
        else
            _migrate_log "warning: $pkg is not installed; leaving it alone"
        fi
    done
}

_http_code() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -k -s -m 10 -o /dev/null -w "%{http_code}" "$url" || true
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -S -O /dev/null --no-check-certificate -T 10 "$url" 2>&1 | \
            sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -n 1
        return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        if uclient-fetch -q -T 10 -O /dev/null "$url"; then
            echo 200
        else
            echo 000
        fi
        return 0
    fi
    echo none
}

_wan_facing_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p' | head -n 1
}

_probe_luci_url() {
    url="$1"
    if _would "check $url"; then
        return 0
    fi
    code=$(_http_code "$url")
    code=$(printf '%s' "$code" | tr -cd '0-9')
    [ -n "$code" ] || code="000"
    _migrate_log "probe $url -> $code"
    case "$code" in
        200|301|302) return 0 ;;
        403)
            _migrate_log "$url returned 403 access forbidden by rule"
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

_luci_https_ok() {
    # 127.0.0.1 hits the same default_server WAN clients use when nginx
    # listens on 443. 403 is the restrict_locally deny, so it is failure.
    # A discovered WAN address is checked the same way when the packet
    # actually gets an HTTP status; a hairpin miss does not by itself fail.
    if ! luci_keep_restrict_locally && _lan_include_has restrict_locally; then
        _migrate_log "restrict_locally still on nginx._lan; WAN clients get 403"
        return 1
    fi
    url="https://127.0.0.1/cgi-bin/luci/"
    if ! _probe_luci_url "$url"; then
        return 1
    fi
    wan_ip=$(_wan_facing_ip)
    case "$wan_ip" in
        ""|127.0.0.1) return 0 ;;
    esac
    if _would "check https://$wan_ip/cgi-bin/luci/"; then
        return 0
    fi
    wan_code=$(_http_code "https://$wan_ip/cgi-bin/luci/")
    wan_code=$(printf '%s' "$wan_code" | tr -cd '0-9')
    [ -n "$wan_code" ] || wan_code="000"
    _migrate_log "probe https://$wan_ip/cgi-bin/luci/ -> $wan_code"
    case "$wan_code" in
        200|301|302) return 0 ;;
        403)
            _migrate_log "WAN listener returned 403 access forbidden by rule"
            return 1
            ;;
        *)
            _migrate_log "WAN listener gave no 200/302 (code $wan_code); loopback status stands"
            return 0
            ;;
    esac
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
    tar czf "$_tarball" -C "${LUCI_NGINX_ETC_ROOT:-/}" etc/config
    opkg list-installed > "$_installed"
    echo "$_tarball"
}

_restore_nginx_uci_stopped() {
    # Put the UCI back without starting nginx. uhttpd is about to own 443.
    saved="$1"
    [ -n "$saved" ] && [ -f "$saved" ] || return 1
    if _would "uci import nginx < $saved"; then
        return 0
    fi
    uci import nginx < "$saved"
    uci commit nginx
}

_uhttpd_answers_443() {
    url="https://127.0.0.1:443/cgi-bin/luci/"
    if _would "check $url"; then
        return 0
    fi
    code=$(_http_code "$url")
    code=$(printf '%s' "$code" | tr -cd '0-9')
    _migrate_log "uhttpd probe $url -> ${code:-000}"
    case "$code" in
        200|301|302|401|403) return 0 ;;
    esac
    return 1
}

_abort_back_to_uhttpd() {
    saved="$1"
    _migrate_log "rolling back; stopping nginx and starting uhttpd on 443"
    if _would "$INIT_D/nginx stop"; then
        echo "WOULD $INIT_D/uhttpd enable"
        echo "WOULD $INIT_D/uhttpd start"
        return 0
    fi
    if [ -x "$INIT_D/nginx" ]; then
        "$INIT_D/nginx" stop 2>/dev/null || true
        "$INIT_D/nginx" disable 2>/dev/null || true
    fi
    if ! _restore_nginx_uci_stopped "$saved"; then
        _migrate_log "nginx uci backup was not restored"
    fi
    if [ -x "$INIT_D/uhttpd" ]; then
        "$INIT_D/uhttpd" enable 2>/dev/null || true
        "$INIT_D/uhttpd" start 2>/dev/null || true
    else
        _migrate_log "uhttpd init absent; cannot start it"
        return 1
    fi
    if _uhttpd_answers_443; then
        _migrate_log "uhttpd is answering on 443 again"
        return 0
    fi
    _migrate_log "uhttpd did not answer on 443 after rollback"
    return 1
}

_configure_nginx_uci() {
    # UCI only. nginx is not started: uhttpd still holds 80 and 443.
    _migrate_log "configure nginx uci (https only, bondix locations, no restrict_locally)"
    LUCI_NGINX_DEFER_RELOAD=1
    ensure_bondix_locations_include || true
    if ! drop_restrict_locally; then
        LUCI_NGINX_DEFER_RELOAD=0
        return 1
    fi
    _migrate_log "https-only (no _redirect2ssl, no listen 80)"
    disable_http_redirect || true
    LUCI_NGINX_DEFER_RELOAD=0
    return 0
}

_stop_uhttpd_for_cutover() {
    if [ ! -x "$INIT_D/uhttpd" ]; then
        _migrate_log "uhttpd init absent; not stopping it"
        return 0
    fi
    _migrate_log "stop uhttpd so nginx can bind 443"
    if _would "$INIT_D/uhttpd stop"; then
        return 0
    fi
    "$INIT_D/uhttpd" stop
}

_start_nginx_after_uhttpd() {
    nginx_generate_conf
    if ! nginx_test_config; then
        _migrate_log "nginx -t failed"
        return 1
    fi
    if _would "$INIT_D/nginx enable"; then
        echo "WOULD $INIT_D/nginx start"
        return 0
    fi
    if [ ! -x "$INIT_D/nginx" ]; then
        _migrate_log "nginx init absent"
        return 1
    fi
    "$INIT_D/nginx" enable || return 1
    if ! "$INIT_D/nginx" start; then
        "$INIT_D/nginx" restart || return 1
    fi
    nginx_test_config
}

_retire_uhttpd() {
    # Health check already passed. Disable, then remove the daemon.
    # luci / luci-ssl depend on uhttpd, so those metapackages go first.
    # No --autoremove: LuCI apps and luci-base stay.
    _migrate_log "health check passed; disable and remove uhttpd"
    if [ -x "$INIT_D/uhttpd" ]; then
        if _would "$INIT_D/uhttpd disable"; then
            echo "WOULD opkg remove uhttpd uhttpd-mod-ubus"
            return 0
        fi
        "$INIT_D/uhttpd" disable 2>/dev/null || true
    elif _would "$INIT_D/uhttpd disable"; then
        echo "WOULD opkg remove uhttpd uhttpd-mod-ubus"
        return 0
    fi
    for pkg in luci-light luci-ssl luci; do
        if _pkg_installed "$pkg"; then
            _migrate_log "opkg remove $pkg so uhttpd can be removed"
            opkg remove "$pkg" || _migrate_log "warning: opkg remove $pkg failed"
        fi
    done
    rc=0
    for pkg in uhttpd-mod-ubus uhttpd; do
        if _pkg_installed "$pkg"; then
            _migrate_log "opkg remove $pkg"
            opkg remove "$pkg" || rc=1
        else
            _migrate_log "$pkg already absent"
        fi
    done
    return "$rc"
}

migrate_to_nginx() {
    _migrate_log "backup /etc/config"
    _backup_for_rollback >/dev/null || return 1

    _migrate_log "opkg update"
    if _would "opkg update"; then
        :
    elif ! opkg update; then
        _migrate_log "opkg update failed; uhttpd was left running and untouched; uhttpd was not removed"
        return 1
    fi

    if ! _install_nginx_packages; then
        _migrate_log "package install failed; uhttpd was left running and untouched; uhttpd was not removed"
        return 1
    fi
    if ! _install_default_packages; then
        _migrate_log "default package install failed; uhttpd was left running and untouched; uhttpd was not removed"
        return 1
    fi
    _warn_expected_packages

    saved=$(_backup_nginx_uci) || return 1
    if ! _configure_nginx_uci; then
        _migrate_log "nginx uci configure failed; uhttpd was not stopped; rolling back uci"
        _restore_nginx_uci_stopped "$saved" || true
        return 1
    fi

    if ! _stop_uhttpd_for_cutover; then
        _migrate_log "could not stop uhttpd; rolling back"
        _abort_back_to_uhttpd "$saved" || true
        return 1
    fi
    if ! _start_nginx_after_uhttpd; then
        _migrate_log "nginx -t or start failed; rolling back to uhttpd"
        _abort_back_to_uhttpd "$saved" || true
        return 1
    fi
    if ! _luci_https_ok; then
        _migrate_log "LuCI HTTPS was not 200 or 302; rolling back to uhttpd"
        _abort_back_to_uhttpd "$saved" || true
        return 1
    fi
    if ! _retire_uhttpd; then
        _migrate_log "nginx is serving LuCI but removing uhttpd failed; uhttpd was not started"
        return 1
    fi
    _migrate_log "luci https ok"
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
            # Already on nginx, including a box migrated by an older
            # script that left restrict_locally in place. post_update.sh
            # runs this path once per BUILD_SHA.
            ensure_bondix_locations_include
            include_added=$?
            if ! drop_restrict_locally; then
                return 1
            fi
            disable_http_redirect
            redirect_rc=$?
            if [ "$include_added" -eq 0 ]; then
                reload_nginx_after_include || redirect_rc=$?
            fi
            if [ "$redirect_rc" -ne 0 ]; then
                return "$redirect_rc"
            fi
            if ! _luci_https_ok; then
                _migrate_log "LuCI HTTPS was not 200 or 302; uhttpd was not started"
                return 1
            fi
            _migrate_log "luci https ok"
            return 0
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
