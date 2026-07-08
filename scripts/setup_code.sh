#!/bin/sh

# Setup Code Script for OpenWrt
# This script sets up the OpenWrt monitoring service to run main.py continuously

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
OPENWRT_DIR="${OPENWRT_DIR:-/root/openwrt}"
PYTHON="${PYTHON:-/usr/bin/python3}"
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

# Step 1: Install Python and pip
install_python() {
    print_step "Step 1: Installing Python and pip"
    
    print_info "Updating package list..."
    opkg update
    if [ $? -eq 0 ]; then
        print_success "Package list updated"
    else
        print_warning "Package update completed with warnings (this is usually OK)"
    fi
    
    # Check if Python 3 is already installed
    if command -v python3 > /dev/null 2>&1; then
        python_version=$(python3 --version 2>&1)
        print_success "Python 3 is already installed: $python_version"
        PYTHON=$(command -v python3)
    else
        print_info "Installing Python 3..."
        opkg install python3
        if [ $? -eq 0 ]; then
            print_success "Python 3 installed successfully"
            PYTHON=$(command -v python3)
        else
            print_error "Failed to install Python 3"
            exit 1
        fi
    fi
    
    # Check if pip is already installed
    if command -v pip3 > /dev/null 2>&1; then
        pip_version=$(pip3 --version 2>&1)
        print_success "pip is already installed: $pip_version"
    else
        print_info "Installing pip..."
        opkg install python3-pip
        if [ $? -eq 0 ]; then
            print_success "pip installed successfully"
        else
            print_error "Failed to install pip"
            exit 1
        fi
    fi
    
    # Verify installation
    python3_path=$(command -v python3)
    pip3_path=$(command -v pip3)
    print_info "Python 3 location: $python3_path"
    print_info "pip3 location: $pip3_path"
    
    # Update PYTHON variable if it was found
    if [ -n "$python3_path" ]; then
        PYTHON="$python3_path"
    fi
    
    # Verify Python version
    print_info "Checking Python version..."
    python_version=$($PYTHON --version 2>&1)
    print_success "Python version: $python_version"
    
    return 0
}

# Step 2: Install Python dependencies
install_dependencies() {
    print_step "Step 2: Installing Python Dependencies"
    
    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # requirements.txt should be in the parent directory of scripts/
    REQUIREMENTS_FILE="$SCRIPT_DIR/../requirements.txt"
    
    if [ ! -f "$REQUIREMENTS_FILE" ]; then
        print_warning "requirements.txt not found at $REQUIREMENTS_FILE"
        # Try in OPENWRT_DIR (where main.py is)
        if [ -f "$OPENWRT_DIR/requirements.txt" ]; then
            REQUIREMENTS_FILE="$OPENWRT_DIR/requirements.txt"
            print_info "Found requirements.txt at: $REQUIREMENTS_FILE"
        else
            print_error "requirements.txt not found. Please ensure it exists."
            print_info "Searched locations:"
            print_info "  - $SCRIPT_DIR/../requirements.txt"
            print_info "  - $OPENWRT_DIR/requirements.txt"
            exit 1
        fi
    fi
    
    print_info "Installing packages from requirements.txt..."
    print_info "Using --break-system-packages flag for global installation"
    
    pip3 install --break-system-packages -r "$REQUIREMENTS_FILE"
    if [ $? -eq 0 ]; then
        print_success "All dependencies installed successfully"
    else
        print_error "Failed to install some dependencies"
        exit 1
    fi
    
    # Verify installed packages
    print_info "Verifying installed packages..."
    while IFS= read -r package || [ -n "$package" ]; do
        # Skip empty lines and comments
        package=$(echo "$package" | sed 's/#.*//' | xargs)
        if [ -z "$package" ]; then
            continue
        fi
        
        # Extract package name (remove version specifiers)
        package_name=$(echo "$package" | sed 's/[>=<].*//' | xargs)
        
        if python3 -c "import $package_name" 2>/dev/null; then
            print_success "✓ $package_name is installed"
        else
            print_warning "✗ $package_name may not be installed correctly"
        fi
    done < "$REQUIREMENTS_FILE"
    
    return 0
}

# Step 3: Verify main.py exists
verify_main_py() {
    print_step "Step 3: Verifying main.py"
    
    if [ ! -f "$OPENWRT_DIR/main.py" ]; then
        print_error "main.py not found at $OPENWRT_DIR/main.py"
        print_info "Please ensure main.py is located at $OPENWRT_DIR/main.py"
        exit 1
    fi
    
    print_success "main.py found at $OPENWRT_DIR/main.py"
    
    # Check if main.py is executable (optional)
    if [ -x "$OPENWRT_DIR/main.py" ]; then
        print_info "main.py is executable"
    else
        print_info "main.py is not executable (this is OK)"
    fi
    
    return 0
}

