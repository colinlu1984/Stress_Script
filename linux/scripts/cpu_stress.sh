#!/usr/bin/env bash
# =============================================================================
# Script      : cpu_stress.sh
# Description : CPU stress test for Intel/AMD single/dual-socket servers
#               Compatible with Rocky Linux and Ubuntu
# Usage       : ./cpu_stress.sh [OPTIONS]
# Date        : 2026-03-09
# =============================================================================
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="$(dirname "$SCRIPT_DIR")/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${RESULT_DIR}/cpu_stress_$(hostname -s)_${TIMESTAMP}.log"

# ── Defaults ──────────────────────────────────────────────────────────────────
DURATION=14400          # seconds (4 hours); override with -d
CPU_METHOD="matrixprod" # stress-ng cpu method; override with -m

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
# Write raw command output to log file only (no terminal clutter during test)
log_cmd_output() {
    "$@" >> "$LOG_FILE" 2>&1 || true
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

CPU stress test for Intel/AMD, single/dual-socket servers.
Supports Rocky Linux and Ubuntu.

Options:
  -d, --duration SEC    Test duration in seconds (default: ${DURATION})
  -m, --method   NAME   stress-ng CPU method (default: ${CPU_METHOD})
                        Common values: matrixprod, fft, int64, float, all
  -y, --yes             Skip confirmation prompt (for automated runs)
  -h, --help            Show this help

Examples:
  $(basename "$0")                        # Default 30-minute test
  $(basename "$0") -d 3600               # 1-hour test
  $(basename "$0") -d 60 -m all          # Quick 1-minute test, all methods
  $(basename "$0") -d 7200 -y            # 2-hour test, no prompt
EOF
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration) DURATION="$2";   shift 2 ;;
        -m|--method)   CPU_METHOD="$2"; shift 2 ;;
        -y|--yes)      SKIP_CONFIRM=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Validate duration is a positive integer
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
    echo "Error: --duration must be a positive integer (seconds)" >&2
    exit 1
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
    if ! command -v mpstat &>/dev/null; then
        missing_tools+=("mpstat"); missing_pkgs+=("$PKG_SYSSTAT")
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

    # lm-sensors: optional, for temperature monitoring
    if command -v sensors &>/dev/null; then
        SENSORS_OK=true
    else
        log_warn "sensors not found — temperature monitoring disabled."
        log_warn "  Install: sudo ${PKG_INSTALL} ${PKG_SENSORS}"
    fi
}

# ── CPU Information ───────────────────────────────────────────────────────────
detect_cpu() {
    CPU_VENDOR_RAW=$(lscpu | awk '/^Vendor ID/{print $3}')
    CPU_MODEL=$(lscpu    | awk -F': +' '/^Model name/{print $2}')
    SOCKETS=$(lscpu      | awk '/^Socket\(s\)/{print $2}')
    CORES_PER_SOCKET=$(lscpu | awk '/^Core\(s\) per socket/{print $NF}')
    THREADS_PER_CORE=$(lscpu | awk '/^Thread\(s\) per core/{print $NF}')
    TOTAL_LOGICAL=$(nproc)
    NUMA_NODES=$(lscpu   | awk '/^NUMA node\(s\)/{print $NF}')

    case "$CPU_VENDOR_RAW" in
        GenuineIntel) CPU_VENDOR="Intel" ;;
        AuthenticAMD) CPU_VENDOR="AMD"   ;;
        *)            CPU_VENDOR="$CPU_VENDOR_RAW" ;;
    esac

    # Determine test mode label
    if [[ "$SOCKETS" -ge 2 ]] && [[ "$NUMACTL_OK" == true ]]; then
        TEST_MODE="Dual-Socket (numactl per NUMA node)"
    elif [[ "$SOCKETS" -ge 2 ]]; then
        TEST_MODE="Dual-Socket (no NUMA binding — numactl missing)"
    else
        TEST_MODE="Single-Socket"
    fi
}

print_cpu_info() {
    log_section "CPU Information"
    local info
    info=$(cat <<EOF
  Vendor        : ${CPU_VENDOR}
  Model         : ${CPU_MODEL}
  Sockets       : ${SOCKETS}
  Cores/Socket  : ${CORES_PER_SOCKET}
  Threads/Core  : ${THREADS_PER_CORE}
  Logical CPUs  : ${TOTAL_LOGICAL}
  NUMA Nodes    : ${NUMA_NODES}
  Test Mode     : ${TEST_MODE}
  Duration      : ${DURATION}s  ($(( DURATION / 60 )) min $(( DURATION % 60 )) sec)
  CPU Method    : ${CPU_METHOD}
EOF
)
    echo "$info" | tee -a "$LOG_FILE"
}

