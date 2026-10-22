#!/usr/bin/env python3
"""Select an available iPhone running the unit test target's minimum iOS or newer."""

import json
import re
import sys

MINIMUM_IOS_VERSION = (27, 0, 0)


def select_device(payload):
    candidates = []
    for runtime, devices in payload.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        version += (0,) * max(0, 3 - len(version))
        if version < MINIMUM_IOS_VERSION:
            continue
        for device in devices:
            device_type = device.get("deviceTypeIdentifier", "")
            is_iphone = ".iPhone-" in device_type or device.get("name", "").startswith("iPhone")
            if device.get("isAvailable") and is_iphone and device.get("udid"):
                candidates.append((version, device.get("state") == "Booted", device["udid"], device))
    if not candidates:
        raise ValueError("Install an available iPhone simulator with iOS 27.0 or newer on the xcode-27 runner.")
    version, _, _, device = max(candidates, key=lambda value: value[:3])
    return version, device


def main():
    try:
        version, device = select_device(json.load(sys.stdin))
    except (ValueError, TypeError, AttributeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print(device["udid"])
    version_text = ".".join(str(part) for part in version)
    print(f"Selected {device['name']} (iOS {version_text}, {device['udid']})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
