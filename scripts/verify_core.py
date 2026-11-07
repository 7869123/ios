"""Run the real Swift compiler/tests and preserve evidence. Never substitutes a parser."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="artifacts/core-verification")
    args = parser.parse_args()
    output = (ROOT / args.output).resolve()
    if not output.is_relative_to(ROOT):
        parser.error("output must stay within the repository")
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["AIUTILITY_LIVE_TESTS"] = "0"
    environment["AIUTILITY_KEYCHAIN_TESTS"] = "0"
    swift = shutil.which("swift")
    commands = [
        ("swift-version", ["swift", "--version"]),
        ("core-build", ["swift", "build", "--package-path", "Packages/AIUtilityCore"]),
        ("core-tests", ["swift", "test", "--package-path", "Packages/AIUtilityCore"]),
    ]
    results = []
    for name, command in commands:
        if not swift:
            result = {"name": name, "command": command, "status": "not_started", "exit_code": None,
                      "reason": "Swift executable not found; no Swift process was started"}
            content = result["reason"] + "\n"
        else:
            completed = subprocess.run([swift, *command[1:]], cwd=ROOT, env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                       encoding="utf-8", errors="replace", check=False)
            result = {"name": name, "command": command,
                      "status": "passed" if completed.returncode == 0 else "failed",
                      "exit_code": completed.returncode}
            content = completed.stdout
        result["log"] = name + ".log"
        (output / result["log"]).write_text(content, encoding="utf-8")
        results.append(result)
        print(f"{name}: {result['status']}; Swift exit code={result['exit_code']}")
    report = {
        "executed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "swift_executable": swift,
        "live_api_tests_enabled": False,
        "commands": results,
        "swift_tests_executed": 0 if not swift else None,
        "test_count_note": "0 means no compiler was available; null means consult the actual test log",
        "apple_sdk_verified": False,
        "device_verified": False,
    }
    (output / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if any(result["status"] == "not_started" for result in results):
        return 2  # This is the verification runner's exit code, NOT a Swift compiler exit code.
    return 0 if all(result["status"] == "passed" for result in results) else 1


if __name__ == "__main__":
    sys.exit(main())
