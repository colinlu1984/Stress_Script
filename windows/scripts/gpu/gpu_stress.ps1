# =============================================================================
# Script      : gpu_stress.ps1
# Description : GPU stress test for Windows servers — supports single/multi-GPU
#               (up to 8 cards). Auto-selects gpu-burn or dcgmi engine.
#               Compatible with H100/H800, A100/A800, RTX 4090/3090.
#
# Engines:
#   gst    NVIDIA GPUStressTest — https://github.com/NVIDIA/GPUStressTest
#          Requires: CUDA 12.x + Visual Studio 2022 to build
#          Files needed: gst.exe + pthreadVC3.dll (place next to this script)
#   dcgmi  NVIDIA DCGM — https://developer.nvidia.com/dcgm
#          Best choice for H100/A100 on Windows Server
# Usage       : .\gpu_stress.ps1 [OPTIONS]
# Date        : 2026-03-16
# =============================================================================
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('g')][string]  $Gpu        = '',      # comma-separated GPU indices, '' = all
    [Alias('d')][int]     $Duration   = 14400,   # seconds (4 hours)
    [Alias('e')][ValidateSet('auto','gst','dcgmi')]
               [string]  $Engine     = 'auto',
    [Alias('T')][int]     $TempLimit  = 85,      # °C warning threshold
               [switch]  $NoEccStop              # don't abort on ECC uncorrected error
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ResultDir = Join-Path (Split-Path $ScriptDir -Parent) 'results'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $ResultDir "gpu_stress_${Timestamp}.log"

$null = New-Item -ItemType Directory -Force -Path $ResultDir

# ── Runtime state ─────────────────────────────────────────────────────────────
$NvSmiCmd    = ''
$GstCmd      = ''    # NVIDIA GPUStressTest (gst.exe)
$DcgmiCmd    = ''
$EngineUsed  = ''
$GpuList     = @()   # final list of GPU indices to stress
$MonitorJob  = $null
$StopOnEcc   = -not $NoEccStop
$OverallPass = $true

# ── Logging ───────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Level, [string]$Message, [string]$Color = 'White')
    $line = "[{0}]  {1}  {2}" -f $Level.PadRight(5), (Get-Date -Format 'HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Host $line -ForegroundColor $Color
}
function Log-Info  { param([string]$m) Write-Log 'INFO'  $m 'Green'  }
function Log-Warn  { param([string]$m) Write-Log 'WARN'  $m 'Yellow' }
function Log-Error { param([string]$m) Write-Log 'ERROR' $m 'Red'; exit 1 }
function Log-Sep   { $bar = '─' * 72; Add-Content $LogFile $bar; Write-Host $bar -ForegroundColor Cyan }
function Log-Section { param([string]$t) Log-Sep; Log-Info "  $t"; Log-Sep }

# ── nvidia-smi detection ──────────────────────────────────────────────────────
function Find-NvidiaSmi {
    # Common install path on Windows
    $nvsmPath = 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    if (Test-Path $nvsmPath) { $script:NvSmiCmd = $nvsmPath; return }

    $cmd = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $script:NvSmiCmd = $cmd.Source; return }

    Log-Error @"
nvidia-smi.exe not found.
  Ensure NVIDIA drivers are installed and nvidia-smi.exe is in PATH.
  Typical location: C:\Program Files\NVIDIA Corporation\NVSMI\
"@
}

# ── GPU enumeration ───────────────────────────────────────────────────────────
function Detect-Gpus {
    $indices = & $script:NvSmiCmd --query-gpu=index --format=csv,noheader,nounits 2>&1 |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { $_.Trim() }

    if (-not $indices) { Log-Error "No NVIDIA GPUs detected by nvidia-smi." }

    # Resolve GPU list from parameter
    $script:GpuList = if ($Gpu) {
        $Gpu -split ',' | ForEach-Object { $_.Trim() }
    } else {
        @($indices)
    }

    Log-Sep
    Log-Info "Detected $(@($indices).Count) GPU(s). Stressing: $($script:GpuList -join ', ')"
    Log-Sep

    & $script:NvSmiCmd --query-gpu=index,name,driver_version,memory.total,ecc.mode.current `
        --format=csv,noheader,nounits 2>&1 | ForEach-Object {
        $parts = $_ -split ','
        if ($parts.Count -ge 5) {
            Log-Info ("  GPU {0}: {1} | VRAM: {2} MiB | ECC: {3} | Driver: {4}" -f `
                $parts[0].Trim(), $parts[1].Trim(), $parts[3].Trim(), $parts[4].Trim(), $parts[2].Trim())
        }
    }
    Log-Sep
}

