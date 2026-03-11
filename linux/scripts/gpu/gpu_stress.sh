#!/usr/bin/env bash
# =============================================================================
# 脚本名称: gpu_stress.sh
# 描    述: GPU 压力测试脚本，支持单卡/多卡并行，自动选择 gpu-burn / dcgmi 引擎
# 用    法: ./gpu_stress.sh [OPTIONS]
# 作    者: <author>
# 更新日期: 2026-03-11
# =============================================================================
set -euo pipefail

# ── 常量 ──────────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RESULTS_DIR="${SCRIPT_DIR}/../../../results"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="${RESULTS_DIR}/gpu_stress_${TIMESTAMP}.log"
readonly MONITOR_INTERVAL=30   # 采样间隔（秒）

# ── 默认参数 ──────────────────────────────────────────────────────────────────
GPU_LIST=()        # 空 = 全部 GPU
DURATION=14400     # 4 小时（秒）
ENGINE="auto"      # auto | gpu-burn | dcgmi
TEMP_LIMIT=85      # 温度告警阈值 °C
STOP_ON_ECC=true   # 检测到 uncorrected ECC 错误时中止测试

# ── 状态变量 ──────────────────────────────────────────────────────────────────
OS_FAMILY=""
PKG_INSTALL=""
GPUBURN_CMD=""
DCGMI_CMD=""
ENGINE_USED=""
MONITOR_PID=""
declare -A GPU_PEAK_TEMP=()
declare -A GPU_ECC_ERRORS=()
OVERALL_RESULT="PASS"

# ── 日志函数 ──────────────────────────────────────────────────────────────────
log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo "[WARN]  $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; exit 1; }
log_sep()   { echo "$(printf '─%.0s' {1..72})" | tee -a "$LOG_FILE"; }

# ── 用法说明 ──────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
用法: $(basename "$0") [OPTIONS]

选项:
  -g, --gpu         指定压测的 GPU 编号，逗号分隔（默认: all）
                    示例: --gpu 0,1,3
  -d, --duration    压测持续时间，单位秒（默认: 14400，即 4 小时）
  -e, --engine      压测引擎: auto | gpu-burn | dcgmi（默认: auto）
                    auto 优先使用 gpu-burn，不可用时降级到 dcgmi
  -T, --temp-limit  温度告警阈值，超过则写入告警（默认: 85 °C）
      --no-ecc-stop 检测到 ECC uncorrected 错误时不中止，仅记录告警
  -h, --help        显示此帮助信息

示例:
  $(basename "$0")                          # 全卡压测 4 小时
  $(basename "$0") --gpu 0,1 --duration 3600       # 0、1 号卡压测 1 小时
  $(basename "$0") --engine dcgmi --duration 7200  # 强制使用 dcgmi 压测 2 小时
  $(basename "$0") --temp-limit 80                 # 温度超过 80°C 告警
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

# ── 参数解析 ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--gpu)
            IFS=',' read -ra GPU_LIST <<< "$2"
            shift 2
            ;;
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -e|--engine)
            ENGINE="$2"
            shift 2
            ;;
        -T|--temp-limit)
            TEMP_LIMIT="$2"
            shift 2
            ;;
        --no-ecc-stop)
            STOP_ON_ECC=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ── 清理函数（EXIT / INT / TERM 时执行）────────────────────────────────────────
cleanup() {
    # 停止监控进程
    if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
    fi
    # 停止所有后台压测子进程
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    log_info "清理完成，日志已保存到: ${LOG_FILE}"
}
trap cleanup EXIT INT TERM

# ── 初始化结果目录 ─────────────────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"

# ── OS 识别 ───────────────────────────────────────────────────────────────────
detect_os() {
    local os_id=""
    if [[ -f /etc/os-release ]]; then
        os_id=$(. /etc/os-release && echo "${ID:-}")
    fi
    case "${os_id,,}" in
        rocky|rhel|centos|almalinux|fedora)
            PKG_INSTALL="dnf install -y"
            OS_FAMILY="rpm"
            ;;
        ubuntu|debian)
            PKG_INSTALL="apt-get install -y"
            OS_FAMILY="deb"
            ;;
        *)
            PKG_INSTALL="dnf install -y"
            OS_FAMILY="rpm"
            log_warn "未知 OS '${os_id}'，假设为 RPM 系"
            ;;
    esac
}

# ── 基础依赖检查 ──────────────────────────────────────────────────────────────
check_deps() {
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi 未找到。请确认 NVIDIA 驱动已正确安装。"
    fi
    log_info "nvidia-smi 版本: $(nvidia-smi --version | head -1)"
}

