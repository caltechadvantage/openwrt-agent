#!/bin/sh
# Stop the watchdog, put Bondix /1 routes and the proxy chain back, and
# remove the init script. The UCI file is kept so a reinstall remembers
# the site choice. WD_PURGE=1 deletes the UCI file too.
#
# WD_PREFIX installs the same paths under a test root and skips procd.

PREFIX="${WD_PREFIX:-}"
ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
WD="$ROOT/scripts/bondix-watchdog.sh"

if [ -z "$PREFIX" ] && [ -x "$WD" ]; then
    /bin/sh "$WD" cleanup || true
fi

if [ -z "$PREFIX" ] && [ -x /etc/init.d/bondix-watchdog ]; then
    /etc/init.d/bondix-watchdog stop 2>/dev/null || true
    /etc/init.d/bondix-watchdog disable 2>/dev/null || true
fi

rm -f "$PREFIX/etc/init.d/bondix-watchdog"
rm -f "$PREFIX"/etc/rc.d/S*bondix-watchdog "$PREFIX"/etc/rc.d/K*bondix-watchdog

if [ "${WD_PURGE:-0}" = "1" ]; then
    rm -f "$PREFIX/etc/config/bondix-watchdog"
    echo "removed bondix-watchdog config"
fi

echo "bondix-watchdog uninstalled"
