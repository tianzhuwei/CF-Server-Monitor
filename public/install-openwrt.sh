#!/bin/sh
# ==============================================================================
# V1.1.0
# CF-Server-Monitor 安装/卸载脚本 (OpenWrt 专用版)
# 支持: OpenWrt / LEDE / ImmortalWrt (procd + opkg)
# 纯 POSIX sh 实现，无 bash 依赖
# Fixes: 1. 独立协程无 wait 阻塞 2. 原子化原子覆盖 3. 兼容 procd 服务框架
#        4. 严格 set -u 闭环 5. 使用 /tmp 替代 /dev/shm（OpenWrt 无 /dev/shm）
# ==============================================================================

set -eu

# 路径定义（月度流量追踪）
TRAFFIC_DATA_DIR="/var/lib/cf-probe"
TRAFFIC_DATA_FILE="${TRAFFIC_DATA_DIR}/traffic.dat"

# 颜色定义（busybox sh 下仅 printf '%b' 可用）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 路径定义
SERVICE_NAME="cf-probe"
PROCD_FILE="/etc/init.d/${SERVICE_NAME}"
SCRIPT_FILE="/usr/local/bin/${SERVICE_NAME}.sh"
PID_FILE="/var/run/${SERVICE_NAME}.pid"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
SHM_DIR="/tmp"  # OpenWrt 无 /dev/shm，使用 /tmp 替代

# ---------------------------------------------------------------
# 统一输出工具（纯 POSIX sh）
# ---------------------------------------------------------------
print_banner() {
    printf '%b╔══════════════════════════════════════════════════╗%b\n' "${CYAN}" "${NC}"
    printf '%b║     CF-Server-Monitor 探针管理工具 (OpenWrt)     ║%b\n' "${CYAN}" "${NC}"
    printf '%b╚══════════════════════════════════════════════════╝%b\n' "${CYAN}" "${NC}"
}

info()  { printf '%b[✓]%b %s\n' "${GREEN}" "${NC}" "$1"; }
warn()  { printf '%b[!]%b %s\n' "${YELLOW}" "${NC}" "$1"; }
error() { printf '%b[✗]%b %s\n' "${RED}"   "${NC}" "$1"; exit 1; }
step()  { printf '%b[→]%b %s\n' "${BLUE}"  "${NC}" "$1"; }

sed_escape() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/&/\\&/g; s/@/\\@/g; s/\//\\\//g; s/|/\\|/g; s/"/\\"/g'
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 权限运行此脚本: sudo sh $0"
    fi
}

# ---------------------------------------------------------------
# OS / Init 系统探测
# ---------------------------------------------------------------
detect_os() {
    if [ -f /etc/openwrt_release ]; then
        OS_ID="openwrt"
    elif [ -f /etc/os-release ]; then
        OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'")
    else
        OS_ID=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    OS_ID=${OS_ID:-"unknown"}

    case "$OS_ID" in
        openwrt|lede|immortalwrt) PKG_MGR="opkg" ;;
        *) warn "检测到非 OpenWrt 系统: $OS_ID，仍将尝试使用 opkg" ; PKG_MGR="opkg" ;;
    esac

    # 探测 init 系统
    if command -v procd >/dev/null 2>&1 || [ -f /sbin/procd ]; then
        INIT_SYSTEM="procd"
    elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/runlevels ]; then
        INIT_SYSTEM="openrc"
    elif [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="manual"
    fi
}

# ---------------------------------------------------------------
# 依赖安装（OpenWrt 版 — 纯 POSIX sh，无需 bash）
# ---------------------------------------------------------------
install_deps() {
    step "检查系统依赖组件..."

    # OpenWrt 需要的包
    # curl:      HTTP 上报
    # coreutils: 提供完整的 date、df 等
    # procps-ng: 提供完整的 pgrep、pkill
    # ip-full:   提供 ss 命令（网络连接统计）
    required_pkgs="curl coreutils procps-ng ip-full"

    if ! command -v opkg >/dev/null 2>&1; then
        error "未找到 opkg 包管理器，当前系统不是 OpenWrt 系列。"
    fi

    step "更新 OPKG 索引并安装基础依赖..."
    opkg update >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    opkg install $required_pkgs >/dev/null 2>&1 || \
        opkg install --force-overwrite $required_pkgs >/dev/null 2>&1 || \
        warn "部分依赖安装失败，请手动执行: opkg install $required_pkgs"

    required_cmds="curl awk grep sed"
    for cmd in $required_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "缺少依赖: $cmd，某些功能可能不可用。"
        fi
    done

    # 可选依赖检查（不阻塞安装）
    for cmd in pgrep pkill ss; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "缺少可选依赖: $cmd（不影响核心监控功能）"
        fi
    done

    info "基础依赖组件检查通过"

    # 提示 init 情况
    case "$INIT_SYSTEM" in
        procd)   info "检测到 procd，将注册为 OpenWrt 系统服务。" ;;
        openrc)  warn "检测到 OpenRC — 建议使用 install-alpine.sh。" ;;
        systemd) warn "检测到 systemd — 建议使用 install.sh。" ;;
        manual)  warn "未检测到 init 系统，将采用后台进程方式运行。" ;;
    esac
}

