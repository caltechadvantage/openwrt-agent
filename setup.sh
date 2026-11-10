#!/bin/sh

# Setup Script for OpenWrt
# This script sets up the complete environment for the OpenWrt monitoring project
# It configures both ngrok and code service (code service handles dependencies)
#
# Modes:
#   ./setup.sh                    Interactive - prompts for confirmation and ngrok config
#   ./setup.sh --non-interactive  Reads DTS_* env vars, no prompts. Used by the dashboard's
#                                 claim-token install flow.

NON_INTERACTIVE=0
case "${1:-}" in
    --non-interactive|-y) NON_INTERACTIVE=1 ;;
esac
[ "${DTS_NON_INTERACTIVE:-0}" = "1" ] && NON_INTERACTIVE=1
export DTS_NON_INTERACTIVE="$NON_INTERACTIVE"

# Site name = a human-friendly label shown next to the GB-<MAC> ID in
# ThingsBoard. Without it, every router looks like a hex string in the
# device list. Saved to ~/.openwrt/config.json as site_name; provision.py
# reads it and sends it as deviceLabel during TB provisioning.
SITE_NAME="${DTS_SITE_NAME:-}"

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}>>>${NC} $1"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Make sure /etc/openwrt-agent.env carries an NGROK_AUTHTOKEN before we
# call setup_ngrok.sh. The script itself errors out cleanly if the file
# is missing — without this helper, a manual ``./setup.sh`` invocation
# bails on step 1 and the operator has to ssh back in and write the
# file by hand.
#
# Resolution order:
#   1. /etc/openwrt-agent.env already has it → nothing to do
#   2. NGROK_AUTHTOKEN env var (e.g. dashboard-generated installer)
#      → persist to /etc/openwrt-agent.env so future runs need no env
#   3. Interactive mode → prompt the operator once, then persist
#   4. Non-interactive mode → fall through; setup_ngrok.sh will error
#      with its usual "set the token" message
ensure_ngrok_token() {
    local env_file="/etc/openwrt-agent.env"

    # 1. Already present in env_file — done
    if [ -f "$env_file" ]; then
        local existing
        existing=$(sed -n 's/^NGROK_AUTHTOKEN=\(.*\)/\1/p' "$env_file" | head -1)
        [ -n "$existing" ] && return 0
    fi

    # 2. Inherited from env (dashboard installer flow, or operator
    #    invoked: NGROK_AUTHTOKEN=xxx ./setup.sh)
    local token="${NGROK_AUTHTOKEN:-}"

    # 3. Fall back to the committed shared token in scripts/bootstrap.env
    #    so a plain `git clone && ./setup.sh` on a fresh router still
    #    comes up online without operator input. The dashboard install
    #    flow (step 2) still wins because it exports NGROK_AUTHTOKEN
    #    before we get here, giving per-tenant overrides priority.
    if [ -z "$token" ] && [ -f "$SCRIPT_DIR/scripts/bootstrap.env" ]; then
        # shellcheck disable=SC1091
        . "$SCRIPT_DIR/scripts/bootstrap.env"
        token="${NGROK_AUTHTOKEN:-}"
    fi

    # 4. Prompt only if interactive and we still don't have a token
    if [ -z "$token" ] && [ "$NON_INTERACTIVE" != "1" ]; then
        print_info "ngrok authtoken not configured."
        print_info "Get yours from https://dashboard.ngrok.com/your-authtokens"
        printf "Paste the NGROK_AUTHTOKEN (or press Enter to skip): "
        read token
    fi

    if [ -z "$token" ]; then
        return 0   # let setup_ngrok.sh emit its standard error
    fi

    mkdir -p /etc
    (
        umask 077
        # Preserve any other key=value lines already in the file; replace
        # NGROK_AUTHTOKEN if present, append otherwise.
        if [ -f "$env_file" ]; then
            grep -v '^NGROK_AUTHTOKEN=' "$env_file" > "${env_file}.tmp" || true
        else
            : > "${env_file}.tmp"
        fi
        echo "NGROK_AUTHTOKEN=$token" >> "${env_file}.tmp"
        mv "${env_file}.tmp" "$env_file"
        chmod 600 "$env_file"
    )
    print_success "Saved ngrok authtoken to $env_file"
}

