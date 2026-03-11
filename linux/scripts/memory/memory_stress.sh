#!/usr/bin/env bash
# =============================================================================
# Script      : memory_stress.sh
# Description : Memory stress test for Intel/AMD single/dual-socket servers
#               Compatible with Rocky Linux and Ubuntu
# Usage       : ./memory_stress.sh [OPTIONS]
# Date        : 2026-03-10
# =============================================================================
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="$(dirname "$SCRIPT_DIR")/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${RESULT_DIR}/memory_stress_$(hostname -s)_${TIMESTAMP}.log"

# ── Defaults ──────────────────────────────────────────────────────────────────
DURATION=14400    # seconds (4 hours); override with -d
MEM_PERCENT=80    # percentage of total RAM to stress; override with -p
VM_METHOD="all"   # stress-ng vm method; override with -m
WORKERS=0         # 0 = auto (1 per NUMA node); override with -w

# ── Runtime state ─────────────────────────────────────────────────────────────
MONITOR_PIDS=()
STRESS_PIDS=()
SENSORS_OK=false
NUMACTL_OK=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
# Terminal gets color; log file gets plain text
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

Memory stress test for Intel/AMD, single/dual-socket servers.
Supports Rocky Linux and Ubuntu.

Options:
  -d, --duration SEC      Test duration in seconds (default: ${DURATION})
  -p, --mem-percent PCT   Percentage of total RAM to stress (default: ${MEM_PERCENT})
                          Range: 1-95. Keep <=80 to avoid OOM on production systems.
  -m, --vm-method NAME    stress-ng vm method (default: ${VM_METHOD})
                          Common values: all, flip, walk-0d, walk-1d, rowhammer
  -w, --workers N         Number of vm workers (default: auto = 1 per NUMA node)
  -y, --yes               Skip confirmation prompt (for automated runs)
  -h, --help              Show this help

Examples:
  $(basename "$0")                          # Default 4-hour test, 80% RAM
  $(basename "$0") -d 3600                 # 1-hour test
  $(basename "$0") -d 60 -p 50            # Quick 1-minute test, 50% RAM
  $(basename "$0") -d 14400 -p 80 -y      # 4-hour test, no prompt
EOF
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration)    DURATION="$2";    shift 2 ;;
        -p|--mem-percent) MEM_PERCENT="$2"; shift 2 ;;
        -m|--vm-method)   VM_METHOD="$2";   shift 2 ;;
        -w|--workers)     WORKERS="$2";     shift 2 ;;
        -y|--yes)         SKIP_CONFIRM=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Validate duration
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
    echo "Error: --duration must be a positive integer (seconds)" >&2; exit 1
fi

# Validate mem-percent (1–95 to avoid system OOM)
if ! [[ "$MEM_PERCENT" =~ ^[0-9]+$ ]] || [[ "$MEM_PERCENT" -lt 1 ]] || [[ "$MEM_PERCENT" -gt 95 ]]; then
    echo "Error: --mem-percent must be an integer between 1 and 95" >&2; exit 1
fi

# Validate workers
if ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then
    echo "Error: --workers must be a non-negative integer (0 = auto)" >&2; exit 1
fi

# ── Init ──────────────────────────────────────────────────────────────────────
mkdir -p "$RESULT_DIR"
touch "$LOG_FILE"

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
    [[ -f /etc/os-release ]] || log_error "/etc/os-release not found — cannot detect OS."
    # shellcheck source=/dev/null
    source /etc/os-release
    local os_id="${ID,,}"
    case "$os_id" in
        rocky|rhel|centos|almalinux|fedora)
            PKG_INSTALL="dnf install -y"
            PKG_SYSSTAT="sysstat"
            PKG_SENSORS="lm_sensors"
            ;;
        ubuntu|debian)
            PKG_INSTALL="apt-get install -y"
            PKG_SYSSTAT="sysstat"
            PKG_SENSORS="lm-sensors"
            ;;
        *)
            log_warn "Unknown OS '${os_id}' — assuming RPM-based. Install hints may be inaccurate."
            PKG_INSTALL="dnf install -y"
            PKG_SYSSTAT="sysstat"
            PKG_SENSORS="lm_sensors"
            ;;
    esac
    log_info "OS: ${PRETTY_NAME:-$os_id}"
}

