# Shared ngrok v3 endpoint writer. Sourced by the setup scripts.
# Does not start or stop ngrok.

# Loopback nginx on 443. The dial target is localhost. nginx's LuCI
# server is named _lan and listens as the default SSL server, so SNI
# localhost still lands there. The Host header is rewritten to _lan so
# that server, including conf.d/bondix.locations, is the one that
# answers. /etc/hosts still maps _lan to 127.0.0.1. The shell endpoint
# below is unchanged. This file does not start or stop ngrok.
#
# Upstream TLS verification: ngrok 3.33's endpoints schema has no field
# to set it. `ngrok config check` rejects upstream_tls_verify on
# config.Endpoint and config.Upstream. Verification is off unless the
# process is started with --upstream-tls-verify, which these scripts
# do not pass. The self-signed nginx certificate (name _lan, not
# localhost) is therefore not checked. The hop is loopback only.

NGROK_UI_UPSTREAM="https://localhost:443"
NGROK_UI_HOST="_lan"
NGROK_HOSTS_MARKER="# openwrt-agent-luci-sni"

ensure_luci_sni_hosts() {
    hosts_file="${NGROK_HOSTS_FILE:-/etc/hosts}"
    if [ ! -f "$hosts_file" ] && [ "${LUCI_NGINX_DRY_RUN:-0}" != "1" ]; then
        return 0
    fi
    if [ -f "$hosts_file" ] && grep -q "$NGROK_HOSTS_MARKER" "$hosts_file" 2>/dev/null; then
        return 0
    fi
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD append 127.0.0.1 _lan to $hosts_file"
        return 0
    fi
    printf '127.0.0.1 _lan %s\n' "$NGROK_HOSTS_MARKER" >> "$hosts_file"
}

backup_ngrok_config() {
    if [ ! -f "$NGROK_CONFIG" ]; then
        return 0
    fi
    stamp=$(date +%Y%m%d%H%M%S)
    backup="${NGROK_CONFIG}.bak.${stamp}"
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD cp $NGROK_CONFIG $backup"
        return 0
    fi
    cp -a "$NGROK_CONFIG" "$backup"
}

write_ngrok_config() {
    backup_ngrok_config
    ensure_luci_sni_hosts
    config_dir=$(dirname "$NGROK_CONFIG")
    if [ "${LUCI_NGINX_DRY_RUN:-0}" = "1" ]; then
        echo "WOULD write $NGROK_CONFIG upstream=${NGROK_UI_UPSTREAM} host=${NGROK_UI_HOST}"
        return 0
    fi
    mkdir -p "$config_dir"
    cat > "$NGROK_CONFIG" << EOF
version: "3"
agent:
    authtoken: ${NGROK_AUTHTOKEN}

endpoints:
  - name: https-ui
    url: https://${NGROK_URL_PREFIX}.ngrok.gigabonding.com
    upstream:
      url: ${NGROK_UI_UPSTREAM}
    traffic_policy:
      on_http_request:
        - actions:
            - type: add-headers
              config:
                headers:
                  host: ${NGROK_UI_HOST}

  - name: ttyd
    url: https://${NGROK_URL_PREFIX}${TTYD_URL_SUFFIX}.ngrok.gigabonding.com
    upstream:
      url: http://${TTYD_UPSTREAM_IP}:${TTYD_UPSTREAM_PORT}
EOF
}

# Point an existing https-ui endpoint at https://localhost:443.
# Leaves the shell/ttyd endpoint, the authtoken, and the public URLs
# alone. Does not start, stop, or signal ngrok. No-op when the file is
# missing or the UI upstream is already localhost:443.
migrate_ngrok_luci_upstream() {
    config="${NGROK_CONFIG:-/root/.config/ngrok/ngrok.yml}"
    [ -f "$config" ] || return 0
    grep -q 'name:[[:space:]]*https-ui' "$config" || return 0
    if awk '
        BEGIN { in_ui = 0; want = 0; found = 0 }
        {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*https-ui[[:space:]]*$/) {
                in_ui = 1
                want = 0
            } else if ($0 ~ /^[[:space:]]*-[[:space:]]*name:/ && in_ui) {
                in_ui = 0
                want = 0
            }
            if (in_ui && $0 ~ /^[[:space:]]*upstream:[[:space:]]*$/) {
                want = 1
            }
            if (want && $0 ~ /^[[:space:]]*url:[[:space:]]*https:\/\/localhost:443[[:space:]]*$/) {
                found = 1
            }
            if (want && $0 ~ /^[[:space:]]*url:/) {
                want = 0
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$config"; then
        return 0
    fi
    NGROK_CONFIG="$config"
    backup_ngrok_config
    tmp="${config}.tmp.$$"
    awk '
        BEGIN { in_ui = 0; want = 0 }
        {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*https-ui[[:space:]]*$/) {
                in_ui = 1
                want = 0
            } else if ($0 ~ /^[[:space:]]*-[[:space:]]*name:/ && in_ui) {
                in_ui = 0
                want = 0
            }
            if (in_ui && $0 ~ /^[[:space:]]*upstream:[[:space:]]*$/) {
                want = 1
            }
            if (want && $0 ~ /^[[:space:]]*url:/) {
                sub(/url:.*/, "url: https://localhost:443")
                want = 0
            }
            print
        }
    ' "$config" > "$tmp"
    mv "$tmp" "$config"
}
