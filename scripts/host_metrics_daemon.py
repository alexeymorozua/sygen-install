#!/usr/bin/env python3
"""Host metrics bridge for sygen-core (Docker on macOS Colima / Linux).

Writes a JSON snapshot of the *host's* CPU%, RAM used, and disk used to a
shared path every --interval seconds. sygen-core bind-mounts that file
read-only at /data/host_metrics.json; helpers in rest_routes.py prefer it
over container-local /proc/psutil values, which on macOS only see the VM.

Stdlib-only. Auto-detects macOS vs Linux. Atomic writes (tmp + rename)
so readers never observe a half-written file.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time


def _cpu_percent_macos() -> float:
    """Parse `top -l 1 -n 0` for "CPU usage: X% user, Y% sys, Z% idle"."""
    out = subprocess.run(
        ["/usr/bin/top", "-l", "1", "-n", "0"],
        capture_output=True, text=True, timeout=5,
    ).stdout
    for line in out.splitlines():
        if line.startswith("CPU usage:"):
            # "CPU usage: 4.16% user, 6.25% sys, 89.58% idle"
            try:
                idle = float(line.split(",")[-1].strip().split("%")[0])
                return round(100.0 - idle, 1)
            except (IndexError, ValueError):
                return 0.0
    return 0.0


def _ram_used_macos() -> int:
    """Host RAM used in bytes via vm_stat + sysctl hw.memsize."""
    total = int(subprocess.run(
        ["/usr/sbin/sysctl", "-n", "hw.memsize"],
        capture_output=True, text=True, timeout=5,
    ).stdout.strip() or 0)
    if total <= 0:
        return 0
    vm = subprocess.run(
        ["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5,
    ).stdout
    page_size = 4096
    free_pages = 0
    inactive_pages = 0
    speculative_pages = 0
    for line in vm.splitlines():
        if line.startswith("Mach Virtual Memory Statistics"):
            # "(page size of 16384 bytes)"
            if "page size of" in line:
                try:
                    page_size = int(line.split("page size of")[1].split()[0])
                except (IndexError, ValueError):
                    pass
        elif line.startswith("Pages free:"):
            free_pages = int(line.split(":")[1].strip().rstrip("."))
        elif line.startswith("Pages inactive:"):
            inactive_pages = int(line.split(":")[1].strip().rstrip("."))
        elif line.startswith("Pages speculative:"):
            speculative_pages = int(line.split(":")[1].strip().rstrip("."))
    avail = (free_pages + inactive_pages + speculative_pages) * page_size
    return max(total - avail, 0)


def _disk_used_macos() -> int:
    """Host disk used in bytes via `df -k /` (1024-byte blocks)."""
    out = subprocess.run(
        ["/bin/df", "-k", "/"], capture_output=True, text=True, timeout=5,
    ).stdout
    lines = out.strip().splitlines()
    if len(lines) < 2:
        return 0
    parts = lines[1].split()
    if len(parts) < 3:
        return 0
    try:
        return int(parts[2]) * 1024
    except ValueError:
        return 0


def _cpu_percent_linux(prev: list[tuple[int, int]]) -> float:
    """Compute CPU% from /proc/stat delta. ``prev`` is a 1-element list
    used as mutable state across calls.
    """
    with open("/proc/stat") as f:
        line = f.readline()
    parts = line.split()
    idle = int(parts[4])
    total = sum(int(p) for p in parts[1:])
    if not prev:
        prev.append((idle, total))
        return 0.0
    prev_idle, prev_total = prev[0]
    prev[0] = (idle, total)
    d_total = total - prev_total
    d_idle = idle - prev_idle
    if d_total == 0:
        return 0.0
    return round((1 - d_idle / d_total) * 100, 1)


def _ram_used_linux() -> int:
    """Host RAM used in bytes via /proc/meminfo (MemTotal - MemAvailable)."""
    info: dict[str, int] = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if parts[0].rstrip(":") in ("MemTotal", "MemAvailable"):
                info[parts[0].rstrip(":")] = int(parts[1]) * 1024  # kB → B
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", 0)
    return max(total - avail, 0)


def _disk_used_linux() -> int:
    return shutil.disk_usage("/").used


def _atomic_write(path: str, payload: dict) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, separators=(",", ":"))
    os.rename(tmp, path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Sygen host-metrics daemon")
    parser.add_argument("--output", required=True, help="Path to write JSON")
    parser.add_argument("--interval", type=float, default=10.0,
                        help="Seconds between writes (default 10)")
    args = parser.parse_args()

    is_macos = sys.platform == "darwin"
    cpu_state: list[tuple[int, int]] = []  # Linux-only delta cache

    while True:
        try:
            if is_macos:
                payload = {
                    "ts": time.time(),
                    "cpu_percent": _cpu_percent_macos(),
                    "ram_used_bytes": _ram_used_macos(),
                    "disk_used_bytes": _disk_used_macos(),
                }
            else:
                payload = {
                    "ts": time.time(),
                    "cpu_percent": _cpu_percent_linux(cpu_state),
                    "ram_used_bytes": _ram_used_linux(),
                    "disk_used_bytes": _disk_used_linux(),
                }
            _atomic_write(args.output, payload)
        except Exception as exc:
            print(f"host_metrics_daemon: error: {exc}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
