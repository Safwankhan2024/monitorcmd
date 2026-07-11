#!/usr/bin/env python3
import argparse
import csv
import datetime
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import time
import ctypes

try:
    import psutil
except ImportError:
    psutil = None

try:
    import msvcrt
    import threading
    import tkinter as tk
    from tkinter import ttk
    HAS_MSVCRT = True
except ImportError:
    HAS_MSVCRT = False

try:
    import json
except ImportError:
    json = None

try:
    import yaml
except ImportError:
    yaml = None

INTERVAL_MIN = 0.5
CONSOLE_WIDTH = 80
COUNTER_WARNING = None
COUNTERS_HEALTHY = True
COUNTER_REPAIR_ATTEMPTED = False
LAST_COUNTER_RECOVERY_ATTEMPT = datetime.datetime.min
GPU_NAME = 'Detecting GPU...'
HAS_NVIDIA_SMI = bool(shutil.which('nvidia-smi'))

CPU_COUNTER = r'\Processor(_Total)\% Processor Time'
GPU_ENGINE_COUNTER = r'\GPU Engine(*engtype_3D)\Utilization Percentage'
DISK_READ_COUNTER = r'\PhysicalDisk(_Total)\Disk Read Bytes/sec'
DISK_WRITE_COUNTER = r'\PhysicalDisk(_Total)\Disk Write Bytes/sec'
NET_COUNTER = r'\Network Interface(*)\Bytes Total/sec'
SHARED_VRAM_USAGE_COUNTER = r'\GPU Adapter Memory(*)\Shared Usage'
SHARED_VRAM_LIMIT_COUNTER = r'\GPU Adapter Memory(*)\Shared Limit'

EXCLUDED_NET_PATTERNS = [
    r'loopback', r'isatap', r'teredo', r'qos', r'pseudo', r'kernel', r'hyper-v', r'vmware', r'virtualbox'
]

# ── Quick-Link Key Bindings ──────────────────────────────────────────────────
# Supports YAML (quick_links.yaml) or JSON (quick_links.json), both gitignored.
# YAML is recommended for long multi-line text (AI prompts, etc.).
# See README.md for the format.

DEFAULT_KEY_LINKS = {
    '1': 'https://platform.openai.com/docs/api-reference',
    '2': 'https://github.com/ggerganov/llama.cpp',
    '3': 'nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv -l 1',
    '4': 'ollama run llama3.2',
    '5': '',
    '6': '',
    '7': '',
    '8': '',
    '9': '',
    '0': '',
}


