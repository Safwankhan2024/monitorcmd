<# : 
@echo off
title Lightweight Hardware Monitor (Task Manager Engine)
mode con cols=65 lines=13
:: This executes the PowerShell code below natively without temp files
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw)))"
exit /b
#>

# --- POWERSHELL CODE STARTS HERE ---
$ErrorActionPreference = 'SilentlyContinue'

# 1. Get Total Dedicated VRAM (Try NVIDIA driver first, fallback to WMI)
$vramTotalGB = "Unknown"
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $nvMem = (nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
    if ($nvMem -match '\d+') { $vramTotalGB = [math]::Round([int]$matches[0] / 1024, 2) }
}
if ($vramTotalGB -eq "Unknown") {
    $gpuHardware = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 } | Select-Object -First 1
    if ($gpuHardware) { $vramTotalGB = [math]::Round($gpuHardware.AdapterRAM / 1GB, 2) }
}

while ($true) {
    # CPU
    $cpuCounter = Get-Counter "\Processor(_Total)\% Processor Time"
    $cpu = if ($cpuCounter) { [math]::Round($cpuCounter.CounterSamples.CookedValue, 1) } else { 0 }

    # RAM & Max Shared Limit (Windows allocates ~50% of System RAM as Shared GPU limit)
    $os = Get-CimInstance Win32_OperatingSystem
    $rTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $rLeft  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $rUse   = [math]::Round($rTotal - $rLeft, 1)
    $sharedTotal = [math]::Round($rTotal / 2, 1) 

    # GPU Usage
    $gpuUtil = Get-Counter "\GPU Engine(*engtype_3D)\Utilization Percentage"
    $gpuUse  = if ($gpuUtil) { [math]::Round(($gpuUtil.CounterSamples.CookedValue | Measure-Object -Sum).Sum, 1) } else { 0 }
    if ($gpuUse -gt 100) { $gpuUse = 100 }

    # GPU Temp
    $gpuTemp = "N/A"
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $nvTemp = (nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)
        if ($nvTemp -match '\d+') { $gpuTemp = $matches[0] }
    }
    if ($gpuTemp -eq "N/A") {
        $gpuTempCounter = Get-Counter "\Thermal Zone Information(*)\Temperature"
        if ($gpuTempCounter) {
            $rawTemp = ($gpuTempCounter.CounterSamples.CookedValue | Measure-Object -Max).Maximum
            if ($rawTemp -and $rawTemp -gt 2731.5) { $gpuTemp = [math]::Round(($rawTemp - 2731.5) / 10, 0) }
        }
    }

    # Dedicated VRAM Usage (Physical VRAM on the card)
    $vramCounter = Get-Counter "\GPU Adapter Memory(*)\Dedicated Usage"
    $vramUse = if ($vramCounter) { [math]::Round((($vramCounter.CounterSamples.CookedValue | Measure-Object -Sum).Sum) / 1GB, 2) } else { 0 }
    
    # Shared VRAM Usage (System RAM borrowed by the GPU)
    $sharedCounter = Get-Counter "\GPU Adapter Memory(*)\Shared Usage"
    $sharedUse = if ($sharedCounter) { [math]::Round((($sharedCounter.CounterSamples.CookedValue | Measure-Object -Sum).Sum) / 1GB, 2) } else { 0 }

    # Render Interface
    Clear-Host
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "        LIGHTWEIGHT HARDWARE MONITOR (TASK MANAGER FEED)        " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "CPU Usage:      $cpu % "
    Write-Host "RAM Usage:      $rUse GB / Total: $rTotal GB ($rLeft GB Free)"
    Write-Host "----------------------------------------------------------------"
    Write-Host "GPU Usage:      $gpuUse % "
    Write-Host "GPU Temp:       $gpuTemp C"
    Write-Host "Dedicated VRAM: $vramUse GB / Total: $vramTotalGB GB"
    Write-Host "Shared VRAM:    $sharedUse GB / Total: $sharedTotal GB"
    Write-Host "----------------------------------------------------------------"
    Write-Host "Updating every 1 seconds. Press CTRL+C to Exit." -ForegroundColor DarkGray
    
    Start-Sleep -Seconds 1
}