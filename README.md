# monitorcmd — 0 VRAM System Monitor for LLM Inference

> **Zero VRAM overhead.** A lightweight Windows console monitor that uses **0 MB of VRAM** to track VRAM, GPU, and system resources in real-time — purpose-built for LLM inference optimization.

Double-click `monitor.bat` and watch your GPU metrics without stealing the very resource you're trying to measure.

## Why 0 VRAM Matters

When running LLM inference, every megabyte of VRAM counts. Most monitoring tools (Task Manager GPU tab, HWInfo, MSI Afterburner OSD, etc.) consume GPU memory just to display metrics — which is exactly what you're trying to optimize.

**monitorcmd uses pure Windows Performance Counters and `nvidia-smi` CLI queries.** No GPU rendering, no overlays, no DirectX hooks. Just a text console reading the same counters the OS already collects. **VRAM impact: 0 MB.**

## What It Monitors

| Category | Metrics |
|----------|---------|
| **VRAM** | Used / Free / Total, % Used, Memory Bus Utilization, Shared GPU RAM |
| **GPU** | Compute utilization, Temperature, Power draw |
| **System** | CPU usage, RAM (Used/Total/Free), RAM available for CPU offload |
| **I/O** | Disk read/write throughput, Network throughput |

### LLM-Specific Insights

- **RAM for Offload** — Free system RAM minus an 8 GB OS reserve, giving you a rough guide for how many CPU-offloaded LLM layers you can fit
- **VRAM % Used** — Instant visibility into how much dedicated VRAM your model is consuming
- **Shared GPU RAM** — Tracks shared memory usage (useful for models that spill beyond dedicated VRAM)

## Requirements

- **Windows 10 or later**
- **PowerShell 5.1+** (built into Windows)
- **Optional: NVIDIA driver with `nvidia-smi`** — required for GPU temperature, VRAM usage/total, power draw, and accurate GPU name detection. On non-NVIDIA systems, GPU compute falls back to WMI 3D-engine utilization counters.
- **Python version (optional):** Python 3.7+ with `psutil` (`pip install psutil`) for fallback metrics when performance counters are unavailable.

## Quick Start

```bat
:: From Command Prompt — just double-click or run:
monitor.bat

:: From PowerShell:
.\monitor.ps1
.\monitor.ps1 -IntervalSeconds 2
.\monitor.ps1 -IntervalSeconds 0.5 -NoColor

:: From Python:
python monitor.py
python monitor.py --interval-seconds 2
python monitor.py --interval-seconds 0.5 --no-color
```

### PowerShell Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-IntervalSeconds` | `1` | Refresh interval in seconds (minimum `0.5`) |
| `-NoColor` | off | Disable ANSI escape sequences |

### Python Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--interval-seconds` | `1.0` | Refresh interval in seconds (minimum `0.5`) |
| `--no-color` | off | Disable ANSI escape sequences |

Press **Ctrl+C** to exit.

## Display Layout

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

## Metrics Explained

| Line | Primary Data Source | Fallback (when counters fail) | Notes |
|------|-------------|-------------|-------|
| **CPU Usage** | `\Processor(_Total)\% Processor Time` | `Win32_Processor` WMI `LoadPercentage` | Warm-up sample on first run for accuracy |
| **System RAM** | `Win32_OperatingSystem` / `GlobalMemoryStatusEx` | — | Used / Total / Free in GB; total refreshed every 30s |
| **GPU Compute** | `nvidia-smi` utilization.gpu (if available) | `\GPU Engine(*engtype_3D)\Utilization Percentage` | 3D engines summed, capped at 100% |
| **GPU Temp** | `nvidia-smi --query-gpu=temperature.gpu` | — | Shows `N/A` on non-NVIDIA GPUs |
| **GPU Power** | `nvidia-smi --query-gpu=power.draw` | — | Shows `N/A` on non-NVIDIA GPUs |
| **VRAM Used/Free/Total** | `nvidia-smi --query-gpu=memory.used,free,total` | — | In GB, 2 decimal precision; shows `0` on non-NVIDIA systems |
| **VRAM % Used** | Calculated from nvidia-smi memory values | — | Percentage of dedicated VRAM consumed |
| **VRAM Mem Util** | `nvidia-smi --query-gpu=utilization.memory` | — | Memory bus utilization percentage |
| **Shared GPU RAM** | `\GPU Adapter Memory(*)\Shared Usage` + Shared Limit counter | — | Shows used / limit in GB; "no limit counter" if unavailable |
| **RAM for Offload** | Free RAM − 8 GB OS reserve | — | Rough guide for CPU-offloaded LLM layers |
| **Disk Read/Write** | `\PhysicalDisk(_Total)\Disk Read/Write Bytes/sec` | `Win32_PerfFormattedData_PerfDisk_LogicalDisk` WMI | Aggregate across all physical disks, formatted as MB/s or KB/s |
| **Network** | `\Network Interface(*)\Bytes Total/sec` | `Win32_PerfFormattedData_Tcpip_NetworkInterface` WMI | Excludes loopback, ISATAP, Teredo, QoS, pseudo, kernel, Hyper-V, VMware, and VirtualBox interfaces |

