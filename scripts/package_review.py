"""Package a clean committed snapshot plus full Git history; exclude untracked data."""
import argparse
import datetime
import hashlib
import io
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="review/AIUtility-round2-review.zip")
    args = parser.parse_args()
    destination = (ROOT / args.output).resolve()
    if not destination.is_relative_to(ROOT):
        parser.error("output must stay within the repository")
    if git("status", "--porcelain").strip():
        parser.error("commit the working tree before creating a review snapshot")
    destination.parent.mkdir(parents=True, exist_ok=True)
    revision = git("rev-parse", "HEAD").decode().strip()
    history = ROOT / "artifacts" / "review-build" / (revision + ".bundle")
    history.parent.mkdir(parents=True, exist_ok=True)
    git("bundle", "create", str(history), "--all")
    git("bundle", "verify", str(history))
    hashes = {}
    archive = zipfile.ZipFile(io.BytesIO(git("archive", "--format=zip", "HEAD")))
    with archive, zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as output:
        for item in archive.infolist():
            if item.is_dir():
                continue
            data = archive.read(item)
            output.writestr(item.filename, data)
            hashes[item.filename] = hashlib.sha256(data).hexdigest()
        bundle_bytes = history.read_bytes()
        output.writestr("AIUtility-history.bundle", bundle_bytes)
        manifest = {
            "commit": revision,
            "base_commit": "f2b766e",
            "packaged_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source_file_count": len(hashes),
            "file_sha256": hashes,
            "history_sha256": hashlib.sha256(bundle_bytes).hexdigest(),
            "verification_report": "validation/github-actions/summary.json",
            "notice": "Read STATUS.md for actual Linux Core CI evidence. Apple SDK and device validation remain incomplete.",
        }
        output.writestr("REVIEW_MANIFEST.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    with zipfile.ZipFile(destination) as check:
        if check.testzip() is not None:
            raise RuntimeError("ZIP integrity check failed")
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".zip.sha256").write_text(checksum + "  " + destination.name + "\n", encoding="ascii")
    print(json.dumps({"zip": str(destination), "commit": revision, "source_files": len(hashes),
                      "bytes": destination.stat().st_size, "sha256": checksum}, indent=2))


if __name__ == "__main__":
    main()
