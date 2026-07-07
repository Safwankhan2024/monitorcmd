param(
    [double]$IntervalSeconds = 1,
    [switch]$NoColor
)

if ($IntervalSeconds -lt 0.5) { $IntervalSeconds = 0.5 }

$script:ConsoleWidth = 72
$script:LayoutDrawn = $false
$script:ValueLineStart = 0
$script:CounterWarning = $null
$script:HasNvidiaSmi = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)

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

function Get-NvidiaSmiValue {
    param([string]$Query)
    if (-not $script:HasNvidiaSmi) { return $null }
    $raw = & nvidia-smi --query-gpu=$Query --format=csv,noheader,nounits 2>$null
    if ($raw -match '\d+(\.\d+)?') { return $matches[0] }
    return $null
}

function Get-VramTotalGB {
    $nvMem = Get-NvidiaSmiValue 'memory.total'
    if ($nvMem) {
        return @{ Value = [math]::Round([double]$nvMem / 1024, 2); Approx = $false }
    }

    $limitCounter = Get-Counter '\GPU Adapter Memory(*)\Dedicated Limit' -ErrorAction SilentlyContinue
    if ($limitCounter) {
        $sum = Sum-CounterSamples $limitCounter.CounterSamples
        if ($sum -gt 0) {
            return @{ Value = [math]::Round($sum / 1GB, 2); Approx = $false }
        }
    }

    $gpuHardware = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.AdapterRAM -gt 0 } |
        Select-Object -First 1
    if ($gpuHardware) {
        return @{ Value = [math]::Round($gpuHardware.AdapterRAM / 1GB, 2); Approx = $true }
    }

    return @{ Value = $null; Approx = $false }
}

function Get-RamTotalGB {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        return [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    }
    return 0
}

function Get-SharedVramLimitGB {
    param([double]$RamTotalGB)

    $sharedLimitCounter = Get-Counter '\GPU Adapter Memory(*)\Shared Limit' -ErrorAction SilentlyContinue
    if ($sharedLimitCounter) {
        $sum = Sum-CounterSamples $sharedLimitCounter.CounterSamples
        if ($sum -gt 0) {
            return @{ Value = [math]::Round($sum / 1GB, 1); Estimated = $false }
        }
    }

    return @{ Value = [math]::Round($RamTotalGB / 2, 1); Estimated = $true }
}

function Get-CounterSamples {
    param([double]$SampleInterval)

    $paths = @(
        '\Processor(_Total)\% Processor Time',
        '\GPU Engine(*engtype_3D)\Utilization Percentage',
        '\GPU Adapter Memory(*)\Dedicated Usage',
        '\GPU Adapter Memory(*)\Shared Usage',
        '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
        '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
        '\Network Interface(*)\Bytes Total/sec'
    )

    try {
        $result = Get-Counter -Counter $paths -SampleInterval $SampleInterval -ErrorAction Stop
        return $result.CounterSamples
    }
    catch {
        $script:CounterWarning = 'Performance counters unavailable — some metrics may show 0.'
        return $null
    }
}

function Get-SamplesByPath {
    param($AllSamples, [string]$PathPattern)
    if (-not $AllSamples) { return @() }
    $AllSamples | Where-Object { $_.Path -like $PathPattern }
}

function Write-Line {
    param([string]$Text)
    Write-Host $Text.PadRight($script:ConsoleWidth)
}

function Write-StaticLayout {
    Clear-Host
    Write-Line ('=' * $script:ConsoleWidth)
    Write-Line '       LIGHTWEIGHT HARDWARE MONITOR (TASK MANAGER FEED)'
    Write-Line ('=' * $script:ConsoleWidth)
    if ($script:CounterWarning) {
        Write-Line $script:CounterWarning
    }
    $script:ValueLineStart = [Console]::CursorTop
    Write-Line 'CPU Usage:      '
    Write-Line 'RAM Usage:      '
    Write-Line ('-' * $script:ConsoleWidth)
    Write-Line 'GPU Usage:      '
    Write-Line 'GPU Temp:       '
    Write-Line 'Dedicated VRAM: '
    Write-Line 'Shared VRAM:    '
    Write-Line ('-' * $script:ConsoleWidth)
    Write-Line 'Disk Read:      '
    Write-Line 'Disk Write:     '
    Write-Line 'Network:        '
    Write-Line ('-' * $script:ConsoleWidth)
    Write-Line ('Updating every {0:N1}s. Press Ctrl+C to exit.' -f $IntervalSeconds)
    $script:LayoutDrawn = $true
}

function Write-ValueAt {
    param([int]$LineOffset, [string]$Text)
    [Console]::SetCursorPosition(0, $script:ValueLineStart + $LineOffset)
    Write-Host $Text.PadRight($script:ConsoleWidth) -NoNewline
}

