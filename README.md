# Lightweight Hardware Monitor

A minimal Windows console monitor designed specifically for **LLM inference monitoring** (VRAM + system feed). It reads the same performance counters as Task Manager and displays them in a compact, real-time frame. Double-click `monitor.bat` or run the PowerShell script directly.

## Requirements

- **Windows 10 or later**
- **PowerShell 5.1+** (built into Windows)
- **Optional: NVIDIA driver with `nvidia-smi`** — required for GPU temperature, VRAM usage/total, power draw, and accurate GPU name detection. On non-NVIDIA systems, GPU compute falls back to WMI 3D-engine utilization counters.

## Quick Start

```bat
:: From Command Prompt — just double-click or run:
monitor.bat

:: From PowerShell:
.\monitor.ps1
.\monitor.ps1 -IntervalSeconds 2
.\monitor.ps1 -IntervalSeconds 0.5 -NoColor
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-IntervalSeconds` | `1` | Refresh interval in seconds (minimum `0.5`) |
| `-NoColor` | off | Disable colored usage thresholds |

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

| Line | Data Source | Notes |
|------|-------------|-------|
| **CPU Usage** | `\Processor(_Total)\% Processor Time` | Includes a warm-up sample on first run for accurate readings |
| **System RAM** | `Win32_OperatingSystem` (cached total) | Shows Used / Total / Free in GB; total refreshed every 30s |
| **GPU Compute** | `\GPU Engine(*engtype_3D)\Utilization Percentage` | Summed across all 3D engines, capped at 100%. Falls back to `nvidia-smi` utilization when NVIDIA GPU detected |
| **GPU Temp** | `nvidia-smi --query-gpu=temperature.gpu` | Shows `N/A` on non-NVIDIA GPUs |
| **GPU Power** | `nvidia-smi --query-gpu=power.draw` | Shows `N/A` on non-NVIDIA GPUs |
| **VRAM Used/Free/Total** | `nvidia-smi --query-gpu=memory.used,free,total` | In GB, 2 decimal precision. Shows `0` on non-NVIDIA systems |
| **VRAM % Used** | Calculated from nvidia-smi memory values | Percentage of dedicated VRAM consumed |
| **VRAM Mem Util** | `nvidia-smi --query-gpu=utilization.memory` | Memory bus utilization percentage |
| **Shared GPU RAM** | `\GPU Adapter Memory(*)\Shared Usage` + Shared Limit counter | Shows used / limit in GB; falls back to "no limit counter" message |
| **RAM for Offload** | Free RAM − 8 GB OS reserve | Rough guide for how much system RAM is available for CPU-offloaded LLM layers |
| **Disk Read/Write** | `\PhysicalDisk(_Total)\Disk Read/Write Bytes/sec` | Aggregate across all physical disks, formatted as MB/s or KB/s |
| **Network** | `\Network Interface(*)\Bytes Total/sec` | Excludes loopback, ISATAP, Teredo, QoS, pseudo, kernel, Hyper-V, VMware, and VirtualBox interfaces |

## File Structure

| File | Purpose |
|------|---------|
| `monitor.bat` | Launcher — sets console window to 80×26, invokes PowerShell with `-NoProfile -ExecutionPolicy Bypass` |
| `monitor.ps1` | Full monitoring logic — counter collection, frame formatting, ANSI color support, nvidia-smi integration |

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
| `Format-Frame` | Builds the 24-line ASCII frame string |
| `Show-Frame` | Writes frame to console, clears leftover lines from previous longer frame, positions cursor below |

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