def load_key_links():
    """Load quick links from config file, fall back to defaults.
    
    Priority: quick_links.yaml > quick_links.json > DEFAULT_KEY_LINKS
    """
    base_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Try YAML first (best for multi-line text)
    yaml_path = os.path.join(base_dir, 'quick_links.yaml')
    if yaml and os.path.exists(yaml_path):
        try:
            with open(yaml_path, 'r', encoding='utf-8') as f:
                data = yaml.safe_load(f)
                if isinstance(data, dict):
                    return {str(k): str(v) for k, v in data.items()}
        except Exception:
            pass
    
    # Fall back to JSON
    json_path = os.path.join(base_dir, 'quick_links.json')
    if json and os.path.exists(json_path):
        try:
            with open(json_path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    
    return DEFAULT_KEY_LINKS


KEY_LINKS = DEFAULT_KEY_LINKS

_popup_active = False
_popup_lock = threading.Lock()


class QuickLinkPopup:
    """Always-on-top window with copyable text, auto-sized with scrolling."""

    MAX_HEIGHT = 600  # maximum window height in pixels
    LINE_HEIGHT = 18  # approximate height per line in Consolas 10
    WIDTH = 700       # fixed window width

    def __init__(self, title, text):
        self.root = tk.Tk()
        self.root.title(title)
        self.root.resizable(False, False)
        self.root.attributes('-topmost', True)
        self.root.configure(padx=10, pady=10)

        lbl = ttk.Label(self.root, text='Ready to copy (Ctrl+C / right-click → Copy):')
        lbl.pack(anchor='nw', pady=(0, 4))

        # Create scrollable text frame
        scroll_frame = ttk.Frame(self.root)
        scroll_frame.pack(fill='both', expand=True, pady=(0, 8))

        self.textbox = tk.Text(scroll_frame, wrap='word', font=('Consolas', 10),
                               yscrollcommand=lambda *a: vbar.set(*a))
        self.textbox.insert('1.0', text)
        self.textbox.configure(state='disabled')
        self.textbox.pack(side='left', fill='both', expand=True)

        vbar = ttk.Scrollbar(scroll_frame, orient='vertical', command=self.textbox.yview)
        vbar.pack(side='right', fill='y')

        # Calculate height based on text content, capped at MAX_HEIGHT
        line_count = text.count('\n') + 1
        calc_height = min(line_count * self.LINE_HEIGHT + 40, self.MAX_HEIGHT)
        self.root.geometry(f'{self.WIDTH}x{calc_height}')

        btn = ttk.Button(self.root, text='Close', command=self._close)
        btn.pack(anchor='e')

        self.root.bind('<Escape>', lambda e: self._close())
        self.root.protocol('WM_DELETE_WINDOW', self._close)

    def _close(self):
        self.root.destroy()

    def run(self):
        self.root.mainloop()


def _show_popup(text):
    """Show popup in its own thread so monitoring never blocks."""
    global _popup_active
    popup = QuickLinkPopup('Quick Link', text)
    popup.run()
    with _popup_lock:
        _popup_active = False


def _key_checker_thread():
    """Poll for key presses; spawn popup on trigger keys."""
    global _popup_active
    while True:
        try:
            if HAS_MSVCRT and msvcrt.kbhit():
                ch = msvcrt.getch()          # returns bytes like b'1'
                key = ch.decode('utf-8')     # decode to str '1'
                if key and key in KEY_LINKS:
                    link_text = KEY_LINKS[key].strip()
                    if link_text:
                        with _popup_lock:
                            if not _popup_active:
                                _popup_active = True
                                t = threading.Thread(target=_show_popup, args=(link_text,), daemon=True)
                                t.start()
        except Exception:
            pass
        time.sleep(0.08)  # light polling


def enable_ansi():
    if os.name != 'nt':
        return False

    try:
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return False

        ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        if not kernel32.SetConsoleMode(handle, mode.value | ENABLE_VIRTUAL_TERMINAL_PROCESSING):
            return False

        return True
    except Exception:
        return False


def set_console_size():
    if os.name == 'nt':
        os.system('mode con cols=80 lines=26')


def parse_typeperf_output(stdout):
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    if len(lines) < 2:
        return {}

    reader = csv.reader(lines)
    rows = list(reader)
    if len(rows) < 2:
        return {}

    header = rows[0]
    values = rows[-1]
    result = {}

    for path, value in zip(header[1:], values[1:]):
        normalized = value.replace('"', '').strip()
        normalized = normalized.replace(',', '.')
        try:
            result[path] = float(normalized)
        except ValueError:
            result[path] = 0.0

    return result


def run_typeperf(counters, sample_interval):
    args = ['typeperf', '-sc', '1', '-si', str(sample_interval)] + counters
    try:
        proc = subprocess.run(args, capture_output=True, text=True)
    except FileNotFoundError:
        return None

    if proc.returncode != 0:
        return None

    return parse_typeperf_output(proc.stdout)


def sum_counter_samples(values):
    return sum(values) if values else 0.0


def get_samples_by_path(samples, path_pattern):
    if not samples:
        return []
    return [value for path, value in samples.items() if fnmatch.fnmatchcase(path, path_pattern)]


def get_nvidia_gpu_stats():
    if not HAS_NVIDIA_SMI:
        return None

    try:
        result = subprocess.run(
            [
                'nvidia-smi',
                '--query-gpu=name,memory.used,memory.free,memory.total,utilization.gpu,utilization.memory,temperature.gpu,power.draw',
                '--format=csv,noheader,nounits',
            ],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return None

    if result.returncode != 0 or not result.stdout.strip():
        return None

    line = result.stdout.strip().splitlines()[0]
    parts = [part.strip() for part in line.split(',')]
    if len(parts) < 8:
        return None

    try:
        return {
            'Name': parts[0],
            'MemUsedMiB': float(parts[1]),
            'MemFreeMiB': float(parts[2]),
            'MemTotalMiB': float(parts[3]),
            'GpuUtil': float(parts[4]),
            'MemUtil': float(parts[5]),
            'Temp': float(parts[6]),
            'PowerW': float(parts[7]),
        }
    except ValueError:
        return None


def get_ram_total_gb():
    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ('dwLength', ctypes.c_ulong),
            ('dwMemoryLoad', ctypes.c_ulong),
            ('ullTotalPhys', ctypes.c_ulonglong),
            ('ullAvailPhys', ctypes.c_ulonglong),
            ('ullTotalPageFile', ctypes.c_ulonglong),
            ('ullAvailPageFile', ctypes.c_ulonglong),
            ('ullTotalVirtual', ctypes.c_ulonglong),
            ('ullAvailVirtual', ctypes.c_ulonglong),
            ('sullAvailExtendedVirtual', ctypes.c_ulonglong),
        ]

    mem = MEMORYSTATUSEX()
    mem.dwLength = ctypes.sizeof(mem)
    ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(mem))
    return round(mem.ullTotalPhys / (1024 ** 3), 1)


