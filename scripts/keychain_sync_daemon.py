#!/usr/bin/env python3
"""Sync the macOS Keychain Claude Code OAuth credential to a file on disk.

Newer Claude Code CLI builds on macOS migrated their OAuth tokens out of
``~/.claude/.credentials.json`` and into the user's login Keychain
(service: ``Claude Code-credentials``). The on-disk file is left as a
fake placeholder. Sygen's sygen-core container bind-mounts that file at
``/home/sygen/.claude/.credentials.json`` and only ever sees the
placeholder, which surfaces inside the container as "Not logged in".

This daemon reads the keychain item and writes the JSON back to the
file every ``--interval`` seconds (default 15 min) so the file always
holds a fresh token. The OAuth token rotates roughly monthly, so a
periodic sync is sufficient — no Keychain change-notify needed.

Stdlib-only. Atomic writes (tmp + rename) at 0600 perms so readers
never observe a half-written file. Catches every error inside the loop
so transient Keychain access failures (e.g. user revoked perms, locked
keychain) do not kill the daemon — it just retries on the next tick.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

KEYCHAIN_SERVICE = "Claude Code-credentials"


def _read_keychain() -> str | None:
    """Return the raw keychain payload string, or None on failure."""
    res = subprocess.run(
        ["/usr/bin/security", "find-generic-password",
         "-s", KEYCHAIN_SERVICE, "-w"],
        check=False, capture_output=True, text=True, timeout=10,
    )
    if res.returncode != 0:
        return None
    payload = res.stdout.strip()
    return payload or None


def _is_valid_payload(payload: str) -> bool:
    try:
        data = json.loads(payload)
    except (ValueError, TypeError):
        return False
    inner = data.get("claudeAiOauth")
    return isinstance(inner, dict) and bool(inner.get("accessToken"))


def _read_file(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def _atomic_write(path: str, payload: str) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(payload)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.rename(tmp, path)
    os.chmod(path, 0o600)


def _sync_once(target: str) -> bool:
    """Run one sync cycle. Returns True if the file was rewritten."""
    payload = _read_keychain()
    if payload is None:
        print("keychain_sync: keychain item not accessible "
              f"(service={KEYCHAIN_SERVICE!r}); skipping",
              file=sys.stderr)
        return False
    if not _is_valid_payload(payload):
        print("keychain_sync: keychain payload is not a valid Claude "
              "OAuth JSON; skipping", file=sys.stderr)
        return False
    current = _read_file(target)
    if current is not None and current.strip() == payload.strip():
        return False
    _atomic_write(target, payload)
    print(f"keychain_sync: wrote {target} ({len(payload)} bytes)")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Sygen Keychain → file sync")
    parser.add_argument("--target", default=os.path.expanduser(
        "~/.claude/.credentials.json"),
        help="Path to write keychain payload to")
    parser.add_argument("--interval", type=float, default=60.0,
        help="Seconds between sync cycles (default 60 = 1 min)")
    parser.add_argument("--once", action="store_true",
        help="Sync once and exit (no loop)")
    args = parser.parse_args()

    if args.once:
        try:
            _sync_once(args.target)
        except Exception as exc:
            print(f"keychain_sync: error: {exc}", file=sys.stderr)
            return 1
        return 0

    while True:
        try:
            _sync_once(args.target)
        except Exception as exc:
            print(f"keychain_sync: error: {exc}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