# ── Monitoring ────────────────────────────────────────────────────────────────
start_monitoring() {
    log_section "Starting Monitors"

    # mpstat: log per-core utilization every 5 seconds (log file only)
    {
        echo "=== mpstat per-core utilization — interval 5s ==="
        mpstat -P ALL 5
    } >> "$LOG_FILE" 2>&1 &
    MONITOR_PIDS+=($!)
    log_info "CPU utilization monitor started (PID ${MONITOR_PIDS[-1]})"

    # Temperature: sample every 10 seconds (log file only)
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
    log_section "Starting CPU Stress"
    log_info "Method: ${CPU_METHOD} | Duration: ${DURATION}s | Logical CPUs: ${TOTAL_LOGICAL}"

    if [[ "$SOCKETS" -ge 2 ]] && [[ "$NUMACTL_OK" == true ]]; then
        # Dual-socket: one stress-ng per NUMA node, each fills its own CPUs and memory
        log_info "Launching stress-ng on NUMA node 0..."
        numactl --cpunodebind=0 --membind=0 \
            stress-ng --cpu 0 \
                      --cpu-method "$CPU_METHOD" \
                      --timeout "${DURATION}s" \
                      --metrics-brief \
            >> "$LOG_FILE" 2>&1 &
        STRESS_PIDS+=($!)

        log_info "Launching stress-ng on NUMA node 1..."
        numactl --cpunodebind=1 --membind=1 \
            stress-ng --cpu 0 \
                      --cpu-method "$CPU_METHOD" \
                      --timeout "${DURATION}s" \
                      --metrics-brief \
            >> "$LOG_FILE" 2>&1 &
        STRESS_PIDS+=($!)

        log_info "stress-ng running on both sockets (PIDs: ${STRESS_PIDS[*]})"
    else
        # Single-socket or fallback: all logical CPUs
        [[ "$SOCKETS" -ge 2 ]] && \
            log_warn "Dual-socket detected but numactl unavailable — running without NUMA binding."

        log_info "Launching stress-ng on all ${TOTAL_LOGICAL} logical CPUs..."
        stress-ng --cpu "$TOTAL_LOGICAL" \
                  --cpu-method "$CPU_METHOD" \
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
    local report_interval=30   # seconds between progress lines

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
        log_info "Progress: ${pct}% | elapsed: ${elapsed}s | remaining: ~${remaining}s"
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
    # Banner
    log_section "CPU Stress Test — $(date)"
    log_info "Host    : $(hostname)"
    log_info "Log     : ${LOG_FILE}"

    detect_os
    check_deps
    detect_cpu
    print_cpu_info

    # Confirm before starting
    if [[ "$SKIP_CONFIRM" == false ]]; then
        echo ""
        echo -e "${BOLD}Ready to start. Press ENTER to continue, Ctrl+C to cancel...${NC}"
        read -r
    fi

    # ── Pre-test snapshot (log file only) ────────────────────────────────────
    log_section "Pre-Test Snapshot"
    {
        echo "--- lscpu ---"
        lscpu
        echo ""
        echo "--- /proc/cpuinfo (model + physical id per socket) ---"
        grep -E "^(model name|physical id|processor)" /proc/cpuinfo | sort -u
        echo ""
        echo "--- Memory info (numactl) ---"
        numactl --hardware 2>/dev/null || echo "(numactl not available)"
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
    show_progress   # blocks, printing progress every 30s

    # Wait for stress-ng to fully exit and flush metrics
    log_info "Waiting for stress-ng to finish..."
    for pid in "${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}"; do
        wait "$pid" 2>/dev/null || true
    done

    stop_monitoring

    # ── Post-test snapshot ───────────────────────────────────────────────────
    log_section "Post-Test Snapshot"
    {
        if [[ "$SENSORS_OK" == true ]]; then
            echo "--- Final Temperature ---"
            sensors 2>/dev/null || true
            echo ""
        fi
        echo "--- Current CPU Frequency (MHz) ---"
        paste \
            <(ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null) \
            <(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null) \
            2>/dev/null \
            | awk '{n=split($1,a,"/"); printf "  cpu%-4s: %d MHz\n", a[n-1], $2/1000}' \
            || echo "  (CPU frequency info not available)"
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
