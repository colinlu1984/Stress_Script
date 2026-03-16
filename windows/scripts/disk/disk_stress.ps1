# =============================================================================
# Script      : disk_stress.ps1
# Description : Disk stress test — supports Broadcom hardware RAID and
#               direct-attached NVMe / SSD on Windows servers.
#               Uses diskspd (Microsoft) as the I/O engine.
# Usage       : .\disk_stress.ps1 [OPTIONS]
# Date        : 2026-03-16
# Requires    : Run as Administrator; diskspd.exe in script dir or PATH
# =============================================================================
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Alias('d')][int]     $Duration   = 14400,   # seconds (4 hours)
    [Alias('D')][string[]]$Drive      = @(),      # e.g. C:, D: — empty = auto-detect
    [Alias('s')][string]  $Size       = '',       # diskspd test file size, e.g. 10G — empty = auto
    [Alias('r')][string]  $RaidLevel  = '',       # override: none/0/1/5/6/10
    [Alias('t')][string]  $DiskType   = '',       # override: hdd/ssd/nvme
    [Alias('y')][switch]  $Yes                    # skip confirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ResultDir = Join-Path (Split-Path $ScriptDir -Parent) 'results'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $ResultDir "disk_stress_$($env:COMPUTERNAME)_${Timestamp}.log"

$null = New-Item -ItemType Directory -Force -Path $ResultDir

# ── Runtime state ─────────────────────────────────────────────────────────────
$DiskspdCmd   = ''
$StorCliCmd   = ''
$StorCliOk    = $false
$HasRaidCard  = $false
$TargetDrives = @()    # resolved drive letters with colon, e.g. "C:", "D:"
$TestFiles    = @()    # paths to diskspd test files (one per drive)
$DetectedRaid = ''
$DetectedType = ''
$MonitorJob   = $null

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

# ── diskspd detection ─────────────────────────────────────────────────────────
function Find-Diskspd {
    # 1. Script directory (recommended: place diskspd.exe next to this script)
    $local = Join-Path $ScriptDir 'diskspd.exe'
    if (Test-Path $local) { $script:DiskspdCmd = $local; return $true }

    # 2. PATH
    $inPath = Get-Command 'diskspd.exe' -ErrorAction SilentlyContinue
    if ($inPath) { $script:DiskspdCmd = $inPath.Source; return $true }

    return $false
}

# ── storcli detection ─────────────────────────────────────────────────────────
function Find-StorCli {
    $candidates = @(
        (Join-Path $ScriptDir 'storcli64.exe'),
        'C:\Program Files (x86)\MegaRAID Storage Manager\storcli64.exe',
        'C:\Program Files\MegaRAID Storage Manager\storcli64.exe',
        'C:\storcli\storcli64.exe',
        'storcli64.exe'
    )
    foreach ($c in $candidates) {
        if ($c -notmatch '\\' -or (Test-Path $c)) {
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if ($cmd) { $script:StorCliCmd = $cmd.Source; return $true }
            if ((Test-Path $c)) { $script:StorCliCmd = $c; return $true }
        }
    }
    return $false
}

# ── RAID card detection ───────────────────────────────────────────────────────
function Detect-RaidCard {
    # Check PCI devices for Broadcom/LSI/Avago MegaRAID
    $pciDevs = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'MegaRAID|Broadcom.*RAID|LSI.*RAID|Avago' }
    if ($pciDevs) {
        $script:HasRaidCard = $true
        Log-Info "Broadcom/LSI hardware RAID controller detected."
    } else {
        Log-Info "No hardware RAID controller detected."
    }
}

# ── storcli query ─────────────────────────────────────────────────────────────
function Query-StorCli {
    if (-not $script:StorCliOk) { return }

    Log-Section "RAID Controller Info (storcli)"
    @(
        "/c0 show",
        "/c0/vall show",
        "/c0/eall/sall show"
    ) | ForEach-Object {
        $args = $_ -split ' '
        try {
            $out = & $script:StorCliCmd $args 2>&1 | Out-String
            "--- storcli64 $_ ---`n$out`n" | Add-Content $LogFile
        } catch { }
    }

    # Detect RAID level
    try {
        $vallOut = & $script:StorCliCmd /c0/vall show 2>&1 | Out-String
        if ($vallOut -match 'RAID(\d+)') {
            $script:DetectedRaid = $Matches[1]
            Log-Info "Detected RAID level: RAID$($script:DetectedRaid)"
        }
    } catch { }

    # Detect disk type (HDD vs SSD)
    if (-not $DiskType) {
        try {
            $pdOut = & $script:StorCliCmd /c0/eall/sall show 2>&1 | Out-String
            if ($pdOut -match 'Solid State Device') {
                $script:DetectedType = 'ssd'
            } else {
                $script:DetectedType = 'hdd'
            }
            Log-Info "Detected disk type: $($script:DetectedType.ToUpper())"
        } catch { }
    }
}