## File Structure

| File | Purpose |
|------|---------|
| `monitor.bat` | Launcher — sets console window to 80×26, invokes PowerShell with `-NoProfile -ExecutionPolicy Bypass` |
| `monitor.ps1` | Full monitoring logic — counter collection, frame formatting, ANSI color support, nvidia-smi integration |
| `monitor.py` | Python implementation of the same monitor — uses `typeperf` for counters, `psutil` for fallback metrics |

## Architecture

### Key Functions (`monitor.ps1`)

| Function | Role |
|----------|------|
| `Initialize-Console` | Enables ANSI escape sequences via `kernel32.dll` P/Invoke; sets buffer/window width to 80 |
| `Format-Throughput` | Converts bytes/sec → human-readable (MB/s, KB/s, B/s) |
| `Sum-CounterSamples` | Sums `CookedValue` across multiple counter instances |
| `Get-NvidiaGpuStats` | Parses `nvidia-smi` CSV output into a hashtable (name, memory, temp, power, utilization) |
| `Get-RamTotalGB` | Reads total visible memory from `Win32_OperatingSystem` |
| `Get-SharedVramGB` | Reads shared GPU memory usage and limit from Performance Counters |
| `Get-CounterSamples` | Collects all Performance Counter data in a single poll |
| `Get-SamplesByPath` | Filters counter samples by WMI path pattern |
| `Format-Frame` | Builds the ASCII frame string |
| `Show-Frame` | Writes frame to console, clears leftover lines from previous longer frame, positions cursor below |
| `Test-Counters` | Quick probe of `\Processor(_Total)\% Processor Time` to verify counter health |
| `Try-RepairCounters` | Attempts `lodctr /r` (non-elevated → elevated → from stdcnt.ad) to repair corrupted counters |
| `Get-FallbackMetrics` | WMI-based fallback for CPU, disk, and network when performance counters are unavailable |

### Key Functions (`monitor.py`)

| Function | Role |
|----------|------|
| `enable_ansi()` | Enables VT100/ANSI sequences via `kernel32.dll` `SetConsoleMode` |
| `set_console_size()` | Sets console to 80×26 via `mode con` |
| `run_typeperf()` | Runs `typeperf` CLI and parses CSV output into a dict |
| `get_nvidia_gpu_stats()` | Runs `nvidia-smi` and parses CSV into a dict |
| `get_ram_total_gb()` / `get_ram_free_gb()` | Calls `GlobalMemoryStatusEx` via ctypes |
| `get_shared_vram_gb()` | Reads shared VRAM usage and limit via `typeperf` |
| `test_counters()` / `try_repair_counters()` | Same counter repair logic as PowerShell version |
| `get_fallback_metrics()` | Uses `psutil` for CPU, disk, and network fallback (falls back to sleep if psutil unavailable) |
| `format_frame()` | Builds the ASCII frame string |
| `show_frame()` | Renders frame using ANSI cursor home or full clear |

## Resilience

### Performance Counter Repair

Both the PowerShell and Python versions include automatic counter repair. At startup, the monitor tests `\Processor(_Total)\% Processor Time`. If the test fails, it attempts repair in this order:

1. **`lodctr /r`** — non-elevated rebuild from registry backup
2. **`lodctr /r` (elevated)** — prompts UAC for admin rights
3. **`lodctr /r:<Windows>\System32\stdcnt.ad`** — rebuild from the .ad template file

If all repairs fail, the monitor falls back to WMI metrics (PowerShell) or `psutil` (Python).

### Fallback Metrics

When performance counters are unavailable, the monitor gracefully degrades:

| Metric | PowerShell Fallback | Python Fallback |
|--------|-------------------|----------------|
| CPU | `Win32_Processor` WMI `LoadPercentage` | `psutil.cpu_percent()` |
| Disk | `Win32_PerfFormattedData_PerfDisk_LogicalDisk` | `psutil.disk_io_counters()` |
| Network | `Win32_PerfFormattedData_Tcpip_NetworkInterface` | `psutil.net_io_counters()` |
| GPU | — (shows 0%) | — (shows 0%) |