# Step 4: Create OpenWrt directory if needed
create_directory() {
    print_step "Step 4: Creating Required Directories"
    
    if [ ! -d "$OPENWRT_DIR" ]; then
        print_info "Creating directory: $OPENWRT_DIR"
        mkdir -p "$OPENWRT_DIR"
        if [ $? -eq 0 ]; then
            print_success "Directory created: $OPENWRT_DIR"
        else
            print_error "Failed to create directory: $OPENWRT_DIR"
            exit 1
        fi
    else
        print_success "Directory already exists: $OPENWRT_DIR"
    fi
    
    return 0
}

# Step 5: Create run_main.sh wrapper script
create_run_main_script() {
    print_step "Step 5: Creating run_main.sh Wrapper Script"
    
    local run_main_path="$OPENWRT_DIR/run_main.sh"
    
    print_info "Creating run_main.sh at $run_main_path..."
    
    # Calculate SCRIPT path relative to run_main.sh location
    # Since run_main.sh will be at /root/openwrt/run_main.sh
    # and main.py will be at /root/openwrt/main.py (same directory)
    local script_path="$OPENWRT_DIR/main.py"
    
    cat > "$run_main_path" << EOF
#!/bin/sh

# Wrapper to run main.py continuously
#
# procd starts services with HOME=/ by default. Without the export
# below, the agent's settings.py would resolve ~/.openwrt to
# /.openwrt/ instead of /root/.openwrt/, miss the config.json the
# operator wrote, and report "Device not provisioned" in a restart
# loop. Force HOME=/root here so the running service sees the same
# files an interactive root shell would.
export HOME=/root

PYTHON="$PYTHON"

SCRIPT_DIR="\$(dirname "\$0")"

# Compiled dist ships one bytecode subdir per supported Python minor
# (py310, py311, py312). Pick the one that matches the router's
# installed python3 at each boot — so an in-place opkg upgrade to a
# newer minor doesn't strand the agent on incompatible .pyc files.
#
# Source checkout (dev machines): no pyXY subdir exists, run main.py
# directly from SCRIPT_DIR.
PYVER=\$(\$PYTHON -c 'import sys;print(f"py{sys.version_info.major}{sys.version_info.minor}")' 2>/dev/null)
if [ -n "\$PYVER" ] && [ -d "\$SCRIPT_DIR/\$PYVER" ]; then
    CODE_DIR="\$SCRIPT_DIR/\$PYVER"
    ENTRY="main.pyc"
    # PYTHONPATH so settings.py + local_settings.py at repo root are
    # importable while working dir is the bytecode subdir. Import
    # resolution: bytecode subdir first (main, utils.*), repo root
    # second (settings, local_settings). No name conflicts because
    # nothing in the bytecode subdir shadows settings.
    export PYTHONPATH="\$SCRIPT_DIR:\$PYTHONPATH"
else
    CODE_DIR="\$SCRIPT_DIR"
    ENTRY="main.py"
fi

LOG="$LOG_FILE"

touch "\$LOG"
chmod 644 "\$LOG"

echo "Starting OpenWrt Python service..." >> "\$LOG"
echo "Script location: \$SCRIPT_DIR" >> "\$LOG"
echo "Code dir: \$CODE_DIR entry=\$ENTRY" >> "\$LOG"

while true; do
    echo "\$(date -u) - Running \$ENTRY" >> "\$LOG"
    (cd "\$CODE_DIR" && \$PYTHON "\$ENTRY") >> "\$LOG" 2>&1
    echo "\$(date -u) - \$ENTRY stopped. Restarting in 10s..." >> "\$LOG"
    sleep 10
done
EOF
    
    if [ $? -eq 0 ]; then
        print_success "run_main.sh created successfully"
    else
        print_error "Failed to create run_main.sh"
        exit 1
    fi
    
    print_info "Making run_main.sh executable..."
    chmod +x "$run_main_path"
    if [ $? -eq 0 ]; then
        print_success "run_main.sh is now executable"
    else
        print_error "Failed to make run_main.sh executable"
        exit 1
    fi
    
    # Display the script path for verification
    print_info "Script will use:"
    echo -e "  ${CYAN}Python:${NC} $PYTHON"
    echo -e "  ${CYAN}Main Script:${NC} $script_path"
    echo -e "  ${CYAN}Log File:${NC} $LOG_FILE"
    
    return 0
}

