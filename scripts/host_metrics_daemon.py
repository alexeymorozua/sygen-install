#!/usr/bin/env python3
"""Host metrics bridge for sygen-core (Docker on macOS Colima / Linux).

Writes a JSON snapshot of the *host's* CPU%, RAM (used + total), and disk
(used + total) to a shared path every --interval seconds. sygen-core
bind-mounts the PARENT DIRECTORY read-only at /data/host_metrics; the
daemon writes ``state.json`` inside it atomically (tmp + rename). The
directory mount is required because Colima freezes the container inode
of a single-file bind mount at container start, so atomic renames on
the host leave the container reading an orphan inode (v1.6.32 fix).
Helpers in rest_routes.py prefer these values over container-local
/proc/psutil values, which on macOS only see the VM.

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


def _ram_macos() -> tuple[int, int]:
    """Host RAM (used, total) bytes via vm_stat + sysctl hw.memsize."""
    total = int(subprocess.run(
        ["/usr/sbin/sysctl", "-n", "hw.memsize"],
        capture_output=True, text=True, timeout=5,
    ).stdout.strip() or 0)
    if total <= 0:
        return (0, 0)
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
    return (max(total - avail, 0), total)


def _disk_macos() -> tuple[int, int]:
    """Host disk (used, total) bytes.

    On modern macOS (APFS) the boot volume is split into a sealed read-only
    system volume mounted at ``/`` (~12 GB) and a writable data volume at
    ``/System/Volumes/Data`` (where /Users lives — typically hundreds of GB).
    The user-meaningful "disk used" is the data volume; ``df /`` would only
    report system files. Fall back to ``/`` if the Data path is missing
    (Intel Macs on older macOS, or unusual setups).
    """
    target = "/System/Volumes/Data" if os.path.exists("/System/Volumes/Data") else "/"
    out = subprocess.run(
        ["/bin/df", "-k", target], capture_output=True, text=True, timeout=5,
    ).stdout
    lines = out.strip().splitlines()
    if len(lines) < 2:
        return (0, 0)
    parts = lines[1].split()
    if len(parts) < 4:
        return (0, 0)
    try:
        # df -k columns: Filesystem  1024-blocks  Used  Available  ...
        total = int(parts[1]) * 1024
        used = int(parts[2]) * 1024
        return (used, total)
    except ValueError:
        return (0, 0)


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


def _ram_linux() -> tuple[int, int]:
    """Host RAM (used, total) bytes via /proc/meminfo."""
    info: dict[str, int] = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if parts[0].rstrip(":") in ("MemTotal", "MemAvailable"):
                info[parts[0].rstrip(":")] = int(parts[1]) * 1024  # kB → B
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", 0)
    return (max(total - avail, 0), total)


def _disk_linux() -> tuple[int, int]:
    du = shutil.disk_usage("/")
    return (du.used, du.total)


def _atomic_write(path: str, payload: dict) -> None:
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
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
                ram_used, ram_total = _ram_macos()
                disk_used, disk_total = _disk_macos()
                cpu_pct = _cpu_percent_macos()
            else:
                ram_used, ram_total = _ram_linux()
                disk_used, disk_total = _disk_linux()
                cpu_pct = _cpu_percent_linux(cpu_state)
            payload = {
                "ts": time.time(),
                "cpu_percent": cpu_pct,
                "ram_used_bytes": ram_used,
                "ram_total_bytes": ram_total,
                "disk_used_bytes": disk_used,
                "disk_total_bytes": disk_total,
            }
            _atomic_write(args.output, payload)
        except Exception as exc:
            print(f"host_metrics_daemon: error: {exc}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
