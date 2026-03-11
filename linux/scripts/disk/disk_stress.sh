#!/usr/bin/env bash
# =============================================================================
# Script      : disk_stress.sh
# Description : Disk stress test for HDD / NVMe on servers with Broadcom
#               hardware RAID or direct-attached disks.
#               Compatible with Rocky Linux and Ubuntu.
# Usage       : ./disk_stress.sh [OPTIONS]
# Date        : 2026-03-11
# =============================================================================
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="$(dirname "$SCRIPT_DIR")/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${RESULT_DIR}/disk_stress_$(hostname -s)_${TIMESTAMP}.log"

# ── Defaults ──────────────────────────────────────────────────────────────────
DURATION=14400        # total seconds (4 hours); override with -d
TEST_SIZE=""          # fio test file size per device; "" = auto
RAID_LEVEL_OVERRIDE="" # manual RAID level override; "" = auto from storcli
DISK_TYPE_OVERRIDE="" # manual disk type override; "" = auto
# Devices added via -D flags accumulate here; empty = auto-detect
USER_DEVICES=()

# storcli download URL (version 007.2705, released 2023-08-25)
readonly STORCLI_ZIP_URL="https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip"
readonly STORCLI_BIN="/opt/MegaRAID/storcli/storcli64"

# ── Runtime state ─────────────────────────────────────────────────────────────
MONITOR_PIDS=()
FIO_PIDS=()
SENSORS_OK=false
STORCLI_OK=false
HAS_RAID_CARD=false
# Populated by detect_targets()
RAID_DEVICES=()    # logical volumes managed by RAID card  (e.g. /dev/sda)
NVME_DEVICES=()    # NVMe devices direct-attached to board (e.g. /dev/nvme0n1)
RAID_LEVEL=""      # RAID level string: none/0/1/5/6/10
DISK_TYPE=""       # hdd / ssd / nvme
TEST_FILES=()      # fio test file paths (one per target device)

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info() {
    local msg="[INFO]  $(date +%T) $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${GREEN}${msg}${NC}"
}
log_warn() {
    local msg="[WARN]  $(date +%T) $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${YELLOW}${msg}${NC}"
}
log_error() {
    local msg="[ERROR] $(date +%T) $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${RED}${msg}${NC}" >&2
    exit 1
}
log_section() {
    local bar="=================================================="
    { printf "\n%s\n  %s\n%s\n" "$bar" "$*" "$bar"; } >> "$LOG_FILE"
    echo -e "\n${BOLD}${CYAN}${bar}${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}${bar}${NC}"
}
log_cmd_output() {
    "$@" >> "$LOG_FILE" 2>&1 || true
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Disk stress test — supports Broadcom hardware RAID (HDD) and direct-attached
NVMe (M.2 / U.2). Compatible with Rocky Linux and Ubuntu.
Must be run as root.

Options:
  -d, --duration   SEC   Total test duration in seconds (default: ${DURATION})
  -D, --device     DEV   Add a test device manually (can repeat; overrides auto-detect)
                         Examples: -D /dev/sda  -D /dev/nvme0n1
  -s, --size       SIZE  fio test file size per device (default: auto ~10% free space)
                         Examples: 10G  20G  500M
  -r, --raid       LVL   Override detected RAID level: none / 0 / 1 / 5 / 6 / 10
  -t, --disk-type  TYPE  Override detected disk type:  hdd / ssd / nvme
  -y, --yes              Skip confirmation prompt
  -h, --help             Show this help

Examples:
  $(basename "$0")                            # Auto-detect everything, 4h test
  $(basename "$0") -d 3600                   # 1-hour test
  $(basename "$0") -D /dev/sda -r 5 -t hdd  # Manual: RAID-5 HDD on /dev/sda
  $(basename "$0") -D /dev/nvme0n1 -D /dev/nvme1n1  # Two NVMe devices
EOF
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration)  DURATION="$2";             shift 2 ;;
        -D|--device)    USER_DEVICES+=("$2");       shift 2 ;;
        -s|--size)      TEST_SIZE="$2";             shift 2 ;;
        -r|--raid)      RAID_LEVEL_OVERRIDE="$2";   shift 2 ;;
        -t|--disk-type) DISK_TYPE_OVERRIDE="$2";    shift 2 ;;
        -y|--yes)       SKIP_CONFIRM=true;          shift   ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Validate duration
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
    echo "Error: --duration must be a positive integer (seconds)" >&2; exit 1
