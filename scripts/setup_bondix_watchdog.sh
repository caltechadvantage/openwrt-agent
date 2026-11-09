#!/bin/sh
# Idempotent install of the Bondix watchdog. An existing UCI file is
# left alone so a site can disable last-resort and keep that across
# updates. Set BONDIX_WATCHDOG_SOURCE_ONLY is not used here.
#
# WD_PREFIX, when set, installs under that directory and does not
# enable or start the service. Used by tests.

PREFIX="${WD_PREFIX:-}"
ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
INIT_SRC="$ROOT/files/bondix-watchdog.init"
UCI_SRC="$ROOT/files/bondix-watchdog.config"
INIT_DST="$PREFIX/etc/init.d/bondix-watchdog"
UCI_DST="$PREFIX/etc/config/bondix-watchdog"

if [ ! -f "$INIT_SRC" ] || [ ! -f "$UCI_SRC" ]; then
    echo "bondix-watchdog files missing under $ROOT/files" >&2
    exit 1
fi

mkdir -p "$PREFIX/etc/init.d" "$PREFIX/etc/config"
cp "$INIT_SRC" "$INIT_DST"
chmod 755 "$INIT_DST"

if [ -f "$UCI_DST" ]; then
    echo "keeping existing $UCI_DST"
else
    cp "$UCI_SRC" "$UCI_DST"
    chmod 644 "$UCI_DST"
    echo "installed $UCI_DST"
fi

if [ -n "$PREFIX" ]; then
    echo "prefix install only ($PREFIX), service not started"
    exit 0
fi

if [ ! -f /etc/rc.common ]; then
    echo "no /etc/rc.common, skip enable (not an OpenWrt init system)"
    exit 0
fi

/etc/init.d/bondix-watchdog enable
/etc/init.d/bondix-watchdog restart
echo "bondix-watchdog enabled"
