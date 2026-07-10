# monitorcmd — 0 VRAM System Monitor for LLM Inference

> **Zero VRAM overhead.** A lightweight Windows console monitor that uses **0 MB of VRAM** to track GPU and system resources in real-time — purpose-built for LLM inference optimization.

Run `python monitor.py` and watch your GPU metrics without stealing the very resource you're trying to measure.

## Why 0 VRAM Matters

When running LLM inference, every megabyte of VRAM counts. Most monitoring tools (Task Manager GPU tab, HWInfo, MSI Afterburner, etc.) consume GPU memory just to display metrics — which is exactly what you're trying to optimize.

**monitorcmd uses Windows Performance Counters and `nvidia-smi` CLI queries.** No GPU rendering, no overlays, no DirectX hooks. Just a text console reading the same counters the OS already collects. **VRAM impact: 0 MB.**

## What It Monitors

| Category | Metrics |
|----------|---------|
| **VRAM** | Used / Free / Total, % Used, Memory Bus Utilization, Shared GPU RAM |
| **GPU** | Compute utilization, Temperature, Power draw |
| **System** | CPU usage, RAM (Used/Total/Free), RAM available for CPU offload |
| **I/O** | Disk read/write throughput, Network throughput |

### LLM-Specific Insights

- **RAM for Offload** — Free system RAM minus an 8 GB OS reserve, so you know how many CPU-offloaded LLM layers you can fit
- **VRAM % Used** — Instant visibility into how much dedicated VRAM your model is consuming
- **Shared GPU RAM** — Tracks shared memory usage (useful for models that spill beyond dedicated VRAM)

## Requirements

- **Windows 10 or later**
- **Python 3.7+**
- **Optional:** `psutil` (`pip install psutil`) — used as a fallback when Windows performance counters are unavailable
- **Optional:** NVIDIA driver with `nvidia-smi` — required for GPU temperature, VRAM, and power metrics

## Installation

```bash
git clone https://github.com/yourusername/monitorcmd.git
cd monitorcmd
pip install psutil  # optional, but recommended
```

## Usage

```bash
# Default — refreshes every second
python monitor.py

# Faster refresh (half-second updates)
python monitor.py --interval-seconds 0.5

# Disable colors (for terminals that don't support ANSI)
python monitor.py --no-color
```

| Argument | Default | Description |
|----------|---------|-------------|
| `--interval-seconds` | `1.0` | Refresh interval in seconds (minimum `0.5`) |
| `--no-color` | off | Disable ANSI color codes |

Press **Ctrl+C** to exit.

## Example Output

```
================================================================================
            LLM HARDWARE MONITOR (VRAM + SYSTEM FEED)
NVIDIA GeForce RTX 4090
================================================================================
CPU Usage:          23.4 %
System RAM:         12.8 /  31.5 GB   ( 18.7 GB free)
--------------------------------------------------------------------------------
GPU Compute:        67.2 %
GPU Temp:           72 C
GPU Power:          245 W
--------------------------------------------------------------------------------
VRAM Used:          18.42 GB
VRAM Free:           7.58 GB
VRAM Total:         24.00 GB
VRAM % Used:        76.8 %
VRAM Mem Util:      82.3 %
Shared GPU RAM:      0.12 /   4.0 GB used
RAM for Offload:    10.7 GB free for CPU layers
--------------------------------------------------------------------------------
Disk Read:          45.2 MB/s
Disk Write:         12.8 MB/s
Network:             3.1 MB/s
--------------------------------------------------------------------------------
Updating every 1.0s. Press Ctrl+C to exit.
```

## How It Works

The monitor collects data from three sources:

1. **`typeperf`** — Windows Performance Counters for CPU, disk, network, and GPU compute
2. **`nvidia-smi`** — NVIDIA CLI for VRAM, temperature, power, and memory utilization
3. **`psutil`** — Python library as a fallback when performance counters are unavailable

It runs in a simple loop: poll counters → query GPU → format frame → print to console → sleep → repeat.

## Tips

- **Run alongside your LLM server** — Since monitorcmd uses 0 VRAM, you can run it in a separate console while Ollama, llama.cpp, vLLM, etc. are active without impacting inference
- **Faster refresh** — Use `--interval-seconds 0.5` for half-second updates
- **No NVIDIA GPU?** — CPU, RAM, disk, and network metrics still work; GPU fields will show `N/A` or `0`
- **Counter corruption?** — Common after Windows updates. The monitor will auto-repair, or run `lodctr /r` as Administrator

## Troubleshooting

| Issue | Fix |
|-------|-----|
| All metrics show 0 | Try running as Administrator; performance counters may need elevated privileges |
| "Performance counters unavailable" | Run `lodctr /r` from an elevated command prompt |
| GPU stats not showing | Make sure NVIDIA driver is installed and `nvidia-smi` works in a terminal |
| Text appears cut off | Widen your console window to at least 80 characters |
| Colors not showing | Use `--no-color`, or upgrade to Windows Terminal |
