#!/usr/bin/env python3
"""rename_site.py — change the site name used at provisioning time.

Invoked by ``/etc/init.d/openwrt-main rename "<new name>"``. Writes
the new value to ``~/.openwrt/config.json``. This affects the TB
device label in two ways:

  * On the **next provisioning call** (after a factory reset, a
    cleared ``tb_token``, or a fresh install), provision.py sends
    the new name as ``deviceLabel`` so the device appears named on
    its first connect.
  * The new name is included in every telemetry tick under the
    ``site_name`` key so it's visible in TB telemetry.

For an **already-provisioned** device, the TB ``label`` field is
the dashboard's source of truth and the TB access token issued to
the agent isn't allowed to mutate it. Rename the device from the
dashboard (Devices page → rename) — the backend pushes the new
label back to the router as a TB shared attribute, and
utils/rpc_control.py mirrors it into this same config.json. So the
two sides converge either way.

Empty string clears the site name; the dashboard then falls back to
the GB-<MAC> identifier on the next provisioning call.

Exit codes:
  0  changed (or unchanged, which is treated as success)
  1  invalid input
  2  config write failed
"""
import os
import sys

# Allow being executed as ``python3 rename_site.py "..."`` from
# anywhere on the router. The agent lives at /root/DTS-MobileQ/openwrt
# in the standard layout; resolve relative to this script so we don't
# care where the user is when they run it.
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            'Usage: rename_site.py "<new site name>"\n'
            '       rename_site.py ""   (clears the site name)\n'
        )
        return 1
    new_name = argv[1]

    from utils.site_name import get_site_name, set_site_name

    current = get_site_name()
    try:
        changed = set_site_name(new_name)
    except ValueError as e:
        sys.stderr.write(f"Invalid site name: {e}\n")
        return 1
    except RuntimeError as e:
        sys.stderr.write(f"Failed to write config: {e}\n")
        return 2

    if changed:
        cleaned = get_site_name()
        if cleaned:
            sys.stdout.write(
                f"Site name updated locally: {current!r} -> {cleaned!r}\n"
                "  - Future provisioning calls will send this as deviceLabel.\n"
                "  - Telemetry will include site_name on the next tick.\n"
                "  - For an already-provisioned device, also rename from the\n"
                "    dashboard (Devices > rename) so the TB label is updated;\n"
                "    the change mirrors back here automatically.\n"
            )
        else:
            sys.stdout.write(
                "Site name cleared locally. Re-provisioning will fall back\n"
                "to the GB-<MAC> identifier.\n"
            )
    else:
        sys.stdout.write(f"Site name already set to {current!r}; no change.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
