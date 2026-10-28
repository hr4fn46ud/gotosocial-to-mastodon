#!/usr/bin/env python3
"""Build versioned source assets from a clean, committed Git tree."""
import argparse
import datetime as dt
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(ROOT / "dist"), help="Release asset directory")
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / "scripts/check.py")], check=True)
    if git("status", "--porcelain").strip():
        raise ValueError("Commit or remove pending changes before building a release")
    version = (ROOT / "VERSION").read_text().strip()
    prefix = "gotosocial-to-mastodon-" + version
    epoch = int(git("show", "-s", "--format=%ct", "HEAD").strip())
    files = [Path(os.fsdecode(name)) for name in git("ls-files", "-z").split(b"\0") if name]
    for path in files:
        if (ROOT / path).is_symlink() or not (ROOT / path).is_file():
            raise ValueError("Release input must be a regular tracked file: " + str(path))
        if any(part in (".git", "dist", "archive", "archives", "exports", "reports", "backups", "__pycache__") for part in path.parts):
            raise ValueError("Private/generated directory is tracked: " + str(path))
        content = (ROOT / path).read_bytes()
        if re.search(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})", content):
            raise ValueError("Possible GitHub token in release input: " + str(path))
    output = Path(args.output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    zip_path = output / (prefix + ".zip")
    tar_path = output / (prefix + ".tar.gz")
    timestamp = dt.datetime.fromtimestamp(max(epoch, 315532800), dt.timezone.utc).timetuple()[:6]
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(files):
            info = zipfile.ZipInfo(prefix + "/" + path.as_posix(), timestamp)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if os.access(ROOT / path, os.X_OK) else 0o644
            info.external_attr = (0o100000 | mode) << 16
            archive.writestr(info, (ROOT / path).read_bytes(), compresslevel=9)
    with tar_path.open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=epoch, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in sorted(files):
                    content = (ROOT / path).read_bytes()
                    info = tarfile.TarInfo(prefix + "/" + path.as_posix())
                    info.size = len(content)
                    info.mode = 0o755 if os.access(ROOT / path, os.X_OK) else 0o644
                    info.mtime = epoch
                    archive.addfile(info, io.BytesIO(content))
    with zipfile.ZipFile(zip_path) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP integrity check failed")
        if len(archive.namelist()) != len(files):
            raise ValueError("ZIP file count mismatch")
    with tarfile.open(tar_path, "r:gz") as archive:
        if len(archive.getmembers()) != len(files):
            raise ValueError("tar.gz file count mismatch")
        for member in archive.getmembers():
            if not member.isfile() or not member.name.startswith(prefix + "/"):
                raise ValueError("Unexpected archive member")
    checksums = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n"
                        for path in (zip_path, tar_path))
    (output / "SHA256SUMS").write_text(checksums)
    print("Built and verified %d tracked files in %s" % (len(files), output))
    print(checksums, end="")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Release build failed: " + str(error), file=sys.stderr)
        sys.exit(1)
