#!/bin/sh

# Setup ngrok Script for OpenWrt
# This script installs and configures ngrok service for tunneling

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
NGROK_BIN="/usr/bin/ngrok"
NGROK_CONFIG="/root/.config/ngrok/ngrok.yml"
# Ngrok account auth token. Supply via env (NGROK_AUTHTOKEN=<token>)
# OR /etc/openwrt-agent.env (sourced below if present). Never tracked
# in source.
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"
LOCAL_PORT="80"
[ -f /etc/openwrt-agent.env ] && . /etc/openwrt-agent.env
if [ -z "$NGROK_AUTHTOKEN" ]; then
    echo "[ERROR] NGROK_AUTHTOKEN not set." >&2
    echo "        Run as:  NGROK_AUTHTOKEN=<token> $0" >&2
    echo "        Or drop one line into /etc/openwrt-agent.env:" >&2
    echo "            NGROK_AUTHTOKEN=<token>" >&2
    exit 1
fi

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

# Step 1: Configure uhttpd on port 80
configure_uhttpd() {
    print_step "Step 1: Configuring uhttpd on Port 80"
    
    print_info "Checking uhttpd status..."
    if /etc/init.d/uhttpd status > /dev/null 2>&1; then
        print_success "uhttpd is running"
    else
        print_info "Starting uhttpd..."
        /etc/init.d/uhttpd start
        if [ $? -eq 0 ]; then
            print_success "uhttpd started successfully"
        else
            print_error "Failed to start uhttpd"
            return 1
        fi
    fi
    
    print_info "Enabling uhttpd to start at boot..."
    /etc/init.d/uhttpd enable
    if [ $? -eq 0 ]; then
        print_success "uhttpd enabled for boot"
    else
        print_warning "Failed to enable uhttpd (may already be enabled)"
    fi
    
    print_info "Configuring uhttpd to listen on port ${LOCAL_PORT}..."
    uci set uhttpd.main.listen_http="0.0.0.0:${LOCAL_PORT}"
    if [ $? -eq 0 ]; then
        print_success "uhttpd configured to listen on 0.0.0.0:${LOCAL_PORT}"
    else
        print_error "Failed to configure uhttpd listen port"
        return 1
    fi
    
    print_info "Committing uhttpd configuration changes..."
    uci commit uhttpd
    if [ $? -eq 0 ]; then
        print_success "uhttpd configuration committed"
    else
        print_error "Failed to commit uhttpd configuration"
        return 1
    fi
    
    print_info "Restarting uhttpd..."
    /etc/init.d/uhttpd restart
    if [ $? -eq 0 ]; then
        print_success "uhttpd restarted successfully"
    else
        print_error "Failed to restart uhttpd"
        return 1
    fi
    
    print_info "Starting dropbear SSH service..."
    /etc/init.d/dropbear start
    if [ $? -eq 0 ]; then
        print_success "dropbear started successfully"
    else
        print_warning "dropbear may already be running"
    fi
    
    # Verify uhttpd is running
    print_info "Verifying uhttpd is accessible on port ${LOCAL_PORT}..."
    sleep 2
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${LOCAL_PORT} | grep -q "200\|301\|302\|401\|403"; then
        print_success "uhttpd is running and accessible on port ${LOCAL_PORT}"
    else
        print_warning "uhttpd may not be fully ready yet. Please verify manually with: curl http://127.0.0.1:${LOCAL_PORT}"
    fi
    
    return 0
}