# ── Dependency Check ──────────────────────────────────────────────────────────
check_deps() {
    local missing_tools=()
    local missing_pkgs=()

    if ! command -v stress-ng &>/dev/null; then
        missing_tools+=("stress-ng"); missing_pkgs+=("stress-ng")
    fi
    if ! command -v vmstat &>/dev/null; then
        missing_tools+=("vmstat"); missing_pkgs+=("$PKG_SYSSTAT")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}
  Install with: sudo ${PKG_INSTALL} ${missing_pkgs[*]}"
    fi

    # numactl: required for dual-socket NUMA binding; warn if absent
    if command -v numactl &>/dev/null; then
        NUMACTL_OK=true
    else
        log_warn "numactl not found — dual-socket NUMA binding will be skipped."
        log_warn "  Install: sudo ${PKG_INSTALL} numactl"
    fi

    # lm-sensors: optional, for temperature monitoring (memory modules run hot)
    if command -v sensors &>/dev/null; then
        SENSORS_OK=true
    else
        log_warn "sensors not found — temperature monitoring disabled."
        log_warn "  Install: sudo ${PKG_INSTALL} ${PKG_SENSORS}"
    fi
}

# ── Memory Information ────────────────────────────────────────────────────────
detect_memory() {
    # Total RAM in kB from /proc/meminfo
    TOTAL_MEM_KB=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
    TOTAL_MEM_MB=$(( TOTAL_MEM_KB / 1024 ))
    TOTAL_MEM_GB=$(( TOTAL_MEM_MB / 1024 ))

    # NUMA topology
    SOCKETS=$(lscpu   | awk '/^Socket\(s\)/{print $2}')
    NUMA_NODES=$(lscpu | awk '/^NUMA node\(s\)/{print $NF}')

    # Determine number of workers
    if [[ "$WORKERS" -eq 0 ]]; then
        WORKERS="$NUMA_NODES"
    fi

    # Memory per worker (in MB), based on MEM_PERCENT of total RAM
    STRESS_MEM_MB=$(( TOTAL_MEM_MB * MEM_PERCENT / 100 / WORKERS ))
    STRESS_MEM_TOTAL_MB=$(( STRESS_MEM_MB * WORKERS ))

    # Test mode label
    if [[ "$SOCKETS" -ge 2 ]] && [[ "$NUMACTL_OK" == true ]]; then
        TEST_MODE="Dual-Socket (numactl per NUMA node)"
    elif [[ "$SOCKETS" -ge 2 ]]; then
        TEST_MODE="Dual-Socket (no NUMA binding — numactl missing)"
    else
        TEST_MODE="Single-Socket"
    fi
}

print_memory_info() {
    log_section "Memory Information"
    local info
    info=$(cat <<EOF
  Total RAM       : ${TOTAL_MEM_GB} GB  (${TOTAL_MEM_MB} MB)
  Sockets         : ${SOCKETS}
  NUMA Nodes      : ${NUMA_NODES}
  Test Mode       : ${TEST_MODE}
  Workers         : ${WORKERS}
  Stress Percent  : ${MEM_PERCENT}%
  Mem/Worker      : ${STRESS_MEM_MB} MB
  Total Stressed  : ${STRESS_MEM_TOTAL_MB} MB  (~$(( STRESS_MEM_TOTAL_MB / 1024 )) GB)
  VM Method       : ${VM_METHOD}
  Duration        : ${DURATION}s  ($(( DURATION / 3600 ))h $(( DURATION % 3600 / 60 ))m $(( DURATION % 60 ))s)
EOF
)
    echo "$info" | tee -a "$LOG_FILE"
}

