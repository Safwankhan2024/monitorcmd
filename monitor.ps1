param(
    [double]$IntervalSeconds = 1,
    [switch]$NoColor
)

if ($IntervalSeconds -lt 0.5) { $IntervalSeconds = 0.5 }

$script:ConsoleWidth = 80
$script:ValueCol = 18
$script:ValueWidth = $script:ConsoleWidth - $script:ValueCol
$script:LayoutDrawn = $false
$script:ValueRows = @{}
$script:FooterRow = 0
$script:CounterWarning = $null
$script:HasNvidiaSmi = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
$script:GpuName = if ($script:HasNvidiaSmi) { 'Detecting GPU...' } else { 'No NVIDIA GPU detected' }

function Initialize-Console {
    try {
        if ([Console]::BufferWidth -ne $script:ConsoleWidth) {
            [Console]::BufferWidth = $script:ConsoleWidth
        }
        if ([Console]::WindowWidth -lt $script:ConsoleWidth) {
            [Console]::WindowWidth = $script:ConsoleWidth
        }
        if ([Console]::BufferHeight -lt 30) {
            [Console]::BufferHeight = 30
        }
        if ([Console]::WindowHeight -lt 26) {
            [Console]::WindowHeight = 26
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
    param([string]$Key, [string]$Label, [int]$LineNum)
    $script:ValueRows[$Key] = $LineNum
    Write-Host ($Label + (' ' * $script:ValueWidth))
}

function Initialize-Display {
    $script:ValueRows = @{}
    $line = 0

    Clear-Host
    Write-Host ('=' * $script:ConsoleWidth); $line++
    Write-Host '            LLM HARDWARE MONITOR (VRAM + SYSTEM FEED)'; $line++
    Write-Host $script:GpuName.PadRight($script:ConsoleWidth); $line++
    Write-Host ('=' * $script:ConsoleWidth); $line++
    if ($script:CounterWarning) {
        Write-Host $script:CounterWarning.PadRight($script:ConsoleWidth); $line++
    }

    Write-LabelRow 'Cpu' 'CPU Usage:        ' $line; $line++
    Write-LabelRow 'Ram' 'System RAM:       ' $line; $line++
    Write-Host ('-' * $script:ConsoleWidth); $line++
    Write-LabelRow 'Gpu' 'GPU Compute:      ' $line; $line++
    Write-LabelRow 'GpuTemp' 'GPU Temp:         ' $line; $line++
    Write-LabelRow 'GpuPower' 'GPU Power:        ' $line; $line++
    Write-Host ('-' * $script:ConsoleWidth); $line++
    Write-LabelRow 'VramUsed' 'VRAM Used:        ' $line; $line++
    Write-LabelRow 'VramFree' 'VRAM Free:        ' $line; $line++
    Write-LabelRow 'VramTotal' 'VRAM Total:       ' $line; $line++
    Write-LabelRow 'VramPct' 'VRAM % Used:      ' $line; $line++
    Write-LabelRow 'VramMemUtil' 'VRAM Mem Util:    ' $line; $line++
    Write-LabelRow 'SharedVram' 'Shared GPU RAM:   ' $line; $line++
    Write-LabelRow 'RamHeadroom' 'RAM for Offload:  ' $line; $line++
    Write-Host ('-' * $script:ConsoleWidth); $line++
    Write-LabelRow 'DiskRead' 'Disk Read:        ' $line; $line++
    Write-LabelRow 'DiskWrite' 'Disk Write:       ' $line; $line++
    Write-LabelRow 'Network' 'Network:          ' $line; $line++
    Write-Host ('-' * $script:ConsoleWidth); $line++

    $script:FooterRow = $line
    Write-Host ('Updating every {0:N1}s. Press Ctrl+C to exit.' -f $IntervalSeconds); $line++
    Write-Host ''; $line++
    Write-Host ''; $line++

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
    Set-Value 'Ram' ('{0,5:N1} / {1,5:N1} GB  ({2,5:N1} GB free)' -f $Metrics.RamUsedGB, $Metrics.RamTotalGB, $Metrics.RamFreeGB)
    Set-Value 'Gpu' ('{0,5:N1} %' -f $Metrics.GpuPercent)
    Set-Value 'GpuTemp' ('{0} C' -f $Metrics.GpuTemp)
    Set-Value 'GpuPower' $Metrics.GpuPower
    Set-Value 'VramUsed' ('{0,6:N2} GB' -f $Metrics.VramUsedGB)
    Set-Value 'VramFree' ('{0,6:N2} GB' -f $Metrics.VramFreeGB)
    Set-Value 'VramTotal' ('{0,6:N2} GB' -f $Metrics.VramTotalGB)
    Set-Value 'VramPct' ('{0,5:N1} %' -f $Metrics.VramPctUsed)
    Set-Value 'VramMemUtil' ('{0,5:N1} %' -f $Metrics.VramMemUtil)
    Set-Value 'SharedVram' $Metrics.SharedVramLabel
    Set-Value 'RamHeadroom' $Metrics.RamHeadroomLabel
    Set-Value 'DiskRead' $Metrics.DiskRead
    Set-Value 'DiskWrite' $Metrics.DiskWrite
    Set-Value 'Network' $Metrics.NetThroughput

    [Console]::SetCursorPosition(0, $script:FooterRow)
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

Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -ErrorAction SilentlyContinue | Out-Null

try {
    while ($true) {
        if (((Get-Date) - $staticCache.LastStaticRefresh).TotalSeconds -ge 30) {
            $staticCache.RamTotalGB = Get-RamTotalGB
            $staticCache.LastStaticRefresh = Get-Date
        }

        $sampleInterval = [math]::Min(1, $IntervalSeconds)
        $allSamples = Get-CounterSamples -SampleInterval $sampleInterval

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

        Update-Display @{
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
