"""Inspect private CI using Git Credential Manager; never print or persist credentials."""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["inspect", "runs", "jobs", "logs", "evidence", "dispatch"])
    parser.add_argument("--repository", default="7869123/ios")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--sha")
    parser.add_argument("--output", default="artifacts/github-ci")
    args = parser.parse_args()
    parts = args.repository.split("/")
    if len(parts) != 2 or not all(part and all(c.isalnum() or c in "-_." for c in part) for part in parts):
        parser.error("repository must be OWNER/REPO")
    environment = os.environ.copy()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GCM_INTERACTIVE"] = "never"
    credential = subprocess.run(["git", "credential", "fill"], cwd=ROOT,
        input="protocol=https\nhost=github.com\nusername=" + parts[0] + "\n\n",
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=30)
    fields = dict(line.split("=", 1) for line in credential.stdout.splitlines() if "=" in line)
    token = fields.get("password")
    if credential.returncode != 0 or not token:
        raise RuntimeError("GitHub login required; complete Git Credential Manager browser login")
    opener = urllib.request.build_opener(NoRedirect())
    base = "https://api.github.com/repos/" + args.repository

    def request(path, body=None):
        headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "AIUtility-CI-verification"}
        data = json.dumps(body).encode() if body is not None else None
        if data is not None:
            headers["Content-Type"] = "application/json"
        try:
            with opener.open(urllib.request.Request(base + path, data=data, headers=headers), timeout=30) as response:
                content = response.read()
                return json.loads(content) if content else None
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308) and body is None:
                target = error.headers.get("Location", "")
                parsed = urllib.parse.urlparse(target)
                host = parsed.hostname or ""
                if parsed.scheme != "https" or not host.endswith((".blob.core.windows.net", ".githubusercontent.com")):
                    raise RuntimeError("Unexpected download origin; authorization was not forwarded") from None
                # Signed downloads must never receive the GitHub Authorization header.
                with opener.open(urllib.request.Request(target, headers={"User-Agent": "AIUtility-CI-verification"}), timeout=30) as download:
                    return download.read()
            raise RuntimeError("GitHub API HTTP " + str(error.code)) from None

    repository = request("")
    if not repository.get("private"):
        raise RuntimeError("Repository is not private; stopping before further actions")
    if args.command == "inspect":
        result = {key: repository.get(key) for key in ("full_name", "private", "default_branch", "permissions")}
    elif args.command == "runs":
        query = {"per_page": "10"}
        if args.sha:
            query["head_sha"] = args.sha
        runs = request("/actions/workflows/swift.yml/runs?" + urllib.parse.urlencode(query))
        result = [{key: run.get(key) for key in ("id", "head_sha", "status", "conclusion", "html_url", "run_attempt")}
                  for run in runs.get("workflow_runs", [])]
    elif args.command == "jobs":
        if not args.run_id:
            parser.error("--run-id required")
        jobs = request("/actions/runs/" + str(args.run_id) + "/jobs")
        result = [{key: job.get(key) for key in ("id", "name", "status", "conclusion", "steps")} for job in jobs.get("jobs", [])]
    elif args.command == "dispatch":
        request("/actions/workflows/swift.yml/dispatches", {"ref": "main", "inputs": {"build_apple": False, "build_poc": False}})
        result = {"dispatched": "swift.yml", "ref": "main", "apple_enabled": False}
    else:
        if not args.run_id:
            parser.error("--run-id required")
        if args.command == "evidence":
            artifacts = request("/actions/runs/" + str(args.run_id) + "/artifacts")
            candidates = [item for item in artifacts.get("artifacts", [])
                          if item["name"].startswith("core-linux-evidence-") and not item.get("expired")]
            if not candidates:
                raise RuntimeError("Core CI evidence artifact not available")
            artifact = max(candidates, key=lambda item: item["created_at"])
            data = request("/actions/artifacts/" + str(artifact["id"]) + "/zip")
        else:
            data = request("/actions/runs/" + str(args.run_id) + "/logs")
        if not isinstance(data, bytes):
            raise RuntimeError("Expected CI log archive")
        output = (ROOT / args.output / str(args.run_id)).resolve()
        if not output.is_relative_to(ROOT / "artifacts"):
            parser.error("logs must be saved under artifacts/")
        output.mkdir(parents=True, exist_ok=True)
        if args.command == "evidence":
            output = output / "evidence"
            output.mkdir(exist_ok=True)
        (output / ("evidence.zip" if args.command == "evidence" else "logs.zip")).write_bytes(data)
        files = []
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            expected = {"swift-version.log", "core-build.log", "core-tests.log", "exit-codes.txt"}
            if args.command == "evidence" and set(archive.namelist()) != expected:
                raise RuntimeError("Unexpected files in Core evidence artifact")
            for member in archive.infolist():
                if member.is_dir():
                    continue
                target = (output / member.filename).resolve()
                if not target.is_relative_to(output):
                    raise RuntimeError("Unsafe archive path")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(member))
                files.append(member.filename)
        result = {"run_id": args.run_id, "output": str(output.relative_to(ROOT)), "files": files}
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, subprocess.TimeoutExpired) as error:
        # Never print request headers, credential stdout or signed download URLs.
        print(str(error) if isinstance(error, RuntimeError) else type(error).__name__, file=sys.stderr)
        sys.exit(1)
