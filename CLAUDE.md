# CLAUDE.md — Stress_Script 项目 AI 助手指南

## 1. 项目简介

**Stress_Script** 是一个 Bash 脚本工具集，用于对服务器、服务或应用程序进行**压力测试与性能基准测试**。工具集提供可配置的负载生成脚本，帮助工程师评估系统在高负载或异常条件下的行为表现。

典型使用场景包括：
- CPU、内存、磁盘 I/O、网络带宽的压力测试
- Web 服务的并发请求压测
- 数据库连接池压测
- 长时间持续负载下的系统稳定性验证

---

## 2. 目录结构

```
Stress_Script/
├── CLAUDE.md                  # 本文件 — AI 助手指南
├── README.md                  # 面向用户的项目说明文档
├── scripts/                   # 所有压测脚本存放目录
│   ├── cpu_stress.sh          # CPU 压测脚本示例
│   ├── mem_stress.sh          # 内存压测脚本示例
│   ├── disk_stress.sh         # 磁盘 I/O 压测脚本示例
│   └── http_stress.sh         # HTTP 并发压测脚本示例
├── configs/                   # 测试场景配置文件
│   └── scenario.example.conf  # 配置文件模板（含注释说明）
├── results/                   # 测试结果输出目录（已加入 .gitignore）
└── tests/                     # 脚本逻辑验证测试
    └── test_utils.sh          # 辅助函数单元测试
```

> 新增脚本时，请统一放置在 `scripts/` 目录下，并遵循下方编写规范。

---

## 3. Bash 脚本编写规范

### 3.1 文件头部模板

每个脚本开头必须包含以下结构：

```bash
#!/usr/bin/env bash
# =============================================================================
# 脚本名称: script_name.sh
# 描    述: 一句话描述脚本用途
# 用    法: ./script_name.sh [OPTIONS]
# 作    者: <author>
# 更新日期: YYYY-MM-DD
# =============================================================================
set -euo pipefail
```

- `#!/usr/bin/env bash`：使用 `env` 查找 bash，提升跨平台兼容性
- `set -e`：遇到命令失败立即退出
- `set -u`：使用未定义变量时报错退出
- `set -o pipefail`：管道中任意命令失败时整体视为失败

### 3.2 `--help` 参数

所有面向用户的脚本**必须**实现 `--help` / `-h` 参数，并在无参数时打印使用说明：

```bash
usage() {
    cat <<EOF
用法: $(basename "$0") [OPTIONS]

选项:
  -t, --threads   并发线程数 (默认: 4)
  -d, --duration  持续时间，单位秒 (默认: 60)
  -h, --help      显示此帮助信息

示例:
  $(basename "$0") --threads 8 --duration 120
EOF
}

# 无参数时显示帮助
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--threads)  THREADS="$2"; shift 2 ;;
        -d|--duration) DURATION="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done
```

### 3.3 注释规范

- **文件级注释**：在脚本头部模板中完整描述（见 3.1）
- **函数级注释**：每个函数前说明其用途、参数和返回值
- **行内注释**：解释"为什么"而非"是什么"，尤其是魔法数字或非直觉的操作

```bash
# 最大并发数设为 512，与目标服务器 ulimit -n 上限一致
MAX_CONNECTIONS=512

# 使用 /dev/urandom 而非 /dev/zero，以绕过内核页缓存压缩优化
dd if=/dev/urandom of="$TMPFILE" bs=1M count=512
```

### 3.4 变量规范

```bash
# 全局常量使用大写
readonly MAX_RETRIES=3
readonly LOG_FILE="/tmp/stress_$(date +%Y%m%d_%H%M%S).log"

# 局部变量使用小写，函数内用 local 声明
run_test() {
    local thread_count="$1"
    local duration="$2"
    # ...
}

# 所有变量展开时加双引号
echo "结果写入: ${LOG_FILE}"
```

### 3.5 输出与日志

```bash
# 信息输出到 stdout
log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
# 警告输出到 stderr
log_warn()  { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
# 错误输出到 stderr 后退出
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }
```