# ── Engine selection ──────────────────────────────────────────────────────────

function Find-Gst {
    # gst.exe = NVIDIA GPUStressTest (https://github.com/NVIDIA/GPUStressTest)
    # Place gst.exe (and pthreadVC3.dll) in the same directory as this script.
    $local = Join-Path $ScriptDir 'gst.exe'
    if (Test-Path $local) { $script:GstCmd = $local; return $true }
    $cmd = Get-Command 'gst.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $script:GstCmd = $cmd.Source; return $true }
    return $false
}

function Find-Dcgmi {
    $candidates = @(
        'dcgmi.exe',
        'C:\Program Files\NVIDIA Corporation\DCGM\dcgmi.exe'
    )
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $script:DcgmiCmd = $cmd.Source; return $true }
        if (Test-Path $c) { $script:DcgmiCmd = $c; return $true }
    }
    return $false
}

function Select-Engine {
    switch ($Engine) {
        'auto' {
            if (Find-Dcgmi) {
                # dcgmi is preferred for H100/A100 data-center GPUs on Windows Server
                $script:EngineUsed = 'dcgmi'
                Log-Info "Engine: dcgmi ($($script:DcgmiCmd))"
            } elseif (Find-Gst) {
                $script:EngineUsed = 'gst'
                Log-Info "Engine: NVIDIA GPUStressTest ($($script:GstCmd))"
            } else {
                Log-Error @"
No stress engine found. Install one of the following:

  gst.exe   NVIDIA GPUStressTest (recommended, supports all NVIDIA GPUs)
            Build: https://github.com/NVIDIA/GPUStressTest
            Requires: CUDA 12.x + Visual Studio 2022
            Place gst.exe and pthreadVC3.dll in: $ScriptDir

  dcgmi.exe NVIDIA DCGM (best for H100/A100 on Windows Server)
            Install: https://developer.nvidia.com/dcgm
"@
            }
        }
        'gst' {
            if (Find-Gst) {
                $script:EngineUsed = 'gst'
                Log-Info "Engine: NVIDIA GPUStressTest ($($script:GstCmd))"
            } else {
                Log-Error "gst.exe not found. Place gst.exe + pthreadVC3.dll in: $ScriptDir"
            }
        }
        'dcgmi' {
            if (Find-Dcgmi) {
                $script:EngineUsed = 'dcgmi'
                Log-Info "Engine: dcgmi ($($script:DcgmiCmd))"
            } else {
                Log-Error "dcgmi.exe not found. Install NVIDIA DCGM: https://developer.nvidia.com/dcgm"
            }
        }
    }
}

