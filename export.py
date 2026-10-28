#!/usr/bin/env python3
"""Portable GoToSocial account archive. Python 3.9+, standard library only."""
import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

FORMAT = "gts-mastodon-migrator/1"
VERSION = "0.2.0"


class MigrationError(Exception):
    pass


def atomic_json(path, value):
    path = Path(path)
    tmp = path.with_name(path.name + ".part")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def safe_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value):
        raise MigrationError("Invalid ID in server response")
    return value


def origin(url):
    p = urllib.parse.urlsplit(url)
    return (p.scheme, p.hostname, p.port or (443 if p.scheme == "https" else 80))


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise MigrationError("Refusing an insecure redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if origin(req.full_url) != origin(newurl):
            redirected.remove_header("Authorization")
        return redirected


class Client:
    def __init__(self, server, token, retries=4):
        self.server = server
        self.token = token
        self.retries = retries
        self.opener = urllib.request.build_opener(Redirects())

    def get(self, url, dest=None):
        if urllib.parse.urlsplit(url).scheme != "https":
            raise MigrationError("Only HTTPS URLs are allowed")
        headers = {"User-Agent": "gotosocial-to-mastodon/" + VERSION}
        if origin(url) == origin(self.server):
            headers["Authorization"] = "Bearer " + self.token
        for attempt in range(self.retries + 1):
            try:
                with self.opener.open(urllib.request.Request(url, headers=headers), timeout=90) as response:
                    if dest is None:
                        raw = response.read(64 * 1024 * 1024 + 1)
                        if len(raw) > 64 * 1024 * 1024:
                            raise MigrationError("API response exceeds the size limit")
                        return json.loads(raw)
                    tmp = dest.with_name(dest.name + ".part")
                    with tmp.open("wb") as f:
                        size = 0
                        while True:
                            block = response.read(1024 * 1024)
                            if not block:
                                break
                            size += len(block)
                            if size > 1024 * 1024 * 1024:
                                raise MigrationError("Media file exceeds 1 GiB")
                            f.write(block)
                        f.flush()
                        os.fsync(f.fileno())
                    expected = response.headers.get("Content-Length")
                    if expected is not None and size != int(expected):
                        raise MigrationError("Incomplete media download")
                    tmp.replace(dest)
                    return None
            except urllib.error.HTTPError as e:
                if e.code not in (429, 500, 502, 503, 504) or attempt == self.retries:
                    raise MigrationError("HTTP %s while fetching data; check permissions and server status" % e.code) from None
                delay = e.headers.get("Retry-After", "")
                if delay.isdigit():
                    delay = int(delay)
                else:
                    from email.utils import parsedate_to_datetime
                    try:
                        delay = max(0, (parsedate_to_datetime(delay) - dt.datetime.now(dt.timezone.utc)).total_seconds())
                    except (ValueError, TypeError):
                        delay = 2 ** attempt
                if delay > 300:
                    raise MigrationError("Server requested a longer wait; resume the export later")
                time.sleep(delay)
            except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError) as e:
                if attempt == self.retries:
                    raise MigrationError("Network request failed; the export can be resumed") from None
                time.sleep(2 ** attempt)

    def api(self, path, params=None):
        return self.get(self.server + path + ("?" + urllib.parse.urlencode(params) if params else ""))