---

## 4. Git 操作规范

### 4.1 分支策略

- **`main`**：稳定分支，**禁止直接推送**
- **功能/修复分支**：`<user>/<short-description>`，例如 `alice/add-disk-stress`
- **AI 生成分支**：`claude/<task-id>`

### 4.2 标准开发流程（使用 `gh` CLI）

```bash
# 1. 从最新 main 创建功能分支
git checkout main && git pull origin main
git checkout -b alice/add-disk-stress

# 2. 开发、提交
git add scripts/disk_stress.sh
git commit -m "Add disk I/O stress script with configurable block size"

# 3. 推送分支
git push -u origin alice/add-disk-stress

# 4. 通过 gh CLI 创建 Pull Request
gh pr create \
  --title "Add disk I/O stress script" \
  --body "新增磁盘 I/O 压测脚本，支持 --block-size 和 --duration 参数配置。" \
  --base main

# 5. PR 合并后删除本地分支
git checkout main && git pull origin main
git branch -d alice/add-disk-stress
```

### 4.3 Commit Message 规范

使用祈使句，格式为：`<动词> <内容>`

```
Add CPU stress script with configurable thread count
Fix memory leak in sustained load loop
Update http_stress: support HTTPS targets
Remove deprecated disk_fill.sh (replaced by disk_stress.sh)
```

### 4.4 不要提交的内容

`.gitignore` 中应包含：

```
results/
*.log
.env
*.tmp
__pycache__/
```

---

## 5. 测试规范

### 5.1 语法检查（必须）

提交前对所有修改的脚本执行静态检查：

```bash
# shellcheck — Shell 脚本静态分析
shellcheck scripts/*.sh

# bash 语法检查
bash -n scripts/cpu_stress.sh
```

CI 流程中必须包含上述检查，不通过不允许合并。

### 5.2 冒烟测试（Smoke Test）

每个脚本至少需通过以下冒烟测试：

```bash
# 1. --help 参数正常输出并以 exit 0 退出
./scripts/cpu_stress.sh --help
echo "exit code: $?"  # 应为 0

# 2. 以最小参数执行（短时间，低负载）
./scripts/cpu_stress.sh --threads 1 --duration 3
echo "exit code: $?"  # 应为 0

# 3. 传入非法参数时以非 0 退出并提示错误
./scripts/cpu_stress.sh --invalid-flag 2>&1 || echo "正确：非法参数触发退出"
```

### 5.3 辅助函数单元测试

`tests/test_utils.sh` 中为公共辅助函数编写测试：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 简单断言函数
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc — 期望 '$expected'，实际 '$actual'" >&2
        exit 1
    fi
}

# 示例：测试日志前缀格式
source ./scripts/utils.sh
output=$(log_info "test message" 2>&1)
assert_eq "log_info 前缀包含 INFO" "1" "$(echo "$output" | grep -c '\[INFO\]')"
```

运行所有测试：

```bash
bash tests/test_utils.sh
```

### 5.4 PR 检查清单

- [ ] `shellcheck` 通过，无警告
- [ ] `bash -n` 语法检查通过
- [ ] `--help` 参数输出正确
- [ ] 冒烟测试（最小参数）通过
- [ ] 未硬编码目标 IP、密码或任何敏感信息
- [ ] `.gitignore` 覆盖所有输出文件

---

## AI 助手快速参考

| 场景 | 操作 |
|------|------|
| 新增脚本 | 放入 `scripts/`，遵循头部模板，实现 `--help` |
| 修改已有脚本 | 先用 Read 工具读取文件，理解后再编辑 |
| 提交代码 | `shellcheck` → `bash -n` → 冒烟测试 → commit → push |
| 创建 PR | 使用 `gh pr create`，不直接推送 main |
| 添加依赖工具 | 在脚本顶部检测依赖并给出安装提示 |

---

*最后更新：2026-03-06。项目结构或规范发生重大变化时请同步更新本文件。*