# ---------------------------------------------------------------
# 清理旧进程 / 旧服务
# ---------------------------------------------------------------
stop_old_service() {
    step "清理可能存在的旧服务进程..."

    # procd 服务
    if [ "$INIT_SYSTEM" = "procd" ] && [ -f "$PROCD_FILE" ]; then
        "$PROCD_FILE" stop >/dev/null 2>&1 || true
        "$PROCD_FILE" disable >/dev/null 2>&1 || true
        rm -f "$PROCD_FILE"
    fi

    # PID 文件方式的后台进程
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
            kill -TERM "$old_pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "$old_pid" >/dev/null 2>&1 || true
        fi
        rm -f "$PID_FILE"
    fi

    # 兜底：按进程名杀
    if pgrep -f "${SERVICE_NAME}.sh" >/dev/null 2>&1; then
        pkill -9 -f "${SERVICE_NAME}.sh" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------
# 注入探针脚本（纯 POSIX sh，无任何 bash 特有语法）
# OpenWrt 适配：/dev/shm → /tmp
# ---------------------------------------------------------------
create_script() {
    report_interval=${1:-60}
    ping_type=${2:-http}
    ct_node=${3:-}
    cu_node=${4:-}
    cm_node=${5:-}
    bd_node=${6:-}
    reset_day=${7:-1}
    step "注入工业级监控采集探针..."

    # 先写占位符内容，再用 sed 替换 PING_TYPE_PLACEHOLDER
    cat > "${SCRIPT_FILE}" << 'PROBE_EOF'
#!/bin/sh
# 激活严格的未定义变量检查与错误即刻退出
set -eu

SERVER_ID="${1:-}"
SECRET="${2:-}"
WORKER_URL="${3:-}"
REPORT_INTERVAL="${4:-60}"
PING_TYPE="${5:-PING_TYPE_PLACEHOLDER}"
CT_NODE="${6:-}"
CU_NODE="${7:-}"
CM_NODE="${8:-}"
BD_NODE="${9:-}"
RESET_DAY="${10:-1}"

# OpenWrt 共享内存目录（/dev/shm 在 OpenWrt 上不存在）
SHM_DIR="/tmp"

# 严苛环境下的规范 JSON 字段转义函数
# 纯 POSIX sh 实现：使用 sed/tr 替代 ${var//} 和 $'' 语法
escape_json() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r' '  '
}

safe_div() {
    num="${1:-0}"
    den="${2:-0}"
    def="${3:-0}"
    if [ "${den}" -eq 0 ]; then echo "${def}"; else echo $(( num / den )); fi
}

get_net_bytes() {
    awk 'NR>2 && $1~/^(eth|en|wl)[a-z0-9]*:/{rx+=$2;tx+=$10}END{printf "%.0f %.0f\n",rx,tx}' /proc/net/dev 2>/dev/null || echo "0 0";
}

# ------------------ 月度流量追踪模块 ------------------
# 功能：计算当月消耗流量（上行/下行），自动处理服务器重启和跨月重置
TRAFFIC_DATA_DIR="/var/lib/cf-probe"
TRAFFIC_DATA_FILE="${TRAFFIC_DATA_DIR}/traffic.dat"

# 获取当月账单周期起始时间戳（UTC+0）
get_period_start_ts() {
    reset_day="$1"
    now_ts="$2"
    year=''; month=''; day=''
    # 使用 UTC 时间获取年月日（兼容 busybox date 和 GNU date）
    if date -u -d "@${now_ts}" '+%Y' >/dev/null 2>&1; then
        year=$(date -u -d "@${now_ts}" '+%Y')
        month=$(date -u -d "@${now_ts}" '+%m')
        day=$(date -u -d "@${now_ts}" '+%d')
    else
        year=$(date -u -r "${now_ts}" '+%Y')
        month=$(date -u -r "${now_ts}" '+%m')
        day=$(date -u -r "${now_ts}" '+%d')
    fi

    target_day="$reset_day"
    # 处理月份最后一天：2月最多29天，4/6/9/11月最多30天
    case "$month" in
        02) [ "$target_day" -gt 29 ] && target_day=29 ;;
        04|06|09|11) [ "$target_day" -gt 30 ] && target_day=30 ;;
    esac

    period_start_ts=''
    if [ "$day" -ge "$target_day" ]; then
        if date -u -d "${year}-${month}-${target_day} 00:00:00" '+%s' >/dev/null 2>&1; then
            period_start_ts=$(date -u -d "${year}-${month}-${target_day} 00:00:00" '+%s')
        else
            period_start_ts=$(date -u -r "${now_ts}" '+%s')
        fi
    else
        prev_month=$((month - 1))
        [ "$prev_month" -eq 0 ] && { prev_month=12; year=$((year - 1)); }
        prev_month_str=$(printf "%02d" "$prev_month")
        case "$prev_month" in
            02) [ "$target_day" -gt 29 ] && target_day=29 ;;
            04|06|09|11) [ "$target_day" -gt 30 ] && target_day=30 ;;
        esac
        if date -u -d "${year}-${prev_month_str}-${target_day} 00:00:00" '+%s' >/dev/null 2>&1; then
            period_start_ts=$(date -u -d "${year}-${prev_month_str}-${target_day} 00:00:00" '+%s')
        else
            period_start_ts=$(date -u -r "${now_ts}" '+%s')
        fi
    fi
    echo "$period_start_ts"
}

# 计算月度流量（自动持久化）
calc_monthly_traffic() {
    current_rx="$1"
    current_tx="$2"
    reset_day="${RESET_DAY:-1}"
    now_ts=$(date '+%s')

    mkdir -p "${TRAFFIC_DATA_DIR}" 2>/dev/null || true

    # 读取上次保存的数据
    saved_rx_prev=0; saved_tx_prev=0; saved_rx_period=0; saved_tx_period=0
    saved_last_check=0; saved_period_start=0
    if [ -f "${TRAFFIC_DATA_FILE}" ]; then
        tmp_rx_prev=''; tmp_tx_prev=''; tmp_rx_period=''; tmp_tx_period=''
        tmp_last_check=''; tmp_period_start=''
        while IFS='=' read -r key value; do
            case "$key" in
                RX_PREV) tmp_rx_prev="$value" ;;
                TX_PREV) tmp_tx_prev="$value" ;;
                RX_PERIOD) tmp_rx_period="$value" ;;
                TX_PERIOD) tmp_tx_period="$value" ;;
                LAST_CHECK) tmp_last_check="$value" ;;
                PERIOD_START) tmp_period_start="$value" ;;
            esac
        done < "${TRAFFIC_DATA_FILE}"
        saved_rx_prev=${tmp_rx_prev:-0}; saved_tx_prev=${tmp_tx_prev:-0}
        saved_rx_period=${tmp_rx_period:-0}; saved_tx_period=${tmp_tx_period:-0}
        saved_last_check=${tmp_last_check:-0}; saved_period_start=${tmp_period_start:-0}
    fi

    # 计算当前账单周期起始
    period_start_ts=$(get_period_start_ts "$reset_day" "$now_ts")

    # 检测是否是首次运行
    rx_delta=0; tx_delta=0
    if [ "$saved_last_check" -ne 0 ]; then
        if [ "$current_rx" -lt "$saved_rx_prev" ] || [ "$current_tx" -lt "$saved_tx_prev" ]; then
            rx_delta=0; tx_delta=0
        else
            rx_delta=$((current_rx - saved_rx_prev))
            tx_delta=$((current_tx - saved_tx_prev))
        fi

        # 判断是否进入新账单周期（跨月）
        if [ "$period_start_ts" -ne "$saved_period_start" ] && [ "$saved_period_start" -ne 0 ]; then
            saved_rx_period="$rx_delta"; saved_tx_period="$tx_delta"
        else
            saved_rx_period=$((saved_rx_period + rx_delta))
            saved_tx_period=$((saved_tx_period + tx_delta))
        fi
    else
        saved_rx_period=0
        saved_tx_period=0
    fi

    # 持久化保存
    cat > "${TRAFFIC_DATA_FILE}.tmp" << EOF
