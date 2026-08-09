import json
import os

ROOT_DIR = os.path.expanduser("~/.openwrt")
os.makedirs(ROOT_DIR, exist_ok=True)

INTERVAL = 30


DEFAULT_CONFIG = {
    "interval": 30,
    "ngrok_duration": 1800  # Auto-stop duration in seconds (default: 30 minutes)
}

CONFIG_FILE = os.path.join(ROOT_DIR, "config.json")
if not os.path.exists(CONFIG_FILE):
    import tempfile
    print("No config found! Creating the default one...")
    try:
        fd, tmp_path = tempfile.mkstemp(dir=ROOT_DIR, suffix=".tmp")
        with os.fdopen(fd, "w") as tmp_f:
            json.dump(DEFAULT_CONFIG, tmp_f, indent=2)
            tmp_f.flush()
            os.fsync(tmp_f.fileno())
        os.replace(tmp_path, CONFIG_FILE)
    except Exception as e:
        print(f"Warning: Failed to create config file atomically: {e}")
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


API_TIMEOUT = 5

APP_DIR = os.path.dirname(os.path.realpath(__file__))

CRASH_FILE = os.path.join(ROOT_DIR, "crash.dump")

# ThingsBoard provisioning credentials.
#
# SECURITY: these MUST be supplied per deployment via either the
# environment or local_settings.py. There are no source-tracked
# defaults — the repo is public, and any literal here would let
# anyone with internet access mint TB devices against this tenant.
# Operators see the override format in local_settings.py.example.
#
# At runtime the agent only needs these when first provisioning a
# device; an already-onboarded unit reads its TB access token from
# ~/.openwrt/config.json and never touches the provisioning endpoint
# again. So a unit whose tb_token is already set keeps working even
# with these unset — but utils/provision.provision_device() raises a
# clear error if it's invoked without them set.
TB_PROVISION_KEY    = os.environ.get("TB_PROVISION_KEY")
TB_PROVISION_SECRET = os.environ.get("TB_PROVISION_SECRET")
TB_SERVER_URL       = os.environ.get("TB_SERVER_URL", "http://137.184.5.176:8080")

# --- DTS-MobileQ dual-publish broker (migration window) ---
# Set MQTT_BROKER_HOST in ~/.openwrt/local_settings.py to mirror every
# telemetry frame onto the DTS-MobileQ dashboard alongside ThingsBoard.
# Leave unset and the agent behaves as before: HTTP→TB + MQTT-RPC→TB.
#
# When set, on each publish cycle the agent:
#   * still HTTP-POSTs to TB (unchanged customer path)
#   * additionally publishes the same payload to
#     ``v1/devices/<name>/telemetry`` on this broker
#   * subscribes to ``v1/devices/<name>/rpc/request/+`` so commands
#     from the DTS dashboard reach the device
#
# DTS_HTTP_URL is optional. When provided, the agent provisions itself
# against DTS's ThingsBoard-compatible ``/api/v1/provision`` on first
# run and stores the returned token as ``dts_token`` in config.json.
# Without it the operator pre-creates the device row by name in the
# DTS admin UI (either path is supported).
MQTT_BROKER_HOST = os.environ.get("MQTT_BROKER_HOST") or None
MQTT_BROKER_PORT = int(os.environ.get("MQTT_BROKER_PORT", "1883"))
MQTT_BROKER_USERNAME = os.environ.get("MQTT_BROKER_USERNAME") or None
MQTT_BROKER_PASSWORD = os.environ.get("MQTT_BROKER_PASSWORD") or None
DTS_HTTP_URL = os.environ.get("DTS_HTTP_URL") or None  # e.g. http://157.173.106.229:5173

# Turn screen off time(minutes)
SCREEN_SAVER_TIME = 1

# Ngrok auto-stop duration (seconds)
# ngrok will automatically stop after this duration when started via RPC
NGROK_DURATION = 1800  # Default: 30 minutes (1800 seconds)

# Bondix server Prometheus metrics (channel latency, loss, tunnel uptime).
#
# SECURITY: same rule as TB above — the scrape password is only ever
# supplied via env or local_settings.py, never tracked in source.
# Without it, the agent silently skips Bondix Prometheus and falls
# back to the per-WAN ping stats that the agent collects on its own;
# nothing else breaks.
BONDIX_SERVER_URL  = os.environ.get("BONDIX_SERVER_URL",  "https://134.199.206.28/metrics")
BONDIX_SERVER_USER = os.environ.get("BONDIX_SERVER_USER", "prometheus")
BONDIX_SERVER_PASS = os.environ.get("BONDIX_SERVER_PASS")
BONDIX_SERVER_TIMEOUT = 10

# Per-deployment overrides. Two supported locations, applied in order
# so the persistent per-device config dir wins when both exist:
#   1. local_settings.py at the repo root (resolved via PYTHONPATH, which
#      setup_code.sh exports to the code dir).
#   2. ~/.openwrt/local_settings.py (the persistent config dir alongside
#      config.json). Historically the docs and error messages pointed
#      operators here, but a bare ``import`` never resolved it — this
#      block makes that documented location actually work.
try:
    from local_settings import *  # noqa: F401,F403 (repo-root override)
except ImportError:
    pass

_LOCAL_SETTINGS_PATH = os.path.join(ROOT_DIR, "local_settings.py")
if os.path.exists(_LOCAL_SETTINGS_PATH):
    try:
        _overrides: dict = {}
        with open(_LOCAL_SETTINGS_PATH, "r") as _f:
            exec(compile(_f.read(), _LOCAL_SETTINGS_PATH, "exec"), _overrides)
        # Mirror ``from x import *`` semantics: only public names.
        globals().update(
            {k: v for k, v in _overrides.items() if not k.startswith("_")}
        )
    except Exception as _e:
        print(f"Warning: failed to load {_LOCAL_SETTINGS_PATH}: {_e}")