# ── GPU 检测与列表构建 ────────────────────────────────────────────────────────
detect_gpus() {
    local all_ids
    # 查询所有 GPU 编号（0-based）
    mapfile -t all_ids < <(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null)

    if [[ ${#all_ids[@]} -eq 0 ]]; then
        log_error "未检测到任何 NVIDIA GPU。"
    fi

    # 如果用户未指定 --gpu，则使用全部
    if [[ ${#GPU_LIST[@]} -eq 0 ]]; then
        GPU_LIST=("${all_ids[@]}")
    fi

    log_sep
    log_info "检测到 ${#all_ids[@]} 张 GPU，本次压测: ${GPU_LIST[*]}"
    log_sep

    # 打印每卡基本信息
    while IFS=',' read -r idx name driver mem_total ecc_mode; do
        idx="${idx// /}"
        name="${name# }"
        driver="${driver# }"
        mem_total="${mem_total# }"
        ecc_mode="${ecc_mode# }"
        log_info "  GPU ${idx}: ${name} | VRAM: ${mem_total} MiB | ECC: ${ecc_mode} | 驱动: ${driver}"
        GPU_PEAK_TEMP[$idx]=0
        GPU_ECC_ERRORS[$idx]=0
    done < <(nvidia-smi \
        --query-gpu=index,name,driver_version,memory.total,ecc.mode.current \
        --format=csv,noheader,nounits 2>/dev/null)
    log_sep
}

# ── 压测引擎检测 ──────────────────────────────────────────────────────────────

# 查找 gpu-burn 可执行文件（本地目录或 PATH）
find_gpuburn() {
    # 优先查找脚本同目录
    local local_bin="${SCRIPT_DIR}/gpu_burn"
    if [[ -x "$local_bin" ]]; then
        GPUBURN_CMD="$local_bin"
        return 0
    fi
    if command -v gpu_burn &>/dev/null; then
        GPUBURN_CMD="$(command -v gpu_burn)"
        return 0
    fi
    return 1
}

# 尝试从源码编译 gpu-burn（需要 CUDA toolkit 和 make）
build_gpuburn() {
    if ! command -v nvcc &>/dev/null; then
        log_warn "nvcc 未找到，无法编译 gpu-burn。"
        return 1
    fi
    if ! command -v make &>/dev/null; then
        log_warn "make 未找到，无法编译 gpu-burn。"
        return 1
    fi
    if ! command -v git &>/dev/null; then
        log_warn "git 未找到，无法克隆 gpu-burn。"
        return 1
    fi

    local build_dir
    build_dir=$(mktemp -d)
    log_info "正在从源码编译 gpu-burn（需要约 1 分钟）..."

    git clone --depth=1 https://github.com/wilicc/gpu-burn.git "$build_dir" \
        >> "$LOG_FILE" 2>&1 || {
        log_warn "克隆 gpu-burn 仓库失败，请检查网络连接。"
        rm -rf "$build_dir"
        return 1
    }

    make -C "$build_dir" >> "$LOG_FILE" 2>&1 || {
        log_warn "gpu-burn 编译失败，请检查 CUDA toolkit 版本。"
        rm -rf "$build_dir"
        return 1
    }

    cp "${build_dir}/gpu_burn" "${SCRIPT_DIR}/gpu_burn"
    chmod +x "${SCRIPT_DIR}/gpu_burn"
    rm -rf "$build_dir"

    GPUBURN_CMD="${SCRIPT_DIR}/gpu_burn"
    log_info "gpu-burn 编译成功: ${GPUBURN_CMD}"
    return 0
}

# 查找 dcgmi
find_dcgmi() {
    if command -v dcgmi &>/dev/null; then
        DCGMI_CMD="$(command -v dcgmi)"
        return 0
    fi
    return 1
}

# 根据 --engine 选择引擎
select_engine() {
    case "$ENGINE" in
        auto)
            if find_gpuburn; then
                ENGINE_USED="gpu-burn"
                log_info "引擎选择: gpu-burn (${GPUBURN_CMD})"
            elif build_gpuburn; then
                ENGINE_USED="gpu-burn"
                log_info "引擎选择: gpu-burn（已编译）"
            elif find_dcgmi; then
                ENGINE_USED="dcgmi"
                log_info "引擎选择: dcgmi (${DCGMI_CMD})"
            else
                log_error "未找到可用压测引擎。
  请安装 gpu-burn（需要 CUDA toolkit）或 DCGM：
    gpu-burn : git clone https://github.com/wilicc/gpu-burn && cd gpu-burn && make
    DCGM     : https://developer.nvidia.com/dcgm"
            fi
            ;;
        gpu-burn)
            if find_gpuburn; then
                ENGINE_USED="gpu-burn"
                log_info "引擎: gpu-burn (${GPUBURN_CMD})"
            elif build_gpuburn; then
                ENGINE_USED="gpu-burn"
                log_info "引擎: gpu-burn（已编译）"
            else
                log_error "gpu-burn 不可用，且编译失败。"
            fi
            ;;
        dcgmi)
            find_dcgmi || log_error "dcgmi 未找到。请安装 DCGM：
  https://developer.nvidia.com/dcgm"
            ENGINE_USED="dcgmi"
            log_info "引擎: dcgmi (${DCGMI_CMD})"
            ;;
        *)
            log_error "未知引擎: ${ENGINE}。可选: auto | gpu-burn | dcgmi"
            ;;
    esac
}

# ── 实时监控（后台循环） ──────────────────────────────────────────────────────
#
# 每 MONITOR_INTERVAL 秒采样一次所有 GPU 的关键指标，写入日志并检查告警条件。
# 函数在子 shell 中以后台进程运行，通过写入共享 LOG_FILE 汇报状态。
#
monitor_loop() {
    local -r temp_limit="$1"
    local -r stop_on_ecc="$2"

    while true; do
        # H100/A100 有 ECC；RTX 消费卡返回 [N/A]，需兼容处理
        while IFS=',' read -r idx name temp util power mem_used mem_total \
                              ecc_corr ecc_uncorr; do
            # 去除首尾空格
            idx="${idx// /}"; temp="${temp// /}"; util="${util// /}"
            power="${power// /}"; mem_used="${mem_used// /}"
            name="${name# }"; ecc_corr="${ecc_corr// /}"; ecc_uncorr="${ecc_uncorr// /}"

            # 跳过当前压测范围外的 GPU
            local in_list=false
            for g in "${GPU_LIST[@]}"; do
                [[ "$g" == "$idx" ]] && { in_list=true; break; }
            done
            $in_list || continue

            # 记录采样行
            printf "[MONITOR] %s GPU%-2s %-25s Temp:%3s°C  Util:%3s%%  Power:%6sW  Mem:%6s/%sMiB  ECC(corr/uncorr):%s/%s\n" \
                "$(date '+%H:%M:%S')" "$idx" "$(echo "$name" | cut -c1-25)" \
                "$temp" "$util" "$power" "$mem_used" "$mem_total" \
                "$ecc_corr" "$ecc_uncorr" >> "$LOG_FILE"

            # 温度告警
            if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > temp_limit )); then
                echo "[WARN]  $(date '+%H:%M:%S') GPU${idx} 温度 ${temp}°C 超过阈值 ${temp_limit}°C！" \
                    | tee -a "$LOG_FILE" >&2
            fi

            # ECC uncorrected 错误告警（[N/A] 表示卡不支持 ECC，跳过）
            if [[ "$ecc_uncorr" =~ ^[0-9]+$ ]] && (( ecc_uncorr > 0 )); then
                echo "[WARN]  $(date '+%H:%M:%S') GPU${idx} ECC uncorrected 错误: ${ecc_uncorr}！" \
                    | tee -a "$LOG_FILE" >&2
                if [[ "$stop_on_ecc" == "true" ]]; then
                    echo "[ERROR] $(date '+%H:%M:%S') 因 ECC 错误中止测试。" \
                        | tee -a "$LOG_FILE" >&2
                    # 通知父进程终止
                    kill -TERM "$PPID" 2>/dev/null || true
                    exit 1
                fi
            fi

        done < <(nvidia-smi \
            --query-gpu=index,name,temperature.gpu,utilization.gpu,\
power.draw,memory.used,memory.total,\
ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total \
            --format=csv,noheader,nounits 2>/dev/null)

        sleep "$MONITOR_INTERVAL"
    done
}

