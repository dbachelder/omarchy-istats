#!/usr/bin/env python3
"""Streaming system telemetry for the dan.istats Omarchy bar widget.

Reads /proc and sysfs directly (no third-party modules) and prints one compact
JSON object per tick on stdout, flushed, so the QML side can consume it with a
SplitParser. GPU fields come from nvidia-smi when an NVIDIA card is present and
degrade to null otherwise. Every section is independently guarded: one missing
file must not take the whole stream down.
"""

import argparse
import json
import os
import subprocess
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK")
CPU_COUNT = os.cpu_count() or 1

NV_SMI = [
    "nvidia-smi",
    "--query-gpu=name,utilization.gpu,utilization.memory,memory.used,memory.total,"
    "temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,fan.speed",
    "--format=csv,noheader,nounits",
]


def read(path, default=None):
    try:
        with open(path) as handle:
            return handle.read()
    except OSError:
        return default


def read_int(path, default=None):
    raw = read(path)
    if raw is None:
        return default
    try:
        return int(raw.strip())
    except ValueError:
        return default


# --------------------------------------------------------------------- CPU
def cpu_times():
    """Return (total_ticks, {core: (active, total)}) from /proc/stat."""
    raw = read("/proc/stat", "")
    overall = None
    cores = {}
    for line in raw.splitlines():
        if not line.startswith("cpu"):
            break
        parts = line.split()
        if parts[0] == "cpu":
            values = [int(v) for v in parts[1:]]
            overall = (sum(values) - values[3] - values[4], sum(values))
        elif parts[0][3:].isdigit():
            values = [int(v) for v in parts[1:]]
            cores[int(parts[0][3:])] = (sum(values) - values[3] - values[4], sum(values))
    return overall, cores


def cpu_breakdown():
    """Cumulative (user, system, idle) ticks from the aggregate cpu line."""
    parts = read("/proc/stat", "").splitlines()
    if not parts:
        return None
    values = [int(v) for v in parts[0].split()[1:]]
    if len(values) < 8:
        return None
    user = values[0] + values[1]
    system = values[2] + values[5] + values[6] + values[7]
    idle = values[3] + values[4]
    return user, system, idle


def cpu_freq_ghz():
    freqs = []
    base = "/sys/devices/system/cpu"
    try:
        for name in os.listdir(base):
            if not name.startswith("cpu") or not name[3:].isdigit():
                continue
            khz = read_int(f"{base}/{name}/cpufreq/scaling_cur_freq")
            if khz:
                freqs.append(khz / 1_000_000)
    except OSError:
        pass
    if freqs:
        return round(sum(freqs) / len(freqs), 2)
    # Fallback: /proc/cpuinfo "cpu MHz".
    mhz = []
    for line in read("/proc/cpuinfo", "").splitlines():
        if line.startswith("cpu MHz"):
            try:
                mhz.append(float(line.split(":", 1)[1].strip()))
            except (ValueError, IndexError):
                pass
    return round(sum(mhz) / len(mhz) / 1000, 2) if mhz else None


def hwmon_value(driver, prefer_labels=("tctl", "tdie", "temp1")):
    base = "/sys/class/hwmon"
    try:
        entries = os.listdir(base)
    except OSError:
        return None
    for entry in entries:
        if read(f"{base}/{entry}/name", "").strip() != driver:
            continue
        for label in prefer_labels:
            if label.startswith("temp"):
                raw = read_int(f"{base}/{entry}/{label}_input")
                if raw:
                    return round(raw / 1000, 1)
            else:
                for try_label in (label, "Tctl", "Tdie"):
                    label_path = f"{base}/{entry}/temp1_label"
                    if read(label_path, "").strip().lower() == try_label.lower():
                        raw = read_int(f"{base}/{entry}/temp1_input")
                        if raw:
                            return round(raw / 1000, 1)
        raw = read_int(f"{base}/{entry}/temp1_input")
        if raw:
            return round(raw / 1000, 1)
    return None


# ------------------------------------------------------------------- MEMORY
def memory():
    info = {}
    for line in read("/proc/meminfo", "").splitlines():
        key, _, rest = line.partition(":")
        value = rest.strip().split()[0] if rest.strip() else "0"
        try:
            info[key] = int(value) * 1024
        except ValueError:
            info[key] = 0
    total = info.get("MemTotal", 0)
    available = info.get("MemAvailable", info.get("MemFree", 0))
    used = max(total - available, 0)
    swap_total = info.get("SwapTotal", 0)
    swap_used = max(swap_total - info.get("SwapFree", 0), 0)
    return {
        "total": total,
        "used": used,
        "available": available,
        "pct": round(used / total * 100, 1) if total else 0.0,
        "swap_total": swap_total,
        "swap_used": swap_used,
    }


# -------------------------------------------------------------------- DISK
_ROOT_DEVICE = None


