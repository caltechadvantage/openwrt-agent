# OpenWrt Monitoring Service

Monitoring for OpenWrt routers. Collects system metrics and forwards them to ThingsBoard, and sets up ngrok for remote access to the router's LuCI interface.

## Features

- **System Metrics Collection**: Collects router metrics (CPU, memory, network, etc.)
- **ThingsBoard Integration**: Sends metrics to ThingsBoard for visualization and monitoring
- **ngrok Tunneling**: Secure tunnels to reach the LuCI interface and ttyd web terminal remotely
- **Auto-restart Service**: Restarts the monitoring service if it crashes
- **Service Management**: Standard OpenWrt service management with procd

## Requirements

- OpenWrt router with SSH access
- Root access to the router
- Internet connectivity for ThingsBoard communication
- ngrok account and authtoken (for remote LuCI access)

## Installation Guide

> **Production routers are not installed from this repo.** The DTS-MobileQ
> dashboard generates a one-line installer (Register Device, copy the
> install command) that downloads the **compiled** distribution repo
> `caltechadvantage/openwrt-agent` (Python bytecode only, `.pyc` per
> interpreter version, no source) as a tarball and runs `setup.sh`
> non-interactively with the ngrok token pre-seeded. The download uses
> `uclient-fetch` + `tar`, both in the OpenWrt base system, so a stock
> BusyBox router needs no `git`. That is the supported onboarding path,
> and the one the "Check for update" button pulls from (also over a
> tarball, via `update.sh`). `openwrt-agent` is produced automatically
> from this source repo by `.github/workflows/publish-dist.yml` on every
> push to `main` (see [RELEASING.md](RELEASING.md)).
>
> The manual clone below is for **development against the source** and for
> reference (a dev box has `git`). Field units are onboarded from the
> compiled `openwrt-agent` tarball via the dashboard installer instead.

### Quick Setup (development / source install)

1. **Clone the project into router:**
   ```bash
   opkg update
   opkg install git-http
   # Source repo (this repo): for development only.
   # Field units are onboarded from the compiled openwrt-agent dist
   # via the dashboard installer instead (see the note above).
   git clone https://github.com/caltechadvantage/openwrt.git
   ```

2. **SSH into router and run setup:**
   ```bash
   ssh root@your-router-ip
   cd /root/openwrt
   chmod +x setup.sh
   ./setup.sh
   ```

3. **During setup, you'll be prompted for:**
   - Ngrok URL prefix (e.g., `hd-spokane` or `hd-main`)
   - ttyd URL suffix (e.g., `-shell`, default: `-shell`)
   - ttyd upstream IP (default: auto-detected from br-lan interface, or `172.16.16.1`)
   - ttyd upstream port (default: `7681`)

### What the Setup Scripts Do

**`setup.sh`** (Main script):
- Installs ngrok binary and configuration
- Installs Python dependencies (`requests`, `paho-mqtt`)
- Creates and starts monitoring service
- Configures uhttpd for LuCI access

**Individual scripts:**
- `scripts/setup_ngrok.sh` - Installs ngrok binary and creates config file
- `scripts/setup_code.sh` - Installs Python packages and creates service
- `scripts/setup_ngrok_service.sh` - (Optional) Sets up ngrok as a service

### Verify Installation

```bash
# Check service status
/etc/init.d/openwrt-main status

# Check logs
tail -f /var/log/openwrt-main.log

# Verify device appears in ThingsBoard dashboard
```

### Troubleshooting

- **Permission errors**: Run as root (`su -`)
- **Python packages fail**: Check internet connection, run `opkg update`
- **Service won't start**: Check logs at `/var/log/openwrt-main.log`
- **Device not in ThingsBoard**: Verify server URL in `settings.py` and check network connectivity

## Service Management

### ngrok Management

If ngrok is set up as a service:

```bash
# Start service
/etc/init.d/ngrok start

# Stop service
/etc/init.d/ngrok stop

# Check status
/etc/init.d/ngrok status

# View logs
tail -f /var/log/ngrok.log
```

If ngrok is not set up as a service, you can start it manually:

```bash
# Start ngrok manually
ngrok start --all --config /root/.config/ngrok/ngrok.yml

# Or run in background
ngrok start --all --config /root/.config/ngrok/ngrok.yml &
```

### Code Monitoring Service

```bash
# Start service
/etc/init.d/openwrt-main start

# Stop service
/etc/init.d/openwrt-main stop

# Restart service
/etc/init.d/openwrt-main restart

# Check status
/etc/init.d/openwrt-main status

# View logs
tail -f /var/log/openwrt-main.log
```

## Uninstallation

To remove all services:

```bash
chmod +x uninstall.sh
./uninstall.sh
```

This will:
1. Uninstall ngrok (binary and configuration)
2. Uninstall code monitoring service
3. Preserve your code files and Python installation

**Note**: This will NOT remove the ngrok service (if installed separately). To remove the ngrok service, run `scripts/uninstall_ngrok_service.sh`.

