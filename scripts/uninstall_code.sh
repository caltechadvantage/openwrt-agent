#!/bin/sh

# Uninstall Code Script for OpenWrt
# This script removes the OpenWrt monitoring service and cleans up related files

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
OPENWRT_DIR="${OPENWRT_DIR:-/root/openwrt}"
LOG_FILE="/var/log/openwrt-main.log"

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
    print_step "Step 1: Stopping OpenWrt Main Service"
    
    if [ ! -f "/etc/init.d/openwrt-main" ]; then
        print_warning "OpenWrt main service not found (may already be removed)"
        return 0
    fi
    
    print_info "Checking service status..."
    if /etc/init.d/openwrt-main status > /dev/null 2>&1; then
        print_info "Service is running, stopping it..."
        /etc/init.d/openwrt-main stop
        sleep 3
        if ! /etc/init.d/openwrt-main status > /dev/null 2>&1; then
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
    print_step "Step 2: Disabling OpenWrt Main Service"
    
    if [ ! -f "/etc/init.d/openwrt-main" ]; then
        print_warning "OpenWrt main service not found (may already be removed)"
        return 0
    fi
    
    print_info "Disabling service from boot..."
    /etc/init.d/openwrt-main disable
    if [ $? -eq 0 ]; then
        print_success "Service disabled successfully"
    else
        print_warning "Service may already be disabled"
    fi
    
    return 0
}

# Step 3: Kill any remaining processes
kill_processes() {
    print_step "Step 3: Cleaning Up Processes"
    
    print_info "Checking for running processes..."
    
    # Check for run_main.sh processes
    run_main_count=$(ps | grep -c "[r]un_main.sh" || echo "0")
    if [ "$run_main_count" -gt "0" ]; then
        print_warning "Found $run_main_count run_main.sh process(es)"
        print_info "Killing run_main.sh processes..."
        pkill -f "run_main.sh" 2>/dev/null
        sleep 2
        
        # Force kill if still running
        remaining=$(ps | grep -c "[r]un_main.sh" || echo "0")
        if [ "$remaining" -gt "0" ]; then
            print_warning "Some processes still running, force killing..."
            pkill -9 -f "run_main.sh" 2>/dev/null
            sleep 1
        fi
    fi
    
    # Check for main.py processes
    main_py_count=$(ps | grep -c "[m]ain.py" || echo "0")
    if [ "$main_py_count" -gt "0" ]; then
        print_warning "Found $main_py_count main.py process(es)"
        print_info "Killing main.py processes..."
        pkill -f "main.py" 2>/dev/null
        sleep 2
        
        # Force kill if still running
        remaining=$(ps | grep -c "[m]ain.py" || echo "0")
        if [ "$remaining" -gt "0" ]; then
            print_warning "Some processes still running, force killing..."
            pkill -9 -f "main.py" 2>/dev/null
            sleep 1
        fi
    fi
    
    # Verify cleanup
    final_run_main=$(ps | grep -c "[r]un_main.sh" || echo "0")
    final_main_py=$(ps | grep -c "[m]ain.py" || echo "0")
    
    if [ "$final_run_main" -eq "0" ] && [ "$final_main_py" -eq "0" ]; then
        print_success "All processes terminated"
    else
        if [ "$final_run_main" -gt "0" ]; then
            print_warning "$final_run_main run_main.sh process(es) may still be running"
        fi
        if [ "$final_main_py" -gt "0" ]; then
            print_warning "$final_main_py main.py process(es) may still be running"
        fi
    fi
    
    return 0
}

# Step 4: Remove the init script
remove_init_script() {
    print_step "Step 4: Removing Init Script"
    
    if [ ! -f "/etc/init.d/openwrt-main" ]; then
        print_warning "Init script not found at /etc/init.d/openwrt-main"
        return 0
    fi
    
    print_info "Removing /etc/init.d/openwrt-main..."
    rm -f /etc/init.d/openwrt-main
    if [ $? -eq 0 ]; then
        print_success "Init script removed successfully"
    else
        print_error "Failed to remove init script"
        return 1
    fi
    
    # Check for symlinks and remove them
    print_info "Checking for service symlinks..."
    symlinks_found=0
    
    for link in /etc/rc.d/S*openwrt-main /etc/rc.d/K*openwrt-main; do
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

# Step 5: Optional cleanup - remove run_main.sh and logs
cleanup_optional() {
    print_step "Step 5: Optional Cleanup"
    
    local run_main_path="$OPENWRT_DIR/run_main.sh"
    
    read -p "Do you want to remove run_main.sh? (y/N): " remove_wrapper
    if [ "$remove_wrapper" = "y" ] || [ "$remove_wrapper" = "Y" ]; then
        if [ -f "$run_main_path" ]; then
            print_info "Removing run_main.sh..."
            rm -f "$run_main_path"
            if [ $? -eq 0 ]; then
                print_success "Removed: $run_main_path"
            else
                print_warning "Failed to remove run_main.sh"
            fi
        else
            print_info "run_main.sh not found"
        fi
    else
        print_info "Keeping run_main.sh"
    fi
    
    read -p "Do you want to remove log file? (y/N): " remove_logs
    if [ "$remove_logs" = "y" ] || [ "$remove_logs" = "Y" ]; then
        if [ -f "$LOG_FILE" ]; then
            print_info "Removing log file..."
            rm -f "$LOG_FILE"
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
    echo -e "${RED}    OpenWrt Code Uninstall Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    # Confirm uninstallation
    print_warning "This will remove the OpenWrt monitoring service from your system."
    print_info "The service will be stopped and removed, but your code files will be preserved unless you choose to remove them."
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "Uninstallation cancelled by user"
        exit 0
    fi
    
    # Execute all steps
    stop_service
    disable_service
    kill_processes
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
    if [ ! -f "/etc/init.d/openwrt-main" ]; then
        print_success "✓ Service file removed"
    else
        print_error "✗ Service file still exists"
    fi
    
    # Check if processes are running
    run_main_count=$(ps | grep -c "[r]un_main.sh" || echo "0")
    main_py_count=$(ps | grep -c "[m]ain.py" || echo "0")
    
    if [ "$run_main_count" -eq "0" ] && [ "$main_py_count" -eq "0" ]; then
        print_success "✓ No processes running"
    else
        if [ "$run_main_count" -gt "0" ]; then
            print_warning "✗ $run_main_count run_main.sh process(es) still running"
        fi
        if [ "$main_py_count" -gt "0" ]; then
            print_warning "✗ $main_py_count main.py process(es) still running"
        fi
    fi
    
    echo ""
}

# Run main function
main

