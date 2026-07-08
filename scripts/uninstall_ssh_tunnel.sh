#!/bin/sh

# Uninstall SSH Tunnel Script for OpenWrt
# This script removes the SSH tunnel service and cleans up related files

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# Step 1: Stop the service
stop_service() {
    print_step "Step 1: Stopping SSH Tunnel Service"
    
    if [ ! -f "/etc/init.d/ssh-tunnel" ]; then
        print_warning "SSH tunnel service not found (may already be removed)"
        return 0
    fi
    
    print_info "Checking service status..."
    if /etc/init.d/ssh-tunnel status > /dev/null 2>&1; then
        print_info "Service is running, stopping it..."
        /etc/init.d/ssh-tunnel stop
        sleep 2
        if ! /etc/init.d/ssh-tunnel status > /dev/null 2>&1; then
            print_success "Service stopped successfully"
        else
            print_warning "Service may still be running"
        fi
    else
        print_info "Service is not running"
    fi
    
    return 0
}

# Step 2: Disable the service
disable_service() {
    print_step "Step 2: Disabling SSH Tunnel Service"
    
    if [ ! -f "/etc/init.d/ssh-tunnel" ]; then
        print_warning "SSH tunnel service not found (may already be removed)"
        return 0
    fi
    
    print_info "Disabling service from boot..."
    /etc/init.d/ssh-tunnel disable
    if [ $? -eq 0 ]; then
        print_success "Service disabled successfully"
    else
        print_warning "Service may already be disabled"
    fi
    
    return 0
}

# Step 3: Kill any remaining autossh processes
kill_autossh() {
    print_step "Step 3: Cleaning Up autossh Processes"
    
    print_info "Checking for running autossh processes..."
    autossh_count=$(ps | grep -c "autossh.*-R" || echo "0")
    
    if [ "$autossh_count" -gt "0" ]; then
        print_warning "Found $autossh_count autossh process(es)"
        print_info "Killing all autossh processes..."
        
        # Kill by process name
        killall autossh 2>/dev/null
        sleep 1
        
        # Double check and force kill if needed
        remaining=$(ps | grep -c "autossh.*-R" || echo "0")
        if [ "$remaining" -gt "0" ]; then
            print_warning "Some processes still running, force killing..."
            killall -9 autossh 2>/dev/null
            sleep 1
        fi
        
        # Verify cleanup
        final_count=$(ps | grep -c "autossh.*-R" || echo "0")
        if [ "$final_count" -eq "0" ]; then
            print_success "All autossh processes terminated"
        else
            print_warning "Some autossh processes may still be running"
        fi
    else
        print_info "No autossh processes found"
        print_success "No cleanup needed"
    fi
    
    return 0
}

# Step 4: Remove the init script
remove_init_script() {
    print_step "Step 4: Removing SSH Tunnel Init Script"
    
    if [ ! -f "/etc/init.d/ssh-tunnel" ]; then
        print_warning "Init script not found at /etc/init.d/ssh-tunnel"
        return 0
    fi
    
    print_info "Removing /etc/init.d/ssh-tunnel..."
    rm -f /etc/init.d/ssh-tunnel
    if [ $? -eq 0 ]; then
        print_success "Init script removed successfully"
    else
        print_error "Failed to remove init script"
        return 1
    fi
    
    # Check for symlinks and remove them
    print_info "Checking for service symlinks..."
    if [ -L "/etc/rc.d/S*ssh-tunnel" ] || [ -L "/etc/rc.d/K*ssh-tunnel" ]; then
        print_info "Removing service symlinks..."
        rm -f /etc/rc.d/S*ssh-tunnel 2>/dev/null
        rm -f /etc/rc.d/K*ssh-tunnel 2>/dev/null
        print_success "Symlinks removed"
    else
        print_info "No symlinks found"
    fi
    
    return 0
}

# Step 5: Optional cleanup - remove SSH key and logs
cleanup_optional() {
    print_step "Step 5: Optional Cleanup"
    
    read -p "Do you want to remove SSH keys? (y/N): " remove_keys
    if [ "$remove_keys" = "y" ] || [ "$remove_keys" = "Y" ]; then
        print_info "Removing SSH keys..."
        
        # Find and remove common key names
        key_patterns="/root/.ssh/openwrt_ed25519 /root/.ssh/openwrt_ed25519.pub"
        removed=0
        
        for key in $key_patterns; do
            if [ -f "$key" ]; then
                rm -f "$key"
                if [ $? -eq 0 ]; then
                    print_success "Removed: $key"
                    removed=1
                fi
            fi
        done
        
        if [ $removed -eq 0 ]; then
            print_info "No SSH keys found to remove"
        fi
    else
        print_info "Keeping SSH keys"
    fi
    
    read -p "Do you want to remove log file? (y/N): " remove_logs
    if [ "$remove_logs" = "y" ] || [ "$remove_logs" = "Y" ]; then
        if [ -f "/var/log/ssh-tunnel.log" ]; then
            print_info "Removing log file..."
            rm -f /var/log/ssh-tunnel.log
            if [ $? -eq 0 ]; then
                print_success "Log file removed"
            else
                print_warning "Failed to remove log file"
            fi
        else
            print_info "Log file not found"
        fi
    else
        print_info "Keeping log file"
    fi
    
    return 0
}

# Main execution
main() {
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${RED}    OpenWrt SSH Tunnel Uninstall Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    # Confirm uninstallation
    print_warning "This will remove the SSH tunnel service from your system."
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "Uninstallation cancelled by user"
        exit 0
    fi
    
    # Execute all steps
    stop_service
    disable_service
    kill_autossh
    remove_init_script || { print_error "Failed to remove init script"; exit 1; }
    cleanup_optional
    
    # Final summary
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Uninstallation completed successfully!"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Verification:"
    
    # Check if service file exists
    if [ ! -f "/etc/init.d/ssh-tunnel" ]; then
        print_success "✓ Service file removed"
    else
        print_error "✗ Service file still exists"
    fi
    
    # Check if autossh processes are running
    autossh_count=$(ps | grep -c "autossh.*-R" || echo "0")
    if [ "$autossh_count" -eq "0" ]; then
        print_success "✓ No autossh processes running"
    else
        print_warning "✗ $autossh_count autossh process(es) still running"
    fi
    
    echo ""
}

# Run main function
main

