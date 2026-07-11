# monitorcmd

A Windows console monitor that uses **0 MB of VRAM** to watch GPU and system resources in real-time. Built for LLM inference — you can run it alongside Ollama, llama.cpp, vLLM, etc. without stealing the VRAM you're trying to measure.

It reads Windows Performance Counters (`typeperf`) and `nvidia-smi` CLI output. No GPU rendering, no overlays, no hooks. Just text in a console.

## Requirements

- Windows 10 or later
- Python 3.7+
- `psutil` (optional, fallback when performance counters fail): `pip install psutil`
- NVIDIA driver with `nvidia-smi` (optional, for GPU/VRAM metrics)

## Usage

```bash
python monitor.py
python monitor.py --interval-seconds 0.5
python monitor.py --no-color
```

| Argument | Default | Description |
|---|---|---|
| `--interval-seconds` | `1.0` | Refresh interval in seconds (minimum `0.5`) |
| `--no-color` | off | Disable ANSI color codes |

Press **Ctrl+C** to exit.

## Quick Links

While the monitor is running, press **1**–**0** on your keyboard to pop up a small window with pre-assigned text (URLs, commands, notes) ready to copy. Press **Esc** or click **Close** to dismiss. The monitoring loop is completely unaffected.

### Configuring Quick Links

Open `monitor.py` and edit the `KEY_LINKS` dictionary:

```python
KEY_LINKS = {
    '1': 'https://platform.openai.com/docs/api-reference',
    '2': 'https://github.com/ggerganov/llama.cpp',
    '3': 'nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv -l 1',
    '4': 'ollama run llama3.2',
    '5': '',  # add your own text here
    '6': '',
    '7': '',
    '8': '',
    '9': '',
    '0': '',
}
```

- Assign any URL, command, or note to any key
- Leave empty (`''`) to disable that key
- Add custom keys like `'q': 'your text here'`

### How It Works

A background thread polls `msvcrt.kbhit()` every 80 ms. When it detects a trigger key, it spawns a small **Tkinter** popup (always-on-top) in a separate thread. The main monitoring loop never blocks.

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

## Metrics Explained

Each line in the output corresponds to a specific value from the code:

### CPU & RAM

| Display Label | Code Variable | Source | What It Means |
|---|---|---|---|
| `CPU Usage` | `cpu_percent` | `typeperf` → `\Processor(_Total)\% Processor Time` | Overall CPU utilization across all cores |
| `System RAM` | `ram_used_gb` / `ram_free_gb` | `GlobalMemoryStatusEx` | Physical RAM: used, total, and free |

### GPU

| Display Label | Code Variable | Source | What It Means |
|---|---|---|---|
| `GPU Compute` | `gpu_percent` | `nvidia-smi` → `utilization.gpu` | How busy the GPU's CUDA/graphics cores are (0-100%) |
| `GPU Temp` | `gpu_temp` | `nvidia-smi` → `temperature.gpu` | GPU core temperature in °C |
| `GPU Power` | `gpu_power` | `nvidia-smi` → `power.draw` | Current power draw in watts |

### VRAM (Video RAM)

| Display Label | Code Variable | Source | What It Means |
|---|---|---|---|
| `VRAM Used` | `vram_used_gb` | `nvidia-smi` → `memory.used` | Dedicated GPU memory currently in use (MiB → GB) |
| `VRAM Free` | `vram_free_gb` | `nvidia-smi` → `memory.free` | Dedicated GPU memory still available (MiB → GB) |
| `VRAM Total` | `vram_total_gb` | `nvidia-smi` → `memory.total` | Total dedicated GPU memory on the card (MiB → GB) |
| `VRAM % Used` | `vram_pct_used` | Calculated: `(MemUsedMiB / MemTotalMiB) * 100` | Percentage of dedicated VRAM consumed |
| `VRAM Mem Util` | `vram_mem_util` | `nvidia-smi` → `utilization.memory` | **Memory bus activity** — how much the VRAM bandwidth is being used for reads/writes (0-100%). Different from "% Used": you can have 90% VRAM allocated but only 10% memory bus utilization if the model is idle |

### Shared Memory & Offload

| Display Label | Code Variable | Source | What It Means |
|---|---|---|---|
| `Shared GPU RAM` | `shared_vram_label` | `typeperf` → `\GPU Adapter Memory(*)\Shared Usage` | System RAM the GPU can borrow when dedicated VRAM is full. Shows used / limit in GB. **Warning:** If this starts rising during LLM inference, it means your model is spilling beyond dedicated VRAM onto system RAM — inference speed will drop dramatically (often to 1-2 tokens/sec) because system RAM is accessed over PCIe, not the GPU's direct memory bus |
| `RAM for Offload` | `ram_headroom_label` | Calculated: `ram_free_gb - 8.0` | Free system RAM minus 8 GB OS reserve — rough estimate of how much RAM is available for CPU-offloaded LLM layers |

### Disk & Network

| Display Label | Code Variable | Source | What It Means |
|---|---|---|---|
| `Disk Read` | `disk_read_rate` | `typeperf` → `\PhysicalDisk(_Total)\Disk Read Bytes/sec` | Total disk read throughput across all disks |
| `Disk Write` | `disk_write_rate` | `typeperf` → `\PhysicalDisk(_Total)\Disk Write Bytes/sec` | Total disk write throughput across all disks |
| `Network` | `net_rate` | `typeperf` → `\Network Interface(*)\Bytes Total/sec` | Combined send + receive across all real network adapters (excludes loopback, virtual, and tunnel interfaces) |

## How It Works

```
main() loop:
  1. Poll typeperf for CPU, GPU Engine, Disk, Network counters
  2. Run nvidia-smi for GPU name, VRAM, temperature, power, utilization
  3. Call GlobalMemoryStatusEx for system RAM
  4. Query typeperf for shared GPU memory
  5. Build ASCII frame → print to console
  6. Sleep until next interval
```

If `typeperf` fails (corrupted performance counters), the monitor tries to auto-repair with `lodctr /r`, then falls back to `psutil` for CPU/disk/network.

## Tips

- **Run alongside your LLM server** — 0 VRAM overhead means it won't impact inference
- **Faster refresh** — `--interval-seconds 0.5` for half-second updates
- **No NVIDIA GPU?** — CPU, RAM, disk, and network still work; GPU fields show `N/A` or `0`

## Troubleshooting

| Issue | Fix |
|---|---|
| All metrics show 0 | Try running as Administrator |
| GPU stats not showing | Check that `nvidia-smi` works in a terminal |
| Text cut off | Widen console to at least 80 columns |
| Colors not showing | Use `--no-color`, or upgrade to Windows Terminal |