fi

# Validate RAID level override
if [[ -n "$RAID_LEVEL_OVERRIDE" ]]; then
    case "$RAID_LEVEL_OVERRIDE" in
        none|0|1|5|6|10) ;;
        *) echo "Error: --raid must be one of: none 0 1 5 6 10" >&2; exit 1 ;;
    esac
fi

# Validate disk type override
if [[ -n "$DISK_TYPE_OVERRIDE" ]]; then
    case "$DISK_TYPE_OVERRIDE" in
        hdd|ssd|nvme) ;;
        *) echo "Error: --disk-type must be one of: hdd ssd nvme" >&2; exit 1 ;;
    esac
fi

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)." >&2; exit 1
fi

# ── Init ──────────────────────────────────────────────────────────────────────
mkdir -p "$RESULT_DIR"
touch "$LOG_FILE"

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
    [[ -f /etc/os-release ]] || log_error "/etc/os-release not found."
    # shellcheck source=/dev/null
    source /etc/os-release
    local os_id="${ID,,}"
    case "$os_id" in
        rocky|rhel|centos|almalinux|fedora)
            PKG_INSTALL="dnf install -y"
            PKG_SYSSTAT="sysstat"
            PKG_SENSORS="lm_sensors"
            OS_FAMILY="rpm"
            ;;
        ubuntu|debian)
            PKG_INSTALL="apt-get install -y"
            PKG_SYSSTAT="sysstat"
            PKG_SENSORS="lm-sensors"
            OS_FAMILY="deb"
            ;;
        *)
            log_warn "Unknown OS '${os_id}' — assuming RPM-based."
            PKG_INSTALL="dnf install -y"
            PKG_SYSSTAT="sysstat"
            PKG_SENSORS="lm_sensors"
            OS_FAMILY="rpm"
            ;;
    esac
    log_info "OS: ${PRETTY_NAME:-$os_id}"
}

# ── Dependency Check ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()

    command -v fio      &>/dev/null || missing+=("fio")
    command -v iostat   &>/dev/null || missing+=("iostat ($PKG_SYSSTAT)")
    command -v lsblk    &>/dev/null || missing+=("lsblk (util-linux)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}
  Install with: sudo ${PKG_INSTALL} fio ${PKG_SYSSTAT}"
    fi

    command -v sensors &>/dev/null && SENSORS_OK=true || {
        log_warn "sensors not found — temperature monitoring disabled."
        log_warn "  Install: sudo ${PKG_INSTALL} ${PKG_SENSORS}"
    }
}

# ── storcli Installation ──────────────────────────────────────────────────────

# Search for an already-installed storcli64 binary.
# Sets STORCLI_CMD to its full path, or returns 1 if not found.
find_storcli() {
    local candidates=(
        storcli64 storcli
        /opt/MegaRAID/storcli/storcli64
        /usr/local/sbin/storcli64
        /usr/sbin/storcli64
    )
    for c in "${candidates[@]}"; do
        if command -v "$c" &>/dev/null 2>&1; then
            STORCLI_CMD="$(command -v "$c")"
            return 0
        fi
        if [[ -x "$c" ]]; then
            STORCLI_CMD="$c"
            return 0
        fi
    done
    return 1
}

