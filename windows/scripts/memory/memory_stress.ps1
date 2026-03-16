# =============================================================================
# Script      : memory_stress.ps1
# Description : Memory stress test for Intel/AMD Windows servers
#               Allocates a configurable percentage of RAM and exercises
#               sequential and random access patterns.
# Usage       : .\memory_stress.ps1 [OPTIONS]
# Date        : 2026-03-16
# =============================================================================
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('d')][int]  $Duration   = 14400,   # seconds (4 hours)
    [Alias('p')][ValidateRange(1,95)]
               [int]  $MemPercent = 80,        # % of total RAM to allocate
    [Alias('w')][int]  $Workers   = 0,         # 0 = auto (1 per NUMA node / socket)
    [Alias('y')][switch]$Yes                   # skip confirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ResultDir = Join-Path (Split-Path $ScriptDir -Parent) 'results'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $ResultDir "memory_stress_$($env:COMPUTERNAME)_${Timestamp}.log"

$null = New-Item -ItemType Directory -Force -Path $ResultDir

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

# ── Validate params ───────────────────────────────────────────────────────────
if ($Duration -lt 1) { Log-Error "-Duration must be a positive integer (seconds)." }

# ── Memory Detection ──────────────────────────────────────────────────────────
function Get-MemoryInfo {
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    $os   = Get-CimInstance -ClassName Win32_OperatingSystem
    $procs = @(Get-CimInstance -ClassName Win32_Processor)

    $script:TotalMemMB  = [int]($cs.TotalPhysicalMemory / 1MB)
    $script:TotalMemGB  = [int]($script:TotalMemMB / 1024)
    $script:FreeMemMB   = [int]($os.FreePhysicalMemory / 1KB)
    $script:Sockets     = $procs.Count

    # DIMM slot details (informational only)
    try {
        $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory)
        $script:DimmCount    = $dimms.Count
        $script:DimmSpeedMHz = ($dimms | Where-Object Speed | Select-Object -First 1 -ExpandProperty Speed)
    } catch {
        $script:DimmCount    = 0
        $script:DimmSpeedMHz = 0
    }

    # Determine number of workers
    $script:ActiveWorkers = if ($Workers -gt 0) { $Workers } else { [Math]::Max(1, $script:Sockets) }

    # Memory per worker in MB
    $targetMB = [int]($script:TotalMemMB * $MemPercent / 100)
    $script:MemPerWorkerMB = [int]($targetMB / $script:ActiveWorkers)
    $script:StressTotalMB  = $script:MemPerWorkerMB * $script:ActiveWorkers
}

function Print-MemoryInfo {
    Log-Section "Memory Information"
    $dh = [int]($Duration / 3600); $dm = [int](($Duration % 3600) / 60); $ds = $Duration % 60
    $dimmInfo = if ($script:DimmCount -gt 0) { "$($script:DimmCount) slots @ $($script:DimmSpeedMHz) MHz" } else { "N/A" }
    @"
  Total RAM       : $($script:TotalMemGB) GB  ($($script:TotalMemMB) MB)
  Free (now)      : $($script:FreeMemMB) MB
  Sockets         : $($script:Sockets)
  DIMM Info       : $dimmInfo
  Workers         : $($script:ActiveWorkers)
  Stress Percent  : ${MemPercent}%
  Mem/Worker      : $($script:MemPerWorkerMB) MB
  Total Stressed  : $($script:StressTotalMB) MB  (~$([int]($script:StressTotalMB/1024)) GB)
  Duration        : ${Duration}s  (${dh}h ${dm}m ${ds}s)
"@ | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor White
}

# ── Monitoring (background job) ────────────────────────────────────────────────
function Start-Monitoring {
    $logPath = $LogFile

    $script:MonitorJob = Start-Job -ScriptBlock {
        param([string]$LogPath)
        while ($true) {
            try {
                $os    = Get-CimInstance -ClassName Win32_OperatingSystem
                $freeMB = [int]($os.FreePhysicalMemory / 1KB)
                $totalMB = [int]($os.TotalVisibleMemorySize / 1KB)
                $usedMB = $totalMB - $freeMB
                $usedPct = [int]($usedMB * 100 / $totalMB)
                $ts = Get-Date -Format 'HH:mm:ss'
                Add-Content -Path $LogPath -Value "[MONITOR] $ts  Mem used: ${usedMB} MB / ${totalMB} MB (${usedPct}%)  Free: ${freeMB} MB"
            } catch { }
            Start-Sleep -Seconds 30
        }
    } -ArgumentList $logPath

    Log-Info "Memory monitor started (Job ID $($script:MonitorJob.Id), interval 30s)"
}

function Stop-Monitoring {
    if ($script:MonitorJob) {
        Stop-Job  $script:MonitorJob -ErrorAction SilentlyContinue
        Remove-Job $script:MonitorJob -ErrorAction SilentlyContinue
        $script:MonitorJob = $null
    }
}