# Get br-lan interface IP address
get_br_lan_ip() {
    # Try ifconfig first (legacy method)
    BR_LAN_IP=$(ifconfig br-lan 2>/dev/null | grep "inet addr" | awk '{print $2}' | cut -d: -f2)
    
    # If ifconfig didn't work, try ip command (modern method)
    if [ -z "$BR_LAN_IP" ]; then
        BR_LAN_IP=$(ip addr show br-lan 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    fi
    
    # If still empty, try uci (OpenWrt configuration method)
    if [ -z "$BR_LAN_IP" ]; then
        BR_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
    fi
    
    echo "$BR_LAN_IP"
}

# Step 2: Get user input for ngrok configuration
get_ngrok_config() {
    print_step "Step 2: ngrok Configuration"
    
    print_info "Please provide the following information for ngrok configuration:"
    echo ""
    
    read -p "Enter the first part of ngrok URL (e.g., hd-spokane): " NGROK_URL_PREFIX
    if [ -z "$NGROK_URL_PREFIX" ]; then
        print_error "ngrok URL prefix cannot be empty"
        exit 1
    fi
    
    read -p "Enter ttyd URL suffix (e.g., -shell, default: -shell): " TTYD_URL_SUFFIX
    if [ -z "$TTYD_URL_SUFFIX" ]; then
        TTYD_URL_SUFFIX="-shell"
    fi
    
    # Automatically get br-lan IP address
    print_info "Extracting IP address from br-lan interface..."
    TTYD_UPSTREAM_IP=$(get_br_lan_ip)
    
    if [ -z "$TTYD_UPSTREAM_IP" ]; then
        print_warning "Could not automatically detect br-lan IP address"
        read -p "Enter ttyd upstream IP (default: 172.16.16.1): " TTYD_UPSTREAM_IP
        if [ -z "$TTYD_UPSTREAM_IP" ]; then
            TTYD_UPSTREAM_IP="172.16.16.1"
        fi
    else
        print_success "Detected br-lan IP: ${TTYD_UPSTREAM_IP}"
        read -p "Enter ttyd upstream IP (default: ${TTYD_UPSTREAM_IP}): " USER_TTYD_UPSTREAM_IP
        if [ -n "$USER_TTYD_UPSTREAM_IP" ]; then
            TTYD_UPSTREAM_IP="$USER_TTYD_UPSTREAM_IP"
        fi
    fi
    
    read -p "Enter ttyd upstream port (default: 7681): " TTYD_UPSTREAM_PORT
    if [ -z "$TTYD_UPSTREAM_PORT" ]; then
        TTYD_UPSTREAM_PORT="7681"
    fi
    
    print_info "Configuration summary:"
    echo -e "  ${CYAN}HTTPS URL:${NC} https://${NGROK_URL_PREFIX}.ngrok.gigabonding.com"
    echo -e "  ${CYAN}ttyd URL:${NC} https://${NGROK_URL_PREFIX}${TTYD_URL_SUFFIX}.ngrok.gigabonding.com"
    echo -e "  ${CYAN}ttyd Upstream:${NC} http://${TTYD_UPSTREAM_IP}:${TTYD_UPSTREAM_PORT}"
    echo -e "  ${CYAN}Local Port:${NC} ${LOCAL_PORT}"
    
    read -p "Continue with this configuration? (Y/n): " confirm
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        print_error "Configuration cancelled by user"
        exit 1
    fi
    
    return 0
}

# Step 3: Install ngrok binary
install_ngrok_binary() {
    print_step "Step 3: Installing ngrok Binary"
    
    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    NGROK_SOURCE="$SCRIPT_DIR/ngrok"
    
    if [ ! -f "$NGROK_SOURCE" ]; then
        print_error "ngrok binary not found at $NGROK_SOURCE"
        print_info "Please ensure the ngrok binary file is located in the scripts directory"
        exit 1
    fi
    
    print_info "Copying ngrok binary to ${NGROK_BIN}..."
    cp "$NGROK_SOURCE" "$NGROK_BIN"
    if [ $? -eq 0 ]; then
        print_success "ngrok binary copied successfully"
    else
        print_error "Failed to copy ngrok binary"
        return 1
    fi
    
    print_info "Making ngrok binary executable (chmod 755)..."
    chmod 755 "$NGROK_BIN"
    if [ $? -eq 0 ]; then
        print_success "ngrok binary is now executable"
    else
        print_error "Failed to make ngrok binary executable"
        return 1
    fi
    
    print_info "Verifying ngrok runs from PATH..."
    if $NGROK_BIN version > /dev/null 2>&1; then
        ngrok_version=$($NGROK_BIN version 2>&1 | head -n 1)
        print_success "ngrok is working: $ngrok_version"
    else
        print_error "Failed to verify ngrok. Please check the binary"
        return 1
    fi
    
    return 0
}

# Step 4: Create ngrok configuration file
create_ngrok_config() {
    print_step "Step 4: Creating ngrok Configuration File"
    
    # Create config directory if it doesn't exist
    CONFIG_DIR="$(dirname "$NGROK_CONFIG")"
    if [ ! -d "$CONFIG_DIR" ]; then
        print_info "Creating config directory: $CONFIG_DIR"
        mkdir -p "$CONFIG_DIR"
        if [ $? -eq 0 ]; then
            print_success "Config directory created"
        else
            print_error "Failed to create config directory"
            return 1
        fi
    fi
    
    print_info "Creating ngrok configuration file at $NGROK_CONFIG..."
    
    cat > "$NGROK_CONFIG" << EOF
version: "3"
agent:
    authtoken: ${NGROK_AUTHTOKEN}

endpoints:
  - name: https-ui
    url: https://${NGROK_URL_PREFIX}.ngrok.gigabonding.com
    upstream:
      url: http://127.0.0.1:${LOCAL_PORT}

  - name: ttyd
    url: https://${NGROK_URL_PREFIX}${TTYD_URL_SUFFIX}.ngrok.gigabonding.com
    upstream:
      url: http://${TTYD_UPSTREAM_IP}:${TTYD_UPSTREAM_PORT}
EOF
    
    if [ $? -eq 0 ]; then
        print_success "ngrok configuration file created successfully"
    else
        print_error "Failed to create ngrok configuration file"
        return 1
    fi
    
    # Display configuration
    print_info "Configuration file contents:"
    echo ""
    cat "$NGROK_CONFIG"
    echo ""
    
    return 0
}

# Step 5: Create ngrok init script
create_ngrok_service() {
    print_step "Step 5: Creating ngrok Service"
    
    print_info "Creating /etc/init.d/ngrok..."
    
    cat > /etc/init.d/ngrok << 'EOFSERVICE'
#!/bin/sh /etc/rc.common
# /etc/init.d/ngrok
# Starts ngrok automatically after reboot

START=99
STOP=10

CONFIG="/root/.config/ngrok/ngrok.yml"
LOG="/var/log/ngrok.log"

start() {
    echo "[ngrok] Starting ngrok tunnels..." > $LOG

    # Wait for WAN
    while ! ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; do
        echo "[ngrok] Waiting for network..." >> $LOG
        sleep 5
    done

    echo "[ngrok] Network up. Launching ngrok..." >> $LOG
    # Start ngrok with explicit config
    /usr/bin/ngrok start --all --config $CONFIG >> $LOG 2>&1 &
}

stop() {
    echo "[ngrok] Stopping ngrok..." >> $LOG
    killall -9 ngrok
}
EOFSERVICE
    
    if [ $? -eq 0 ]; then
        print_success "Init script created successfully"
    else
        print_error "Failed to create init script"
        return 1
    fi
    
    print_info "Making init script executable..."
    chmod +x /etc/init.d/ngrok
    if [ $? -eq 0 ]; then
        print_success "Init script is now executable"
    else
        print_error "Failed to make init script executable"
        return 1
    fi
    
    return 0
}

# Step 6: Enable and start the service
enable_service() {
    print_step "Step 6: Enabling and Starting ngrok Service"
    
    print_info "Enabling ngrok service to start at boot..."
    /etc/init.d/ngrok enable
    if [ $? -eq 0 ]; then
        print_success "Service enabled for boot"
    else
        print_error "Failed to enable service"
        return 1
    fi
    
    print_info "Starting ngrok service..."
    /etc/init.d/ngrok start
    sleep 3
    
    # Check if ngrok process is running
    if pgrep -f "ngrok start" > /dev/null 2>&1; then
        print_success "ngrok service started successfully"
    else
        print_warning "Service may not be running yet. Check logs: tail -f /var/log/ngrok.log"
    fi
    
    return 0
}

# Main execution
main() {
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}    OpenWrt ngrok Setup Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    # Execute all steps
    configure_uhttpd || { print_error "Failed to configure uhttpd"; exit 1; }
    get_ngrok_config || { print_error "Failed to get ngrok configuration"; exit 1; }
    install_ngrok_binary || { print_error "Failed to install ngrok binary"; exit 1; }
    create_ngrok_config || { print_error "Failed to create ngrok configuration"; exit 1; }
    create_ngrok_service || { print_error "Failed to create ngrok service"; exit 1; }
    enable_service || { print_error "Failed to enable service"; exit 1; }
    
    # Final summary
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Setup completed successfully!"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Service Management Commands:"
    echo -e "  ${CYAN}Start:${NC}   /etc/init.d/ngrok start"
    echo -e "  ${CYAN}Stop:${NC}    /etc/init.d/ngrok stop"
    echo -e "  ${CYAN}Status:${NC}  /etc/init.d/ngrok status"
    echo -e "  ${CYAN}Logs:${NC}    tail -f /var/log/ngrok.log"
    echo ""
    print_info "Configuration:"
    echo -e "  ${CYAN}HTTPS URL:${NC} https://${NGROK_URL_PREFIX}.ngrok.gigabonding.com"
    echo -e "  ${CYAN}ttyd URL:${NC} https://${NGROK_URL_PREFIX}${TTYD_URL_SUFFIX}.ngrok.gigabonding.com"
    echo -e "  ${CYAN}ttyd Upstream:${NC} http://${TTYD_UPSTREAM_IP}:${TTYD_UPSTREAM_PORT}"
    echo -e "  ${CYAN}Config File:${NC} $NGROK_CONFIG"
    echo -e "  ${CYAN}Binary:${NC} $NGROK_BIN"
    echo ""
    print_info "Viewing recent log entries..."
    if [ -f "/var/log/ngrok.log" ]; then
        echo ""
        tail -n 5 /var/log/ngrok.log 2>/dev/null || print_info "Log file is empty or not yet created"
        echo ""
    else
        print_info "Log file will be created when service starts"
        echo ""
    fi
}

# Run main function
main