install_storcli() {
    # ── Step 1: look for a local package in the same directory as this script ──
    # Supported layouts (place either file next to disk_stress.sh):
    #   storcli-*.noarch.rpm   (Rocky / RHEL)
    #   storcli_*_all.deb      (Ubuntu / Debian)
    local local_pkg=""
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        local_pkg=$(find "$SCRIPT_DIR" -maxdepth 1 -name "storcli-*.noarch.rpm" | head -1)
    else
        local_pkg=$(find "$SCRIPT_DIR" -maxdepth 1 -name "storcli_*_all.deb"    | head -1)
    fi

    if [[ -n "$local_pkg" ]]; then
        log_info "Found local storcli package: ${local_pkg}"
        _install_storcli_pkg "$local_pkg"
        return
    fi

    # ── Step 2: fall back to downloading from Broadcom ────────────────────────
    log_info "No local package found — downloading from Broadcom..."

    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        log_error "Neither wget nor curl is available. Install one first:
  sudo ${PKG_INSTALL} wget"
    fi

    command -v unzip &>/dev/null || {
        log_info "unzip not found — installing..."
        $PKG_INSTALL unzip >> "$LOG_FILE" 2>&1 \
            || log_error "Failed to install unzip."
    }

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    log_info "Downloading storcli package (~30 MB)..."
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${tmpdir}/storcli.zip" "$STORCLI_ZIP_URL" \
            || log_error "wget download failed. Check network connectivity."
    else
        curl -fL# -o "${tmpdir}/storcli.zip" "$STORCLI_ZIP_URL" \
            || log_error "curl download failed. Check network connectivity."
    fi

    log_info "Extracting package..."
    unzip -q "${tmpdir}/storcli.zip" -d "${tmpdir}" \
        || log_error "Failed to extract storcli ZIP."

    # The outer ZIP may contain a second ZIP with the actual OS packages
    local inner_zip
    inner_zip=$(find "${tmpdir}" -name "Unified_storcli_all_os.zip" | head -1)
    if [[ -n "$inner_zip" ]]; then
        unzip -q "$inner_zip" -d "${tmpdir}" \
            || log_error "Failed to extract inner Unified_storcli_all_os.zip."
    fi

    local pkg
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        pkg=$(find "${tmpdir}" -name "storcli-*.noarch.rpm" | head -1)
        [[ -n "$pkg" ]] || log_error "RPM package not found in archive."
    else
        pkg=$(find "${tmpdir}" -name "storcli_*_all.deb" | head -1)
        [[ -n "$pkg" ]] || log_error "DEB package not found in archive."
    fi

    _install_storcli_pkg "$pkg"

    rm -rf "$tmpdir"
    trap - EXIT
}

# Internal helper: install a resolved .rpm or .deb package path
_install_storcli_pkg() {
    local pkg="$1"
    log_info "Installing storcli package: $(basename "$pkg") ..."
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        rpm -ivh "$pkg" >> "$LOG_FILE" 2>&1 \
            || log_error "rpm install failed."
    else
        dpkg -i "$pkg" >> "$LOG_FILE" 2>&1 \
            || log_error "dpkg install failed."
    fi

    # Create convenience symlink if the binary landed outside PATH
    if [[ -x "$STORCLI_BIN" ]] && ! command -v storcli64 &>/dev/null; then
        ln -sf "$STORCLI_BIN" /usr/local/sbin/storcli64
    fi

    rm -rf "$tmpdir"
    trap - EXIT

    log_info "storcli64 installed successfully."
}

ensure_storcli() {
    if find_storcli; then
        log_info "storcli64 found: ${STORCLI_CMD}"
        STORCLI_OK=true
        return
    fi

    # Only attempt download when a Broadcom RAID card is actually present
    if [[ "$HAS_RAID_CARD" == true ]]; then
        install_storcli
        if find_storcli; then
            STORCLI_OK=true
        else
            log_warn "storcli64 still not found after install — RAID info will be unavailable."
        fi
    fi
}

# ── RAID Card Detection ───────────────────────────────────────────────────────
detect_raid_card() {
    if lspci 2>/dev/null | grep -qiE "megaraid|broadcom.*raid|lsi.*raid|avago"; then
        HAS_RAID_CARD=true
        log_info "Broadcom hardware RAID controller detected."
    else
        log_info "No hardware RAID controller detected."
    fi
}