def export(args, client):
    root = Path(args.output).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    # One process per archive, automatically released on exit/crash.
    import fcntl
    with (root / ".export.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise MigrationError("Another export is already using this archive") from None
        return export_locked(args, client, root)


def export_locked(args, client, root):
    account = client.api("/api/v1/accounts/verify_credentials")
    if not isinstance(account, dict) or not account.get("id") or not account.get("url"):
        raise MigrationError("Invalid account response")
    aid = safe_id(account["id"])
    if args.account and args.account != account.get("username"):
        raise MigrationError("The token does not belong to the specified local source account")
    identity = {"server": args.source, "account_id": aid, "account_url": account["url"]}
    identity_file = root / "identity.json"
    if identity_file.exists():
        if json.loads(identity_file.read_text()) != identity:
            raise MigrationError("Archive belongs to a different source; use a new directory")
    elif any(p.name != ".export.lock" for p in root.iterdir()):
        raise MigrationError("Output directory contains unrelated files")
    else:
        atomic_json(identity_file, identity)
    # A rerun must never leave an old 'complete' manifest beside partial new content.
    (root / "manifest.json").unlink(missing_ok=True)
    (root / "posts").mkdir(exist_ok=True)
    (root / "media").mkdir(exist_ok=True)
    atomic_json(root / "account.json", account)
    records = []
    seen = set()
    cursor = None
    boosts = 0
    while True:
        params = {"limit": 40, "exclude_replies": "false", "exclude_reblogs": "false"}
        if cursor:
            params["max_id"] = cursor
        page = client.api("/api/v1/accounts/" + aid + "/statuses", params)
        if not isinstance(page, list):
            raise MigrationError("Invalid status list")
        if not page:
            break
        previous = cursor
        for status in page:
            if not isinstance(status, dict):
                raise MigrationError("Invalid post in server response")
            sid = safe_id(status.get("id"))
            key = int(sid) if sid.isdigit() else sid
            old_key = (int(previous) if previous.isdigit() else previous) if previous else None
            if sid in seen or (old_key is not None and (type(key) != type(old_key) or key >= old_key)):
                raise MigrationError("Repeated or out-of-order pagination; export stopped")
            seen.add(sid)
            previous = sid
            if status.get("reblog"):
                boosts += 1
                continue
            if str(status.get("account", {}).get("id")) != aid:
                raise MigrationError("Unexpected author in the account status list")
            # Source is fetched again on resume to capture edits. Media are content-checked.
            source = client.api("/api/v1/statuses/" + sid + "/source")
            if not isinstance(source, dict) or not isinstance(source.get("text"), str):
                raise MigrationError("Source text unavailable: " + sid)
            if source.get("id") != sid:
                raise MigrationError("Source text belongs to a different post: " + sid)
            relative = "posts/" + sid + ".json"
            old = {}
            if (root / relative).exists():
                old = json.loads((root / relative).read_text())
            old_media = {m["id"]: m for m in old.get("media", [])}
            media = []
            for attachment in status.get("media_attachments", []):
                mid = safe_id(attachment.get("id"))
                url = attachment.get("url")
                if not url:
                    raise MigrationError("Original media unavailable: " + sid + "/" + mid)
                suffix = Path(urllib.parse.urlsplit(url).path).suffix.lower()
                if not re.fullmatch(r"\.[a-z0-9]{1,8}", suffix):
                    suffix = ".bin"
                name = "media/" + sid + "-" + mid + suffix
                dest = root / name
                cached = old_media.get(mid, {})
                if not (dest.is_file() and cached.get("source_url") == url and
                        cached.get("sha256") == digest(dest)):
                    client.get(url, dest)
                media.append({"id": mid, "path": name, "source_url": url,
                              "sha256": digest(dest), "size": dest.stat().st_size,
                              "type": attachment.get("type"), "description": attachment.get("description"),
                              "focus": (attachment.get("meta") or {}).get("focus")})
            atomic_json(root / relative, {"status": status, "source": source, "media": media})
            records.append(relative)
        cursor = previous
        print("Exported: %d posts" % len(records), flush=True)
    files = ["identity.json", "account.json"] + records
    for record in records:
        files.extend(m["path"] for m in json.loads((root / record).read_text())["media"])
    manifest = {"format": FORMAT, "exporter_version": VERSION, "complete": True, "source": identity,
                "exported_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "posts": records, "excluded_boosts": boosts,
                "files": {name: {"sha256": digest(root / name), "size": (root / name).stat().st_size}
                          for name in sorted(set(files))}}
    atomic_json(root / "manifest.json", manifest)
    print("Complete: %s (%d posts, %d boosts excluded)" % (root, len(records), boosts))
    return manifest


def main():
    p = argparse.ArgumentParser(description="Export GoToSocial posts and original media")
    p.add_argument("--version", action="version", version="gotosocial-to-mastodon " + VERSION)
    p.add_argument("--source", required=True, help="GoToSocial HTTPS base URL")
    p.add_argument("--account", help="Optional local username used to verify token ownership")
    p.add_argument("--output", required=True, help="Archive directory; reuse the same directory to resume")
    p.add_argument("--token-file", help="User token file; alternatively use GTS_TOKEN or the hidden prompt")
    args = p.parse_args()
    args.source = args.source.rstrip("/")
    parsed = urllib.parse.urlsplit(args.source)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or
            parsed.path or parsed.query or parsed.fragment):
        p.error("--source must be an HTTPS base URL without a path or credentials")
    os.umask(0o077)
    try:
        token = Path(args.token_file).read_text().strip() if args.token_file else os.environ.get("GTS_TOKEN")
        token = token or getpass.getpass("GoToSocial user access token: ")
        if not token or any(c.isspace() for c in token):
            raise MigrationError("Invalid access token")
        export(args, Client(args.source, token))
    except (MigrationError, OSError, ValueError) as e:
        print("Error: " + str(e), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted; run the same export command to resume", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
