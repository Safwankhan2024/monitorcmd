param(
    [double]$IntervalSeconds = 1,
    [switch]$NoColor
)

if ($IntervalSeconds -lt 0.5) { $IntervalSeconds = 0.5 }

$script:ConsoleWidth = 80
$script:FrameDrawn = $false
$script:UseAnsi = $false
$script:CounterWarning = $null
$script:HasNvidiaSmi = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
$script:GpuName = if ($script:HasNvidiaSmi) { 'Detecting GPU...' } else { 'No NVIDIA GPU detected' }
$script:FrameLines = 0
$script:CountersHealthy = $true
$script:CounterRepairAttempted = $false
$script:LastCounterRecoveryAttempt = [DateTime]::MinValue

function Initialize-Console {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'ConsoleMode').Type) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ConsoleMode {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
}
"@
        }
        $handle = [ConsoleMode]::GetStdHandle(-11)
        [uint32]$mode = 0
        [void][ConsoleMode]::GetConsoleMode($handle, [ref]$mode)
        $script:UseAnsi = [ConsoleMode]::SetConsoleMode($handle, $mode -bor 4)

        if ([Console]::BufferWidth -lt $script:ConsoleWidth) {
            [Console]::BufferWidth = $script:ConsoleWidth
        }
        if ([Console]::WindowWidth -lt $script:ConsoleWidth) {
            [Console]::WindowWidth = $script:ConsoleWidth
        }
    }
    catch { }
}

function Format-Throughput {
    param([double]$BytesPerSec)
    if ($BytesPerSec -ge 1MB) { return ('{0:N1} MB/s' -f ($BytesPerSec / 1MB)) }
    if ($BytesPerSec -ge 1KB) { return ('{0:N1} KB/s' -f ($BytesPerSec / 1KB)) }
    return ('{0:N0} B/s' -f [math]::Max(0, $BytesPerSec))
}

function Sum-CounterSamples {
    param($Samples)
    if (-not $Samples) { return 0 }
    ($Samples.CookedValue | Measure-Object -Sum).Sum
}

function Get-NvidiaGpuStats {
    if (-not $script:HasNvidiaSmi) { return $null }

    $raw = & nvidia-smi --query-gpu=name,memory.used,memory.free,memory.total,utilization.gpu,utilization.memory,temperature.gpu,power.draw --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return $null }

    $parts = ($raw -split ',\s*', 8)
    if ($parts.Count -lt 8) { return $null }

    return @{
        Name        = $parts[0].Trim()
        MemUsedMiB  = [double]$parts[1]
        MemFreeMiB  = [double]$parts[2]
        MemTotalMiB = [double]$parts[3]
        GpuUtil     = [double]$parts[4]
        MemUtil     = [double]$parts[5]
        Temp        = [double]$parts[6]
        PowerW      = [double]$parts[7]
    }
}

function Get-RamTotalGB {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        return [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    }
    return 0
}

function Get-SharedVramGB {
    $usageCounter = Get-Counter '\GPU Adapter Memory(*)\Shared Usage' -ErrorAction SilentlyContinue
    $limitCounter = Get-Counter '\GPU Adapter Memory(*)\Shared Limit' -ErrorAction SilentlyContinue

    $used = if ($usageCounter) { [math]::Round((Sum-CounterSamples $usageCounter.CounterSamples) / 1GB, 2) } else { 0 }
    $limit = if ($limitCounter) { [math]::Round((Sum-CounterSamples $limitCounter.CounterSamples) / 1GB, 1) } else { 0 }

    return @{ UsedGB = $used; LimitGB = $limit }
}

function Get-CounterSamples {
    param([double]$SampleInterval)

    $paths = @(
        '\Processor(_Total)\% Processor Time',
        '\GPU Engine(*engtype_3D)\Utilization Percentage',
        '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
        '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
        '\Network Interface(*)\Bytes Total/sec'
    )

    try {
        $result = Get-Counter -Counter $paths -SampleInterval $SampleInterval -ErrorAction Stop
        if (-not $script:CountersHealthy) {
            $script:CountersHealthy = $true
            $script:CounterWarning = $null
        }
        return $result.CounterSamples
    }
    catch {
        if ($script:CountersHealthy) {
            $script:CountersHealthy = $false
            Try-RepairCounters
        }
        else {
            # Try recovery every 30 seconds
            $now = Get-Date
            if (($now - $script:LastCounterRecoveryAttempt).TotalSeconds -ge 30) {
                $script:LastCounterRecoveryAttempt = $now
                if (Test-Counters) {
                    $script:CountersHealthy = $true
                    $script:CounterWarning = $null
                }
            }
        }
        return $null
    }
}