RX_PREV=${current_rx}
TX_PREV=${current_tx}
RX_PERIOD=${saved_rx_period}
TX_PERIOD=${saved_tx_period}
LAST_CHECK=${now_ts}
PERIOD_START=${period_start_ts}
EOF
    mv "${TRAFFIC_DATA_FILE}.tmp" "${TRAFFIC_DATA_FILE}" 2>/dev/null || true

    # 返回当月流量（上行=tx, 下行=rx）
    echo "$saved_rx_period $saved_tx_period"
}

get_cpu_stat() {
    awk '/^cpu /{total=$2+$3+$4+$5+$6+$7+$8+$9;idle=$5+$6;printf "%.0f %.0f\n",total,idle}' /proc/stat 2>/dev/null || echo "0 0";
}

get_http_ping() {
    rtt=$(curl -o /dev/null -s -m 1 --connect-timeout 1 -w "%{time_total}" "http://${1:-}" 2>/dev/null | awk '{printf "%.0f", $1*1000}')
    if [ -n "$rtt" ] && [ "$rtt" -gt 0 ] 2>/dev/null; then
        echo "$rtt"
    else
        echo ""
    fi
}

get_tcp_ping() {
    host="${1:-}"
    port="${2:-443}"
    scheme="http"
    timing=''

    if [ -z "${host}" ]; then
        echo ""
        return
    fi

    if [ "${port}" = "443" ]; then
        scheme="https"
    fi

    timing=$(curl -k -o /dev/null -s \
        --connect-timeout 2 \
        --max-time 3 \
        -w "%{time_namelookup} %{time_connect}" \
        "${scheme}://${host}:${port}/" 2>/dev/null || true)

    awk -v t="${timing}" 'BEGIN{
        split(t, a, " ")
        dns = a[1] + 0
        conn = a[2] + 0
        if (conn <= 0 || conn < dns) {
            print ""
            exit
        }
        ms = int((conn - dns) * 1000 + 0.5)
        if (ms < 1) ms = 1
        print ms
    }'
}

get_ping() {
    host="$1"
    port="${2:-443}"

    if [ "${PING_TYPE}" = "tcp" ]; then
        get_tcp_ping "$host" "$port"
    else
        get_http_ping "$host"
    fi
}

# 静态测试节点定义（空值则跳过）
CT_NODE="${CT_NODE:-}"
CU_NODE="${CU_NODE:-}"
CM_NODE="${CM_NODE:-}"
BD_NODE="${BD_NODE:-}"

