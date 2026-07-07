param(
    [double]$IntervalSeconds = 1,
    [switch]$NoColor
)

if ($IntervalSeconds -lt 0.5) { $IntervalSeconds = 0.5 }

$script:ConsoleWidth = 72
$script:ValueCol = 16
$script:ValueWidth = $script:ConsoleWidth - $script:ValueCol
$script:LayoutDrawn = $false
$script:ValueRows = @{}
$script:FooterRow = 0
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

function Get-CounterSamples {
    param([double]$SampleInterval)

    $paths = @(
        '\Processor(_Total)\% Processor Time',
        '\GPU Engine(*engtype_3D)\Utilization Percentage',
        '\GPU Adapter Memory(*)\Dedicated Usage',
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

function Write-LabelRow {
    param([string]$Key, [string]$Label)
    $script:ValueRows[$Key] = [Console]::CursorTop
    $blank = ' ' * $script:ValueWidth
    Write-Host ($Label + $blank)
}

function Initialize-Display {
    Clear-Host
    Write-Host ('=' * $script:ConsoleWidth)
    Write-Host '       LIGHTWEIGHT HARDWARE MONITOR (TASK MANAGER FEED)'
    Write-Host ('=' * $script:ConsoleWidth)
    if ($script:CounterWarning) {
        Write-Host $script:CounterWarning.PadRight($script:ConsoleWidth)
    }

    Write-LabelRow 'Cpu' 'CPU Usage:      '
    Write-LabelRow 'Ram' 'RAM Usage:      '
    Write-Host ('-' * $script:ConsoleWidth)
    Write-LabelRow 'Gpu' 'GPU Usage:      '
    Write-LabelRow 'GpuTemp' 'GPU Temp:       '
    Write-LabelRow 'Vram' 'VRAM Usage:     '
    Write-Host ('-' * $script:ConsoleWidth)
    Write-LabelRow 'DiskRead' 'Disk Read:      '
    Write-LabelRow 'DiskWrite' 'Disk Write:     '
    Write-LabelRow 'Network' 'Network:        '
    Write-Host ('-' * $script:ConsoleWidth)

    $script:FooterRow = [Console]::CursorTop
    Write-Host ('Updating every {0:N1}s. Press Ctrl+C to exit.' -f $IntervalSeconds)
    $script:LayoutDrawn = $true
}

function Set-Value {
    param([string]$Key, [string]$Text)
    [Console]::SetCursorPosition($script:ValueCol, $script:ValueRows[$Key])
    [Console]::Write($Text.PadRight($script:ValueWidth))
}

function Update-Display {
    param($Metrics)

    if (-not $script:LayoutDrawn) {
        Initialize-Display
    }

    Set-Value 'Cpu' ('{0,5:N1} %' -f $Metrics.CpuPercent)
    Set-Value 'Ram' ('{0,5:N1} GB / Total: {1,5:N1} GB ({2,5:N1} GB Free)' -f `
        $Metrics.RamUsedGB, $Metrics.RamTotalGB, $Metrics.RamFreeGB)
    Set-Value 'Gpu' ('{0,5:N1} %' -f $Metrics.GpuPercent)
    Set-Value 'GpuTemp' ('{0} C' -f $Metrics.GpuTemp)
    Set-Value 'Vram' ('{0,5:N2} GB / Total: {1} GB' -f $Metrics.VramUsedGB, $Metrics.VramTotalLabel)
    Set-Value 'DiskRead' $Metrics.DiskRead
    Set-Value 'DiskWrite' $Metrics.DiskWrite
    Set-Value 'Network' $Metrics.NetThroughput

    [Console]::SetCursorPosition(0, $script:FooterRow)
}

# --- Initialization ---
$ramTotalGB = Get-RamTotalGB
$vramInfo = Get-VramTotalGB

$staticCache = @{
    RamTotalGB        = $ramTotalGB
    VramTotalGB       = $vramInfo.Value
    VramApprox        = $vramInfo.Approx
    LastStaticRefresh = Get-Date
}

try { [Console]::CursorVisible = $false } catch { }

# Warm up CPU counter (first sample is discarded by the engine on next read with SampleInterval)
Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -ErrorAction SilentlyContinue | Out-Null

try {
    while ($true) {
        # Refresh static totals every 30 seconds
        if (((Get-Date) - $staticCache.LastStaticRefresh).TotalSeconds -ge 30) {
            $staticCache.RamTotalGB = Get-RamTotalGB
            $vramInfo = Get-VramTotalGB
            $staticCache.VramTotalGB = $vramInfo.Value
            $staticCache.VramApprox = $vramInfo.Approx
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
        else { '0.00' }

        Update-Display @{
            CpuPercent     = $cpuPercent
            RamUsedGB      = $ramUsedGB
            RamTotalGB     = $staticCache.RamTotalGB
            RamFreeGB      = $ramFreeGB
            GpuPercent     = $gpuPercent
            GpuTemp        = $gpuTemp
            VramUsedGB     = $vramUsedGB
            VramTotalLabel = $vramTotalLabel
            DiskRead       = Format-Throughput $diskReadRate
            DiskWrite      = Format-Throughput $diskWriteRate
            NetThroughput  = Format-Throughput $netRate
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