# ── Monitoring ────────────────────────────────────────────────────────────────
start_monitoring() {
    log_section "Starting Monitors"

    # vmstat: log page faults, swap activity, and memory stats every 10 seconds
    {
        echo "=== vmstat memory/swap activity — interval 10s ==="
        vmstat -t 10
    } >> "$LOG_FILE" 2>&1 &
    MONITOR_PIDS+=($!)
    log_info "vmstat monitor started (PID ${MONITOR_PIDS[-1]})"

    # /proc/meminfo snapshot every 30 seconds (log file only)
    (
        while true; do
            {
                echo "=== $(date '+%Y-%m-%d %T') /proc/meminfo ==="
                cat /proc/meminfo
            } >> "$LOG_FILE"
            sleep 30
        done
    ) &
    MONITOR_PIDS+=($!)
    log_info "meminfo monitor started (PID ${MONITOR_PIDS[-1]})"

    # Temperature: sample every 10 seconds (memory modules heat up under load)
    if [[ "$SENSORS_OK" == true ]]; then
        (
            while true; do
                { echo "=== $(date '+%Y-%m-%d %T') Temperature ==="; sensors 2>/dev/null || true; } >> "$LOG_FILE"
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

# ── Stress Test ───────────────────────────────────────────────────────────────
run_stress() {
    log_section "Starting Memory Stress"
    log_info "VM Method: ${VM_METHOD} | Duration: ${DURATION}s | Workers: ${WORKERS} | Mem/Worker: ${STRESS_MEM_MB}MB"

    if [[ "$SOCKETS" -ge 2 ]] && [[ "$NUMACTL_OK" == true ]]; then
        # Dual-socket: one stress-ng per NUMA node, each bound to local memory
        for (( node=0; node<NUMA_NODES; node++ )); do
            log_info "Launching stress-ng on NUMA node ${node}..."
            numactl --cpunodebind="${node}" --membind="${node}" \
                stress-ng --vm 1 \
                          --vm-bytes "${STRESS_MEM_MB}M" \
                          --vm-method "$VM_METHOD" \
                          --timeout "${DURATION}s" \
                          --metrics-brief \
                >> "$LOG_FILE" 2>&1 &
            STRESS_PIDS+=($!)
            log_info "  stress-ng on node ${node} started (PID ${STRESS_PIDS[-1]})"
        done
    else
        # Single-socket or no numactl: run all workers together
        [[ "$SOCKETS" -ge 2 ]] && \
            log_warn "Dual-socket detected but numactl unavailable — running without NUMA binding."

        log_info "Launching stress-ng with ${WORKERS} worker(s), ${STRESS_MEM_MB}MB each..."
        stress-ng --vm "$WORKERS" \
                  --vm-bytes "${STRESS_MEM_MB}M" \
                  --vm-method "$VM_METHOD" \
                  --timeout "${DURATION}s" \
                  --metrics-brief \
            >> "$LOG_FILE" 2>&1 &
        STRESS_PIDS+=($!)
        log_info "stress-ng running (PID: ${STRESS_PIDS[-1]})"
    fi
}

# ── Progress Display ──────────────────────────────────────────────────────────
show_progress() {
    local test_start=$SECONDS
    local report_interval=60   # print progress every 60 seconds

    while [[ $(( SECONDS - test_start )) -lt $DURATION ]]; do
        sleep "$report_interval"

        # Stop early if all stress-ng processes have exited
        local any_alive=false
        for pid in "${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}"; do
            kill -0 "$pid" 2>/dev/null && any_alive=true && break
        done
        [[ "$any_alive" == false ]] && break

        local elapsed=$(( SECONDS - test_start ))
        local remaining=$(( DURATION > elapsed ? DURATION - elapsed : 0 ))
        local pct=$(( elapsed * 100 / DURATION ))
        # Include current free memory in progress line for quick health check
        local free_mb
        free_mb=$(awk '/^MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
        log_info "Progress: ${pct}% | elapsed: ${elapsed}s | remaining: ~${remaining}s | MemAvail: ${free_mb}MB"
    done
}

# ── Cleanup on interrupt ──────────────────────────────────────────────────────
cleanup() {
    echo ""
    log_warn "Interrupt received — stopping all processes..."
    for pid in "${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    stop_monitoring
    log_warn "Test aborted. Partial log saved to:"
    log_warn "  ${LOG_FILE}"
    exit 1
}
trap cleanup SIGINT SIGTERM

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log_section "Memory Stress Test — $(date)"
    log_info "Host    : $(hostname)"
    log_info "Log     : ${LOG_FILE}"

    detect_os
    check_deps
    detect_memory
    print_memory_info

    # Confirm before starting
    if [[ "$SKIP_CONFIRM" == false ]]; then
        echo ""
        echo -e "${BOLD}Ready to start. Press ENTER to continue, Ctrl+C to cancel...${NC}"
        read -r
    fi

    # ── Pre-test snapshot (log file only) ────────────────────────────────────
    log_section "Pre-Test Snapshot"
    {
        echo "--- /proc/meminfo ---"
        cat /proc/meminfo
        echo ""
        echo "--- free -h ---"
        free -h
        echo ""
        echo "--- NUMA hardware (numactl) ---"
        numactl --hardware 2>/dev/null || echo "(numactl not available)"
        echo ""
        echo "--- vmstat (initial) ---"
        vmstat -s
        if [[ "$SENSORS_OK" == true ]]; then
            echo ""
            echo "--- Initial Temperature ---"
            sensors 2>/dev/null || true
        fi
    } >> "$LOG_FILE" 2>&1
    log_info "Pre-test snapshot saved to log."

    # ── Run ──────────────────────────────────────────────────────────────────
    start_monitoring
    run_stress
    show_progress   # blocks, printing progress every 60s

    # Wait for all stress-ng processes to exit and flush metrics
    log_info "Waiting for stress-ng to finish..."
    for pid in "${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}"; do
        wait "$pid" 2>/dev/null || true
    done

    stop_monitoring

    # ── Post-test snapshot ───────────────────────────────────────────────────
    log_section "Post-Test Snapshot"
    {
        echo "--- free -h ---"
        free -h
        echo ""
        echo "--- /proc/meminfo ---"
        cat /proc/meminfo
        echo ""
        echo "--- vmstat summary ---"
        vmstat -s
        if [[ "$SENSORS_OK" == true ]]; then
            echo ""
            echo "--- Final Temperature ---"
            sensors 2>/dev/null || true
        fi
    } >> "$LOG_FILE" 2>&1
    log_info "Post-test snapshot saved to log."

    # ── Done ─────────────────────────────────────────────────────────────────
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