GPU metrics (temperature, power, VRAM) require `nvidia-smi` and have no fallback.

### Counter Recovery During Runtime

If counters fail during operation, the monitor periodically re-tests (every 30 seconds) and automatically resumes counter-based metrics when they recover.

## Tips

- **Faster refresh:** Use `-IntervalSeconds 0.5` for half-second updates (minimum). The counter sample interval is capped at 1 second internally; the remaining time is slept.
- **No NVIDIA GPU:** The monitor will still show CPU, RAM, disk, and network metrics. GPU fields will show `N/A` or `0`.
- **Counter corruption:** Common after Windows updates or third-party monitoring tools. The auto-repair usually fixes it. If not, run `lodctr /r` manually as Administrator.
- **Python without psutil:** The Python version works without `psutil`, but fallback metrics will show zeros. Install with `pip install psutil` for full functionality.
- **Running alongside LLM inference:** Since monitorcmd uses 0 VRAM, you can run it in a separate console window while your LLM server (Ollama, llama.cpp, vLLM, etc.) is active — it won't impact your available VRAM or inference performance.

### Execution Flow

```
1. Parse parameters (IntervalSeconds, NoColor)
2. Initialize console (ANSI support, window size)
3. Cache static values (RAM total, initial nvidia-smi stats)
4. Warm-up sample: read CPU counter once (1s) for accurate first reading
5. Main loop (infinite, Ctrl+C to exit):
   a. Every 30s: refresh RAM total from WMI
   b. Poll Performance Counters (interval = min(1, IntervalSeconds))
   c. Parse CPU, GPU compute, disk, network samples
   d. Query nvidia-smi for GPU/VRAM stats
   e. Query shared VRAM counters
   f. Calculate offload headroom (free RAM − 8 GB)
   g. Format and display frame
   h. Sleep remaining time to hit target interval
```

### Script-Level Variables

| Variable | Purpose |
|----------|---------|
| `$script:ConsoleWidth` | Fixed at 80 characters |
| `$script:FrameDrawn` | Tracks whether a frame has been rendered (for cursor positioning) |
| `$script:UseAnsi` | Whether ANSI escape sequences were successfully enabled |
| `$script:CounterWarning` | Cached warning message if performance counters fail |
| `$script:HasNvidiaSmi` | Boolean: is `nvidia-smi` on PATH? |
| `$script:GpuName` | Cached GPU name from nvidia-smi |
| `$script:FrameLines` | Number of lines in the last rendered frame (for cleanup) |

## Error Handling & Edge Cases

| Scenario | Behavior |
|----------|----------|
| No NVIDIA GPU | GPU compute from WMI 3D-engine counter; VRAM/temp/power show `0` or `N/A` |
| `nvidia-smi` not found | Skipped gracefully; all other metrics still work |
| Performance counters unavailable | Warning message displayed; metrics show `0` |
| Console window too narrow | Buffer/window forced to 80 cols; content is right-padded |
| Previous frame longer than current | Extra lines cleared with spaces after each refresh |
| Ctrl+C during sleep | `finally` block restores cursor visibility and prints "Exiting..." |

## Design Decisions

1. **VRAM-focused display** — optimized for LLM inference workflows where VRAM is the primary bottleneck
2. **8 GB OS reserve heuristic** — "RAM for Offload" assumes 8 GB minimum for Windows; adjust this value in the script if needed
3. **Single nvidia-smi call per cycle** — avoids overhead of multiple subprocess invocations
4. **30s RAM total refresh** — total system RAM rarely changes; cached to reduce WMI calls
5. **Warm-up CPU sample** — first `% Processor Time` reading is always 0% on Windows; a dummy poll ensures accurate first display
6. **No external dependencies** — pure PowerShell 5.1, no modules to install

## Troubleshooting

| Issue | Fix |
|-------|-----|
| All metrics show 0 | Run PowerShell as Administrator; Performance Counters may require elevated privileges |
| "Performance counters unavailable" warning | Run `lodctr /r` from an elevated command prompt to rebuild counter registry |
| GPU stats not showing | Ensure NVIDIA driver is installed and `nvidia-smi` works in a standalone terminal |
| Text appears cut off | Increase console window width to ≥80 characters |
| Colors not showing | Your terminal may not support ANSI; use `-NoColor` or upgrade to Windows Terminal |
