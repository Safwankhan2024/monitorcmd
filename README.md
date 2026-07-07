# Lightweight Hardware Monitor

A minimal Windows console monitor that reads the same performance counters as Task Manager. Double-click `monitor.bat` or run the PowerShell script directly.

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (built into Windows)
- Optional: NVIDIA driver with `nvidia-smi` for GPU temperature and accurate VRAM totals

## Usage

```bat
monitor.bat
```

Or with options:

```powershell
.\monitor.ps1 -IntervalSeconds 2
.\monitor.ps1 -NoColor
.\monitor.ps1 -IntervalSeconds 0.5 -NoColor
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-IntervalSeconds` | `1` | Refresh interval in seconds (minimum `0.5`) |
| `-NoColor` | off | Disable colored usage thresholds |

Press **Ctrl+C** to exit.

## Metrics

| Line | Source | Notes |
|------|--------|-------|
| CPU | `\Processor(_Total)\% Processor Time` | Warm-up sample for accurate readings |
| RAM | `Win32_OperatingSystem` + cached total | Used / total / free in GB |
| GPU | `\GPU Engine(*engtype_3D)\Utilization Percentage` | Summed across 3D engines, capped at 100% |
| GPU Temp | `nvidia-smi` | Shows `N/A` on non-NVIDIA GPUs |
| VRAM | `\GPU Adapter Memory(*)\Dedicated Usage` | Total from `nvidia-smi`, dedicated limit counter, or WMI `(approx)` |
| Shared VRAM | `\GPU Adapter Memory(*)\Shared Usage` | Limit from shared limit counter or RAM/2 `(est.)` |
| Disk | `\PhysicalDisk(_Total)\Disk Read/Write Bytes/sec` | Aggregate read and write throughput |
| Net | `\Network Interface(*)\Bytes Total/sec` | Excludes loopback and virtual pseudo-interfaces |

## Files

- `monitor.bat` — launcher (sets window size, invokes PowerShell)
- `monitor.ps1` — monitoring logic and display