# ── Drive auto-detection ──────────────────────────────────────────────────────
function Detect-Drives {
    if ($Drive.Count -gt 0) {
        # User specified drives explicitly
        foreach ($d in $Drive) {
            $letter = $d.TrimEnd('\').TrimEnd(':') + ':'
            if (-not (Test-Path "${letter}\")) { Log-Error "Drive not found: $letter" }
            $script:TargetDrives += $letter
        }
        Log-Info "Using specified drive(s): $($script:TargetDrives -join ', ')"
        return
    }

    # Auto-detect: fixed volumes excluding system drive if possible
    $vols = Get-Volume | Where-Object {
        $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystemType -ne 'Unknown'
    }

    if (-not $vols) { Log-Error "No fixed volumes detected. Use -Drive to specify manually." }

    foreach ($v in $vols) {
        $script:TargetDrives += "$($v.DriveLetter):"
    }
    Log-Info "Auto-detected drive(s): $($script:TargetDrives -join ', ')"
}

# ── Resolve disk type and RAID level ─────────────────────────────────────────
function Resolve-Config {
    # User overrides win over auto-detection
    $script:FinalRaid = if ($RaidLevel) { $RaidLevel } elseif ($script:DetectedRaid) { $script:DetectedRaid } else { 'none' }
    $script:FinalType = if ($DiskType)  { $DiskType  } elseif ($script:DetectedType) { $script:DetectedType  } else {
        # Try to infer from Win32_DiskDrive MediaType
        try {
            $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
            if ($disks | Where-Object { $_.MediaType -eq 'SSD' }) { 'ssd' }
            else { 'hdd' }
        } catch { 'hdd' }
    }
    Log-Info "RAID level: $($script:FinalRaid)   Disk type: $($script:FinalType.ToUpper())"
}

# ── Test file preparation ──────────────────────────────────────────────────────
function Get-AutoSizeGB {
    param([string]$DriveLetter)
    $vol = Get-Volume -DriveLetter $DriveLetter[0] -ErrorAction SilentlyContinue
    if (-not $vol) { return '10G' }
    $freeGB = [int]($vol.SizeRemaining / 1GB)
    $pct10  = [int]($freeGB * 0.10)
    $sizeGB = [Math]::Min([Math]::Max($pct10, 1), 20)
    return "${sizeGB}G"
}

function Prepare-TestFiles {
    Log-Section "Preparing Test Files"
    $script:TestFiles = @()
    foreach ($dl in $script:TargetDrives) {
        $testDir  = "${dl}\diskspd_stress_${Timestamp}"
        $null = New-Item -ItemType Directory -Force -Path $testDir
        $testFile = "${testDir}\testfile.dat"
        $sz = if ($Size) { $Size } else { Get-AutoSizeGB $dl }
        Log-Info "${dl} → test file: $testFile | size: $sz"
        $script:TestFiles += [pscustomobject]@{ Path = $testFile; Drive = $dl; Size = $sz }
    }
}

function Remove-TestFiles {
    foreach ($tf in $script:TestFiles) {
        $dir = Split-Path $tf.Path -Parent
        Remove-Item $tf.Path -Force -ErrorAction SilentlyContinue
        Remove-Item $dir     -Force -ErrorAction SilentlyContinue
    }
    Log-Info "Test files removed."
}

# ── diskspd phase runner ───────────────────────────────────────────────────────
#
# Selects block size, queue depth and write ratio based on disk type / RAID level,
# then runs diskspd across all test files sequentially (one phase at a time).
#
# Parameters:
#   $PhaseName  : label written to log
#   $WriteRatio : 0=read-only  100=write-only  (diskspd -w flag)
#   $Sequential : $true=sequential  $false=random
#   $PhaseSec   : duration of this phase in seconds
#
function Run-DiskspdPhase {
    param([string]$PhaseName, [int]$WriteRatio, [bool]$Sequential, [int]$PhaseSec)

    # Parameter selection based on disk type
    $bs      = '128K'
    $ioDepth = 8
    switch ($script:FinalType) {
        'nvme' { if ($Sequential) { $bs='128K'; $ioDepth=32 } else { $bs='4K'; $ioDepth=64 } }
        'ssd'  { if ($Sequential) { $bs='64K';  $ioDepth=16 } else { $bs='4K'; $ioDepth=32 } }
        default{ if ($Sequential) { $bs='1024K';$ioDepth=8  } else { $bs='4K'; $ioDepth=8  } }
    }

    # RAID 5/6: raise block size on random writes to align with stripe and minimize parity overhead
    if (-not $Sequential -and $WriteRatio -gt 0 -and $script:FinalRaid -in @('5','6') -and $script:FinalType -ne 'nvme') {
        $bs = '64K'
        Log-Info "  RAID$($script:FinalRaid): adjusted random-write block size to $bs"
    }

    $accessFlag = if ($Sequential) { '-s' } else { '-r' }

    Log-Section "Phase: $PhaseName"
    Log-Info "  mode=$(if($Sequential){'seq'}else{'rand'})  bs=$bs  iodepth=$ioDepth  write=$WriteRatio%  duration=${PhaseSec}s"

    foreach ($tf in $script:TestFiles) {
        Log-Info "  Target: $($tf.Path)"
        $diskspdArgs = @(
            "-d$PhaseSec",          # duration
            "-b$bs",                # block size
            $accessFlag,            # sequential or random
            "-o$ioDepth",           # outstanding I/Os per thread per file
            "-t4",                  # 4 threads per file
            "-w$WriteRatio",        # write ratio
            '-D',                   # disable OS file cache (direct I/O like fio direct=1)
            '-Sh',                  # disable hardware and software cache for writes
            "-c$($tf.Size)",        # create test file of this size (no-op if already exists)
            $tf.Path
        )
        try {
            $out = & $script:DiskspdCmd @diskspdArgs 2>&1 | Out-String
            "=== diskspd $PhaseName — $($tf.Drive) ===`n$out" | Add-Content $LogFile
            Log-Info "  Phase $PhaseName on $($tf.Drive) complete."
        } catch {
            Log-Warn "  diskspd failed on $($tf.Drive): $_"
        }
    }
}

# ── Phase schedule ─────────────────────────────────────────────────────────────
function Run-AllPhases {
    # Weights (must sum to 100):  seqW=15  seqR=15  rndW=30  rndR=25  mix=15
    # RAID 5/6: inflate random-write phase to expose parity bottleneck
    $wSeqW = 15; $wSeqR = 15; $wRndW = 30; $wRndR = 25; $wMix = 15
    if ($script:FinalRaid -in @('5','6')) {
        $wRndW = 40; $wSeqW = 12; $wSeqR = 12; $wRndR = 21; $wMix = 15
        Log-Info "RAID$($script:FinalRaid): random-write phase extended to $wRndW% of total duration."
    }

    $d = $Duration
    $tSeqW = [int]($d * $wSeqW / 100)
    $tSeqR = [int]($d * $wSeqR / 100)
    $tRndW = [int]($d * $wRndW / 100)
    $tRndR = [int]($d * $wRndR / 100)
    $tMix  = $d - $tSeqW - $tSeqR - $tRndW - $tRndR

    Log-Section "Test Schedule"
    @"
  Phase 1  Sequential Write  : ${tSeqW}s  (~$([int]($tSeqW/60))min)
  Phase 2  Sequential Read   : ${tSeqR}s  (~$([int]($tSeqR/60))min)
  Phase 3  Random Write 4K   : ${tRndW}s  (~$([int]($tRndW/60))min)
  Phase 4  Random Read  4K   : ${tRndR}s  (~$([int]($tRndR/60))min)
  Phase 5  Mixed 70R/30W     : ${tMix}s  (~$([int]($tMix/60))min)
"@ | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor White

    Run-DiskspdPhase "seq_write"  100 $true  $tSeqW
    Run-DiskspdPhase "seq_read"   0   $true  $tSeqR
    Run-DiskspdPhase "rand_write" 100 $false $tRndW
    Run-DiskspdPhase "rand_read"  0   $false $tRndR
    Run-DiskspdPhase "mixed_rw"   30  $false $tMix
}

# ── Monitoring (disk performance counters) ────────────────────────────────────
function Start-Monitoring {
    $logPath = $LogFile

    $script:MonitorJob = Start-Job -ScriptBlock {
        param([string]$LogPath)
        while ($true) {
            try {
                $ts   = Get-Date -Format 'HH:mm:ss'
                $disks = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_LogicalDisk |
                    Where-Object { $_.Name -ne '_Total' }
                foreach ($d in $disks) {
                    $line = "[MONITOR] $ts  $($d.Name)  ReadBytes/s: $([int]($d.DiskReadBytesPerSec/1MB))MB/s  WriteBytes/s: $([int]($d.DiskWriteBytesPerSec/1MB))MB/s  Util: $($d.PercentDiskTime)%"
                    Add-Content -Path $LogPath -Value $line
                }
            } catch { }
            Start-Sleep -Seconds 10
        }
    } -ArgumentList $logPath

    Log-Info "Disk monitor started (Job ID $($script:MonitorJob.Id), interval 10s)"
}

function Stop-Monitoring {
    if ($script:MonitorJob) {
        Stop-Job  $script:MonitorJob -ErrorAction SilentlyContinue
        Remove-Job $script:MonitorJob -ErrorAction SilentlyContinue
        $script:MonitorJob = $null
    }
}

# ── Snapshots ─────────────────────────────────────────────────────────────────
function Write-Snapshot {
    param([string]$Label)
    @"

=== $Label  $(Get-Date) ===
--- Get-PhysicalDisk ---
$((Get-PhysicalDisk | Format-Table -AutoSize | Out-String))
--- Get-Volume ---
$((Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' } | Format-Table -AutoSize | Out-String))
"@ | Add-Content -Path $LogFile
    if ($script:StorCliOk) {
        "--- storcli RAID status ---" | Add-Content $LogFile
        try { & $script:StorCliCmd /c0 show all 2>&1 | Out-String | Add-Content $LogFile } catch { }
    }
}

# ── Print config ──────────────────────────────────────────────────────────────
function Print-Config {
    Log-Section "Test Configuration"
    @"
  Target Drives  : $($script:TargetDrives -join ', ')
  RAID Level     : $($script:FinalRaid)
  Disk Type      : $($script:FinalType.ToUpper())
  diskspd        : $($script:DiskspdCmd)
  storcli        : $(if($script:StorCliOk){$script:StorCliCmd}else{'not available'})
  Duration       : ${Duration}s  ($([int]($Duration/3600))h $([int](($Duration%3600)/60))m)
"@ | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor White
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
function Invoke-Cleanup {
    Stop-Monitoring
    Log-Info "Log saved to: $LogFile"
}

# ── Main ──────────────────────────────────────────────────────────────────────
try {
    $null = New-Item -ItemType File -Force -Path $LogFile

    Log-Section "Disk Stress Test — $(Get-Date)"
    Log-Info "Host : $($env:COMPUTERNAME)"
    Log-Info "Log  : $LogFile"

    # diskspd is required
    if (-not (Find-Diskspd)) {
        Log-Error @"
diskspd.exe not found.
  Download from: https://github.com/microsoft/diskspd/releases
  Then place diskspd.exe in: $ScriptDir
"@
    }
    Log-Info "diskspd: $DiskspdCmd"

    # storcli is optional (RAID info)
    if (Find-StorCli) {
        $script:StorCliOk = $true
        Log-Info "storcli64: $StorCliCmd"
    } else {
        Log-Warn "storcli64 not found — RAID info unavailable."
        Log-Warn "  Download from Broadcom and place storcli64.exe in: $ScriptDir"
    }

    Detect-RaidCard
    Query-StorCli
    Detect-Drives
    Resolve-Config
    Prepare-TestFiles
    Print-Config

    if (-not $Yes) {
        Write-Host "`nWARNING: diskspd will write to test files on the listed drives." -ForegroundColor Yellow
        Write-Host "Existing data on those drives is safe — test files are in subdirectories." -ForegroundColor Yellow
        Write-Host "`nReady to start. Press ENTER to continue, Ctrl+C to cancel..." -ForegroundColor Yellow
        $null = Read-Host
    }

    Write-Snapshot "Pre-Test"
    Log-Info "Pre-test snapshot saved."

    Start-Monitoring
    Run-AllPhases
    Stop-Monitoring

    Write-Snapshot "Post-Test"
    Log-Info "Post-test snapshot saved."

    Remove-TestFiles

    Log-Section "Test Complete"
    Log-Info "Duration : ${Duration}s"
    Log-Info "Status   : DONE"
    Log-Info "Log file : $LogFile"

} finally {
    Invoke-Cleanup
}