def get_ram_free_gb():
    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ('dwLength', ctypes.c_ulong),
            ('dwMemoryLoad', ctypes.c_ulong),
            ('ullTotalPhys', ctypes.c_ulonglong),
            ('ullAvailPhys', ctypes.c_ulonglong),
            ('ullTotalPageFile', ctypes.c_ulonglong),
            ('ullAvailPageFile', ctypes.c_ulonglong),
            ('ullTotalVirtual', ctypes.c_ulonglong),
            ('ullAvailVirtual', ctypes.c_ulonglong),
            ('sullAvailExtendedVirtual', ctypes.c_ulonglong),
        ]

    mem = MEMORYSTATUSEX()
    mem.dwLength = ctypes.sizeof(mem)
    ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(mem))
    return round(mem.ullAvailPhys / (1024 ** 3), 1)


def format_throughput(bytes_per_sec):
    if bytes_per_sec >= 1024 * 1024:
        return f'{bytes_per_sec / (1024 * 1024):.1f} MB/s'
    if bytes_per_sec >= 1024:
        return f'{bytes_per_sec / 1024:.1f} KB/s'
    return f'{max(0, bytes_per_sec):.0f} B/s'


def test_counters():
    samples = run_typeperf([CPU_COUNTER], 0.5)
    return bool(samples)


def try_repair_counters():
    global COUNTER_WARNING, COUNTERS_HEALTHY, COUNTER_REPAIR_ATTEMPTED
    if COUNTER_REPAIR_ATTEMPTED:
        return

    COUNTER_REPAIR_ATTEMPTED = True
    COUNTER_WARNING = 'Repairing performance counters...'

    try:
        repair = subprocess.run(['lodctr', '/r'], capture_output=True, text=True)
        if repair.returncode == 0:
            COUNTERS_HEALTHY = True
            COUNTER_WARNING = 'Performance counters repaired.'
            time.sleep(1)
            return

        elevated = subprocess.run(
            [
                'powershell',
                '-NoProfile',
                '-Command',
                "Start-Process lodctr -ArgumentList '/r' -Verb RunAs -Wait",
            ],
            capture_output=True,
            text=True,
        )

        if elevated.returncode == 0:
            COUNTERS_HEALTHY = True
            COUNTER_WARNING = 'Performance counters repaired (elevated).'
            time.sleep(1)
            return

        windir = os.environ.get('WINDIR', r'C:\Windows')
        inn_path = os.path.join(windir, 'System32', 'stdcnt.ad')
        if os.path.exists(inn_path):
            rebuild = subprocess.run(
                [
                    'powershell',
                    '-NoProfile',
                    '-Command',
                    f"Start-Process lodctr -ArgumentList '/r:{inn_path}' -Verb RunAs -Wait",
                ],
                capture_output=True,
                text=True,
            )
            if rebuild.returncode == 0:
                COUNTERS_HEALTHY = True
                COUNTER_WARNING = 'Performance counters repaired (from stdcnt.ad).'
                time.sleep(1)
                return

        COUNTER_WARNING = 'Using fallback metrics (counter repair needs admin).'
    except Exception:
        COUNTER_WARNING = 'Using fallback metrics (counter repair needs admin).'


def get_shared_vram_gb():
    usage = run_typeperf([SHARED_VRAM_USAGE_COUNTER], 0.5)
    limit = run_typeperf([SHARED_VRAM_LIMIT_COUNTER], 0.5)

    used = round(sum(usage.values()) / (1024 ** 3), 2) if usage else 0.0
    limit_gb = round(sum(limit.values()) / (1024 ** 3), 1) if limit else 0.0
    return {'UsedGB': used, 'LimitGB': limit_gb}