# ── gpu-burn 压测（每卡独立后台进程）────────────────────────────────────────────
run_gpuburn() {
    local pids=()
    local failed_gpus=()

    log_info "启动 gpu-burn，持续 ${DURATION}s，并行压测 GPU: ${GPU_LIST[*]}"
    log_sep

    for gpu_id in "${GPU_LIST[@]}"; do
        log_info "  GPU${gpu_id}: 启动 gpu-burn..."
        # CUDA_VISIBLE_DEVICES 将 gpu-burn 绑定到指定卡
        # -d 参数使用双精度（FP64），对 H100/A100 更有效
        CUDA_VISIBLE_DEVICES="$gpu_id" "$GPUBURN_CMD" -d "$DURATION" \
            >> "$LOG_FILE" 2>&1 &
        pids+=($!)
    done

    # 等待所有压测进程，收集失败的 GPU
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            failed_gpus+=("${GPU_LIST[$i]}")
        fi
    done

    if [[ ${#failed_gpus[@]} -gt 0 ]]; then
        log_warn "以下 GPU 的 gpu-burn 进程异常退出: ${failed_gpus[*]}"
        OVERALL_RESULT="FAIL"
    fi
}

# ── dcgmi 压测（循环运行 level-3 诊断直到超时） ────────────────────────────────
#
# dcgmi diag 不支持任意时长，通过循环 level-3（每轮约 3-5 min）累计达到目标时长。
# level-3 覆盖内存、计算、带宽等全面检测。
#
run_dcgmi() {
    local end_time=$(( $(date +%s) + DURATION ))
    local round=0
    local failed=false

    log_info "启动 dcgmi diag 循环，目标时长 ${DURATION}s，GPU: ${GPU_LIST[*]}"
    log_sep

    # 将 GPU 列表转换为 dcgmi 所需的逗号分隔格式
    local gpu_str
    gpu_str=$(IFS=','; echo "${GPU_LIST[*]}")

    while (( $(date +%s) < end_time )); do
        (( round++ ))
        log_info "dcgmi diag 第 ${round} 轮开始 (level 3)..."

        if ! "$DCGMI_CMD" diag -g "$gpu_str" -r 3 >> "$LOG_FILE" 2>&1; then
            log_warn "dcgmi diag 第 ${round} 轮报告失败，详情见日志。"
            failed=true
            OVERALL_RESULT="FAIL"
        else
            log_info "dcgmi diag 第 ${round} 轮完成。"
        fi
    done

    $failed && log_warn "dcgmi 共 ${round} 轮中存在失败，请检查日志。"
}

# ── 结果汇总 ──────────────────────────────────────────────────────────────────
print_summary() {
    log_sep
    log_info "压测结束 — 汇总报告"
    log_sep

    # 读取最终 ECC 和峰值温度
    while IFS=',' read -r idx temp ecc_corr ecc_uncorr; do
        idx="${idx// /}"; temp="${temp// /}"
        ecc_corr="${ecc_corr// /}"; ecc_uncorr="${ecc_uncorr// /}"

        local in_list=false
        for g in "${GPU_LIST[@]}"; do
            [[ "$g" == "$idx" ]] && { in_list=true; break; }
        done
        $in_list || continue

        local ecc_str="N/A（不支持 ECC）"
        if [[ "$ecc_corr" =~ ^[0-9]+$ ]]; then
            ecc_str="corrected=${ecc_corr}  uncorrected=${ecc_uncorr}"
            if [[ "$ecc_uncorr" =~ ^[0-9]+$ ]] && (( ecc_uncorr > 0 )); then
                OVERALL_RESULT="FAIL"
            fi
        fi

        local status="PASS"
        [[ "$OVERALL_RESULT" == "FAIL" ]] && status="FAIL"

        log_info "  GPU${idx}: 终态温度=${temp}°C  ECC: ${ecc_str}  → ${status}"

    done < <(nvidia-smi \
        --query-gpu=index,temperature.gpu,\
ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total \
        --format=csv,noheader,nounits 2>/dev/null)

    log_sep
    log_info "总体结果: ${OVERALL_RESULT}"
    log_info "日志文件: ${LOG_FILE}"
    log_sep

    [[ "$OVERALL_RESULT" == "PASS" ]] && return 0 || return 1
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$RESULTS_DIR"

    log_sep
    log_info "GPU 压力测试开始"
    log_info "时长: ${DURATION}s  温度阈值: ${TEMP_LIMIT}°C  ECC中止: ${STOP_ON_ECC}"
    log_sep

    detect_os
    check_deps
    detect_gpus
    select_engine

    # 启动监控后台进程
    monitor_loop "$TEMP_LIMIT" "$STOP_ON_ECC" &
    MONITOR_PID=$!
    log_info "监控进程已启动（PID=${MONITOR_PID}，采样间隔 ${MONITOR_INTERVAL}s）"

    # 执行压测
    case "$ENGINE_USED" in
        gpu-burn) run_gpuburn ;;
        dcgmi)    run_dcgmi   ;;
    esac

    # 停止监控
    kill "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""

    print_summary
}

main "$@"
