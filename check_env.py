#!/usr/bin/env python3
"""Quick environment check for monitorcmd.

Run this after installing dependencies to verify everything is in place.
    python check_env.py
"""
import sys
import subprocess
import shutil

def check_python_version():
    required = (3, 7)
    actual = sys.version_info[:2]
    status = "✓" if actual >= required else "✗"
    print(f"  {status} Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro} (requires >= {'.'.join(map(str, required))})")
    return actual >= required

def check_psutil():
    try:
        import psutil
        status = "✓"
        print(f"  {status} psutil {psutil.__version__}")
        return True
    except ImportError:
        print(f"  ✗ psutil not installed — run: pip install -r requirements.txt")
        return False

def check_nvidia_smi():
    if shutil.which("nvidia-smi"):
        try:
            result = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                gpu = result.stdout.strip().splitlines()[0].strip()
                print(f"  ✓ NVIDIA GPU detected: {gpu}")
                return True
        except Exception:
            pass
        print(f"  ⚠ nvidia-smi found but couldn't query GPU — GPU stats will show N/A")
        return False
    else:
        print(f"  ⚠ nvidia-smi not found — GPU stats will show N/A (CPU/RAM/disk/network still work)")
        return False

def main():
    print("monitorcmd — Environment Check")
    print("-" * 40)
    ok_python = check_python_version()
    ok_psutil = check_psutil()
    ok_nvidia = check_nvidia_smi()
    print("-" * 40)

    if ok_python and ok_psutil:
        print("✓ Ready to run!  python monitor.py")
    elif ok_python:
        print("⚠ Core functionality will work, but installing psutil is recommended.")
        print("  Run: pip install -r requirements.txt")
    else:
        print("✗ Python 3.7+ is required.")
        sys.exit(1)

if __name__ == "__main__":
    main()