def root_device():
    global _ROOT_DEVICE
    if _ROOT_DEVICE is not None:
        return _ROOT_DEVICE
    _ROOT_DEVICE = ""
    try:
        with open("/proc/self/mountinfo") as handle:
            best = None
            for line in handle:
                fields = line.split()
                if len(fields) < 10:
                    continue
                mount = fields[4]
                if mount != "/":
                    continue
                source = fields[9]
                best = os.path.basename(source)
            _ROOT_DEVICE = best or ""
    except OSError:
        pass
    return _ROOT_DEVICE


_DISK_BASE = None


def disk_io():
    """Bytes read/written per second for the device backing /."""
    global _DISK_BASE
    device = root_device()
    if not device:
        return None, None
    # Resolve a partition (nvme0n1p2) to its parent disk (nvme0n1).
    parent = device.rstrip("0123456789").rstrip("p") if "nvme" in device else device.rstrip("0123456789")
    candidates = {device, parent}
    stats = {}
    for line in read("/proc/diskstats", "").splitlines():
        fields = line.split()
        if len(fields) < 14:
            continue
        name = fields[2]
        if name in candidates:
            sectors_read = int(fields[5])
            sectors_written = int(fields[9])
            stats[name] = (sectors_read * 512, sectors_written * 512)
    if device in stats:
        current = stats[device]
        current_name = device
    elif parent in stats:
        current = stats[parent]
        current_name = parent
    else:
        return None, None
    now = time.monotonic()
    if _DISK_BASE is None or _DISK_BASE[0] != current_name:
        _DISK_BASE = (current_name, now, current)
        return 0.0, 0.0
    _, then, previous = _DISK_BASE
    elapsed = max(now - then, 1e-3)
    read_bps = max(current[0] - previous[0], 0) / elapsed
    write_bps = max(current[1] - previous[1], 0) / elapsed
    _DISK_BASE = (current_name, now, current)
    return round(read_bps), round(write_bps)


def disk_usage(mountpoint="/"):
    try:
        stat = os.statvfs(mountpoint)
    except OSError:
        return None
    total = stat.f_blocks * stat.f_frsize
    free = stat.f_bavail * stat.f_frsize
    used = total - free
    return {
        "mount": mountpoint,
        "total": total,
        "used": used,
        "free": free,
        "pct": round(used / total * 100, 1) if total else 0.0,
    }


# ----------------------------------------------------------------- NETWORK
_NET_BASE = {}


def default_iface():
    for line in read("/proc/net/route", "").splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "00000000":
            return fields[0]
    return ""


def interface_stats():
    """Throughput for the default-route interface, falling back to the busiest."""
    raw = read("/proc/net/dev", "")
    now = time.monotonic()
    samples = {}
    for line in raw.splitlines()[2:]:
        name, _, rest = line.partition(":")
        name = name.strip()
        if name == "lo":
            continue
        fields = rest.split()
        if len(fields) < 9:
            continue
        samples[name] = (int(fields[0]), int(fields[8]))

    preferred = default_iface()
    order = ([preferred] if preferred in samples else []) + [
        n for n in samples if n != preferred
    ]
    best = None
    for name in order:
        rx, tx = samples[name]
        previous = _NET_BASE.get(name)
        _NET_BASE[name] = (now, rx, tx)
        if previous is None:
            continue
        elapsed = max(now - previous[0], 1e-3)
        down = max(rx - previous[1], 0) / elapsed
        up = max(tx - previous[2], 0) / elapsed
        if name == preferred:
            return name, round(down), round(up), rx, tx
        if best is None or down + up > best[1] + best[2]:
            best = (name, round(down), round(up), rx, tx)
    if best:
        return best
    name = preferred or (next(iter(samples), ""))
    rx, tx = samples.get(name, (0, 0))
    return name, 0, 0, rx, tx


