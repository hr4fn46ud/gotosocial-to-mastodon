#!/usr/bin/env python3
"""Check public release metadata, documentation links and script versions."""
import re
from pathlib import Path
import subprocess
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]


def check():
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?", version):
        raise ValueError("VERSION must contain a semantic version")
    expected = "gotosocial-to-mastodon " + version
    for command in ([sys.executable, "export.py", "--version"], ["ruby", "import.rb", "--version"]):
        actual = subprocess.check_output(command, cwd=ROOT, text=True).strip()
        if actual != expected:
            raise ValueError("Script version mismatch: " + actual)
    if "## [" + version + "]" not in (ROOT / "CHANGELOG.md").read_text():
        raise ValueError("CHANGELOG.md has no entry for VERSION")
    required = ["README.MD", "LICENSE", "CONTRIBUTING.md", "SECURITY.md", ".github/workflows/ci.yml"]
    for name in required:
        if not (ROOT / name).is_file():
            raise ValueError("Missing required file: " + name)
    for path in ROOT.rglob("*"):
        if any(part in (".git", "dist", "__pycache__") for part in path.relative_to(ROOT).parts):
            continue
        if not path.is_file() or path.suffix.lower() != ".md":
            continue
        for target in re.findall(r"\]\(([^)\s]+)\)", path.read_text()):
            if urllib.parse.urlsplit(target).scheme or target.startswith("#"):
                continue
            relative = urllib.parse.unquote(target.split("#", 1)[0])
            if relative and not (path.parent / relative).exists():
                raise ValueError("Broken local link in %s: %s" % (path.relative_to(ROOT), target))
    print("Release checks passed for " + version)


if __name__ == "__main__":
    try:
        check()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Release check failed: " + str(error), file=sys.stderr)
        sys.exit(1)