# ==============================================================================
# 高并发/无竞态后台网络 Worker 协程
# OpenWrt 适配：使用 /tmp 替代 /dev/shm
# ==============================================================================
run_network_worker() {
    set -eu
    last_ip=0
    last_ping=0

    while true; do
        now=$(date +%s)

        if [ $((now - last_ip)) -ge 600 ] || [ "$last_ip" -eq 0 ]; then
            (curl -s -m 2 --connect-timeout 2 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip=" && echo "1" || echo "0") > /tmp/.cf_ipv4.tmp && mv /tmp/.cf_ipv4.tmp /tmp/.cf_ipv4 || true
            (curl -6 -s -m 2 --connect-timeout 2 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip=" && echo "1" || echo "0") > /tmp/.cf_ipv6.tmp && mv /tmp/.cf_ipv6.tmp /tmp/.cf_ipv6 || true
            last_ip="$now"
        fi

        if [ $((now - last_ping)) -ge 30 ] || [ "$last_ping" -eq 0 ]; then
            [ -n "$CT_NODE" ] && get_ping "$CT_NODE" > /tmp/.cf_ping_ct.tmp && mv /tmp/.cf_ping_ct.tmp /tmp/.cf_ping_ct || rm -f /tmp/.cf_ping_ct
            [ -n "$CU_NODE" ] && get_ping "$CU_NODE" > /tmp/.cf_ping_cu.tmp && mv /tmp/.cf_ping_cu.tmp /tmp/.cf_ping_cu || rm -f /tmp/.cf_ping_cu
            [ -n "$CM_NODE" ] && get_ping "$CM_NODE" > /tmp/.cf_ping_cm.tmp && mv /tmp/.cf_ping_cm.tmp /tmp/.cf_ping_cm || rm -f /tmp/.cf_ping_cm
            [ -n "$BD_NODE" ] && get_ping "$BD_NODE" > /tmp/.cf_ping_bd.tmp && mv /tmp/.cf_ping_bd.tmp /tmp/.cf_ping_bd || rm -f /tmp/.cf_ping_bd
            last_ping="$now"
        fi
        sleep 5
    done
}

# 首次基础数据初始化
NET_STAT=$(get_net_bytes)
RX_PREV=$(echo "$NET_STAT" | awk '{print $1}'); RX_PREV=${RX_PREV:-0}
TX_PREV=$(echo "$NET_STAT" | awk '{print $2}'); TX_PREV=${TX_PREV:-0}

CPU_STAT=$(get_cpu_stat)
PREV_CPU_TOTAL=$(echo "$CPU_STAT" | awk '{print $1}'); PREV_CPU_TOTAL=${PREV_CPU_TOTAL:-0}
PREV_CPU_IDLE=$(echo "$CPU_STAT" | awk '{print $2}'); PREV_CPU_IDLE=${PREV_CPU_IDLE:-0}

PREV_LOOP_TIME=$(date +%s)

echo "[INFO] CF-Server-Monitor Probe Engine Started Successfully."

run_network_worker &

while true; do
    LOOP_START_TIME=$(date +%s)

    MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); MEM_TOTAL_KB=${MEM_TOTAL_KB:-0}
    MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); MEM_AVAIL_KB=${MEM_AVAIL_KB:-0}
    if [ "${MEM_AVAIL_KB}" -eq 0 ]; then
        MEM_FREE_KB=$(awk '/^MemFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); MEM_FREE_KB=${MEM_FREE_KB:-0}
        MEM_BUFF_KB=$(awk '/^Buffers:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); MEM_BUFF_KB=${MEM_BUFF_KB:-0}
        MEM_CACH_KB=$(awk '/^Cached:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); MEM_CACH_KB=${MEM_CACH_KB:-0}
        MEM_AVAIL_KB=$((MEM_FREE_KB + MEM_BUFF_KB + MEM_CACH_KB))
    fi
    RAM_TOTAL=$((MEM_TOTAL_KB / 1024))
    RAM_USED=$(((MEM_TOTAL_KB - MEM_AVAIL_KB) / 1024))
    [ "${RAM_USED}" -lt 0 ] && RAM_USED=0

    if [ "${RAM_TOTAL}" -gt 0 ]; then
        RAM=$(awk -v u="${RAM_USED}" -v t="${RAM_TOTAL}" 'BEGIN {printf "%.2f", (u/t)*100}')
    else
        RAM="0.00"
    fi

    SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); SWAP_TOTAL_KB=${SWAP_TOTAL_KB:-0}
    SWAP_FREE_KB=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0); SWAP_FREE_KB=${SWAP_FREE_KB:-0}
    SWAP_TOTAL=$((SWAP_TOTAL_KB / 1024))
    SWAP_USED=$(((SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024))
    [ "${SWAP_USED}" -lt 0 ] && SWAP_USED=0

    DISK_INFO=$(df -P / 2>/dev/null | tail -n1 || echo "")
    DISK_TOTAL=0; DISK_USED=0; DISK=0
    if [ -n "${DISK_INFO}" ]; then
        DISK_TOTAL=$(echo "${DISK_INFO}" | awk '{print int($2/1024)}')
        DISK_USED=$(echo "${DISK_INFO}" | awk '{print int($3/1024)}')
        DISK=$(echo "${DISK_INFO}" | awk '{print $5}' | tr -d '%')
    fi

    CPU_STAT=$(get_cpu_stat)
    CPU_TOTAL_NOW=$(echo "$CPU_STAT" | awk '{print $1}'); CPU_TOTAL_NOW=${CPU_TOTAL_NOW:-0}
    CPU_IDLE_NOW=$(echo "$CPU_STAT" | awk '{print $2}'); CPU_IDLE_NOW=${CPU_IDLE_NOW:-0}
    DIFF_TOTAL=$((CPU_TOTAL_NOW - PREV_CPU_TOTAL))
    DIFF_IDLE=$((CPU_IDLE_NOW - PREV_CPU_IDLE))

    if [ "${DIFF_TOTAL}" -le 0 ]; then
        CPU="0.00"
    else
        CPU=$(awk -v t="${DIFF_TOTAL}" -v i="${DIFF_IDLE}" 'BEGIN {p=(1-i/t)*100; if(p<0)p=0; if(p>100)p=100; printf "%.2f", p}')
    fi
    PREV_CPU_TOTAL=${CPU_TOTAL_NOW}
    PREV_CPU_IDLE=${CPU_IDLE_NOW}

    if [ -f /etc/os-release ]; then
        OS_RAW=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'")
    else
        OS_RAW=$(uname -srm)
    fi
    OS=${OS_RAW:-"OpenWrt"}
    ARCH=$(uname -m)
    BOOT_TIME=$(awk '$1=="btime"{print $2}' /proc/stat 2>/dev/null)
    if [ -n "${BOOT_TIME:-}" ]; then
        BOOT_TIME=$((BOOT_TIME * 1000))
    else
        uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
        now_sec=$(date +%s)

        if [ "$uptime_sec" -gt 0 ] 2>/dev/null; then
            BOOT_TIME=$(( (now_sec - uptime_sec) * 1000 ))
        else
            BOOT_TIME=0
        fi
    fi
    CPU_INFO=$(grep -m 1 'model name' /proc/cpuinfo 2>/dev/null | awk -F: '{print $2}' | xargs || echo "")
    [ -z "${CPU_INFO}" ] && CPU_INFO=${ARCH}
    CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "1")
    LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "0 0 0")
    PROCESSES=$(ps -e 2>/dev/null | wc -l || echo 0)
    TCP_CONN=$(wc -l < /proc/net/tcp 2>/dev/null || echo 0)
    UDP_CONN=$(wc -l < /proc/net/udp 2>/dev/null || echo 0)

    NET_STAT=$(get_net_bytes)
    RX_NOW=$(echo "$NET_STAT" | awk '{print $1}'); RX_NOW=${RX_NOW:-0}
    TX_NOW=$(echo "$NET_STAT" | awk '{print $2}'); TX_NOW=${TX_NOW:-0}

    MONTHLY_TRAFFIC=$(calc_monthly_traffic "$RX_NOW" "$TX_NOW")
    RX_MONTHLY=$(echo "$MONTHLY_TRAFFIC" | awk '{print $1}')
    TX_MONTHLY=$(echo "$MONTHLY_TRAFFIC" | awk '{print $2}')

    TIME_DELTA=$((LOOP_START_TIME - PREV_LOOP_TIME))
    [ "${TIME_DELTA}" -le 0 ] && TIME_DELTA=${REPORT_INTERVAL}

    RX_DELTA=$((RX_NOW - RX_PREV))
    TX_DELTA=$((TX_NOW - TX_PREV))
    [ "${RX_DELTA}" -lt 0 ] && RX_DELTA=0
    [ "${TX_DELTA}" -lt 0 ] && TX_DELTA=0

    RX_SPEED=$(safe_div "${RX_DELTA}" "${TIME_DELTA}" "0")
    TX_SPEED=$(safe_div "${TX_DELTA}" "${TIME_DELTA}" "0")

    RX_PREV=${RX_NOW}
    TX_PREV=${TX_NOW}
    PREV_LOOP_TIME=${LOOP_START_TIME}

    [ -f /tmp/.cf_ipv4 ] && IPV4=$(cat /tmp/.cf_ipv4) || IPV4="0"
    [ -f /tmp/.cf_ipv6 ] && IPV6=$(cat /tmp/.cf_ipv6) || IPV6="0"
    [ -f /tmp/.cf_ping_ct ] && PING_CT=$(cat /tmp/.cf_ping_ct) || PING_CT=""
    [ -f /tmp/.cf_ping_cu ] && PING_CU=$(cat /tmp/.cf_ping_cu) || PING_CU=""
    [ -f /tmp/.cf_ping_cm ] && PING_CM=$(cat /tmp/.cf_ping_cm) || PING_CM=""
    [ -f /tmp/.cf_ping_bd ] && PING_BD=$(cat /tmp/.cf_ping_bd) || PING_BD=""

    EOS=$(escape_json "${OS}")
    EARCH=$(escape_json "${ARCH}")
    ECPU=$(escape_json "${CPU_INFO}")

    PAYLOAD=$(cat <<EOF
{"id":"$SERVER_ID","secret":"$SECRET","metrics":{"cpu":"$CPU","ram":"$RAM","ram_total":"$RAM_TOTAL","ram_used":"$RAM_USED","swap_total":"$SWAP_TOTAL","swap_used":"$SWAP_USED","disk":"$DISK","disk_total":"$DISK_TOTAL","disk_used":"$DISK_USED","load_avg":"$LOAD_AVG","boot_time":"$BOOT_TIME","net_rx":"$RX_NOW","net_tx":"$TX_NOW","net_rx_monthly":"$RX_MONTHLY","net_tx_monthly":"$TX_MONTHLY","net_in_speed":"$RX_SPEED","net_out_speed":"$TX_SPEED","os":"$EOS","arch":"$EARCH","cpu_info":"$ECPU","cpu_cores":"$CPU_CORES","processes":"$PROCESSES","tcp_conn":"$TCP_CONN","udp_conn":"$UDP_CONN","ip_v4":"$IPV4","ip_v6":"$IPV6","ping_ct":"$PING_CT","ping_cu":"$PING_CU","ping_cm":"$PING_CM","ping_bd":"$PING_BD"}}
EOF
)
    curl -s -o /dev/null -X POST -H "Content-Type: application/json" -d "$PAYLOAD" -m 4 --connect-timeout 2 "$WORKER_URL" 2>/dev/null || true

    LOOP_END_TIME=$(date +%s)
    EXEC_DURATION=$((LOOP_END_TIME - LOOP_START_TIME))
    SLEEP_TIME=$((REPORT_INTERVAL - EXEC_DURATION))
    [ "${SLEEP_TIME}" -le 0 ] && SLEEP_TIME=1
    sleep "${SLEEP_TIME}"
