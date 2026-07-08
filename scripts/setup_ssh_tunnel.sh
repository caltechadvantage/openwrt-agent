#!/bin/sh

# Setup SSH Tunnel Script for OpenWrt
# This script configures LuCI visibility and sets up a persistent SSH reverse tunnel

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
LOCAL_PORT="${LOCAL_PORT:-80}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PORT="${REMOTE_PORT:-}"
KEY_NAME="${KEY_NAME:-openwrt_ed25519}"
SSH_KEY="/root/.ssh/${KEY_NAME}"

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

# Step 1: Configure LuCI visibility
configure_luci() {
    print_step "Step 1: Configuring LuCI Visibility"
    
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
    
    print_info "Disabling HTTPS redirect to allow HTTP access on port ${LOCAL_PORT}..."
    uci set uhttpd.main.redirect_https='0'
    if [ $? -eq 0 ]; then
        print_success "HTTPS redirect disabled"
    else
        print_warning "Failed to disable HTTPS redirect (may already be disabled)"
    fi
    
    print_info "Disabling RFC1918 filtering to allow all connections..."
    uci set uhttpd.main.rfc1918_filter='0'
    if [ $? -eq 0 ]; then
        print_success "RFC1918 filtering disabled"
    else
        print_warning "Failed to disable RFC1918 filtering (may already be disabled)"
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
    
    return 0
}

# Step 2: Generate SSH key
generate_ssh_key() {
    print_step "Step 2: Generating SSH Key"
    
    # Create .ssh directory if it doesn't exist
    if [ ! -d "/root/.ssh" ]; then
        print_info "Creating /root/.ssh directory..."
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        print_success "Directory created"
    fi
    
    # Check if key already exists
    if [ -f "${SSH_KEY}" ]; then
        print_warning "SSH key ${SSH_KEY} already exists"
        read -p "Do you want to overwrite it? (y/N): " overwrite
        if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
            print_info "Using existing SSH key"
            return 0
        fi
        rm -f "${SSH_KEY}" "${SSH_KEY}.pub"
    fi
    
    print_info "Generating new SSH key pair..."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -q
    if [ $? -eq 0 ]; then
        print_success "SSH key generated successfully"
    else
        print_error "Failed to generate SSH key"
        return 1
    fi
    
    # Display public key
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "IMPORTANT: Copy the public key below and add it to your VPS authorized_keys"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "Press Enter after you have added the public key to your VPS authorized_keys..."
    
    return 0
}

# Step 3: Install autossh
install_autossh() {
    print_step "Step 3: Installing autossh"
    
    print_info "Updating package list..."
    opkg update
    if [ $? -eq 0 ]; then
        print_success "Package list updated"
    else
        print_warning "Package update completed with warnings (this is usually OK)"
    fi
    
    print_info "Installing autossh..."
    opkg install autossh
    if [ $? -eq 0 ]; then
        print_success "autossh installed successfully"
    else
        print_error "Failed to install autossh"
        return 1
    fi
    
    return 0
}

# Step 4: Get user input for remote configuration
get_remote_config() {
    print_step "Step 4: Remote Server Configuration"
    
    if [ -z "$REMOTE_HOST" ]; then
        read -p "Enter REMOTE_HOST (VPS IP or hostname): " REMOTE_HOST
    fi
    
    if [ -z "$REMOTE_PORT" ]; then
        read -p "Enter REMOTE_PORT (default: 9080): " REMOTE_PORT
        REMOTE_PORT="${REMOTE_PORT:-9080}"
    fi
    
    print_info "Configuration summary:"
    echo -e "  ${CYAN}Remote Host:${NC} ${REMOTE_HOST}"
    echo -e "  ${CYAN}Remote Port:${NC} ${REMOTE_PORT}"
    echo -e "  ${CYAN}Local Port:${NC} ${LOCAL_PORT}"
    echo -e "  ${CYAN}SSH Key:${NC} ${SSH_KEY}"
    
    read -p "Continue with this configuration? (Y/n): " confirm
    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        print_error "Configuration cancelled by user"
        exit 1
    fi
}