def get_fallback_metrics(sample_interval):
    metrics = {'CpuPercent': 0.0, 'DiskReadRate': 0.0, 'DiskWriteRate': 0.0, 'NetRate': 0.0}

    if psutil:
        metrics['CpuPercent'] = psutil.cpu_percent(interval=sample_interval)

        try:
            disk_before = psutil.disk_io_counters()
            net_before = psutil.net_io_counters()
            time.sleep(sample_interval)
            disk_after = psutil.disk_io_counters()
            net_after = psutil.net_io_counters()
            metrics['DiskReadRate'] = max(0.0, (disk_after.read_bytes - disk_before.read_bytes) / sample_interval)
            metrics['DiskWriteRate'] = max(0.0, (disk_after.write_bytes - disk_before.write_bytes) / sample_interval)
            metrics['NetRate'] = max(0.0, ((net_after.bytes_sent + net_after.bytes_recv) - (net_before.bytes_sent + net_before.bytes_recv)) / sample_interval)
        except Exception:
            pass
    else:
        time.sleep(sample_interval)

    return metrics


def format_frame(metrics):
    lines = [
        '=' * CONSOLE_WIDTH,
        '            LLM HARDWARE MONITOR (VRAM + SYSTEM FEED)',
        GPU_NAME,
        '=' * CONSOLE_WIDTH,
    ]

    if COUNTER_WARNING:
        lines.append(COUNTER_WARNING)

    lines.extend([
        f'CPU Usage:        {metrics["CpuPercent"]:5.1f} %',
        f'System RAM:       {metrics["RamUsedGB"]:5.1f} / {metrics["RamTotalGB"]:5.1f} GB  ({metrics["RamFreeGB"]:5.1f} GB free)',
        '-' * CONSOLE_WIDTH,
        f'GPU Compute:      {metrics["GpuPercent"]:5.1f} %',
        f'GPU Temp:         {metrics["GpuTemp"]} C',
        f'GPU Power:        {metrics["GpuPower"]}',
        '-' * CONSOLE_WIDTH,
        f'VRAM Used:        {metrics["VramUsedGB"]:6.2f} GB',
        f'VRAM Free:        {metrics["VramFreeGB"]:6.2f} GB',
        f'VRAM Total:       {metrics["VramTotalGB"]:6.2f} GB',
        f'VRAM % Used:      {metrics["VramPctUsed"]:5.1f} %',
        f'VRAM Mem Util:    {metrics["VramMemUtil"]:5.1f} %',
        f'Shared GPU RAM:   {metrics["SharedVramLabel"]}',
        f'RAM for Offload:  {metrics["RamHeadroomLabel"]}',
        '-' * CONSOLE_WIDTH,
        f'Disk Read:        {metrics["DiskRead"]}',
        f'Disk Write:       {metrics["DiskWrite"]}',
        f'Network:          {metrics["NetThroughput"]}',
        '-' * CONSOLE_WIDTH,
        f'Updating every {metrics["IntervalSeconds"]:3.1f}s. Press Ctrl+C to exit.',
    ])

    return '\r\n'.join(line.ljust(CONSOLE_WIDTH) for line in lines)


def clear_screen():
    if USE_ANSI:
        sys.stdout.write('\x1b[2J\x1b[H')
        sys.stdout.flush()
    else:
        os.system('cls')


def show_frame(frame):
    if USE_ANSI:
        sys.stdout.write('\x1b[H' + frame)
        sys.stdout.flush()
    else:
        clear_screen()
        print(frame, end='\n', flush=True)


def is_excluded_interface(path):
    token = path.lower()
    return any(pattern in token for pattern in EXCLUDED_NET_PATTERNS)