function Get-SamplesByPath {
    param($AllSamples, [string]$PathPattern)
    if (-not $AllSamples) { return @() }
    $AllSamples | Where-Object { $_.Path -like $PathPattern }
}

function Format-Frame {
    param($Metrics)

    $w = $script:ConsoleWidth
    $lines = @(
        ('=' * $w)
        '            LLM HARDWARE MONITOR (VRAM + SYSTEM FEED)'
        $script:GpuName
        ('=' * $w)
    )

    if ($script:CounterWarning) {
        $lines += $script:CounterWarning
    }

    $lines += @(
        ('CPU Usage:        {0,5:N1} %' -f $Metrics.CpuPercent)
        ('System RAM:       {0,5:N1} / {1,5:N1} GB  ({2,5:N1} GB free)' -f $Metrics.RamUsedGB, $Metrics.RamTotalGB, $Metrics.RamFreeGB)
        ('-' * $w)
        ('GPU Compute:      {0,5:N1} %' -f $Metrics.GpuPercent)
        ('GPU Temp:         {0} C' -f $Metrics.GpuTemp)
        ('GPU Power:        {0}' -f $Metrics.GpuPower)
        ('-' * $w)
        ('VRAM Used:        {0,6:N2} GB' -f $Metrics.VramUsedGB)
        ('VRAM Free:        {0,6:N2} GB' -f $Metrics.VramFreeGB)
        ('VRAM Total:       {0,6:N2} GB' -f $Metrics.VramTotalGB)
        ('VRAM % Used:      {0,5:N1} %' -f $Metrics.VramPctUsed)
        ('VRAM Mem Util:    {0,5:N1} %' -f $Metrics.VramMemUtil)
        ('Shared GPU RAM:   {0}' -f $Metrics.SharedVramLabel)
        ('RAM for Offload:  {0}' -f $Metrics.RamHeadroomLabel)
        ('-' * $w)
        ('Disk Read:        {0}' -f $Metrics.DiskRead)
        ('Disk Write:       {0}' -f $Metrics.DiskWrite)
        ('Network:          {0}' -f $Metrics.NetThroughput)
        ('-' * $w)
        ('Updating every {0:N1}s. Press Ctrl+C to exit.' -f $IntervalSeconds)
    )

    return (($lines | ForEach-Object { $_.PadRight($w) }) -join "`r`n")
}

function Show-Frame {
    param($Metrics)

    $frame = Format-Frame $Metrics
    $newLines = ($frame -split "`n").Count

    [Console]::SetCursorPosition(0, 0)
    [Console]::Out.Write($frame)

    # Clear leftover lines from a previous longer frame
    if ($newLines -lt $script:FrameLines) {
        $windowHeight = [Console]::WindowHeight
        $clearFrom = $newLines
        $clearTo = [Math]::Min($script:FrameLines, $windowHeight - 1)
        for ($i = $clearFrom; $i -le $clearTo; $i++) {
            [Console]::SetCursorPosition(0, $i)
            [Console]::Out.Write((' ' * $script:ConsoleWidth))
        }
    }

    # Position cursor below the frame
    $finalRow = [Math]::Min($newLines, [Console]::WindowHeight - 1)
    [Console]::SetCursorPosition(0, $finalRow)
    $script:FrameLines = $newLines
    $script:FrameDrawn = $true

    [Console]::Out.Flush()
}

# --- Initialization ---
Initialize-Console
$ramTotalGB = Get-RamTotalGB
$nvidiaBoot = Get-NvidiaGpuStats
if ($nvidiaBoot) { $script:GpuName = $nvidiaBoot.Name }

$staticCache = @{
    RamTotalGB        = $ramTotalGB
    LastStaticRefresh = Get-Date
}

try { [Console]::CursorVisible = $false } catch { }

# Pre-test counters at startup; if broken, attempt immediate repair
if (-not (Test-Counters)) { Try-RepairCounters }