# --------------------------------------------------------------------- GPU
def nvidia_gpus():
    try:
        result = subprocess.run(
            NV_SMI, capture_output=True, text=True, timeout=2, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    gpus = []
    for line in result.stdout.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 11:
            continue

        def number(value, cast=float):
            try:
                return cast(value)
            except (TypeError, ValueError):
                return None

        mem_used = number(parts[3], float)
        mem_total = number(parts[4], float)
        gpus.append(
            {
                "vendor": "nvidia",
                "name": parts[0],
                "util": number(parts[1]),
                "mem_util": number(parts[2]),
                "mem_used": int(mem_used * 1024 * 1024) if mem_used is not None else None,
                "mem_total": int(mem_total * 1024 * 1024) if mem_total is not None else None,
                "temp": number(parts[5], float),
                "power": number(parts[6], float),
                "power_limit": number(parts[7], float),
                "clock_mhz": number(parts[8], float),
                "mem_clock_mhz": number(parts[9], float),
                "fan_pct": number(parts[10], float),
            }
        )
    return gpus


# ---------------------------------------------------------------- PROCESSES
_PROC_BASE = {}
_BOOT_WALL = time.time() - float((read("/proc/uptime", "0") or "0").split()[0])


def processes(limit=12):
    """Return (top-by-cpu, top-by-memory) process lists.

    CPU needs a delta between ticks, so the first frame only ever has memory
    data; memory is an absolute RSS read and needs no history.
    """
    now = time.monotonic()
    total_elapsed = now - _PROC_BASE.get("_time", now)
    if total_elapsed <= 0:
        total_elapsed = 1e-3
    page_size = os.sysconf("SC_PAGE_SIZE")
    seen = set()
    rows = []
    try:
        pids = [n for n in os.listdir("/proc") if n.isdigit()]
    except OSError:
        return [], []
    for pid in pids:
        stat = read(f"/proc/{pid}/stat")
        if not stat:
            continue
        close = stat.rfind(")")
        if close < 0:
            continue
        name = stat[stat.find("(") + 1 : close]
        fields = stat[close + 2 :].split()
        if len(fields) < 22:
            continue
        try:
            utime = int(fields[11])
            stime = int(fields[12])
            rss_pages = int(fields[21])
        except (ValueError, IndexError):
            continue
        ticks = utime + stime
        seen.add(pid)
        previous = _PROC_BASE.get(pid)
        cpu_pct = 0.0
        if previous is not None:
            cpu_pct = (ticks - previous) / CLK_TCK / total_elapsed / CPU_COUNT * 100
        rows.append(
            {
                "pid": int(pid),
                "name": name,
                "cpu": round(cpu_pct, 1),
                "mem": max(0, rss_pages) * page_size,
            }
        )
        _PROC_BASE[pid] = ticks
    for pid in list(_PROC_BASE):
        if pid != "_time" and pid not in seen:
            _PROC_BASE.pop(pid, None)
    _PROC_BASE["_time"] = now
    by_cpu = sorted(
        [row for row in rows if row["cpu"] > 0.05], key=lambda row: row["cpu"], reverse=True
    )[:limit]
    by_mem = sorted(rows, key=lambda row: row["mem"], reverse=True)[:limit]
    return by_cpu, by_mem


# ------------------------------------------------------------------- ASSEMBLY
def snapshot(previous):
    overall, cores = cpu_times()
    cpu = {"freq_ghz": cpu_freq_ghz(), "temp": hwmon_value("k10temp")}
    if overall and previous.get("cpu_overall"):
        active_delta = overall[0] - previous["cpu_overall"][0]
        total_delta = overall[1] - previous["cpu_overall"][1]
        if total_delta > 0:
            cpu["total"] = round(active_delta / total_delta * 100, 1)
            cpu["idle"] = round(100 - cpu["total"], 1)
        prev_cores = previous.get("cpu_cores", {})
        core_pct = []
        for index in sorted(cores):
            previous_core = prev_cores.get(index)
            if not previous_core:
                core_pct.append(0.0)
                continue
            active = cores[index][0] - previous_core[0]
            total = cores[index][1] - previous_core[1]
            core_pct.append(round(active / total * 100, 0) if total > 0 else 0.0)
        cpu["cores"] = core_pct
    else:
        cpu["total"] = 0.0
        cpu["idle"] = 100.0
        cpu["cores"] = [0.0 for _ in cores]
    previous["cpu_overall"] = overall
    previous["cpu_cores"] = cores

    breakdown = cpu_breakdown()
    if breakdown and previous.get("cpu_break"):
        user_delta = breakdown[0] - previous["cpu_break"][0]
        system_delta = breakdown[1] - previous["cpu_break"][1]
        idle_delta = breakdown[2] - previous["cpu_break"][2]
        span = user_delta + system_delta + idle_delta
        if span > 0:
            cpu["user"] = round(user_delta / span * 100, 1)
            cpu["system"] = round(system_delta / span * 100, 1)
    if "user" not in cpu:
        cpu["user"] = cpu.get("total", 0.0)
        cpu["system"] = 0.0
    previous["cpu_break"] = breakdown

    read_bps, write_bps = disk_io()
    name, down, up, rx, tx = interface_stats()
    gpus = nvidia_gpus()
    procs_cpu, procs_mem = processes()
    uptime = float((read("/proc/uptime", "0") or "0").split()[0] or 0)
    try:
        load = [round(float(v), 2) for v in read("/proc/loadavg", "").split()[:3]]
    except ValueError:
        load = [0.0, 0.0, 0.0]

    return {
        "t": int(time.time() * 1000),
        "cpu": cpu,
        "mem": memory(),
        "disk": {"root": disk_usage("/"), "read_bps": read_bps, "write_bps": write_bps},
        "net": {"iface": name, "down_bps": down, "up_bps": up, "rx_total": rx, "tx_total": tx},
        "gpus": gpus,
        "procs": procs_cpu,
        "procs_mem": procs_mem,
        "load": load,
        "uptime": uptime,
        "cores": CPU_COUNT,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    previous = {}
    # Prime the deltas so the first emitted frame already carries real rates.
    snapshot(previous)
    time.sleep(min(args.interval, 0.6))
    while True:
        try:
            payload = snapshot(previous)
            sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except Exception as error:  # keep the stream alive no matter what
            sys.stdout.write(json.dumps({"error": str(error)}) + "\n")
            sys.stdout.flush()
        if args.once:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
