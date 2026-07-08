#!/bin/sh

# Uninstall ngrok Script for OpenWrt
# This script removes ngrok binary and configuration file installed by setup_ngrok.sh

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

# Step 1: Kill any running ngrok processes
kill_ngrok_processes() {
    print_step "Step 1: Stopping ngrok Processes"
    
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

# Step 2: Remove ngrok binary
remove_ngrok_binary() {
    print_step "Step 2: Removing ngrok Binary"
    
    if [ ! -f "$NGROK_BIN" ]; then
        print_warning "ngrok binary not found at $NGROK_BIN"
        return 0
    fi
    
    print_info "Removing ngrok binary from $NGROK_BIN..."
    rm -f "$NGROK_BIN"
    if [ $? -eq 0 ]; then
        print_success "ngrok binary removed successfully"
    else
        print_error "Failed to remove ngrok binary"
        return 1
    fi
    
    return 0
}

# Step 3: Remove ngrok configuration file
remove_ngrok_config() {
    print_step "Step 3: Removing ngrok Configuration File"
    
    if [ ! -f "$NGROK_CONFIG" ]; then
        print_warning "ngrok configuration file not found at $NGROK_CONFIG"
        return 0
    fi
    
    print_info "Removing ngrok configuration file from $NGROK_CONFIG..."
    rm -f "$NGROK_CONFIG"
    if [ $? -eq 0 ]; then
        print_success "ngrok configuration file removed successfully"
    else
        print_error "Failed to remove ngrok configuration file"
        return 1
    fi
    
    # Check if config directory is empty and remove if empty
    CONFIG_DIR="$(dirname "$NGROK_CONFIG")"
    if [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
        print_info "Config directory is empty, removing it..."
        rmdir "$CONFIG_DIR" 2>/dev/null
        if [ $? -eq 0 ]; then
            print_success "Config directory removed"
        else
            print_info "Config directory could not be removed (may not be empty)"
        fi
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
    print_warning "This will remove ngrok binary and configuration file from your system."
    print_info "Note: This will NOT remove the ngrok service (if installed separately)."
    print_info "Note: This will NOT modify uhttpd configuration."
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "Uninstallation cancelled by user"
        exit 0
    fi
    
    # Execute all steps
    kill_ngrok_processes
    remove_ngrok_binary || { print_error "Failed to remove ngrok binary"; exit 1; }
    remove_ngrok_config || { print_error "Failed to remove ngrok configuration"; exit 1; }
    
    # Final summary
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Uninstallation completed successfully!"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Verification:"
    
    # Check if binary exists
    if [ ! -f "$NGROK_BIN" ]; then
        print_success "✓ ngrok binary removed"
    else
        print_error "✗ ngrok binary still exists"
    fi
    
    # Check if config file exists
    if [ ! -f "$NGROK_CONFIG" ]; then
        print_success "✓ ngrok configuration file removed"
    else
        print_error "✗ ngrok configuration file still exists"
    fi
    
    # Check if ngrok processes are running
    ngrok_count=$(ps | grep -c "[n]grok" || echo "0")
    if [ "$ngrok_count" -eq "0" ]; then
        print_success "✓ No ngrok processes running"
    else
        print_warning "✗ $ngrok_count ngrok process(es) still running"
    fi
    
    echo ""
    print_info "Note: If you installed the ngrok service separately, run:"
    echo -e "  ${CYAN}scripts/uninstall_ngrok_service.sh${NC}"
    echo ""
}

# Run main function
main

