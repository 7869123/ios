"""Fake fixtures exercise real detectors; no credentials or private paths are embedded."""
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_personal_info import scan_text
from prepush_audit import RULES, is_public_ci_tool_path


def phone():
    return "139" + "00000000"


def artifact():
    return {"id": int(phone()), "name": "poc-evidence-42378051064-1"}


class PersonalInfoTests(unittest.TestCase):
    def test_artifact_metadata_is_not_phone(self):
        text = json.dumps({"artifacts": [artifact()]})
        self.assertEqual(scan_text("validation/example/summary.json", text), [])

    def test_metadata_exception_does_not_hide_other_fields(self):
        text = json.dumps({"artifacts": [dict(artifact(), contact=phone())]})
        self.assertTrue(any(rule == "phone" for _, rule in scan_text("validation/example/summary.json", text)))

    def test_non_validation_json_is_not_exempt(self):
        text = json.dumps({"artifacts": [artifact()]})
        self.assertTrue(scan_text("settings.json", text))

    def test_unknown_artifact_name_is_not_exempt(self):
        text = json.dumps({"artifacts": [dict(artifact(), name="private-data")]})
        self.assertTrue(scan_text("validation/example/summary.json", text))

    def test_malformed_json_is_not_exempt(self):
        self.assertTrue(scan_text("validation/example/summary.json", '{"id":' + phone()))

    def test_only_exact_actions_artifact_url_is_exempt(self):
        url = "https://github.com/7869123/ios/actions/runs/42378051064/artifacts/" + phone()
        self.assertEqual(scan_text("REPORT.md", "[artifact](" + url + ")"), [])
        self.assertTrue(scan_text("REPORT.md", url.replace("github.com", "example.com")))
        self.assertTrue(scan_text("REPORT.md", url + "0" + " " + phone()))

    def test_artifact_link_does_not_hide_phone_next_to_it(self):
        url = "https://github.com/7869123/ios/actions/runs/42378051064/artifacts/" + phone()
        self.assertTrue(scan_text("REPORT.md", url + " contact=" + phone()))

    def test_public_runner_does_not_hide_other_user_paths(self):
        public = "/Users/" + "runner/work/repo"
        private = "/Users/" + "fixture/Documents"
        self.assertEqual(scan_text("REPORT.md", public), [])
        self.assertTrue(scan_text("REPORT.md", public + " " + private))
        self.assertTrue(scan_text("REPORT.md", "/Users/" + "runner-private/file"))

    def test_windows_path_and_location_are_still_detected(self):
        self.assertTrue(scan_text("REPORT.md", "C:" + "/Users/" + "fixture/file"))
        self.assertTrue(scan_text("REPORT.md", "Asia/" + "Example"))


class CredentialTests(unittest.TestCase):
    def matches(self, text):
        return list(re.finditer(RULES["personal_email"], text))

    def test_public_tool_version_only_in_validation_path_export(self):
        path = b"export PATH=/opt/tool" + b"@" + b"3.4.0/bin:/Users/runner/bin"
        match = self.matches(path)[0]
        self.assertTrue(is_public_ci_tool_path("validation/example/archive.log", path, match))
        self.assertFalse(is_public_ci_tool_path("SOURCE.md", path, match))
        self.assertFalse(is_public_ci_tool_path("validation/example/archive.txt", path, match))
        plain = b"text " + path.split(b"=", 1)[1]
        self.assertFalse(is_public_ci_tool_path("validation/example/archive.log", plain, self.matches(plain)[0]))

    def test_actual_email_in_path_export_is_not_exempt(self):
        data = b"export PATH=/opt/fixture" + b"@" + b"private.invalid/bin:/Users/runner/bin"
        self.assertFalse(is_public_ci_tool_path("validation/example/archive.log", data, self.matches(data)[0]))

    def test_versions_outside_bin_or_public_runner_are_not_exempt(self):
        for suffix in (b"/data:/Users/runner/bin", b"/bin:/opt/other/bin"):
            data = b"export PATH=/opt/tool" + b"@" + b"3.4.0" + suffix
            self.assertFalse(is_public_ci_tool_path("validation/example/archive.log", data, self.matches(data)[0]))

    def test_secret_rules_stay_active_in_ci_logs(self):
        fixtures = {
            "github_token": b"ghp_" + b"a" * 40,
            "provider_key": b"sk-test-" + b"a" * 40,
            "private_key": b"-----BEGIN " + b"PRIVATE KEY-----",
            "credential_in_url": b"https://" + b"fixture:fake-secret" + b"@example.com",
        }
        for name, fixture in fixtures.items():
            with self.subTest(rule=name):
                self.assertIsNotNone(re.search(RULES[name], b"export PATH=/Users/runner/bin " + fixture))


if __name__ == "__main__":
    unittest.main()