# ── Stress Worker ─────────────────────────────────────────────────────────────
#
# Each Runspace:
#   1. Allocates TargetMB of byte arrays in 64 MB chunks, touching every page
#      to commit physical memory (prevents virtual memory tricks).
#   2. Runs sequential then random write patterns until the deadline.
#
$StressScript = {
    param([int]$TargetMB, [int]$DurationSec)

    $end       = [DateTime]::UtcNow.AddSeconds($DurationSec)
    $chunkMB   = 64
    $chunkSize = $chunkMB * 1024 * 1024
    $pageSize  = 4096
    $rand      = [Random]::new([int][DateTime]::UtcNow.Ticks)
    $buffers   = [System.Collections.Generic.List[byte[]]]::new()

    # ── Phase 1: allocate and touch (commit physical pages) ──────────────────
    $allocatedMB = 0
    while ($allocatedMB -lt $TargetMB -and [DateTime]::UtcNow -lt $end) {
        $remainMB  = $TargetMB - $allocatedMB
        $thisSize  = [Math]::Min($chunkSize, $remainMB * 1024 * 1024)
        $buf       = [byte[]]::new($thisSize)
        # Touch every 4K page to force physical allocation
        for ($i = 0; $i -lt $buf.Length; $i += $pageSize) { $buf[$i] = 0xAA }
        $buffers.Add($buf)
        $allocatedMB += [int]($thisSize / 1MB)
    }

    # ── Phase 2: sequential write (cache-line thrash) ─────────────────────────
    while ([DateTime]::UtcNow -lt $end) {
        foreach ($buf in $buffers) {
            for ($i = 0; $i -lt $buf.Length; $i += $pageSize) {
                $buf[$i] = [byte]($i -band 0xFF)
            }
        }
    }
}

function Start-StressWorkers {
    $script:Pool = [RunspaceFactory]::CreateRunspacePool(1, $script:ActiveWorkers)
    $script:Pool.Open()

    $script:Workers = @()
    for ($i = 0; $i -lt $script:ActiveWorkers; $i++) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($StressScript).AddParameter('TargetMB', $script:MemPerWorkerMB).AddParameter('DurationSec', $Duration)
        $handle = $ps.BeginInvoke()
        $script:Workers += [pscustomobject]@{ PS = $ps; Handle = $handle }
    }
    Log-Info "Launched $($script:ActiveWorkers) worker(s), $($script:MemPerWorkerMB) MB each"
}

function Wait-StressWorkers {
    Log-Info "Waiting for workers to complete..."
    foreach ($w in $script:Workers) {
        try { $w.PS.EndInvoke($w.Handle) } catch { }
        $w.PS.Dispose()
    }
    $script:Pool.Close()
    $script:Pool.Dispose()
    # Suggest GC to return memory to OS
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

# ── Progress Display ──────────────────────────────────────────────────────────
function Show-Progress {
    $start = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $start).TotalSeconds -lt $Duration) {
        Start-Sleep -Seconds 60
        $alive = $script:Workers | Where-Object { -not $_.Handle.IsCompleted }
        if (-not $alive) { break }

        $elapsed   = [int]([DateTime]::UtcNow - $start).TotalSeconds
        $remaining = [Math]::Max(0, $Duration - $elapsed)
        $pct       = [int]($elapsed * 100 / $Duration)
        $os        = Get-CimInstance -ClassName Win32_OperatingSystem
        $freeMB    = [int]($os.FreePhysicalMemory / 1KB)
        Log-Info "Progress: $pct%  elapsed: ${elapsed}s  remaining: ~${remaining}s  MemFree: ${freeMB} MB"
    }
}

# ── Snapshots ─────────────────────────────────────────────────────────────────
function Write-Snapshot {
    param([string]$Label)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    @"

=== $Label  $(Get-Date) ===
  TotalVisible  : $([int]($os.TotalVisibleMemorySize/1KB)) MB
  FreePhysical  : $([int]($os.FreePhysicalMemory/1KB)) MB
  TotalVirtual  : $([int]($os.TotalVirtualMemorySize/1KB)) MB
  FreeVirtual   : $([int]($os.FreeVirtualMemory/1KB)) MB
"@ | Add-Content -Path $LogFile
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
function Invoke-Cleanup {
    Stop-Monitoring
    if ($script:Pool -and $script:Pool.RunspacePoolStateInfo.State -ne 'Closed') {
        try { $script:Pool.Close() } catch { }
    }
    Log-Info "Log saved to: $LogFile"
}

# ── Main ──────────────────────────────────────────────────────────────────────
try {
    $null = New-Item -ItemType File -Force -Path $LogFile

    Log-Section "Memory Stress Test — $(Get-Date)"
    Log-Info "Host : $($env:COMPUTERNAME)"
    Log-Info "Log  : $LogFile"

    Get-MemoryInfo
    Print-MemoryInfo

    if (-not $Yes) {
        Write-Host "`nReady to start. Press ENTER to continue, Ctrl+C to cancel..." -ForegroundColor Yellow
        $null = Read-Host
    }

    Write-Snapshot "Pre-Test"
    Log-Info "Pre-test snapshot saved."

    Start-Monitoring
    Start-StressWorkers
    Show-Progress
    Wait-StressWorkers
    Stop-Monitoring

    Write-Snapshot "Post-Test"
    Log-Info "Post-test snapshot saved."

    Log-Section "Test Complete"
    Log-Info "Duration : ${Duration}s"
    Log-Info "Status   : DONE"
    Log-Info "Log file : $LogFile"

} finally {
    Invoke-Cleanup
}