done
PROBE_EOF

    # BusyBox sed 可能不支持 -i，使用临时文件方式
    tmpfile="${SCRIPT_FILE}.tmp"
    esc_ping=$(sed_escape "${ping_type}")
    sed "s@PING_TYPE_PLACEHOLDER@${esc_ping}@g" "${SCRIPT_FILE}" > "$tmpfile" && mv "$tmpfile" "${SCRIPT_FILE}"

    chmod +x "${SCRIPT_FILE}"
    info "探针脚本注入完成: ${SCRIPT_FILE}"
}

# ---------------------------------------------------------------
# 创建 procd 服务脚本 / 手动启停入口
# ---------------------------------------------------------------
create_service() {
    ct_node="${1:-}"
    cu_node="${2:-}"
    cm_node="${3:-}"
    bd_node="${4:-}"

    esc_id=$(printf '%s' "$SERVER_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_sec=$(printf '%s' "$SECRET" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')
    esc_url=$(printf '%s' "$WORKER_URL" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_ping=$(printf '%s' "$PING_TYPE" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_ct=$(printf '%s' "$ct_node" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_cu=$(printf '%s' "$cu_node" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_cm=$(printf '%s' "$cm_node" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_bd=$(printf '%s' "$bd_node" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_reset_day=$(printf '%s' "$RESET_DAY" | sed 's/\\/\\\\/g; s/"/\\"/g')

    exec_line="/bin/sh \"${SCRIPT_FILE}\" \"${esc_id}\" \"${esc_sec}\" \"${esc_url}\" \"${REPORT_INTERVAL}\" \"${esc_ping}\" \"${esc_ct}\" \"${esc_cu}\" \"${esc_cm}\" \"${esc_bd}\" \"${esc_reset_day}\""

    if [ "$INIT_SYSTEM" = "procd" ]; then
        step "构建 procd init 脚本..."
        cat > "${PROCD_FILE}" << EOF
#!/bin/sh /etc/rc.common

# CF-Server-Monitor Probe Agent (OpenWrt / procd)
# 自动生成，请勿直接修改。

START=99
STOP=15

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "${SCRIPT_FILE}" "${esc_id}" "${esc_sec}" "${esc_url}" "${REPORT_INTERVAL}" "${esc_ping}" "${esc_ct}" "${esc_cu}" "${esc_cm}" "${esc_bd}" "${esc_reset_day}"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile "${PID_FILE}"
    procd_close_instance
}

stop_service() {
    rm -f "${PID_FILE}"
}

service_triggers() {
    procd_add_reload_trigger "${SERVICE_NAME}"
}
EOF
        chmod +x "${PROCD_FILE}"
        info "procd 服务脚本生成: ${PROCD_FILE}"
    else
        step "非 procd 环境 — 将使用手动后台进程方式运行..."
        info "启停命令将写入: ${SCRIPT_FILE}.ctl"
    fi

    # 记录用于手动启停的命令（两种模式都用）
    echo "#!/bin/sh
# CF-Server-Monitor 手动启停脚本（OpenWrt 兼容）
# 自动生成，请勿直接修改参数。
START_CMD=\"${exec_line} >> ${LOG_FILE} 2>&1 &\"
PID_FILE='${PID_FILE}'
LOG_FILE='${LOG_FILE}'

case \"\${1:-start}\" in
    start)
        if [ -f \"\$PID_FILE\" ] && kill -0 \"\$(cat \$PID_FILE)\" >/dev/null 2>&1; then
            echo '探针已在运行。'
            exit 0
        fi
        nohup ${exec_line} >> \$LOG_FILE 2>&1 &
        echo \$! > \$PID_FILE
        disown >/dev/null 2>&1 || true
        echo '探针已启动（PID: '\"\$(cat \$PID_FILE)\"'）'
        ;;
    stop)
        if [ -f \"\$PID_FILE\" ]; then
            PID=\$(cat \$PID_FILE)
            kill -TERM \$PID >/dev/null 2>&1 || true
            sleep 1
            kill -9 \$PID >/dev/null 2>&1 || true
            rm -f \$PID_FILE
            echo '探针已停止。'
        else
            pkill -9 -f '${SERVICE_NAME}.sh' >/dev/null 2>&1 || true
            echo '未找到 PID 文件，已尝试按进程名清理。'
        fi
        ;;
    status)
        if [ -f \"\$PID_FILE\" ] && kill -0 \"\$(cat \$PID_FILE)\" >/dev/null 2>&1; then
            echo '运行中（PID: '\"\$(cat \$PID_FILE)\"'）'
        else
            echo '未运行'
        fi
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    log)
        tail -f \$LOG_FILE
        ;;
    *)
        echo '用法: \$0 {start|stop|status|restart|log}'
        exit 1
        ;;
esac
" > "${SCRIPT_FILE}.ctl"
    chmod +x "${SCRIPT_FILE}.ctl"
}

# ---------------------------------------------------------------
# 启动服务
# ---------------------------------------------------------------
start_service() {
    step "加载进程树并激活监控探针..."

    if [ "$INIT_SYSTEM" = "procd" ]; then
        "$PROCD_FILE" enable >/dev/null 2>&1 || true
        "$PROCD_FILE" restart || error "procd 服务启动失败，请检查日志: tail -n 30 ${LOG_FILE}"
    else
        sh "${SCRIPT_FILE}.ctl" start || error "后台进程启动失败，请检查日志: tail -n 30 ${LOG_FILE}"
    fi

    sleep 2

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
        info "探针监控引擎已进入平稳运行状态。"
    else
        warn "探针服务可能未启动成功。请排查: tail -n 30 ${LOG_FILE}"
        warn "在 OpenWrt 上可执行: ${PROCD_FILE} status"
    fi
}

# ---------------------------------------------------------------
# 安装主流程
# ---------------------------------------------------------------
install_probe() {
    SERVER_ID=""
    SECRET=""
    WORKER_URL=""
    REPORT_INTERVAL=""
    PING_TYPE=""
    CT_NODE=""
    CU_NODE=""
    CM_NODE=""
    BD_NODE=""
    RESET_DAY=""
    RX_CORRECTION=""
    TX_CORRECTION=""

    for arg in "$@"; do
        case "$arg" in
            -id=*) SERVER_ID="${arg#-id=}" ;;
            -secret=*) SECRET="${arg#-secret=}" ;;
            -url=*) WORKER_URL="${arg#-url=}" ;;
            -interval=*) REPORT_INTERVAL="${arg#-interval=}" ;;
            -ping=*) PING_TYPE="${arg#-ping=}" ;;
            -ct=*) CT_NODE="${arg#-ct=}" ;;
            -cu=*) CU_NODE="${arg#-cu=}" ;;
            -cm=*) CM_NODE="${arg#-cm=}" ;;
            -bd=*) BD_NODE="${arg#-bd=}" ;;
            -reset_day=*) RESET_DAY="${arg#-reset_day=}" ;;
            -rx_correction=*) RX_CORRECTION="${arg#-rx_correction=}" ;;
            -tx_correction=*) TX_CORRECTION="${arg#-tx_correction=}" ;;
        esac
    done

    if [ -z "$SERVER_ID" ] || [ -z "$SECRET" ] || [ -z "$WORKER_URL" ]; then
        printf '%b错误: 运行所需的入参不完整。%b\n\n' "${RED}" "${NC}"
        echo "用法:"
        echo "  sh $0 install -id=SERVER_ID -secret=SECRET -url=WORKER_URL [选项]"
        echo ""
        echo "必需参数:"
        echo "  -id=xxx        服务器ID"
        echo "  -secret=xxx    密钥"
        echo "  -url=xxx       上报地址"
        echo ""
        echo "可选参数:"
        echo "  -interval=N    上报间隔(秒)，默认60"
        echo "  -ping=TYPE     探测类型: http | tcp，默认http"
        echo "  -ct=HOST       自定义CT测试节点"
        echo "  -cu=HOST       自定义CU测试节点"
        echo "  -cm=HOST       自定义CM测试节点"
        echo "  -bd=HOST       自定义BD测试节点"
        echo "  -reset_day=N   流量重置日(1-31)，默认1"
        echo "  -rx_correction=N  下行流量校正(GB)，直接修改当月下行数据"
        echo "  -tx_correction=N  上行流量校正(GB)，直接修改当月上行数据"
        echo ""
        echo "示例:"
        echo "  sh $0 install -id=server123 -secret=abc123 -url=https://worker.example.com"
        echo "  sh $0 install -id=server123 -secret=abc123 -url=https://worker.example.com -interval=30 -ping=tcp"
        echo "  sh $0 install -id=server123 -secret=abc123 -url=https://worker.example.com -reset_day=15"
        echo "  sh $0 install -id=server123 -secret=abc123 -url=https://worker.example.com -rx_correction=10 -tx_correction=5"
        exit 1
    fi

    REPORT_INTERVAL=${REPORT_INTERVAL:-60}
    PING_TYPE=${PING_TYPE:-http}
    RESET_DAY=${RESET_DAY:-1}

    print_banner
    check_root
    detect_os
    install_deps
    stop_old_service
    if [ -n "${RX_CORRECTION}" ] || [ -n "${TX_CORRECTION}" ]; then
        step "应用流量校正..."
        traffic_data_dir="/var/lib/cf-probe"
        traffic_data_file="${traffic_data_dir}/traffic.dat"

        if [ -f "${traffic_data_file}" ]; then
            current_rx_period=0; current_tx_period=0
            while IFS='=' read -r key value; do
                case "$key" in
                    RX_PERIOD) current_rx_period="${value}" ;;
                    TX_PERIOD) current_tx_period="${value}" ;;
                esac
            done < "${traffic_data_file}"

            if [ -n "${RX_CORRECTION}" ] && echo "${RX_CORRECTION}" | awk '{exit($1 == 0)}' 2>/dev/null; then
                rx_correction_bytes=$(echo "${RX_CORRECTION}" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}')
                current_rx_period="${rx_correction_bytes}"
                info "下行流量校正: ${RX_CORRECTION}GB"
            fi

            if [ -n "${TX_CORRECTION}" ] && echo "${TX_CORRECTION}" | awk '{exit($1 == 0)}' 2>/dev/null; then
                tx_correction_bytes=$(echo "${TX_CORRECTION}" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}')
                current_tx_period="${tx_correction_bytes}"
                info "上行流量校正: ${TX_CORRECTION}GB"
            fi

            # BusyBox sed 兼容：使用临时文件
            tmp_traffic="${traffic_data_file}.sed.tmp"
            sed "s/RX_PERIOD=.*/RX_PERIOD=${current_rx_period}/" "${traffic_data_file}" > "$tmp_traffic" && mv "$tmp_traffic" "${traffic_data_file}"
            sed "s/TX_PERIOD=.*/TX_PERIOD=${current_tx_period}/" "${traffic_data_file}" > "$tmp_traffic" && mv "$tmp_traffic" "${traffic_data_file}"
            info "流量校正完成"
        else
            if [ -n "${RX_CORRECTION}" ] || [ -n "${TX_CORRECTION}" ]; then
                mkdir -p "${traffic_data_dir}" 2>/dev/null || true
                now_ts=$(date '+%s')
                rx_correction_bytes=0; tx_correction_bytes=0
                current_rx=$(awk 'NR>2 && $1~/^(eth|en|wl)[a-z0-9]*:/{rx+=$2}END{printf "%.0f", rx}' /proc/net/dev 2>/dev/null || echo 0)
                current_tx=$(awk 'NR>2 && $1~/^(eth|en|wl)[a-z0-9]*:/{tx+=$10}END{printf "%.0f", tx}' /proc/net/dev 2>/dev/null || echo 0)
                [ -n "${RX_CORRECTION}" ] && echo "${RX_CORRECTION}" | awk '{exit($1 == 0)}' 2>/dev/null && rx_correction_bytes=$(echo "${RX_CORRECTION}" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}')
                [ -n "${TX_CORRECTION}" ] && echo "${TX_CORRECTION}" | awk '{exit($1 == 0)}' 2>/dev/null && tx_correction_bytes=$(echo "${TX_CORRECTION}" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}')
                echo "${RX_CORRECTION}" | awk '{exit($1 == 0)}' 2>/dev/null && info "下行流量校正: ${RX_CORRECTION}GB (新建)"
                echo "${TX_CORRECTION}" | awk '{exit($1 == 0)}' 2>/dev/null && info "上行流量校正: ${TX_CORRECTION}GB (新建)"
                cat > "${traffic_data_file}" << EOF