# Query storcli to find:
#   - RAID_LEVEL  (populated into global)
#   - DISK_TYPE   (populated into global, unless override given)
#   - RAID_DEVICES (logical volume block devices)
query_storcli() {
    [[ "$STORCLI_OK" == true ]] || return

    log_section "RAID Controller Info (storcli)"
    {
        echo "--- storcli64 /c0 show ---"
        "$STORCLI_CMD" /c0 show 2>/dev/null || true
        echo ""
        echo "--- storcli64 /c0/vall show ---"
        "$STORCLI_CMD" /c0/vall show 2>/dev/null || true
        echo ""
        echo "--- storcli64 /c0/eall/sall show ---"
        "$STORCLI_CMD" /c0/eall/sall show 2>/dev/null || true
    } >> "$LOG_FILE" 2>&1

    # ── Detect RAID level from virtual drives ─────────────────────────────
    local vd_output
    vd_output=$("$STORCLI_CMD" /c0/vall show 2>/dev/null || true)

    # storcli output contains lines like:  0/0  RAID5  Optl  ...
    local detected_level
    detected_level=$(echo "$vd_output" \
        | awk '/RAID[0-9]+/{
            match($0, /RAID([0-9]+)/, a)
            print a[1]
            exit
          }')

    if [[ -n "$detected_level" ]]; then
        RAID_LEVEL="$detected_level"
        log_info "Detected RAID level: RAID${RAID_LEVEL}"
    else
        log_warn "Could not parse RAID level from storcli output."
        RAID_LEVEL="unknown"
    fi

    # ── Detect physical disk type (HDD vs SSD) ────────────────────────────
    if [[ -z "$DISK_TYPE_OVERRIDE" ]]; then
        local pd_output
        pd_output=$("$STORCLI_CMD" /c0/eall/sall show 2>/dev/null || true)
        # Media Type field: "Hard Disk Device" or "Solid State Device"
        if echo "$pd_output" | grep -qi "Solid State Device"; then
            DISK_TYPE="ssd"
        else
            DISK_TYPE="hdd"
        fi
        log_info "Detected physical disk type: ${DISK_TYPE^^}"
    fi

    # ── Map virtual drives to OS block devices ────────────────────────────
    # storcli names VDs as /c0/v0, /c0/v1 … but doesn't directly give /dev paths.
    # We rely on lsblk to find non-NVMe, non-loop, non-dm block devices that are
    # whole disks — these correspond to RAID logical volumes exposed to the OS.
    while IFS= read -r dev; do
        local devpath="/dev/${dev}"
        [[ -b "$devpath" ]] && RAID_DEVICES+=("$devpath")
    done < <(lsblk -dn -o NAME,TYPE,TRAN 2>/dev/null \
        | awk '$2=="disk" && $3!="nvme" && $3!="" {print $1}')

    if [[ ${#RAID_DEVICES[@]} -gt 0 ]]; then
        log_info "RAID logical volume(s): ${RAID_DEVICES[*]}"
    else
        log_warn "No RAID logical volumes found via lsblk."
    fi
}

# ── NVMe Direct-Attach Detection ─────────────────────────────────────────────
detect_nvme() {
    while IFS= read -r dev; do
        local devpath="/dev/${dev}"
        [[ -b "$devpath" ]] && NVME_DEVICES+=("$devpath")
    done < <(lsblk -dn -o NAME,TRAN 2>/dev/null \
        | awk '$2=="nvme" {print $1}')

    if [[ ${#NVME_DEVICES[@]} -gt 0 ]]; then
        log_info "NVMe device(s) detected: ${NVME_DEVICES[*]}"
    fi
}

# ── Target Resolution ─────────────────────────────────────────────────────────
# Applies manual overrides, validates final device list, selects fio profile.
resolve_targets() {
    # Apply user-specified device list
    if [[ ${#USER_DEVICES[@]} -gt 0 ]]; then
        log_info "Using manually specified device(s): ${USER_DEVICES[*]}"
        RAID_DEVICES=()
        NVME_DEVICES=()
        for dev in "${USER_DEVICES[@]}"; do
            [[ -b "$dev" ]] || log_error "Device not found: ${dev}"
            case "$dev" in
                *nvme*) NVME_DEVICES+=("$dev") ;;
                *)      RAID_DEVICES+=("$dev") ;;
            esac
        done
    fi

    # Apply manual overrides
    [[ -n "$RAID_LEVEL_OVERRIDE" ]] && RAID_LEVEL="$RAID_LEVEL_OVERRIDE"
    [[ -n "$DISK_TYPE_OVERRIDE"  ]] && DISK_TYPE="$DISK_TYPE_OVERRIDE"

    # Default DISK_TYPE for NVMe devices
    [[ ${#NVME_DEVICES[@]} -gt 0 && -z "$DISK_TYPE" ]] && DISK_TYPE="nvme"

    # Fallback if still unset
    [[ -z "$RAID_LEVEL" ]] && RAID_LEVEL="none"
    [[ -z "$DISK_TYPE"  ]] && DISK_TYPE="hdd"

    # Validate we have at least one target
    local total=$(( ${#RAID_DEVICES[@]} + ${#NVME_DEVICES[@]} ))
    if [[ "$total" -eq 0 ]]; then
        log_error "No test devices found. Use -D to specify devices manually."
    fi
}

# ── Test File Management ──────────────────────────────────────────────────────

# Resolve the mount point that contains the given block device
mountpoint_of() {
    local dev="$1"
    # Try to find a filesystem mounted on this exact device
    local mp
    mp=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' | head -1)
    if [[ -n "$mp" ]]; then
        echo "$mp"
        return
    fi
    # Fallback: look at partitions on this disk
    mp=$(lsblk -no MOUNTPOINT "${dev}"* 2>/dev/null | grep -v '^$' | head -1)
    echo "${mp:-}"
}

# Calculate test file size for a given mount point.
# Default: min(10% free space, 20 GB), floor 1 GB.
auto_size_gb() {
    local mp="$1"
    local avail_gb
    avail_gb=$(df -BG "$mp" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    avail_gb="${avail_gb:-0}"

    local pct_gb=$(( avail_gb * 10 / 100 ))
    local cap_gb=20
    local floor_gb=1

    local size_gb=$(( pct_gb < cap_gb ? pct_gb : cap_gb ))
    size_gb=$(( size_gb > floor_gb ? size_gb : floor_gb ))
    echo "${size_gb}G"
}

prepare_test_files() {
    log_section "Preparing Test Files"
    TEST_FILES=()
    local all_devices=("${RAID_DEVICES[@]+"${RAID_DEVICES[@]}"}" \
                       "${NVME_DEVICES[@]+"${NVME_DEVICES[@]}"}")

    for dev in "${all_devices[@]}"; do
        local devname
        devname=$(basename "$dev")
        local mp
        mp=$(mountpoint_of "$dev")

        if [[ -z "$mp" ]]; then
            log_warn "${dev}: no mounted filesystem found — skipping test file creation."
            log_warn "  If this is an unmounted device, partition and mount it first,"
            log_warn "  or use raw device mode (not yet supported in this script)."
            continue
        fi

        local testdir="${mp}/fio_stress_${TIMESTAMP}"
        mkdir -p "$testdir"

        local size
        if [[ -n "$TEST_SIZE" ]]; then
            size="$TEST_SIZE"
        else
            size=$(auto_size_gb "$mp")
        fi

        local testfile="${testdir}/testfile_${devname}"
        TEST_FILES+=("$testfile")
        log_info "${dev} → mount: ${mp} | test file: ${testfile} | size: ${size}"

        # Pre-create the file so fio reports size errors early (not mid-test)
        if ! fallocate -l "$size" "$testfile" 2>/dev/null; then
            # fallocate not available (e.g. XFS fallocate unsupported); fio will create it
            log_warn "  fallocate unavailable — fio will create the file during the test."
        fi
    done

    if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
        log_error "No test files could be prepared. Ensure target devices have mounted filesystems."
    fi
}

cleanup_test_files() {
    for f in "${TEST_FILES[@]+"${TEST_FILES[@]}"}"; do
        local dir
        dir=$(dirname "$f")
        rm -f "$f" 2>/dev/null || true
        rmdir "$dir" 2>/dev/null || true
    done
}

# ── fio Phase Runner ──────────────────────────────────────────────────────────
# Selects block-size and iodepth parameters based on disk type and RAID level,
# then runs all test files concurrently as a single fio job per phase.
#
# Usage: run_fio_phase <phase_name> <rw_mode> <phase_duration_sec>
run_fio_phase() {
    local phase_name="$1"
    local rw_mode="$2"      # read / write / randread / randwrite / randrw
    local phase_dur="$3"

    # ── Parameter selection ───────────────────────────────────────────────
    local bs iodepth rwmixread
    rwmixread=70   # used only for randrw

    case "$DISK_TYPE" in
        nvme)
            # NVMe: large queue depth, 4K random / 128K sequential
            if [[ "$rw_mode" == rand* ]]; then
                bs="4k"; iodepth=64
            else
                bs="128k"; iodepth=32
            fi
            ;;
        ssd)
            if [[ "$rw_mode" == rand* ]]; then
                bs="4k"; iodepth=32
            else
                bs="64k"; iodepth=16
            fi
            ;;
        hdd|*)
            # HDD: limited IOPS, large sequential blocks
            if [[ "$rw_mode" == rand* ]]; then
                bs="4k"; iodepth=8
            else
                bs="1m"; iodepth=8
            fi
            ;;
    esac

    # ── RAID write-penalty adjustment ─────────────────────────────────────
    # RAID 5/6 suffer severe write amplification on small random writes.
    # Use a larger block size to reduce parity overhead and reflect realistic load.
    if [[ "$rw_mode" == *write* ]]; then
        case "$RAID_LEVEL" in
            5|6)
                if [[ "$rw_mode" == rand* && "$DISK_TYPE" != "nvme" ]]; then
                    bs="64k"   # align with RAID stripe to minimize parity rewrites
                    log_info "  RAID${RAID_LEVEL}: adjusting random-write block size to ${bs}"
                fi
                ;;
        esac
    fi

    log_section "Phase: ${phase_name}"
    log_info "  rw=${rw_mode} | bs=${bs} | iodepth=${iodepth} | duration=${phase_dur}s"
    log_info "  devices: ${TEST_FILES[*]}"

    # Build --filename list (colon-separated for fio)
    local filelist
    filelist=$(IFS=':'; echo "${TEST_FILES[*]}")

    # Determine fio size: use existing files (already pre-created above)
    local fio_size_arg=""
    if [[ -n "$TEST_SIZE" ]]; then
        fio_size_arg="--size=${TEST_SIZE}"
    fi

    local fio_extra=""
    [[ "$rw_mode" == "randrw" ]] && fio_extra="--rwmixread=${rwmixread}"

    # Direct I/O bypasses page cache — measures actual disk performance
    fio \
        --name="${phase_name}" \
        --filename="${filelist}" \
        --rw="${rw_mode}" \
        --bs="${bs}" \
        --iodepth="${iodepth}" \
        --ioengine=libaio \
        --direct=1 \
        --runtime="${phase_dur}" \
        --time_based \
        --group_reporting \
        --output-format=normal \
        ${fio_size_arg} \
        ${fio_extra} \
        >> "$LOG_FILE" 2>&1 &
    FIO_PIDS+=($!)
    log_info "  fio started (PID ${FIO_PIDS[-1]})"

    # Wait for this phase to complete before moving to the next
    wait "${FIO_PIDS[-1]}" 2>/dev/null || true
    FIO_PIDS=()
    log_info "  Phase complete."
}

# ── Phase Schedule ────────────────────────────────────────────────────────────
# Divides DURATION across 5 phases. For RAID 5/6 the random-write phase gets
# a larger share to expose parity-write bottlenecks.
#
# Phase weights (sum = 100):
#   seq_write  seq_read  rand_write  rand_read  mixed
#     15         15         30         25        15
# RAID 5/6 rand_write weight → 40, others reduced proportionally.
run_all_phases() {
    local seq_w_pct=15
    local seq_r_pct=15
    local rnd_w_pct=30
    local rnd_r_pct=25
    local mix_pct=15

    case "$RAID_LEVEL" in
        5|6)
            # Increase random-write share to stress parity computation
            rnd_w_pct=40; seq_w_pct=12; seq_r_pct=12; rnd_r_pct=21; mix_pct=15
            log_info "RAID${RAID_LEVEL}: random-write phase extended to ${rnd_w_pct}% of total duration."
            ;;
    esac

    local d=$DURATION
    local t_seq_w=$(( d * seq_w_pct / 100 ))
    local t_seq_r=$(( d * seq_r_pct / 100 ))
    local t_rnd_w=$(( d * rnd_w_pct / 100 ))
    local t_rnd_r=$(( d * rnd_r_pct / 100 ))
    local t_mix=$(( d - t_seq_w - t_seq_r - t_rnd_w - t_rnd_r ))  # absorb rounding

    log_section "Test Schedule"
    cat <<EOF | tee -a "$LOG_FILE"
  Phase 1  Sequential Write  : ${t_seq_w}s  (~$(( t_seq_w/60 ))min)
  Phase 2  Sequential Read   : ${t_seq_r}s  (~$(( t_seq_r/60 ))min)
  Phase 3  Random Write 4K   : ${t_rnd_w}s  (~$(( t_rnd_w/60 ))min)
  Phase 4  Random Read  4K   : ${t_rnd_r}s  (~$(( t_rnd_r/60 ))min)
  Phase 5  Mixed 70R/30W     : ${t_mix}s   (~$(( t_mix/60 ))min)
EOF

    run_fio_phase "seq_write"  "write"    "$t_seq_w"
    run_fio_phase "seq_read"   "read"     "$t_seq_r"
    run_fio_phase "rand_write" "randwrite" "$t_rnd_w"
    run_fio_phase "rand_read"  "randread"  "$t_rnd_r"
    run_fio_phase "mixed_rw"   "randrw"   "$t_mix"
}

# ── Monitoring ────────────────────────────────────────────────────────────────
start_monitoring() {
    log_section "Starting Monitors"

    # iostat: per-device utilization, await, throughput every 10 seconds
    {
        echo "=== iostat -x 10 — disk utilization ==="
        iostat -x 10
    } >> "$LOG_FILE" 2>&1 &
    MONITOR_PIDS+=($!)
    log_info "iostat monitor started (PID ${MONITOR_PIDS[-1]})"

    # storcli RAID health snapshot every 5 minutes
    if [[ "$STORCLI_OK" == true ]]; then
        (
            while true; do
                {
                    echo "=== $(date '+%Y-%m-%d %T') storcli RAID status ==="
                    "$STORCLI_CMD" /c0 show all 2>/dev/null || true
                } >> "$LOG_FILE"
                sleep 300
            done
        ) &
        MONITOR_PIDS+=($!)
        log_info "RAID status monitor started (PID ${MONITOR_PIDS[-1]})"
    fi

    # Temperature every 10 seconds (drives heat up significantly under load)
    if [[ "$SENSORS_OK" == true ]]; then
        (
            while true; do
                {
                    echo "=== $(date '+%Y-%m-%d %T') Temperature ==="
                    sensors 2>/dev/null || true
                } >> "$LOG_FILE"
                sleep 10
            done
        ) &
        MONITOR_PIDS+=($!)
        log_info "Temperature monitor started (PID ${MONITOR_PIDS[-1]})"
    fi
}

stop_monitoring() {
    for pid in "${MONITOR_PIDS[@]+"${MONITOR_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    MONITOR_PIDS=()
}

# ── Print Configuration Summary ───────────────────────────────────────────────
print_config() {
    log_section "Test Configuration"
    local raid_devs="${RAID_DEVICES[*]:-none}"
    local nvme_devs="${NVME_DEVICES[*]:-none}"
    local files="${TEST_FILES[*]:-pending}"
    cat <<EOF | tee -a "$LOG_FILE"
  RAID Devices    : ${raid_devs}
  NVMe Devices    : ${nvme_devs}
  RAID Level      : ${RAID_LEVEL}
  Disk Type       : ${DISK_TYPE^^}
  Test Files      : ${files}
  Total Duration  : ${DURATION}s  ($(( DURATION/3600 ))h $(( DURATION%3600/60 ))m)
EOF
}

# ── Cleanup on Interrupt ──────────────────────────────────────────────────────
cleanup() {
    echo ""
    log_warn "Interrupt received — stopping all processes..."
    for pid in "${FIO_PIDS[@]+"${FIO_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    stop_monitoring
    log_warn "Cleaning up test files..."
    cleanup_test_files
    log_warn "Test aborted. Partial log: ${LOG_FILE}"
    exit 1
}
trap cleanup SIGINT SIGTERM

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log_section "Disk Stress Test — $(date)"
    log_info "Host    : $(hostname)"
    log_info "Log     : ${LOG_FILE}"

    detect_os
    check_deps
    detect_raid_card
    ensure_storcli
    query_storcli
    detect_nvme
    resolve_targets
    prepare_test_files
    print_config

    # ── Confirmation ─────────────────────────────────────────────────────
    if [[ "$SKIP_CONFIRM" == false ]]; then
        echo ""
        echo -e "${BOLD}${YELLOW}WARNING: fio will write to the test files listed above.${NC}"
        echo -e "${BOLD}Data on tested filesystems is safe — test files are created in subdirectories.${NC}"
        echo ""
        echo -e "${BOLD}Ready to start. Press ENTER to continue, Ctrl+C to cancel...${NC}"
        read -r
    fi

    # ── Pre-test snapshot ─────────────────────────────────────────────────
    log_section "Pre-Test Snapshot"
    {
        echo "--- lsblk ---"
        lsblk -o NAME,TYPE,SIZE,ROTA,TRAN,MOUNTPOINT
        echo ""
        echo "--- df -h ---"
        df -h
        echo ""
        echo "--- iostat (initial) ---"
        iostat -x 1 1
        if [[ "$STORCLI_OK" == true ]]; then
            echo ""
            echo "--- storcli initial state ---"
            "$STORCLI_CMD" /c0 show all 2>/dev/null || true
        fi
        if [[ "$SENSORS_OK" == true ]]; then
            echo ""
            echo "--- Initial Temperature ---"
            sensors 2>/dev/null || true
        fi
    } >> "$LOG_FILE" 2>&1
    log_info "Pre-test snapshot saved to log."

    # ── Run ──────────────────────────────────────────────────────────────
    start_monitoring
    run_all_phases

    stop_monitoring

    # ── Post-test snapshot ───────────────────────────────────────────────
    log_section "Post-Test Snapshot"
    {
        echo "--- df -h ---"
        df -h
        echo ""
        echo "--- iostat summary ---"
        iostat -x 1 1
        if [[ "$STORCLI_OK" == true ]]; then
            echo ""
            echo "--- storcli final state ---"
            "$STORCLI_CMD" /c0 show all 2>/dev/null || true
        fi
        if [[ "$SENSORS_OK" == true ]]; then
            echo ""
            echo "--- Final Temperature ---"
            sensors 2>/dev/null || true
        fi
    } >> "$LOG_FILE" 2>&1
    log_info "Post-test snapshot saved to log."

    # ── Cleanup test files ───────────────────────────────────────────────
    log_info "Removing test files..."
    cleanup_test_files

    # ── Done ─────────────────────────────────────────────────────────────
    log_section "Test Complete"
    log_info "Duration : ${DURATION}s"
    log_info "Status   : DONE"
    log_info "Log file : ${LOG_FILE}"
    echo ""
    echo -e "${BOLD}${GREEN}Test finished. Log saved to:${NC}"
    echo -e "  ${CYAN}${LOG_FILE}${NC}"
    echo ""
}

main
