"""Focused tests for the iOS simulator selector used by CI."""

import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("select-ios-test-device.py")
SPEC = importlib.util.spec_from_file_location("select_ios_test_device", SCRIPT_PATH)
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)


class SelectIOSTestDeviceTests(unittest.TestCase):
    def test_selects_booted_device_only_on_exact_required_runtime(self):
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {
                        "name": "iPhone 18 Pro",
                        "udid": "old-runtime",
                        "state": "Booted",
                        "isAvailable": True,
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                    }
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                    {
                        "name": "iPhone Duo",
                        "udid": "shutdown-device",
                        "state": "Shutdown",
                        "isAvailable": True,
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    },
                    {
                        "name": "iPhone Duo",
                        "udid": "booted-device",
                        "state": "Booted",
                        "isAvailable": True,
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    },
                ],
            }
        }

        selected = SELECTOR.select_device(payload)

        self.assertEqual(selected["udid"], "booted-device")

    def test_27_0_device_does_not_fallback_when_27_1_is_missing(self):
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {
                        "name": "iPhone 18 Pro",
                        "udid": "only-27-0-device",
                        "state": "Booted",
                        "isAvailable": True,
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                    }
                ]
            }
        }

        with self.assertRaises(SELECTOR.NoMatchingDevice):
            SELECTOR.select_device(payload)

        runtime_payload = {
            "runtimes": [
                {
                    "version": "27.0",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                    "isAvailable": True,
                }
            ]
        }
        with self.assertRaises(SELECTOR.NoMatchingRuntime):
            SELECTOR.select_runtime(runtime_payload)

    def test_runtime_selection_ignores_other_platforms_at_same_version(self):
        payload = {
            "runtimes": [
                {
                    "version": "27.1",
                    "platform": "tvOS",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-1",
                    "isAvailable": True,
                },
                {
                    "version": "27.1",
                    "platform": "watchOS",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-1",
                    "isAvailable": True,
                },
                {
                    "version": "27.1",
                    "platform": "iOS",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
                    "buildversion": "24A94425",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {
                            "name": "iPhone Duo",
                            "productFamily": "iPhone",
                            "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                        }
                    ],
                },
            ]
        }

        selected = SELECTOR.select_runtime(payload)

        self.assertEqual(selected["identifier"], "com.apple.CoreSimulator.SimRuntime.iOS-27-1")

    def test_invalid_runtime_inventory_is_not_treated_as_missing_runtime(self):
        with self.assertRaisesRegex(ValueError, "Invalid simctl runtime JSON"):
            SELECTOR.select_runtime({})

    def test_device_type_comes_from_runtime_supported_device_types(self):
        payload = {
            "runtimes": [
                {
                    "version": "27.1",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {
                            "name": "iPhone Duo",
                            "productFamily": "iPhone",
                            "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                        }
                    ],
                }
            ]
        }

        selected = SELECTOR.select_device_type(payload)

        self.assertEqual(selected, "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")


if __name__ == "__main__":
    unittest.main()