function Render-Frame {
    param($Metrics)

    if (-not $script:LayoutDrawn) {
        Write-StaticLayout
    }

    Write-ValueAt 0 ('CPU Usage:      {0,5:N1} %' -f $Metrics.CpuPercent)
    Write-ValueAt 1 ('RAM Usage:      {0,5:N1} GB / Total: {1,5:N1} GB ({2,5:N1} GB Free)' -f `
        $Metrics.RamUsedGB, $Metrics.RamTotalGB, $Metrics.RamFreeGB)
    Write-ValueAt 3 ('GPU Usage:      {0,5:N1} %' -f $Metrics.GpuPercent)
    Write-ValueAt 4 ('GPU Temp:       {0} C' -f $Metrics.GpuTemp)
    Write-ValueAt 5 ('Dedicated VRAM: {0,5:N2} GB / Total: {1} GB' -f $Metrics.VramUsedGB, $Metrics.VramTotalLabel)
    Write-ValueAt 6 ('Shared VRAM:    {0,5:N2} GB / Total: {1} GB' -f $Metrics.SharedUsedGB, $Metrics.SharedTotalLabel)
    Write-ValueAt 8 ('Disk Read:      {0}' -f $Metrics.DiskRead)
    Write-ValueAt 9 ('Disk Write:     {0}' -f $Metrics.DiskWrite)
    Write-ValueAt 10 ('Network:        {0}' -f $Metrics.NetThroughput)
}

# --- Initialization ---
$ramTotalGB = Get-RamTotalGB
$vramInfo = Get-VramTotalGB
$sharedInfo = Get-SharedVramLimitGB -RamTotalGB $ramTotalGB

$staticCache = @{
    RamTotalGB        = $ramTotalGB
    VramTotalGB       = $vramInfo.Value
    VramApprox        = $vramInfo.Approx
    SharedTotalGB     = $sharedInfo.Value
    SharedEstimated   = $sharedInfo.Estimated
    LastStaticRefresh = Get-Date
}

# Warm up CPU counter (first sample is discarded by the engine on next read with SampleInterval)
Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -ErrorAction SilentlyContinue | Out-Null

try {
    while ($true) {
        # Refresh static totals every 30 seconds
        if (((Get-Date) - $staticCache.LastStaticRefresh).TotalSeconds -ge 30) {
            $staticCache.RamTotalGB = Get-RamTotalGB
            $vramInfo = Get-VramTotalGB
            $sharedInfo = Get-SharedVramLimitGB -RamTotalGB $staticCache.RamTotalGB
            $staticCache.VramTotalGB = $vramInfo.Value
            $staticCache.VramApprox = $vramInfo.Approx
            $staticCache.SharedTotalGB = $sharedInfo.Value
            $staticCache.SharedEstimated = $sharedInfo.Estimated
            $staticCache.LastStaticRefresh = Get-Date
        }

        $sampleInterval = [math]::Min(1, $IntervalSeconds)
        $allSamples = Get-CounterSamples -SampleInterval $sampleInterval

        $cpu = Get-SamplesByPath $allSamples '*\Processor(_Total)\% Processor Time'
        $cpuPercent = if ($cpu) { [math]::Round(($cpu | Select-Object -First 1).CookedValue, 1) } else { 0 }

        $gpu = Get-SamplesByPath $allSamples '*\GPU Engine(*engtype_3D)\Utilization Percentage'
        $gpuPercent = [math]::Round((Sum-CounterSamples $gpu), 1)
        if ($gpuPercent -gt 100) { $gpuPercent = 100 }

        $vram = Get-SamplesByPath $allSamples '*\GPU Adapter Memory(*)\Dedicated Usage'
        $vramUsedGB = [math]::Round((Sum-CounterSamples $vram) / 1GB, 2)

        $shared = Get-SamplesByPath $allSamples '*\GPU Adapter Memory(*)\Shared Usage'
        $sharedUsedGB = [math]::Round((Sum-CounterSamples $shared) / 1GB, 2)

        $diskRead = Get-SamplesByPath $allSamples '*\PhysicalDisk(_Total)\Disk Read Bytes/sec'
        $diskWrite = Get-SamplesByPath $allSamples '*\PhysicalDisk(_Total)\Disk Write Bytes/sec'
        $diskReadRate = Sum-CounterSamples $diskRead
        $diskWriteRate = Sum-CounterSamples $diskWrite

        $net = Get-SamplesByPath $allSamples '*\Network Interface(*)\Bytes Total/sec'
        $netSamples = $net | Where-Object {
            $_.InstanceName -notmatch '(?i)loopback|isatap|teredo|qos|pseudo|kernel|hyper-v|vmware|virtualbox'
        }
        $netRate = Sum-CounterSamples $netSamples

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $ramFreeGB = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 0 }
        $ramUsedGB = [math]::Round($staticCache.RamTotalGB - $ramFreeGB, 1)

        $gpuTemp = Get-NvidiaSmiValue 'temperature.gpu'
        if (-not $gpuTemp) { $gpuTemp = 'N/A' }

        $vramTotalLabel = if ($staticCache.VramTotalGB) {
            if ($staticCache.VramApprox) { '{0:N2} (approx)' -f $staticCache.VramTotalGB }
            else { '{0:N2}' -f $staticCache.VramTotalGB }
        }
        else { 'N/A' }

        $sharedTotalLabel = if ($staticCache.SharedEstimated) {
            '{0:N1} (est.)' -f $staticCache.SharedTotalGB
        }
        else {
            '{0:N1}' -f $staticCache.SharedTotalGB
        }

        Render-Frame @{
            CpuPercent       = $cpuPercent
            RamUsedGB        = $ramUsedGB
            RamTotalGB       = $staticCache.RamTotalGB
            RamFreeGB        = $ramFreeGB
            GpuPercent       = $gpuPercent
            GpuTemp          = $gpuTemp
            VramUsedGB       = $vramUsedGB
            VramTotalGB      = $staticCache.VramTotalGB
            VramTotalLabel   = $vramTotalLabel
            SharedUsedGB     = $sharedUsedGB
            SharedTotalGB    = $staticCache.SharedTotalGB
            SharedTotalLabel = $sharedTotalLabel
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
    [Console]::CursorVisible = $true
    Write-Host ''
    Write-Host 'Exiting...'
}
