# =============================================================================
# Script      : cpu_stress.ps1
# Description : CPU stress test for Intel/AMD single/dual-socket Windows servers
# Usage       : .\cpu_stress.ps1 [OPTIONS]
# Date        : 2026-03-16
# =============================================================================
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('d')][int]   $Duration = 14400,              # seconds (4 hours)
    [Alias('t')][int]   $Threads  = 0,                  # 0 = auto (all logical CPUs)
    [Alias('m')][ValidateSet('matrixprod','prime','all')]
                [string]$Method   = 'matrixprod',
    [Alias('y')][switch]$Yes                             # skip confirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ResultDir = Join-Path (Split-Path $ScriptDir -Parent) 'results'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $ResultDir "cpu_stress_$($env:COMPUTERNAME)_${Timestamp}.log"

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

# ── CPU Detection ─────────────────────────────────────────────────────────────
function Get-CpuInfo {
    $procs   = @(Get-CimInstance -ClassName Win32_Processor)
    $logical = (Get-CimInstance -ClassName Win32_ComputerSystem).NumberOfLogicalProcessors

    $script:CpuModel   = $procs[0].Name.Trim()
    $script:Sockets    = $procs.Count
    $script:CoresTotal = ($procs | Measure-Object -Property NumberOfCores -Sum).Sum
    $script:LogicalCpu = $logical
    $script:NumaNodes  = $procs.Count   # approximation: 1 NUMA node per socket

    # Temperature via WMI — often requires admin and correct drivers
    try {
        $null = Get-WmiObject -Namespace 'root\wmi' -Class 'MSAcpi_ThermalZoneTemperature' -EA Stop
        $script:TempOk = $true
    } catch {
        $script:TempOk = $false
    }
}

function Print-CpuInfo {
    Log-Section "CPU Information"
    $dh = [int]($Duration / 3600); $dm = [int](($Duration % 3600) / 60); $ds = $Duration % 60
    @"
  Model         : $CpuModel
  Sockets       : $Sockets
  Physical Cores : $CoresTotal
  Logical CPUs  : $LogicalCpu
  NUMA Nodes    : $NumaNodes
  Threads       : $($script:ActiveThreads)
  Method        : $Method
  Duration      : ${Duration}s  (${dh}h ${dm}m ${ds}s)
"@ | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor White
}

# ── Temperature sampling ──────────────────────────────────────────────────────
function Get-CpuTemp {
    if (-not $TempOk) { return $null }
    try {
        # MSAcpi_ThermalZoneTemperature.CurrentTemperature is in tenths of Kelvin
        $zones = Get-WmiObject -Namespace 'root\wmi' -Class 'MSAcpi_ThermalZoneTemperature' -EA SilentlyContinue
        if ($zones) {
            $temps = $zones | ForEach-Object { [int](($_.CurrentTemperature - 2732) / 10) }
            return ($temps | Measure-Object -Maximum).Maximum
        }
    } catch { }
    return $null
}

# ── Monitoring (background job) ────────────────────────────────────────────────
function Start-Monitoring {
    $logPath = $LogFile
    $interval = 10

    $script:MonitorJob = Start-Job -ScriptBlock {
        param([string]$LogPath, [int]$IntervalSec)
        while ($true) {
            try {
                # CPU utilization via performance counter
                $cpuPct = (Get-CimInstance -ClassName Win32_Processor |
                    Measure-Object -Property LoadPercentage -Average).Average
                $ts = Get-Date -Format 'HH:mm:ss'
                $line = "[MONITOR] $ts  CPU: ${cpuPct}%"

                # Temperature if available
                try {
                    $zones = Get-WmiObject -Namespace 'root\wmi' -Class 'MSAcpi_ThermalZoneTemperature' -EA Stop
                    $maxT = ($zones | ForEach-Object { [int](($_.CurrentTemperature - 2732) / 10) } |
                        Measure-Object -Maximum).Maximum
                    $line += "  Temp: ${maxT}°C"
                } catch { }

                Add-Content -Path $LogPath -Value $line
            } catch { }
            Start-Sleep -Seconds $IntervalSec
        }
    } -ArgumentList $logPath, $interval

    Log-Info "CPU monitor started (Job ID $($script:MonitorJob.Id), interval ${interval}s)"
}

function Stop-Monitoring {
    if ($script:MonitorJob) {
        Stop-Job  $script:MonitorJob -ErrorAction SilentlyContinue
        Remove-Job $script:MonitorJob -ErrorAction SilentlyContinue
        $script:MonitorJob = $null
    }
}

# ── Stress Workers (RunspacePool) ─────────────────────────────────────────────
#
# Each Runspace runs a tight CPU-bound loop until the deadline.
# matrixprod : 150×150 double-precision matrix multiplication (FP intensive)
# prime      : trial-division prime sieve (integer intensive)
# all        : alternates between both methods each iteration
#
$MatrixScript = {
    param([int]$DurationSec)
    $end = [DateTime]::UtcNow.AddSeconds($DurationSec)
    $n = 150
    $rand = [Random]::new([int][DateTime]::UtcNow.Ticks)
    $A = [double[,]]::new($n, $n)
    $B = [double[,]]::new($n, $n)
    for ($i = 0; $i -lt $n; $i++) {
        for ($j = 0; $j -lt $n; $j++) {
            $A[$i,$j] = $rand.NextDouble(); $B[$i,$j] = $rand.NextDouble()
        }
    }
    while ([DateTime]::UtcNow -lt $end) {
        $C = [double[,]]::new($n, $n)
        for ($i = 0; $i -lt $n; $i++) {
            for ($j = 0; $j -lt $n; $j++) {
                $s = 0.0
                for ($k = 0; $k -lt $n; $k++) { $s += $A[$i,$k] * $B[$k,$j] }
                $C[$i,$j] = $s
            }
        }
    }
}