# Step 5: Create SSH tunnel init script
create_tunnel_script() {
    print_step "Step 5: Creating SSH Tunnel Init Script"
    
    print_info "Creating /etc/init.d/ssh-tunnel..."
    
    cat > /etc/init.d/ssh-tunnel << EOF
#!/bin/sh /etc/rc.common

# /etc/init.d/ssh-tunnel
# Persistent reverse SSH tunnel OpenWrt -> Bondix server

START=99
STOP=10
USE_PROCD=1

REMOTE_USER="root"
REMOTE_HOST="${REMOTE_HOST}"
REMOTE_PORT="${REMOTE_PORT}"
LOCAL_PORT="${LOCAL_PORT}"
SSH_KEY="${SSH_KEY}"
LOGFILE="/var/log/ssh-tunnel.log"

start_service() {
    echo "Starting persistent SSH reverse tunnel..." | tee -a "\$LOGFILE"
    procd_open_instance
    procd_set_param command autossh -M 0 -N \\
        -R \${REMOTE_PORT}:localhost:\${LOCAL_PORT} \\
        -i \${SSH_KEY} \\
        -o StrictHostKeyChecking=no \\
        -o ServerAliveInterval=30 \\
        -o ServerAliveCountMax=3 \\
        -o ExitOnForwardFailure=yes \\
        \${REMOTE_USER}@\${REMOTE_HOST} >> "\$LOGFILE" 2>&1
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    echo "Stopping SSH reverse tunnel..." | tee -a "\$LOGFILE"
    for pid in \$(ps | grep "autossh.*-R \${REMOTE_PORT}:localhost:\${LOCAL_PORT}" | awk '{print \$1}'); do
        kill \$pid
    done
}
EOF
    
    if [ $? -eq 0 ]; then
        print_success "Init script created successfully"
    else
        print_error "Failed to create init script"
        return 1
    fi
    
    print_info "Making init script executable..."
    chmod +x /etc/init.d/ssh-tunnel
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
    print_step "Step 6: Enabling and Starting SSH Tunnel Service"
    
    print_info "Enabling ssh-tunnel service to start at boot..."
    /etc/init.d/ssh-tunnel enable
    if [ $? -eq 0 ]; then
        print_success "Service enabled for boot"
    else
        print_error "Failed to enable service"
        return 1
    fi
    
    print_info "Starting ssh-tunnel service..."
    /etc/init.d/ssh-tunnel start
    sleep 2
    
    # Check if service is running
    if /etc/init.d/ssh-tunnel status > /dev/null 2>&1; then
        print_success "SSH tunnel service started successfully"
    else
        print_warning "Service may not be running yet. Check logs: tail -f /var/log/ssh-tunnel.log"
    fi
    
    return 0
}

# Main execution
main() {
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}    OpenWrt SSH Tunnel Setup Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    # Execute all steps
    configure_luci || { print_error "Failed to configure LuCI"; exit 1; }
    generate_ssh_key || { print_error "Failed to generate SSH key"; exit 1; }
    install_autossh || { print_error "Failed to install autossh"; exit 1; }
    get_remote_config
    create_tunnel_script || { print_error "Failed to create tunnel script"; exit 1; }
    enable_service || { print_error "Failed to enable service"; exit 1; }
    
    # Final summary
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Setup completed successfully!"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Service Management Commands:"
    echo -e "  ${CYAN}Start:${NC}   /etc/init.d/ssh-tunnel start"
    echo -e "  ${CYAN}Stop:${NC}    /etc/init.d/ssh-tunnel stop"
    echo -e "  ${CYAN}Status:${NC}  /etc/init.d/ssh-tunnel status"
    echo -e "  ${CYAN}Logs:${NC}    tail -f /var/log/ssh-tunnel.log"
    echo ""
    print_info "Tunnel Configuration:"
    echo -e "  ${CYAN}Local:${NC}   localhost:${LOCAL_PORT}"
    echo -e "  ${CYAN}Remote:${NC}  ${REMOTE_HOST}:${REMOTE_PORT}"
    echo ""
}

# Run main function
main