# ── Real-time monitoring (background job) ─────────────────────────────────────
#
# Polls nvidia-smi every 30 s. Warns on temperature or ECC violations.
# Optionally sends a Stop signal to the parent process on uncorrected ECC.
#
function Start-Monitoring {
    $logPath   = $LogFile
    $nvSmi     = $script:NvSmiCmd
    $gpuList   = $script:GpuList
    $tempLim   = $TempLimit
    $stopOnEcc = $StopOnEcc
    $parentPid = $PID

    $script:MonitorJob = Start-Job -ScriptBlock {
        param([string]$NvSmi, [string[]]$GpuList, [int]$TempLim,
              [bool]$StopOnEcc, [string]$LogPath, [int]$ParentPid)
        while ($true) {
            try {
                $rows = & $NvSmi `
                    --query-gpu=index,name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total `
                    --format=csv,noheader,nounits 2>&1

                foreach ($row in $rows) {
                    $p = $row -split ','
                    if ($p.Count -lt 9) { continue }
                    $idx      = $p[0].Trim()
                    $name     = $p[1].Trim().Substring(0, [Math]::Min(25, $p[1].Trim().Length))
                    $temp     = $p[2].Trim()
                    $util     = $p[3].Trim()
                    $power    = $p[4].Trim()
                    $memUsed  = $p[5].Trim()
                    $memTotal = $p[6].Trim()
                    $eccCorr  = $p[7].Trim()
                    $eccUncorr= $p[8].Trim()

                    if ($idx -notin $GpuList) { continue }

                    $ts = Get-Date -Format 'HH:mm:ss'
                    $line = "[MONITOR] $ts GPU{0,-2} {1,-25} Temp:{2,3}°C  Util:{3,3}%  Power:{4,6}W  Mem:{5,6}/{6}MiB  ECC:{7}/{8}" -f `
                        $idx, $name, $temp, $util, $power, $memUsed, $memTotal, $eccCorr, $eccUncorr
                    Add-Content -Path $LogPath -Value $line

                    # Temperature warning
                    if ($temp -match '^\d+$' -and [int]$temp -gt $TempLim) {
                        $warnLine = "[WARN]  $ts GPU${idx} temperature ${temp}°C exceeds threshold ${TempLim}°C!"
                        Add-Content -Path $LogPath -Value $warnLine
                        Write-Warning "GPU${idx} temperature ${temp}°C exceeds ${TempLim}°C!"
                    }

                    # ECC uncorrected error
                    if ($eccUncorr -match '^\d+$' -and [int]$eccUncorr -gt 0) {
                        $warnLine = "[WARN]  $ts GPU${idx} ECC uncorrected errors: ${eccUncorr}!"
                        Add-Content -Path $LogPath -Value $warnLine
                        Write-Warning "GPU${idx} ECC uncorrected errors: ${eccUncorr}!"
                        if ($StopOnEcc) {
                            "[ERROR] $ts Aborting due to ECC uncorrected errors on GPU${idx}." | Add-Content -Path $LogPath
                            # Signal parent process to stop
                            try { Stop-Process -Id $ParentPid -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                }
            } catch { }
            Start-Sleep -Seconds 30
        }
    } -ArgumentList $nvSmi, $gpuList, $tempLim, $stopOnEcc, $logPath, $parentPid

    Log-Info "Monitor started (Job ID $($script:MonitorJob.Id), interval 30s)"
}

function Stop-Monitoring {
    if ($script:MonitorJob) {
        Stop-Job  $script:MonitorJob -ErrorAction SilentlyContinue
        Remove-Job $script:MonitorJob -ErrorAction SilentlyContinue
        $script:MonitorJob = $null
    }
}

# ── NVIDIA GPUStressTest: one process per GPU (CUDA_VISIBLE_DEVICES binding) ───
#
# gst.exe accepts -T=n (loop count, not duration). Since loop duration varies by
# GPU model, we run with -T=9999 (effectively infinite) and terminate each process
# after $Duration seconds via Start-Job timeout — same pattern as the Linux version.
# Each instance sees only its own GPU via CUDA_VISIBLE_DEVICES.
#
function Run-Gst {
    $jobs = @()
    $gstBin = $script:GstCmd
    Log-Info "Launching NVIDIA GPUStressTest on GPU(s): $($script:GpuList -join ', ')  Duration: ${Duration}s"
    Log-Sep

    foreach ($gid in $script:GpuList) {
        Log-Info "  GPU${gid}: starting gst.exe -T=9999 (will run for ${Duration}s then stop)..."
        $logPath = $LogFile
        $job = Start-Job -ScriptBlock {
            param([string]$GstBin, [string]$GpuId, [string]$LogPath)
            $env:CUDA_VISIBLE_DEVICES = $GpuId
            # Redirect stdout/stderr to temp files, then append to shared log
            $out = & $GstBin -T=9999 2>&1 | Out-String
            "=== gst.exe GPU${GpuId} output ===`n$out" | Add-Content -Path $LogPath
        } -ArgumentList $gstBin, $gid, $logPath

        $jobs += [pscustomobject]@{ Job = $job; GpuId = $gid }
    }

    # Wait for Duration seconds, then stop all workers
    $null = Wait-Job -Job ($jobs | ForEach-Object { $_.Job }) -Timeout $Duration

    foreach ($j in $jobs) {
        if ($j.Job.State -eq 'Running') {
            Stop-Job $j.Job -ErrorAction SilentlyContinue
            Log-Info "  GPU$($j.GpuId): stopped after ${Duration}s"
        } elseif ($j.Job.State -eq 'Failed') {
            Log-Warn "  GPU$($j.GpuId): gst.exe job failed"
            $script:OverallPass = $false
        }
        Remove-Job $j.Job -ErrorAction SilentlyContinue
    }
}

# ── dcgmi: loop level-3 diagnostics until duration elapses ────────────────────
function Run-Dcgmi {
    $endTime = [DateTime]::UtcNow.AddSeconds($Duration)
    $round   = 0
    $gpuStr  = $script:GpuList -join ','
    Log-Info "Starting dcgmi diag loop — target duration ${Duration}s, GPU(s): $gpuStr"
    Log-Sep

    while ([DateTime]::UtcNow -lt $endTime) {
        $round++
        Log-Info "dcgmi diag round $round (level 3)..."
        try {
            $out = & $script:DcgmiCmd diag -g $gpuStr -r 3 2>&1 | Out-String
            "=== dcgmi diag round $round ===`n$out" | Add-Content $LogFile
            Log-Info "  Round $round complete."
        } catch {
            Log-Warn "  dcgmi diag round $round reported failure: $_"
            $script:OverallPass = $false
        }
    }
    Log-Info "dcgmi completed $round round(s)."
}

# ── Summary ───────────────────────────────────────────────────────────────────
function Print-Summary {
    Log-Sep
    Log-Info "Stress complete — Summary"
    Log-Sep

    $rows = & $script:NvSmiCmd `
        --query-gpu=index,temperature.gpu,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total `
        --format=csv,noheader,nounits 2>&1

    foreach ($row in $rows) {
        $p = $row -split ','
        if ($p.Count -lt 4) { continue }
        $idx      = $p[0].Trim()
        $temp     = $p[1].Trim()
        $eccCorr  = $p[2].Trim()
        $eccUncorr= $p[3].Trim()

        if ($idx -notin $script:GpuList) { continue }

        $eccStr = if ($eccCorr -match '^\d+$') {
            "corrected=$eccCorr  uncorrected=$eccUncorr"
            if ([int]$eccUncorr -gt 0) { $script:OverallPass = $false }
        } else {
            "N/A (ECC not supported)"
        }

        $status = if ($script:OverallPass) { 'PASS' } else { 'FAIL' }
        Log-Info "  GPU${idx}: final temp=${temp}°C  ECC: $eccStr  → $status"
    }

    Log-Sep
    $result = if ($script:OverallPass) { 'PASS' } else { 'FAIL' }
    Log-Info "Overall result : $result"
    Log-Info "Log file       : $LogFile"
    Log-Sep

    if (-not $script:OverallPass) { exit 1 }
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
function Invoke-Cleanup {
    Stop-Monitoring
    Log-Info "Log saved to: $LogFile"
}

# ── Main ──────────────────────────────────────────────────────────────────────
try {
    $null = New-Item -ItemType File -Force -Path $LogFile

    Log-Sep
    Log-Info "GPU Stress Test — $(Get-Date)"
    Log-Info "Duration: ${Duration}s  TempLimit: ${TempLimit}°C  StopOnECC: $StopOnEcc"
    Log-Sep

    Find-NvidiaSmi
    Log-Info "nvidia-smi: $NvSmiCmd"

    Detect-Gpus
    Select-Engine
    Start-Monitoring

    switch ($EngineUsed) {
        'gst'   { Run-Gst   }
        'dcgmi' { Run-Dcgmi }
    }

    Stop-Monitoring
    Print-Summary

} finally {
    Invoke-Cleanup
}