### Individual Uninstall

```bash
# Uninstall ngrok only
chmod +x scripts/uninstall_ngrok.sh
./scripts/uninstall_ngrok.sh

# Uninstall ngrok service only (if installed separately)
chmod +x scripts/uninstall_ngrok_service.sh
./scripts/uninstall_ngrok_service.sh

# Uninstall code service only
chmod +x scripts/uninstall_code.sh
./scripts/uninstall_code.sh
```

## Configuration

### Settings

Edit `settings.py` to configure:
- ThingsBoard server URL
- Device credentials
- Monitoring intervals
- Other service parameters

### ngrok Configuration

The ngrok configuration is stored in `/root/.config/ngrok/ngrok.yml`. You can edit this file to:
- Change ngrok URL prefix
- Modify ttyd endpoint settings (URL suffix, upstream IP/port)
- Update authtoken

The configuration file includes two endpoints:
- `https-ui`: For accessing LuCI interface (upstream: `http://127.0.0.1:80`)
- `ttyd`: For accessing web terminal (upstream: `http://172.16.16.1:7681` or configured IP/port)

After editing, restart ngrok:
```bash
# If running as service
/etc/init.d/ngrok restart

# If running manually, stop and restart
pkill ngrok
ngrok start --all --config /root/.config/ngrok/ngrok.yml &
```

## Logs

### ngrok Logs
- Location: `/var/log/ngrok.log` (if running as service)
- View: `tail -f /var/log/ngrok.log`
- If running manually, check console output or redirect to a log file

### Code Service Logs
- Location: `/var/log/openwrt-main.log`
- View: `tail -f /var/log/openwrt-main.log`

## Troubleshooting

### Service Won't Start

1. **Check Python installation:**
   ```bash
   python3 --version
   ```

2. **Check dependencies:**
   ```bash
   python3 -c "import requests"
   ```

3. **Check logs:**
   ```bash
   tail -f /var/log/openwrt-main.log
   ```

### ngrok Not Connecting

1. **Verify ngrok configuration:**
   ```bash
   cat /root/.config/ngrok/ngrok.yml
   ```

2. **Check ngrok authtoken:**
   - Ensure the authtoken in the config file is valid
   - Verify ngrok account is active

3. **Check ngrok logs:**
   ```bash
   tail -f /var/log/ngrok.log
   ```

4. **Test ngrok manually:**
   ```bash
   ngrok start --all --config /root/.config/ngrok/ngrok.yml
   ```

5. **Verify network connectivity:**
   ```bash
   ping 1.1.1.1
   curl -I https://api.ngrok.com
   ```

### Service Stops Unexpectedly

1. **Check system resources:**
   ```bash
   free
   df -h
   ```

2. **Check for errors in logs**
3. **Verify network connectivity**
4. **Check ThingsBoard server status**

### Service Not Starting at Boot

1. **Verify service is enabled:**
   ```bash
   ls -la /etc/rc.d/S*ngrok
   ls -la /etc/rc.d/S*openwrt-main
   ```

2. **Re-enable services:**
   ```bash
   /etc/init.d/ngrok enable
   /etc/init.d/openwrt-main enable
   ```

**Note**: If ngrok is not set up as a service, it won't start at boot. Use `scripts/setup_ngrok_service.sh` to set it up as a service.

## Manual Processes Check

```bash
# Check ngrok process
ps | grep ngrok

# Check code service process
ps | grep run_main.sh
ps | grep main.py
```

## File Locations

- **Main Script**: `/root/openwrt/main.py`
- **Wrapper Script**: `/root/openwrt/run_main.sh`
- **ngrok Binary**: `/usr/bin/ngrok`
- **ngrok Config**: `/root/.config/ngrok/ngrok.yml`
- **Init Scripts**: 
  - `/etc/init.d/ngrok` (if service is installed)
  - `/etc/init.d/openwrt-main`
- **Log Files**:
  - `/var/log/ngrok.log` (if service is installed)
  - `/var/log/openwrt-main.log`

## Dependencies

- Python 3
- pip
- requests (Python package)
- ngrok binary (included in `scripts/ngrok`)

## License

This project is provided as-is for monitoring OpenWrt routers.

## Support

For issues or questions:
1. Check the logs for error messages
2. Verify all services are running
3. Ensure network connectivity
4. Review configuration files

## Notes

- The setup script installs Python packages globally with `--break-system-packages` flag
- Code files are preserved during uninstallation
- ngrok requires a valid authtoken (configured in `ngrok.yml`)
- The `setup_ngrok.sh` script only installs the binary and creates the config file
- To run ngrok as a service, use `setup_ngrok_service.sh` separately
- Services automatically restart if they crash
- All services use OpenWrt's procd init system
- ngrok creates two tunnels: one for LuCI interface (https-ui) and one for ttyd web terminal
- The https-ui endpoint connects to `http://127.0.0.1:80` for LuCI access
- The ttyd endpoint connects to the configured IP address (default: `172.16.16.1:7681`) for web terminal access

