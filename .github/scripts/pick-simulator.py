#!/usr/bin/env python3
"""Print the UDID of the newest available iPhone simulator.

The deployment target is iOS 18.0 and runner images rotate their installed
simulators, so CI resolves a destination at run time instead of pinning a
device name that quietly disappears.
"""
import json
import subprocess
import sys

MINIMUM_IOS = (18, 0)


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True, text=True, check=True,
    ).stdout

    best = None
    for runtime, devices in json.loads(raw)["devices"].items():
        if "iOS" not in runtime:
            continue
        version = runtime.split("iOS-")[-1].replace("-", ".")
        try:
            key = tuple(int(part) for part in version.split("."))
        except ValueError:
            continue
        if key < MINIMUM_IOS:
            continue
        for device in devices:
            if device.get("isAvailable") and "iPhone" in device["name"]:
                if best is None or key > best[0]:
                    best = (key, device["udid"], device["name"], version)

    if best is None:
        print("No available iPhone simulator running iOS 18.0 or newer", file=sys.stderr)
        return 1

    print(f"Selected {best[2]} (iOS {best[3]})", file=sys.stderr)
    print(best[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