RX_PREV=${current_rx}
TX_PREV=${current_tx}
RX_PERIOD=${rx_correction_bytes}
TX_PERIOD=${tx_correction_bytes}
LAST_CHECK=${now_ts}
PERIOD_START=0
EOF
                info "流量数据文件创建完成"
            fi
        fi
    fi

    create_script "$REPORT_INTERVAL" "$PING_TYPE" "$CT_NODE" "$CU_NODE" "$CM_NODE" "$BD_NODE" "$RESET_DAY"
    create_service "$CT_NODE" "$CU_NODE" "$CM_NODE" "$BD_NODE"
    start_service

    printf '\n%b=============================================%b\n' "${GREEN}" "${NC}"
    printf  '         CF-Server-Monitor 安装成功\n'
    printf  '%b=============================================%b\n' "${GREEN}" "${NC}"
    printf  '  服务状态 : %bActive (Running)%b\n' "${GREEN}" "${NC}"
    printf  '  配置参数 :\n'
    printf  '    ● Server ID   : %s\n' "${SERVER_ID}"
    printf  '    ● Secret      : %s\n' "${SECRET}"
    printf  '    ● Worker URL  : %s\n' "${WORKER_URL}"
    printf  '    ● 上报间隔    : %s秒\n' "${REPORT_INTERVAL}"
    printf  '    ● 探测类型    : %s\n' "${PING_TYPE}"
    [ -n "${RX_CORRECTION}" ] && printf  '    ● 下行校正    : %sGB\n' "${RX_CORRECTION}"
    [ -n "${TX_CORRECTION}" ] && printf  '    ● 上行校正    : %sGB\n' "${TX_CORRECTION}"
    printf  '    ● 流量重置日  : %s号\n' "${RESET_DAY}"
    [ -n "${CT_NODE}" ] && printf  '    ● CT节点      : %s\n' "${CT_NODE}"
    [ -n "${CU_NODE}" ] && printf  '    ● CU节点      : %s\n' "${CU_NODE}"
    [ -n "${CM_NODE}" ] && printf  '    ● CM节点      : %s\n' "${CM_NODE}"
    [ -n "${BD_NODE}" ] && printf  '    ● BD节点      : %s\n' "${BD_NODE}"
    printf  '  运行模式 : '
    case "$INIT_SYSTEM" in
        procd) echo "procd 系统服务 (${PROCD_FILE})" ;;
        *)     echo "手动后台进程 (PID: $(cat "$PID_FILE"))" ;;
    esac
    printf  '  管理指令 :\n'
    if [ "$INIT_SYSTEM" = "procd" ]; then
        printf  '    ● 查看日志     : tail -f %s\n' "${LOG_FILE}"
        printf  '    ● 查看状态     : %s status\n' "${PROCD_FILE}"
        printf  '    ● 启动/停止    : %s {start|stop|restart}\n' "${PROCD_FILE}"
    else
        printf  '    ● 查看日志     : tail -f %s\n' "${LOG_FILE}"
        printf  '    ● 启动/停止    : sh %s {start|stop|restart|status|log}\n' "${SCRIPT_FILE}.ctl"
    fi
    printf  '    ● 彻底卸载     : sh %s uninstall\n' "$0"
    printf  '%b=============================================%b\n\n' "${GREEN}" "${NC}"
}

