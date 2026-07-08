#!/bin/sh

# Uninstall ngrok Script for OpenWrt
# This script removes the ngrok service and cleans up related files

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
NGROK_LOG="/var/log/ngrok.log"

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
    print_step "Step 1: Stopping ngrok Service"
    
    if [ ! -f "/etc/init.d/ngrok" ]; then
        print_warning "ngrok service not found (may already be removed)"
        return 0
    fi
    
    print_info "Checking service status..."
    if /etc/init.d/ngrok status > /dev/null 2>&1; then
        print_info "Service is running, stopping it..."
        /etc/init.d/ngrok stop
        sleep 2
        if ! /etc/init.d/ngrok status > /dev/null 2>&1; then
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
    print_step "Step 2: Disabling ngrok Service"
    
    if [ ! -f "/etc/init.d/ngrok" ]; then
        print_warning "ngrok service not found (may already be removed)"
        return 0
    fi
    
    print_info "Disabling service from boot..."
    /etc/init.d/ngrok disable
    if [ $? -eq 0 ]; then
        print_success "Service disabled successfully"
    else
        print_warning "Service may already be disabled"
    fi
    
    return 0
}

# Step 3: Kill any remaining ngrok processes
kill_ngrok() {
    print_step "Step 3: Cleaning Up ngrok Processes"
    
    print_info "Checking for running ngrok processes..."
    ngrok_count=$(ps | grep -c "[n]grok" || echo "0")
    
    if [ "$ngrok_count" -gt "0" ]; then
        print_warning "Found $ngrok_count ngrok process(es)"
        print_info "Killing all ngrok processes..."
        
        # Kill by process name
        killall ngrok 2>/dev/null
        sleep 1
        
        # Double check and force kill if needed
        remaining=$(ps | grep -c "[n]grok" || echo "0")
        if [ "$remaining" -gt "0" ]; then
            print_warning "Some processes still running, force killing..."
            killall -9 ngrok 2>/dev/null
            sleep 1
        fi
        
        # Verify cleanup
        final_count=$(ps | grep -c "[n]grok" || echo "0")
        if [ "$final_count" -eq "0" ]; then
            print_success "All ngrok processes terminated"
        else
            print_warning "Some ngrok processes may still be running"
        fi
    else
        print_info "No ngrok processes found"
        print_success "No cleanup needed"
    fi
    
    return 0
}

# Step 4: Remove the init script
remove_init_script() {
    print_step "Step 4: Removing ngrok Init Script"
    
    if [ ! -f "/etc/init.d/ngrok" ]; then
        print_warning "Init script not found at /etc/init.d/ngrok"
        return 0
    fi
    
    print_info "Removing /etc/init.d/ngrok..."
    rm -f /etc/init.d/ngrok
    if [ $? -eq 0 ]; then
        print_success "Init script removed successfully"
    else
        print_error "Failed to remove init script"
        return 1
    fi
    
    # Check for symlinks and remove them
    print_info "Checking for service symlinks..."
    symlinks_found=0
    
    for link in /etc/rc.d/S*ngrok /etc/rc.d/K*ngrok; do
        if [ -L "$link" ]; then
            print_info "Removing symlink: $link"
            rm -f "$link"
            symlinks_found=1
        fi
    done
    
    if [ $symlinks_found -eq 1 ]; then
        print_success "Symlinks removed"
    else
        print_info "No symlinks found"
    fi
    
    return 0
}

# Step 5: Optional cleanup
cleanup_optional() {
    print_step "Step 5: Optional Cleanup"
    
    read -p "Do you want to remove ngrok binary? (y/N): " remove_binary
    if [ "$remove_binary" = "y" ] || [ "$remove_binary" = "Y" ]; then
        if [ -f "$NGROK_BIN" ]; then
            print_info "Removing ngrok binary..."
            rm -f "$NGROK_BIN"
            if [ $? -eq 0 ]; then
                print_success "ngrok binary removed"
            else
                print_warning "Failed to remove ngrok binary"
            fi
        else
            print_info "ngrok binary not found"
        fi
    else
        print_info "Keeping ngrok binary"
    fi
    
    read -p "Do you want to remove ngrok configuration file? (y/N): " remove_config
    if [ "$remove_config" = "y" ] || [ "$remove_config" = "Y" ]; then
        if [ -f "$NGROK_CONFIG" ]; then
            print_info "Removing ngrok configuration file..."
            rm -f "$NGROK_CONFIG"
            if [ $? -eq 0 ]; then
                print_success "Configuration file removed"
            else
                print_warning "Failed to remove configuration file"
            fi
            
            # Check if config directory is empty and remove if empty
            CONFIG_DIR="$(dirname "$NGROK_CONFIG")"
            if [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
                print_info "Config directory is empty, removing it..."
                rmdir "$CONFIG_DIR" 2>/dev/null
                if [ $? -eq 0 ]; then
                    print_success "Config directory removed"
                fi
            fi
        else
            print_info "Configuration file not found"
        fi
    else
        print_info "Keeping ngrok configuration file"
    fi
    
    read -p "Do you want to remove log file? (y/N): " remove_logs
    if [ "$remove_logs" = "y" ] || [ "$remove_logs" = "Y" ]; then
        if [ -f "$NGROK_LOG" ]; then
            print_info "Removing log file..."
            rm -f "$NGROK_LOG"
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
    echo -e "${RED}    OpenWrt ngrok Uninstall Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    # Confirm uninstallation
    print_warning "This will remove the ngrok service from your system."
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "Uninstallation cancelled by user"
        exit 0
    fi
    
    # Execute all steps
    stop_service
    disable_service
    kill_ngrok
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
    if [ ! -f "/etc/init.d/ngrok" ]; then
        print_success "✓ Service file removed"
    else
        print_error "✗ Service file still exists"
    fi
    
    # Check if ngrok processes are running
    ngrok_count=$(ps | grep -c "[n]grok" || echo "0")
    if [ "$ngrok_count" -eq "0" ]; then
        print_success "✓ No ngrok processes running"
    else
        print_warning "✗ $ngrok_count ngrok process(es) still running"
    fi
    
    # Check if binary exists
    if [ ! -f "$NGROK_BIN" ]; then
        print_success "✓ ngrok binary removed"
    else
        print_info "✓ ngrok binary still exists (kept as requested)"
    fi
    
    echo ""
}

# Run main function
main

