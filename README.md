# iStats for Omarchy

An [iStat Menus](https://bjango.com/mac/istatmenus/)-shaped system monitor for the
Omarchy bar. Five readings live in the bar, each one its own click target, and the
dropdown opens focused on whichever reading you clicked.

![iStats dropdown showing the CPU, processes, GPU, memory, disk, network, load and uptime cards](preview.png)

## What it shows

**In the bar**

- Network — live download / upload rate
- CPU — utilisation with a meter
- GPU — utilisation with a meter
- MEM — used percentage with a meter
- SSD — root filesystem usage with a meter

**In the dropdown**

| Card | Contents |
|------|----------|
| CPU | frequency, package temperature, user/system history, a ring per logical thread, thread count |
| Processes | top processes by CPU, or by memory when memory is focused |
| GPU | utilisation, VRAM, temperature and clock dials, VRAM total and power draw (NVIDIA); utilisation and clock on Intel, with shared memory |
| Memory | used percentage, history, total / free / swap |
| Disk | root filesystem usage, free space, read/write history |
| Network | download and upload graphs (independently scaled), interface and lifetime totals |
| Load | 1 / 5 / 15 minute load average |
| Uptime | time since boot |

## Click behaviour

Clicking a reading opens the dashboard with that domain first and highlighted, so
the number you pointed at is the one explained. Clicking the same reading again
closes the panel.

| Click | Opens with |
|-------|------------|
| Network | NETWORK first |
| CPU | CPU first, then CPU HOGS |
| GPU | GPU first |
| MEM | MEMORY first, then MEMORY HOGS |
| SSD | DISK first |
| anywhere else | neutral overview |

## Dashboard from a keybind

```bash
quickshell ipc -p /usr/share/omarchy/shell call io.github.dbachelder.istats toggle
```

Available methods: `open`, `close`, `toggle`, `overview`, `showCpu`, `showGpu`,
`showMem`, `showDisk`, `showNet`, `status`.

## Requirements

- Omarchy with the Quickshell shell (bar widget plugin API).
- `python3` — standard library only; no `psutil`, no `pynvml`, nothing to install.
- Linux `/proc` and `/sys`.
- Optional, for the GPU card and the GPU bar reading (everything else works without it):
  - an NVIDIA GPU with `nvidia-smi` on `PATH`, or
  - an Intel GPU using the `i915` or `xe` driver (no extra tools needed).

## Install

```bash
omarchy plugin add https://github.com/dbachelder/omarchy-istats.git --enable
```

`--enable` places the widget in its default section (right). To move it:

```bash
omarchy bar put io.github.dbachelder.istats --section right
```

## Remove

```bash
omarchy plugin remove io.github.dbachelder.istats
```

Removing the plugin stops the collector process with the widget; no service, timer
or file is left behind.

## Configuration

Settings are inline on the widget's `shell.json` entry. Set them with
`omarchy bar set`:

```bash
omarchy bar set io.github.dbachelder.istats showGpu false
omarchy bar set io.github.dbachelder.istats processCount 10
```

| Key | Default | Meaning |
|-----|---------|---------|
| `intervalSec` | `1` | Collector sample interval, in seconds (1–10) |
| `colorful` | `true` | Use the theme's accent palette; `false` uses the theme accent only |
| `showNet` | `true` | Show the network reading in the bar |
| `showCpu` | `true` | Show the CPU reading in the bar |
| `showGpu` | `true` | Show the GPU reading in the bar |
| `showMem` | `true` | Show the memory reading in the bar |
| `showSsd` | `true` | Show the disk reading in the bar |
| `processCount` | `6` | Rows in the process table (3–12) |

Colours follow the active Omarchy theme; the widget re-reads the theme palette when
you switch themes, so there is nothing to configure for it to look native.

## How it works

The widget starts one long-lived helper process:

```bash
python3 collector/istats_collector.py --interval 1
```

It prints a single compact JSON frame per tick on stdout, which the QML reads with
a `SplitParser`. There is no daemon, no systemd unit, no socket and no database;
the helper's lifetime is the widget's lifetime. History for the graphs is kept in
the shell process as a 60-sample ring buffer.

The collector only reads:

- `/proc/stat`, `/proc/meminfo`, `/proc/loadavg`, `/proc/uptime`, `/proc/net/dev`,
  `/proc/net/route`, `/proc/diskstats`, `/proc/self/mountinfo`, `/proc/<pid>/stat`
- `/sys/class/hwmon/*`, `/sys/devices/system/cpu/*/cpufreq/*`
- `nvidia-smi --query-gpu=...` when an NVIDIA GPU is present
- On Intel GPUs: `/sys/class/drm/card*/gt_*_freq_mhz` for the clock and
  `/proc/<pid>/fdinfo/*` (DRM engine busy-time) for utilisation, plus a one-off
  `lspci -s <slot> -mm` to look up the device name

## Security and permissions

- Runs entirely as your user. It never elevates privileges, never invokes an
  authentication agent or privileged helper, and never writes to system paths.
- No network access: the plugin makes no requests and downloads nothing.
- It does not modify your `shell.json`; you control every setting.
- The only child processes are the bundled Python collector and, on NVIDIA
  systems, `nvidia-smi` (and a single `lspci` call on Intel systems).

## Known limitations

- Per-process disk, GPU and network usage is not available without extra
  privileges, so DISK, GPU and NETWORK focus show the domain card plus the
  CPU-sorted process list rather than a domain-specific hog list. CPU and memory
  hog lists are exact.
- The memory hog list includes kernel threads, which can outrank user processes.
- GPU readings are supported for NVIDIA (via `nvidia-smi`) and Intel (`i915`/`xe`).
  AMD telemetry is not implemented yet.
- Intel GPU utilisation is the busiest engine (render, video, ...) summed across
  your own processes' DRM fdinfo counters. The hardware PMU that `intel_gpu_top`
  uses needs elevated privileges, so work done by other users' processes is not
  counted. Intel GPUs report no VRAM (shared memory), temperature or power, so
  those show `--`. The clock falls back to the requested frequency while the GPU
  sleeps in RC6. The `xe` driver path is untested.

## License

MIT — see [LICENSE](LICENSE).