try {
    while ($true) {
        if (((Get-Date) - $staticCache.LastStaticRefresh).TotalSeconds -ge 30) {
            $staticCache.RamTotalGB = Get-RamTotalGB
            $staticCache.LastStaticRefresh = Get-Date
        }

        $sampleInterval = [math]::Min(1, $IntervalSeconds)
        $allSamples = Get-CounterSamples -SampleInterval $sampleInterval

        if ($allSamples) {
            # Primary: performance counters
            $cpu = Get-SamplesByPath $allSamples '*\Processor(_Total)\% Processor Time'
            $cpuPercent = if ($cpu) { [math]::Round(($cpu | Select-Object -First 1).CookedValue, 1) } else { 0 }

            $gpu = Get-SamplesByPath $allSamples '*\GPU Engine(*engtype_3D)\Utilization Percentage'
            $gpuPercentCounter = [math]::Round((Sum-CounterSamples $gpu), 1)
            if ($gpuPercentCounter -gt 100) { $gpuPercentCounter = 100 }

            $diskRead = Get-SamplesByPath $allSamples '*\PhysicalDisk(_Total)\Disk Read Bytes/sec'
            $diskWrite = Get-SamplesByPath $allSamples '*\PhysicalDisk(_Total)\Disk Write Bytes/sec'
            $diskReadRate = Sum-CounterSamples $diskRead
            $diskWriteRate = Sum-CounterSamples $diskWrite

            $net = Get-SamplesByPath $allSamples '*\Network Interface(*)\Bytes Total/sec'
            $netSamples = $net | Where-Object {
                $_.InstanceName -notmatch '(?i)loopback|isatap|teredo|qos|pseudo|kernel|hyper-v|vmware|virtualbox'
            }
            $netRate = Sum-CounterSamples $netSamples
        }
        else {
            # Fallback: WMI/CIM metrics (no performance counters needed)
            $fallback = Get-FallbackMetrics -SampleInterval $sampleInterval
            $cpuPercent = $fallback.CpuPercent
            $diskReadRate = $fallback.DiskReadRate
            $diskWriteRate = $fallback.DiskWriteRate
            $netRate = $fallback.NetRate
            $gpuPercentCounter = 0
        }

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $ramFreeGB = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 0 }
        $ramUsedGB = [math]::Round($staticCache.RamTotalGB - $ramFreeGB, 1)

        $nvidia = Get-NvidiaGpuStats
        if ($nvidia) { $script:GpuName = $nvidia.Name }

        $vramUsedGB = if ($nvidia) { [math]::Round($nvidia.MemUsedMiB / 1024, 2) } else { 0 }
        $vramFreeGB = if ($nvidia) { [math]::Round($nvidia.MemFreeMiB / 1024, 2) } else { 0 }
        $vramTotalGB = if ($nvidia) { [math]::Round($nvidia.MemTotalMiB / 1024, 2) } else { 0 }
        $vramPctUsed = if ($nvidia -and $nvidia.MemTotalMiB -gt 0) {
            [math]::Round(($nvidia.MemUsedMiB / $nvidia.MemTotalMiB) * 100, 1)
        }
        else { 0 }
        $vramMemUtil = if ($nvidia) { [math]::Round($nvidia.MemUtil, 1) } else { 0 }
        $gpuPercent = if ($nvidia) { [math]::Round($nvidia.GpuUtil, 1) } else { $gpuPercentCounter }
        $gpuTemp = if ($nvidia) { [math]::Round($nvidia.Temp, 0) } else { 'N/A' }
        $gpuPower = if ($nvidia) { ('{0:N0} W' -f $nvidia.PowerW) } else { 'N/A' }

        $sharedVram = Get-SharedVramGB
        $sharedVramLabel = if ($sharedVram.LimitGB -gt 0) {
            '{0,5:N2} / {1,5:N1} GB used' -f $sharedVram.UsedGB, $sharedVram.LimitGB
        }
        else {
            '{0,5:N2} GB used (no limit counter)' -f $sharedVram.UsedGB
        }

        # Rough guide: keep ~8 GB system RAM free for OS; rest can host offloaded layers
        $offloadHeadroomGB = [math]::Max(0, [math]::Round($ramFreeGB - 8, 1))
        $ramHeadroomLabel = '{0,5:N1} GB free for CPU layers' -f $offloadHeadroomGB

        Show-Frame @{
            CpuPercent       = $cpuPercent
            RamUsedGB        = $ramUsedGB
            RamTotalGB       = $staticCache.RamTotalGB
            RamFreeGB        = $ramFreeGB
            GpuPercent       = $gpuPercent
            GpuTemp          = $gpuTemp
            GpuPower         = $gpuPower
            VramUsedGB       = $vramUsedGB
            VramFreeGB       = $vramFreeGB
            VramTotalGB      = $vramTotalGB
            VramPctUsed      = $vramPctUsed
            VramMemUtil      = $vramMemUtil
            SharedVramLabel  = $sharedVramLabel
            RamHeadroomLabel = $ramHeadroomLabel
            DiskRead         = Format-Throughput $diskReadRate
            DiskWrite        = Format-Throughput $diskWriteRate
            NetThroughput    = Format-Throughput $netRate
        }

        $remainingSleep = $IntervalSeconds - $sampleInterval
        if ($remainingSleep -gt 0) {
            Start-Sleep -Seconds $remainingSleep
        }
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch { }
    Write-Host ''
    Write-Host 'Exiting...'
}