# ---------------------------------------------------------------
# 卸载主流程
# ---------------------------------------------------------------
update_probe() {
    update_url="${1:-}"
    
    print_banner
    printf '%b[!] 开始升级 CF-Server-Monitor...%b\n\n' "${YELLOW}" "${NC}"
    
    if [ -z "$update_url" ]; then
        error "升级需要指定更新源URL，请通过管道传入: curl -sL <url> | sh -s update"
    fi
    
    check_root
    detect_os
    
    if [ ! -f "${SCRIPT_FILE}" ]; then
        error "未找到现有探针: ${SCRIPT_FILE}，请先执行安装。"
    fi
    
    info "检测到现有探针，将直接更新脚本..."
    
    step "正在下载最新安装脚本..."
    temp_script="/tmp/cf-probe-install-$$.sh"
    if ! curl -sL "$update_url" -o "$temp_script" 2>/dev/null; then
        rm -f "$temp_script"
        error "下载失败，请检查URL是否可访问: $update_url"
    fi
    
    if ! grep -q "install_probe" "$temp_script" 2>/dev/null; then
        rm -f "$temp_script"
        error "下载的脚本无效。"
    fi
    
    step "提取新版本探针脚本..."
    local start_line
    start_line=$(grep -n "<< 'PROBE_EOF'" "$temp_script" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -z "$start_line" ]; then
        rm -f "$temp_script"
        error "无法找到探针内容起始标记 (heredoc start)。"
    fi
    
    new_probe_content=$(tail -n +$((start_line + 1)) "$temp_script" 2>/dev/null | sed -n '/^PROBE_EOF$/q;p' || true)
    
    if [ -z "$new_probe_content" ]; then
        rm -f "$temp_script"
        error "无法提取探针内容，请确认下载的脚本包含有效的探针代码。"
    fi
    
    step "停止服务..."
    if [ "$INIT_SYSTEM" = "procd" ] && [ -f "$PROCD_FILE" ]; then
        "$PROCD_FILE" stop >/dev/null 2>&1 || true
    elif [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
            kill -TERM "$old_pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "$old_pid" >/dev/null 2>&1 || true
        fi
    fi
    
    step "更新探针脚本..."
    echo "$new_probe_content" > "${SCRIPT_FILE}"
    chmod +x "${SCRIPT_FILE}"
    
    step "重启服务..."
    if [ "$INIT_SYSTEM" = "procd" ]; then
        "$PROCD_FILE" enable >/dev/null 2>&1 || true
        "$PROCD_FILE" restart || error "服务启动失败"
    else
        sh "${SCRIPT_FILE}.ctl" start || error "服务启动失败"
    fi
    
    rm -f "$temp_script"
    
    sleep 2
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
        # 从服务文件提取配置参数（使用 awk 兼容 sh）
        local exec_line s_id s_sec s_url s_interval s_ping s_ct s_cu s_cm s_bd s_reset
        if [ "$INIT_SYSTEM" = "procd" ] && [ -f "$PROCD_FILE" ]; then
            exec_line=$(grep "procd_set_param command" "$PROCD_FILE" 2>/dev/null | head -1 || echo "")
            # procd 格式: procd_set_param command /bin/sh /usr/local/bin/cf-probe.sh "id" "sec" ...
            s_id=$(echo "$exec_line" | awk '{print $5}' | tr -d '"' || echo "")
            s_sec=$(echo "$exec_line" | awk '{print $6}' | tr -d '"' || echo "")
            s_url=$(echo "$exec_line" | awk '{print $7}' | tr -d '"' || echo "")
            s_interval=$(echo "$exec_line" | awk '{print $8}' | tr -d '"' || echo "60")
            s_ping=$(echo "$exec_line" | awk '{print $9}' | tr -d '"' || echo "http")
            s_ct=$(echo "$exec_line" | awk '{print $10}' | tr -d '"' || echo "")
            s_cu=$(echo "$exec_line" | awk '{print $11}' | tr -d '"' || echo "")
            s_cm=$(echo "$exec_line" | awk '{print $12}' | tr -d '"' || echo "")
            s_bd=$(echo "$exec_line" | awk '{print $13}' | tr -d '"' || echo "")
            s_reset=$(echo "$exec_line" | awk '{print $14}' | tr -d '"' || echo "1")
        else
            exec_line=$(grep "^START_CMD=" "${SCRIPT_FILE}.ctl" 2>/dev/null | head -1 || echo "")
            # START_CMD 格式: START_CMD=/usr/local/bin/cf-probe.sh "id" "sec" ...
            s_id=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $2}' | tr -d '"' || echo "")
            s_sec=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $3}' | tr -d '"' || echo "")
            s_url=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $4}' | tr -d '"' || echo "")
            s_interval=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $5}' | tr -d '"' || echo "60")
            s_ping=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $6}' | tr -d '"' || echo "http")
            s_ct=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $7}' | tr -d '"' || echo "")
            s_cu=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $8}' | tr -d '"' || echo "")
            s_cm=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $9}' | tr -d '"' || echo "")
            s_bd=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $10}' | tr -d '"' || echo "")
            s_reset=$(echo "$exec_line" | sed 's/^START_CMD=//' | awk '{print $11}' | tr -d '"' || echo "1")
        fi
        
        printf '\n%b=============================================%b\n' "${GREEN}" "${NC}"
        printf  '         CF-Server-Monitor 升级成功\n'
        printf  '%b=============================================%b\n' "${GREEN}" "${NC}"
        printf  '  服务状态 : %bActive (Running)%b\n' "${GREEN}" "${NC}"
        printf  '  配置参数 :\n'
        printf  '    ● Server ID   : %s\n' "${s_id}"
        printf  '    ● Secret      : %s\n' "${s_sec}"
        printf  '    ● Worker URL  : %s\n' "${s_url}"
        printf  '    ● 上报间隔    : %s秒\n' "${s_interval}"
        printf  '    ● 探测类型    : %s\n' "${s_ping}"
        printf  '    ● 流量重置日  : %s号\n' "${s_reset}"
        [ -n "${s_ct}" ] && printf  '    ● CT节点      : %s\n' "${s_ct}"
        [ -n "${s_cu}" ] && printf  '    ● CU节点      : %s\n' "${s_cu}"
        [ -n "${s_cm}" ] && printf  '    ● CM节点      : %s\n' "${s_cm}"
        [ -n "${s_bd}" ] && printf  '    ● BD节点      : %s\n' "${s_bd}"
        printf  '  管理指令 :\n'
        if [ "$INIT_SYSTEM" = "procd" ]; then
            printf  '    ● 查看日志     : tail -f %s\n' "${LOG_FILE}"
            printf  '    ● 查看状态    : %s status\n' "${PROCD_FILE}"
            printf  '    ● 启动/停止  : %s {start|stop|restart}\n' "${PROCD_FILE}"
        else
            printf  '    ● 查看日志     : tail -f %s\n' "${LOG_FILE}"
            printf  '    ● 启动/停止  : sh %s {start|stop|restart|status|log}\n' "${SCRIPT_FILE}.ctl"
        fi
        printf  '%b=============================================%b\n\n' "${GREEN}" "${NC}"
    else
        warn "服务可能未启动成功，请检查日志。"
    fi
}