# Step 6: Create init script
create_init_script() {
    print_step "Step 6: Creating OpenWrt Init Script"
    
    local init_script="/etc/init.d/openwrt-main"
    local run_main_path="$OPENWRT_DIR/run_main.sh"
    
    print_info "Creating init script at $init_script..."
    
    cat > "$init_script" << EOF
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

EXTRA_COMMANDS="rename"
EXTRA_HELP="        rename <name>   Set the human-friendly site name shown in the dashboard
                        (use \"\" to clear it; restart not required)"

start_service() {
    procd_open_instance
    procd_set_param command $run_main_path
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    # Kill only our wrapper and its child python3 process (not all python3 on the system)
    local wrapper_pids=\$(pgrep -f "run_main.sh" 2>/dev/null)
    if [ -n "\$wrapper_pids" ]; then
        for pid in \$wrapper_pids; do
            # Kill child processes (python3 main.py) of the wrapper
            pkill -P "\$pid" 2>/dev/null || true
            kill "\$pid" 2>/dev/null || true
        done
    fi
}

rename() {
    # Wire \`/etc/init.d/openwrt-main rename "<name>"\` to the Python
    # helper. Writes ~/.openwrt/config.json site_name; the live agent
    # publishes the new value on its next telemetry tick (~30 s), and
    # the backend ingestor mirrors it to the TB device label.
    if [ -z "\$1" ] && [ "\$#" -eq 0 ]; then
        echo "Usage: /etc/init.d/openwrt-main rename \"<new site name>\"" >&2
        echo "       /etc/init.d/openwrt-main rename \"\"   (clears it)" >&2
        return 1
    fi
    $PYTHON "$OPENWRT_DIR/scripts/rename_site.py" "\$1"
}
EOF
    
    if [ $? -eq 0 ]; then
        print_success "Init script created successfully"
    else
        print_error "Failed to create init script"
        exit 1
    fi
    
    print_info "Making init script executable..."
    chmod +x "$init_script"
    if [ $? -eq 0 ]; then
        print_success "Init script is now executable"
    else
        print_error "Failed to make init script executable"
        exit 1
    fi
    
    return 0
}

# Step 7: Enable and start the service
enable_service() {
    print_step "Step 7: Enabling and Starting Service"
    
    local init_script="/etc/init.d/openwrt-main"
    
    # Stop service if already running
    if /etc/init.d/openwrt-main status > /dev/null 2>&1; then
        print_info "Service is already running, stopping it first..."
        /etc/init.d/openwrt-main stop
        sleep 2
    fi
    
    print_info "Enabling openwrt-main service to start at boot..."
    /etc/init.d/openwrt-main enable
    if [ $? -eq 0 ]; then
        print_success "Service enabled for boot"
    else
        print_error "Failed to enable service"
        return 1
    fi
    
    print_info "Starting openwrt-main service..."
    /etc/init.d/openwrt-main start
    sleep 3
    
    # Check if service is running
    if /etc/init.d/openwrt-main status > /dev/null 2>&1; then
        print_success "Service started successfully"
    else
        print_warning "Service may not be running yet. Check logs: tail -f $LOG_FILE"
    fi
    
    # Verify processes
    print_info "Verifying processes..."
    run_main_count=$(ps | grep "run_main.sh" | grep -cv grep)
    main_py_count=$(ps | grep "main.py" | grep -cv grep)
    
    if [ "$run_main_count" -gt "0" ]; then
        print_success "Found $run_main_count run_main.sh process(es)"
    else
        print_warning "No run_main.sh processes found"
    fi
    
    if [ "$main_py_count" -gt "0" ]; then
        print_success "Found $main_py_count main.py process(es)"
    else
        print_warning "No main.py processes found (may start shortly)"
    fi
    
    return 0
}

# Main execution
main() {
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}    OpenWrt Code Setup Script${NC}"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_root
    
    # Execute all steps
    install_python || { print_error "Python installation failed"; exit 1; }
    install_dependencies || { print_error "Dependency installation failed"; exit 1; }
    verify_main_py || { print_error "main.py verification failed"; exit 1; }
    create_directory || { print_error "Directory creation failed"; exit 1; }
    create_run_main_script || { print_error "Failed to create run_main.sh"; exit 1; }
    create_init_script || { print_error "Failed to create init script"; exit 1; }
    enable_service || { print_error "Failed to enable service"; exit 1; }
    
    # Final summary
    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Setup completed successfully!"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Service Management Commands:"
    echo -e "  ${CYAN}Start:${NC}   /etc/init.d/openwrt-main start"
    echo -e "  ${CYAN}Stop:${NC}    /etc/init.d/openwrt-main stop"
    echo -e "  ${CYAN}Status:${NC}  /etc/init.d/openwrt-main status"
    echo -e "  ${CYAN}Restart:${NC} /etc/init.d/openwrt-main restart"
    echo -e "  ${CYAN}Rename:${NC}  /etc/init.d/openwrt-main rename \"<site name>\""
    echo -e "  ${CYAN}Logs:${NC}    tail -f $LOG_FILE"
    echo ""
    print_info "File Locations:"
    echo -e "  ${CYAN}Main Script:${NC} $OPENWRT_DIR/main.py"
    echo -e "  ${CYAN}Wrapper:${NC}     $OPENWRT_DIR/run_main.sh"
    echo -e "  ${CYAN}Init Script:${NC}  /etc/init.d/openwrt-main"
    echo -e "  ${CYAN}Log File:${NC}     $LOG_FILE"
    echo ""
    print_info "Viewing recent log entries..."
    if [ -f "$LOG_FILE" ]; then
        echo ""
        tail -n 5 "$LOG_FILE" 2>/dev/null || print_info "Log file is empty or not yet created"
        echo ""
    else
        print_info "Log file will be created when service starts"
        echo ""
    fi
}

# Run main function
main