# Resolve the ThingsBoard provisioning key/secret and persist them to
# ~/.openwrt/local_settings.py so the agent can onboard on first run.
#
# Mirrors ensure_ngrok_token, with ONE deliberate difference: there is
# no committed fallback. The ngrok token is low-risk and lives in the
# tracked scripts/bootstrap.env; the provisioning secret mints devices
# against the tenant, so it must never enter the public repo. It is
# resolved from uncommitted sources only:
#   1. Already present in a local_settings.py (repo root or ~/.openwrt)
#   2. TB_PROVISION_KEY / TB_PROVISION_SECRET env vars (dashboard
#      installer flow, or operator-exported)
#   3. A gitignored scripts/bootstrap.local.env (drop it onto your
#      golden image / build host for zero-touch fleet installs)
#   4. Interactive prompt
# then persisted to ~/.openwrt/local_settings.py (loaded by settings.py,
# kept outside the code dir so update.sh doesn't clobber it).
ensure_provision_keys() {
    local ls_file="${HOME:-/root}/.openwrt/local_settings.py"
    local repo_ls="$SCRIPT_DIR/local_settings.py"

    # 1. Already configured in either local_settings.py location — done.
    if grep -qs '^[[:space:]]*TB_PROVISION_KEY[[:space:]]*=' "$ls_file" "$repo_ls" 2>/dev/null; then
        print_info "Provisioning keys already present in local_settings.py"
        return 0
    fi

    # 2. Inherited from env (dashboard installer flow, or operator ran:
    #    TB_PROVISION_KEY=xxx TB_PROVISION_SECRET=yyy ./setup.sh)
    local key="${TB_PROVISION_KEY:-}"
    local secret="${TB_PROVISION_SECRET:-}"

    # 3. Gitignored local bootstrap file. Unlike scripts/bootstrap.env
    #    (committed, shared ngrok token), this one is never committed.
    if { [ -z "$key" ] || [ -z "$secret" ]; } && [ -f "$SCRIPT_DIR/scripts/bootstrap.local.env" ]; then
        # shellcheck disable=SC1091
        . "$SCRIPT_DIR/scripts/bootstrap.local.env"
        key="${key:-${TB_PROVISION_KEY:-}}"
        secret="${secret:-${TB_PROVISION_SECRET:-}}"
    fi

    # 4. Prompt only if interactive and still missing.
    if { [ -z "$key" ] || [ -z "$secret" ]; } && [ "$NON_INTERACTIVE" != "1" ]; then
        print_info "ThingsBoard provisioning key/secret not configured."
        print_info "Find them in ThingsBoard: Device profiles > <profile> > Device provisioning."
        [ -z "$key" ]    && { printf "Paste TB_PROVISION_KEY (or Enter to skip): ";    read key; }
        [ -z "$secret" ] && { printf "Paste TB_PROVISION_SECRET (or Enter to skip): "; read secret; }
    fi

    # 5. Still nothing — warn and let provision.py emit its error on the
    #    first run. Don't fail setup: an already-provisioned unit (one
    #    with a tb_token in config.json) runs fine without these.
    if [ -z "$key" ] || [ -z "$secret" ]; then
        print_warning "Provisioning keys not set — a fresh device will NOT onboard."
        print_warning "Add TB_PROVISION_KEY / TB_PROVISION_SECRET to $ls_file, then restart the service."
        return 0
    fi

    # Persist. Preserve any other overrides already in the file; replace
    # the two provision lines if present, append otherwise.
    mkdir -p "$(dirname "$ls_file")"
    (
        umask 077
        if [ -f "$ls_file" ]; then
            grep -v '^[[:space:]]*TB_PROVISION_KEY[[:space:]]*=' "$ls_file" 2>/dev/null \
                | grep -v '^[[:space:]]*TB_PROVISION_SECRET[[:space:]]*=' > "${ls_file}.tmp" || true
        else
            : > "${ls_file}.tmp"
        fi
        echo "TB_PROVISION_KEY = \"$key\"" >> "${ls_file}.tmp"
        echo "TB_PROVISION_SECRET = \"$secret\"" >> "${ls_file}.tmp"
        mv "${ls_file}.tmp" "$ls_file"
        chmod 600 "$ls_file"
    )
    print_success "Saved provisioning keys to $ls_file"
}