def main():
    global GPU_NAME, COUNTER_WARNING, KEY_LINKS

    parser = argparse.ArgumentParser(description='Lightweight hardware monitor for Windows.')
    parser.add_argument('--interval-seconds', type=float, default=1.0, help='Refresh interval in seconds (minimum 0.5)')
    parser.add_argument('--no-color', action='store_true', help='Disable ANSI sequences')
    args = parser.parse_args()

    interval_seconds = max(args.interval_seconds, INTERVAL_MIN)

    set_console_size()
    if not args.no_color:
        globals()['USE_ANSI'] = enable_ansi()

    # Load quick links from config file (gitignored)
    KEY_LINKS = load_key_links()

    # Start background key listener (Windows only)
    if HAS_MSVCRT:
        threading.Thread(target=_key_checker_thread, daemon=True).start()

    ram_total_gb = get_ram_total_gb()
    nvidia_boot = get_nvidia_gpu_stats()
    if nvidia_boot:
        GPU_NAME = nvidia_boot['Name']
    else:
        GPU_NAME = 'No NVIDIA GPU detected'

    static_cache = {'RamTotalGB': ram_total_gb, 'LastStaticRefresh': datetime.datetime.now()}

    if not test_counters():
        try_repair_counters()

    try:
        while True:
            if (datetime.datetime.now() - static_cache['LastStaticRefresh']).total_seconds() >= 30:
                static_cache['RamTotalGB'] = get_ram_total_gb()
                static_cache['LastStaticRefresh'] = datetime.datetime.now()

            sample_interval = min(1.0, interval_seconds)
            samples = run_typeperf([CPU_COUNTER, GPU_ENGINE_COUNTER, DISK_READ_COUNTER, DISK_WRITE_COUNTER, NET_COUNTER], sample_interval)

            if samples:
                cpu_values = get_samples_by_path(samples, f'*{CPU_COUNTER}')
                cpu_percent = round(cpu_values[0], 1) if cpu_values else 0.0

                gpu_samples = get_samples_by_path(samples, f'*{GPU_ENGINE_COUNTER}')
                gpu_percent_counter = round(min(sum_counter_samples(gpu_samples), 100.0), 1)

                disk_read_rate = sum_counter_samples(get_samples_by_path(samples, f'*{DISK_READ_COUNTER}'))
                disk_write_rate = sum_counter_samples(get_samples_by_path(samples, f'*{DISK_WRITE_COUNTER}'))

                net_values = [value for path, value in samples.items() if fnmatch.fnmatchcase(path, f'*{NET_COUNTER}') and not is_excluded_interface(path)]
                net_rate = sum_counter_samples(net_values)
            else:
                fallback = get_fallback_metrics(sample_interval)
                cpu_percent = fallback['CpuPercent']
                disk_read_rate = fallback['DiskReadRate']
                disk_write_rate = fallback['DiskWriteRate']
                net_rate = fallback['NetRate']
                gpu_percent_counter = 0.0

            ram_free_gb = get_ram_free_gb()
            ram_used_gb = round(static_cache['RamTotalGB'] - ram_free_gb, 1)

            nvidia = get_nvidia_gpu_stats()
            if nvidia:
                GPU_NAME = nvidia['Name']

            vram_used_gb = round(nvidia['MemUsedMiB'] / 1024, 2) if nvidia else 0.0
            vram_free_gb = round(nvidia['MemFreeMiB'] / 1024, 2) if nvidia else 0.0
            vram_total_gb = round(nvidia['MemTotalMiB'] / 1024, 2) if nvidia else 0.0
            vram_pct_used = round((nvidia['MemUsedMiB'] / nvidia['MemTotalMiB']) * 100, 1) if nvidia and nvidia['MemTotalMiB'] > 0 else 0.0
            vram_mem_util = round(nvidia['MemUtil'], 1) if nvidia else 0.0
            gpu_percent = round(nvidia['GpuUtil'], 1) if nvidia else gpu_percent_counter
            gpu_temp = int(round(nvidia['Temp'])) if nvidia else 'N/A'
            gpu_power = f'{int(round(nvidia["PowerW"]))} W' if nvidia else 'N/A'

            shared_vram = get_shared_vram_gb()
            if shared_vram['LimitGB'] > 0:
                shared_vram_label = f'{shared_vram["UsedGB"]:5.2f} / {shared_vram["LimitGB"]:5.1f} GB used'
            else:
                shared_vram_label = f'{shared_vram["UsedGB"]:5.2f} GB used (no limit counter)'

            offload_headroom_gb = max(0.0, round(ram_free_gb - 8.0, 1))
            ram_headroom_label = f'{offload_headroom_gb:5.1f} GB free for CPU layers'

            frame = format_frame({
                'CpuPercent': cpu_percent,
                'RamUsedGB': ram_used_gb,
                'RamTotalGB': static_cache['RamTotalGB'],
                'RamFreeGB': ram_free_gb,
                'GpuPercent': gpu_percent,
                'GpuTemp': gpu_temp,
                'GpuPower': gpu_power,
                'VramUsedGB': vram_used_gb,
                'VramFreeGB': vram_free_gb,
                'VramTotalGB': vram_total_gb,
                'VramPctUsed': vram_pct_used,
                'VramMemUtil': vram_mem_util,
                'SharedVramLabel': shared_vram_label,
                'RamHeadroomLabel': ram_headroom_label,
                'DiskRead': format_throughput(disk_read_rate),
                'DiskWrite': format_throughput(disk_write_rate),
                'NetThroughput': format_throughput(net_rate),
                'IntervalSeconds': interval_seconds,
            })

            show_frame(frame)

            remaining_sleep = interval_seconds - min(1.0, interval_seconds)
            if remaining_sleep > 0:
                time.sleep(remaining_sleep)

    except KeyboardInterrupt:
        clear_screen()
        print('Exiting...')


if __name__ == '__main__':
    main()