uninstall_probe() {
    print_banner
    printf '%b[!] 开始执行无残留深度卸载清理方案...%b\n\n' "${YELLOW}" "${NC}"
    check_root
    detect_os

    step "停用并撤销系统守护进程..."
    stop_old_service

    step "清理服务脚本文件..."
    rm -f "${PROCD_FILE}"

    step "销毁探针物理可执行代码文件..."
    rm -f "${SCRIPT_FILE}"
    rm -f "${SCRIPT_FILE}.ctl"

    step "抹除共享内存高速缓存区..."
    rm -f /tmp/.cf_ipv4 /tmp/.cf_ipv6 /tmp/.cf_ping_* 2>/dev/null || true

    step "抹除流量追踪数据..."
    rm -rf /var/lib/${SERVICE_NAME}

    step "清理日志与 PID 文件..."
    rm -f "${PID_FILE}" "${LOG_FILE}" 2>/dev/null || true

    printf '\n%b╔══════════════════════════════════════════╗%b\n' "${GREEN}" "${NC}"
    printf  '║     ✓ 卸载完毕！系统环境无任何残留。     ║\n'
    printf  '%b╚══════════════════════════════════════════╝%b\n\n' "${GREEN}" "${NC}"
}

# ---------------------------------------------------------------
# 入口
# ---------------------------------------------------------------
case "${1:-install}" in
    install)
        shift 1 2>/dev/null || true
        install_probe "$@"
        ;;
    uninstall|remove|delete|purge)
        uninstall_probe
        ;;
    update|upgrade)
        shift 1 2>/dev/null || true
        update_probe "$@"
        ;;
    *)
        echo "未知指令. 可选命令: install | uninstall | update"
        exit 1
        ;;
esac