# Step 1: Run ngrok setup
setup_ngrok() {
    print_step "Step 1: Setting Up ngrok"

    ensure_ngrok_token

    local ngrok_script="$SCRIPT_DIR/scripts/setup_ngrok.sh"

    if [ ! -f "$ngrok_script" ]; then
        print_error "ngrok setup script not found at $ngrok_script"
        exit 1
    fi

    print_info "Running ngrok setup script..."
    chmod +x "$ngrok_script"
    "$ngrok_script"

    if [ $? -eq 0 ]; then
        print_success "ngrok setup completed"
    else
        print_error "ngrok setup failed"
        exit 1
    fi

    return 0
}

# Step 2: Run code setup
setup_code() {
    print_step "Step 2: Setting Up Code Service"
    
    local code_setup_script="$SCRIPT_DIR/scripts/setup_code.sh"
    
    if [ ! -f "$code_setup_script" ]; then
        print_error "Code setup script not found at $code_setup_script"
        exit 1
    fi
    
    print_info "Running code setup script..."
    chmod +x "$code_setup_script"
    "$code_setup_script"
    
    if [ $? -eq 0 ]; then
        print_success "Code service setup completed"
    else
        print_error "Code service setup failed"
        exit 1
    fi
    
    return 0
}

# Main execution
main() {
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}    OpenWrt Complete Setup Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    print_info "This script will:"
    echo -e "  1. ${CYAN}Set up ngrok (binary and configuration)${NC}"
    echo -e "  2. ${CYAN}Set up code monitoring service (includes Python/pip installation and dependencies)${NC}"
    echo ""
    
    if [ "$NON_INTERACTIVE" != "1" ]; then
        printf "Continue with setup? (Y/n): "
        read confirm
        if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            print_info "Setup cancelled by user"
            exit 0
        fi
        if [ -z "$SITE_NAME" ]; then
            echo ""
            print_info "What name should this router show as in ThingsBoard?"
            echo -e "  Examples: ${CYAN}Cintas-Lancaster${NC}, ${CYAN}ACME-NYC-Site-3${NC}, ${CYAN}DTS-Warehouse-A${NC}"
            echo -e "  Leave blank to skip — the device will only show its GB-<MAC> identifier."
            printf "Site / unit name: "
            read SITE_NAME
        fi
    else
        print_info "Non-interactive mode: skipping confirmation"
        [ -n "$SITE_NAME" ] && print_info "Site name from DTS_SITE_NAME: $SITE_NAME"
    fi

    # Persist the site name (if any) BEFORE running the sub-installers so
    # the first call to provision.py picks it up. Empty string is fine:
    # provision.py treats absent/empty site_name as "no label".
    if [ -n "$SITE_NAME" ]; then
        DTS_SITE_NAME="$SITE_NAME" python3 - <<'PYEOF'
import json, os
cfg_path = os.path.expanduser("~/.openwrt/config.json")
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg["site_name"] = os.environ.get("DTS_SITE_NAME", "")
tmp = cfg_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, cfg_path)
print(f"[INFO] Saved site_name='{cfg['site_name']}' to {cfg_path}")
PYEOF
    fi
    export DTS_SITE_NAME

    # Resolve + persist the TB provisioning key/secret BEFORE the code
    # service starts, so the agent's first-run provision.py finds them.
    ensure_provision_keys

    # Execute all steps
    setup_ngrok || { print_error "ngrok setup failed"; exit 1; }
    setup_code || { print_error "Code service setup failed"; exit 1; }
    
    # Final summary
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Complete setup finished successfully!"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Service Management:"
    echo -e "  ${CYAN}Code Service:${NC} /etc/init.d/openwrt-main {start|stop|status}"
    echo ""
    print_info "ngrok Configuration:"
    echo -e "  ${CYAN}Config File:${NC} /root/.config/ngrok/ngrok.yml"
    echo -e "  ${CYAN}Binary:${NC} /usr/bin/ngrok"
    echo -e "  ${CYAN}Start ngrok:${NC} ngrok start --all --config /root/.config/ngrok/ngrok.yml"
    echo ""
    print_info "Log Files:"
    echo -e "  ${CYAN}Code Service:${NC} tail -f /var/log/openwrt-main.log"
    echo ""
}

# Run main function
main