$PrimeScript = {
    param([int]$DurationSec)
    $end = [DateTime]::UtcNow.AddSeconds($DurationSec)
    while ([DateTime]::UtcNow -lt $end) {
        $limit = 50000
        $sieve = [bool[]]::new($limit + 1)
        for ($i = 2; $i -le $limit; $i++) { $sieve[$i] = $true }
        for ($i = 2; $i * $i -le $limit; $i++) {
            if ($sieve[$i]) {
                for ($j = $i * $i; $j -le $limit; $j += $i) { $sieve[$j] = $false }
            }
        }
    }
}

$AllScript = {
    param([int]$DurationSec)
    $end = [DateTime]::UtcNow.AddSeconds($DurationSec)
    $n = 100; $rand = [Random]::new()
    $A = [double[,]]::new($n, $n); $B = [double[,]]::new($n, $n)
    for ($i = 0; $i -lt $n; $i++) { for ($j = 0; $j -lt $n; $j++) {
        $A[$i,$j] = $rand.NextDouble(); $B[$i,$j] = $rand.NextDouble()
    }}
    $toggle = $false
    while ([DateTime]::UtcNow -lt $end) {
        if ($toggle) {
            $C = [double[,]]::new($n, $n)
            for ($i = 0; $i -lt $n; $i++) { for ($j = 0; $j -lt $n; $j++) {
                $s = 0.0; for ($k = 0; $k -lt $n; $k++) { $s += $A[$i,$k]*$B[$k,$j] }
                $C[$i,$j] = $s
            }}
        } else {
            $limit = 30000; $sv = [bool[]]::new($limit+1)
            for ($i = 2; $i -le $limit; $i++) { $sv[$i]=$true }
            for ($i = 2; $i*$i -le $limit; $i++) {
                if ($sv[$i]) { for ($j = $i*$i; $j -le $limit; $j+=$i) { $sv[$j]=$false } }
            }
        }
        $toggle = -not $toggle
    }
}

function Start-StressWorkers {
    $script:Pool = [RunspaceFactory]::CreateRunspacePool(1, $script:ActiveThreads)
    $script:Pool.Open()

    $scriptBlock = switch ($Method) {
        'prime'     { $PrimeScript  }
        'all'       { $AllScript    }
        default     { $MatrixScript }
    }

    $script:Workers = @()
    for ($i = 0; $i -lt $script:ActiveThreads; $i++) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($scriptBlock).AddParameter('DurationSec', $Duration)
        $handle = $ps.BeginInvoke()
        $script:Workers += [pscustomobject]@{ PS = $ps; Handle = $handle }
    }
    Log-Info "Launched $($script:ActiveThreads) stress workers (method: $Method)"
}

function Wait-StressWorkers {
    Log-Info "Waiting for workers to complete..."
    foreach ($w in $script:Workers) {
        try { $w.PS.EndInvoke($w.Handle) } catch { }
        $w.PS.Dispose()
    }
    $script:Pool.Close()
    $script:Pool.Dispose()
}

# ── Progress Display ──────────────────────────────────────────────────────────
function Show-Progress {
    $start = [DateTime]::UtcNow
    $interval = 30

    while (([DateTime]::UtcNow - $start).TotalSeconds -lt $Duration) {
        Start-Sleep -Seconds $interval

        # Check if any worker is still alive
        $alive = $script:Workers | Where-Object { -not $_.Handle.IsCompleted }
        if (-not $alive) { break }

        $elapsed   = [int]([DateTime]::UtcNow - $start).TotalSeconds
        $remaining = [Math]::Max(0, $Duration - $elapsed)
        $pct       = [int]($elapsed * 100 / $Duration)
        $cpuPct    = (Get-CimInstance -ClassName Win32_Processor |
                        Measure-Object -Property LoadPercentage -Average).Average
        Log-Info "Progress: $pct%  elapsed: ${elapsed}s  remaining: ~${remaining}s  CPU: $cpuPct%"
    }
}

# ── Pre / Post snapshots ──────────────────────────────────────────────────────
function Write-Snapshot {
    param([string]$Label)
    @"

=== $Label  $(Get-Date) ===
--- Win32_Processor ---
$((Get-CimInstance Win32_Processor | Format-List Name,NumberOfCores,NumberOfLogicalProcessors,LoadPercentage | Out-String))
--- Win32_OperatingSystem (memory) ---
$((Get-CimInstance Win32_OperatingSystem | Format-List TotalVisibleMemorySize,FreePhysicalMemory | Out-String))
"@ | Add-Content -Path $LogFile
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
function Invoke-Cleanup {
    Stop-Monitoring
    if ($script:Pool -and $script:Pool.RunspacePoolStateInfo.State -ne 'Closed') {
        $script:Pool.Close() | Out-Null
    }
    Log-Info "Log saved to: $LogFile"
}

# ── Main ──────────────────────────────────────────────────────────────────────
try {
    $null = New-Item -ItemType File -Force -Path $LogFile

    Log-Section "CPU Stress Test — $(Get-Date)"
    Log-Info "Host : $($env:COMPUTERNAME)"
    Log-Info "Log  : $LogFile"

    Get-CpuInfo

    # Determine active thread count
    $script:ActiveThreads = if ($Threads -gt 0) { $Threads } else { $LogicalCpu }

    Print-CpuInfo

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
