#!/usr/bin/env python3
"""Select or describe a simulator for the required iOS runtime."""

import argparse
import json
import re
import sys

REQUIRED_IOS_VERSION = (27, 1)
RUNTIME_IDENTIFIER_PATTERN = re.compile(r"\.iOS-(\d+(?:-\d+)*)$")


class NoMatchingDevice(Exception):
    """No available iPhone simulator exists for the required runtime."""


class NoMatchingRuntime(Exception):
    """No available iOS runtime exists for the required version."""


def parse_version(value):
    try:
        parts = tuple(int(part) for part in str(value).split("."))
    except ValueError:
        return None
    return parts if parts and all(part >= 0 for part in parts) else None


def runtime_version_from_identifier(identifier):
    match = RUNTIME_IDENTIFIER_PATTERN.search(identifier or "")
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split("-"))


def select_runtime(payload, required_version=REQUIRED_IOS_VERSION):
    runtimes = payload.get("runtimes") if isinstance(payload, dict) else None
    if not isinstance(runtimes, list):
        raise ValueError("Invalid simctl runtime JSON: expected a runtimes array.")
    for runtime in runtimes:
        if not runtime.get("isAvailable"):
            continue
        identifier = runtime.get("identifier")
        if runtime_version_from_identifier(identifier) == required_version:
            return runtime
    raise NoMatchingRuntime


def select_device(payload, required_version=REQUIRED_IOS_VERSION):
    devices_by_runtime = payload.get("devices") if isinstance(payload, dict) else None
    if not isinstance(devices_by_runtime, dict):
        raise ValueError("Invalid simctl device JSON: expected a devices object.")
    candidates = []
    for runtime, devices in devices_by_runtime.items():
        if runtime_version_from_identifier(runtime) != required_version:
            continue
        for device in devices:
            device_type = device.get("deviceTypeIdentifier", "")
            is_iphone = ".iPhone-" in device_type or device.get("name", "").startswith("iPhone")
            if device.get("isAvailable") and is_iphone and device.get("udid"):
                candidates.append((device.get("state") == "Booted", device["udid"], device))
    if not candidates:
        raise NoMatchingDevice
    _, _, device = max(candidates, key=lambda value: value[:2])
    return device


def select_device_type(runtime_payload, required_version=REQUIRED_IOS_VERSION):
    runtime = select_runtime(runtime_payload, required_version)
    device_types = runtime.get("supportedDeviceTypes", [])
    candidates = []
    for device_type in device_types:
        identifier = device_type.get("identifier", "")
        name = device_type.get("name", "")
        family = device_type.get("productFamily", device_type.get("productFamilyIdentifier", ""))
        is_iphone = family == "iPhone" or ".iPhone-" in identifier or name.startswith("iPhone")
        if is_iphone and identifier:
            candidates.append((name, identifier))
    if not candidates:
        raise ValueError(
            f"The iOS {'.'.join(map(str, required_version))} runtime supports no iPhone simulator device type."
        )
    return sorted(candidates)[0][1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="27.1", help="Required iOS runtime version (default: 27.1).")
    parser.add_argument(
        "--mode",
        choices=("runtime", "device", "device-type"),
        default="device",
        help="Read runtime JSON or device JSON from standard input.",
    )
    args = parser.parse_args()
    required_version = parse_version(args.version)
    if required_version is None:
        parser.error(f"invalid runtime version: {args.version}")
    try:
        payload = json.load(sys.stdin)
        if args.mode == "runtime":
            runtime = select_runtime(payload, required_version)
            print(runtime["identifier"])
            supported_types = ", ".join(
                device_type.get("name", device_type.get("identifier", "unknown"))
                for device_type in runtime.get("supportedDeviceTypes", [])
            ) or "none reported"
            build_version = runtime.get("buildversion", "unknown")
            print(
                f"Found iOS {args.version} runtime ({runtime['identifier']}, build {build_version}; "
                f"supported device types: {supported_types})",
                file=sys.stderr,
            )
        elif args.mode == "device-type":
            print(select_device_type(payload, required_version))
        else:
            device = select_device(payload, required_version)
            print(device["udid"])
            print(f"Selected {device['name']} ({device['udid']})", file=sys.stderr)
    except NoMatchingDevice:
        print(f"::notice::No available iPhone simulator exists for iOS {args.version}.", file=sys.stderr)
        return 2
    except NoMatchingRuntime:
        print(f"::notice::iOS {args.version} simulator runtime is not installed.", file=sys.stderr)
        return 2
    except (ValueError, TypeError, AttributeError, KeyError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