function Try-RepairCounters {
    if ($script:CounterRepairAttempted) { return }
    $script:CounterRepairAttempted = $true

    try {
        $script:CounterWarning = 'Repairing performance counters...'
        Start-Transcript -Path $null -Append 2>$null | Out-Null

        # Try non-elevated first
        $repairResult = lodctr /r 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:CountersHealthy = $true
            $script:CounterWarning = 'Performance counters repaired.'
            Start-Sleep -Seconds 1
            return
        }

        # Try elevated via Start-Process
        $elevatedResult = Start-Process -FilePath 'lodctr' -ArgumentList '/r' -Verb RunAs -Wait -PassThru -NoNewWindow 2>$null
        if ($elevatedResult.ExitCode -eq 0) {
            $script:CountersHealthy = $true
            $script:CounterWarning = 'Performance counters repaired (elevated).'
            Start-Sleep -Seconds 1
            return
        }

        # Fallback: try rebuilding from inn file
        $windir = $env:WINDIR
        $innPath = Join-Path $windir 'System32\stdcnt.ad'
        if (Test-Path $innPath) {
            $rebuildResult = Start-Process -FilePath 'lodctr' -ArgumentList "/r:$innPath" -Verb RunAs -Wait -PassThru -NoNewWindow 2>$null
            if ($rebuildResult.ExitCode -eq 0) {
                $script:CountersHealthy = $true
                $script:CounterWarning = 'Performance counters repaired (from stdcnt.ad).'
                Start-Sleep -Seconds 1
                return
            }
        }

        $script:CounterWarning = 'Using fallback metrics (counter repair needs admin).'
    }
    catch {
        $script:CounterWarning = 'Using fallback metrics (counter repair needs admin).'
    }
}

function Test-Counters {
    try {
        Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 0.5 -MaxSamples 1 -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-FallbackMetrics {
    param([double]$SampleInterval)

    $metrics = @{
        CpuPercent = 0
        DiskReadRate = 0
        DiskWriteRate = 0
        NetRate = 0
    }

    # CPU via WMI
    try {
        $cpu1 = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Sum
        $metrics.CpuPercent = [math]::Round($cpu1.Sum / $cpu1.Count, 1)
    }
    catch {}

    # Disk via WMI
    try {
        $disks = Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk -Filter 'Name="_Total"'
        if ($disks) {
            $metrics.DiskReadRate = $disks.DiskReadBytesPerSec
            $metrics.DiskWriteRate = $disks.DiskWriteBytesPerSec
        }
    }
    catch {}

    # Network via WMI
    try {
        $adapters = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface
        $totalBytes = 0
        foreach ($adapter in $adapters) {
            if ($adapter.Name -notmatch '(?i)loopback|isatap|teredo|qos|pseudo|kernel|hyper-v|vmware|virtualbox') {
                $totalBytes += $adapter.BytesTotalPerSec
            }
        }
        $metrics.NetRate = $totalBytes
    }
    catch {}

    return $metrics
}
