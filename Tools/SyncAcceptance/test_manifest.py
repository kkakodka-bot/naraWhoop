import json
import unittest
from manifest import sanitized_xcresult


class ManifestPrivacyTests(unittest.TestCase):
    def test_allowlist_drops_identifiers_and_untrusted_failure_text(self):
        result = sanitized_xcresult({
            "result": "Failed", "passedTests": 2, "failedTests": 1,
            "testFailures": [{"failureText": "private-token-and-health-value"}],
            "devicesAndConfigurations": [{"device": {
                "deviceId": "private-hardware-id", "deviceName": "private-person-name",
                "architecture": "arm64", "modelName": "Synthetic phone", "osVersion": "17", "platform": "iOS",
            }}],
        })
        encoded = json.dumps(result)
        self.assertNotIn("private", encoded)
        self.assertEqual(result["failed_tests"], 1)
        self.assertEqual(result["environments"][0]["platform"], "iOS")


if __name__ == "__main__":
    unittest.main()
