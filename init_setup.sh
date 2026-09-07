#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 初始化脚本
# 支持推荐、精简、完整和自定义模式；无人值守运行必须显式使用 --yes。

SCRIPT_VERSION="3.1.0"
SCRIPT_AUTHOR="P0me1oo"
LOGFILE="${LOGFILE:-/var/log/debian_init_setup.log}"
LOCKFILE="${LOCKFILE:-/run/debian-init-setup.lock}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/debian-init-setup}"
BACKUP_ID="$(date +%F-%H%M%S)-$$"
BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_ID}"
SSH_PORT="${SSH_PORT:-10721}"
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_HARDENING_FILE="${SSH_DROPIN_DIR}/000-init-setup-hardening.conf"
JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_LIMIT_FILE="${JOURNALD_DROPIN_DIR}/99-init-setup-limits.conf"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAeb9XSLy+uB8WrKCBopAfKSuBejJnvMJv+lygUXKXLB mjj}"
TARGET_TIMEZONE="${TARGET_TIMEZONE:-Asia/Shanghai}"
SCRIPT_START_TS="$(date +%s)"
LAST_ERR_LINE=""
LAST_ERR_COMMAND=""
SSH_READY=0
SSH_SERVICE_RELOADED=0
IPV6_REBOOT_REQUIRED=0
IPV6_PERSISTENCE_READY=0
INTERACTIVE_MODE="${INTERACTIVE_MODE:-auto}"
ORIGINAL_STDIN_IS_TTY=0
ORIGINAL_STDOUT_IS_TTY=0
[ -t 0 ] && ORIGINAL_STDIN_IS_TTY=1
[ -t 1 ] && ORIGINAL_STDOUT_IS_TTY=1

# 先保存显式设置的环境变量，再依次应用模式默认值、环境变量和命令行参数。
declare -a MODULE_TOGGLE_NAMES=(
  ENABLE_SYSTEM_UPDATE ENABLE_COMMON_TOOLS ENABLE_NEXTTRACE_MTR ENABLE_DISABLE_IPV6
  ENABLE_BBR ENABLE_SSH_BASELINE ENABLE_UFW ENABLE_FAIL2BAN ENABLE_JOURNAL_LIMIT
  ENABLE_TIMEZONE ENABLE_DOCKER
)
declare -A ENV_MODULE_OVERRIDES=()
for module_var in "${MODULE_TOGGLE_NAMES[@]}"; do
  if [[ -v "$module_var" ]] && [ -n "${!module_var}" ]; then
    ENV_MODULE_OVERRIDES["$module_var"]="${!module_var}"
  fi
done
unset module_var

ENABLE_SYSTEM_UPDATE="${ENABLE_SYSTEM_UPDATE:-yes}"
ENABLE_COMMON_TOOLS="${ENABLE_COMMON_TOOLS:-yes}"
ENABLE_DISABLE_IPV6="${ENABLE_DISABLE_IPV6:-yes}"
ENABLE_BBR="${ENABLE_BBR:-yes}"
ENABLE_SSH_BASELINE="${ENABLE_SSH_BASELINE:-yes}"
ENABLE_UFW="${ENABLE_UFW:-yes}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-yes}"
ENABLE_JOURNAL_LIMIT="${ENABLE_JOURNAL_LIMIT:-yes}"
ENABLE_TIMEZONE="${ENABLE_TIMEZONE:-yes}"
ENABLE_DOCKER="${ENABLE_DOCKER:-yes}"
ENABLE_NEXTTRACE_MTR="${ENABLE_NEXTTRACE_MTR:-yes}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-50M}"
MODE="${MODE:-recommended}"
MODE_EXPLICIT=0
YES_EXPLICIT=0
REPLACE_EXISTING_RUNTIME=0
CHECK_ONLY=0
DRY_RUN=0
STATUS_ONLY=0
RESTORE_ONLY=0
RESTORE_IPV6_ONLY=0
LOCK_FD=""

declare -a SOFT_ERRORS=()
declare -a SKIPPED_STEPS=()
declare -a UFW_ALLOWED_SSH_PORTS=()
declare -a SSH_TRANSACTION_FILES=()
declare -a CLI_TOGGLE_VALUES=()
declare -a CLI_TOGGLE_LISTS=()
declare -A BACKED_UP_FILES=()

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_err() { echo -e "${RED}[ERROR]${NC} $1"; }

print_section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

usage() {
  cat <<'USAGE'
用法:
  bash init_setup.sh [选项]

终端中直接运行会先选择运行模式；默认是推荐模式。
非交互环境必须显式使用 --yes，避免把脚本通过管道执行时误改系统。
自定义交互默认开启各模块：[Y/n] 回车开启，输入 n 关闭。

模块名:
  update, tools, nexttrace-mtr, bbr, ssh, ufw, fail2ban, journald, timezone, ipv6, docker, all

选项:
  -y, --yes, --non-interactive     不显示交互菜单；非终端执行时必须提供
      --interactive                强制显示交互菜单
      --mode MODE                  模式：recommended、minimal、full、custom
      --disable a,b,c              关闭模块，例如 --disable docker,ipv6
      --enable a,b,c               开启模块
      --ssh-port PORT              SSH 端口，默认 10721
      --ssh-key "KEY"              root SSH 公钥
      --timezone TZ                时区，默认 Asia/Shanghai
      --journal-max-use SIZE        systemd journal 最大占用，默认 50M；支持 100M、1G 等格式
      --logfile PATH               日志路径，默认 /var/log/debian_init_setup.log
      --check                      只检查运行环境，不修改系统
      --dry-run                    显示将执行的模块，不修改系统
      --status                     输出当前状态，不修改系统
      --restore                    恢复最近一次脚本备份的配置
      --restore-ipv6                只恢复 IPv6，不执行初始化模块
      --replace-existing-runtime  允许 Docker 模块替换已有容器运行时
      --no-journal-limit           不配置 systemd journal 大小限制
      --no-nexttrace-mtr           不安装 NextTrace 和 mtr
  -h, --help                       显示帮助
  -V, --version                    显示版本

示例:
  bash init_setup.sh
  bash init_setup.sh --mode recommended
  bash init_setup.sh --yes --mode minimal
  bash init_setup.sh --yes --mode full
  bash init_setup.sh --yes --mode recommended --disable ipv6,docker
  bash init_setup.sh --check
  bash init_setup.sh --yes --restore-ipv6
USAGE
}

print_version() {
  printf 'init_setup.sh %s，作者 %s\n' "$SCRIPT_VERSION" "$SCRIPT_AUTHOR"
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_yes() {
  case "${1,,}" in
    yes|y|true|1|on|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_bool_value() {
  case "${1,,}" in
    yes|y|true|1|on|enable|enabled) printf 'yes' ;;
    no|n|false|0|off|disable|disabled) printf 'no' ;;
    *) return 1 ;;
  esac
}

normalize_bool_var() {
  local var_name="$1" value
  if ! value="$(normalize_bool_value "${!var_name}")"; then
    print_err "${var_name} 的值无效: ${!var_name}。请使用 yes/no、true/false、1/0。"
    exit 2
  fi
  printf -v "$var_name" '%s' "$value"
}

normalize_all_booleans() {
  local v
  for v in "${MODULE_TOGGLE_NAMES[@]}"; do
    normalize_bool_var "$v"
  done
}

set_mode() {
  local value="${1,,}"
  case "$value" in
    recommended|recommend|rec) MODE="recommended" ;;
    minimal|mini) MODE="minimal" ;;
    full|complete) MODE="full" ;;
    custom|manual) MODE="custom" ;;
    *) print_err "未知模式: $1。可用模式：recommended、minimal、full、custom。"; exit 2 ;;
  esac
  MODE_EXPLICIT=1
}

apply_mode_defaults() {
  case "$MODE" in
    recommended)
      ENABLE_SYSTEM_UPDATE=yes
      ENABLE_COMMON_TOOLS=yes
      ENABLE_NEXTTRACE_MTR=yes
      ENABLE_BBR=yes
      ENABLE_SSH_BASELINE=yes
      ENABLE_UFW=yes
      ENABLE_FAIL2BAN=yes
      ENABLE_JOURNAL_LIMIT=yes
      ENABLE_TIMEZONE=yes
      ENABLE_DISABLE_IPV6=no
      ENABLE_DOCKER=no
      ;;
    minimal)
      ENABLE_SYSTEM_UPDATE=yes
      ENABLE_COMMON_TOOLS=no
      ENABLE_NEXTTRACE_MTR=no
      ENABLE_BBR=yes
      ENABLE_SSH_BASELINE=yes
      ENABLE_UFW=yes
      ENABLE_FAIL2BAN=no
      ENABLE_JOURNAL_LIMIT=yes
      ENABLE_TIMEZONE=yes
      ENABLE_DISABLE_IPV6=no
      ENABLE_DOCKER=no
      ;;
    full)
      ENABLE_SYSTEM_UPDATE=yes
      ENABLE_COMMON_TOOLS=yes
      ENABLE_NEXTTRACE_MTR=yes
      ENABLE_BBR=yes
      ENABLE_SSH_BASELINE=yes
      ENABLE_UFW=yes
      ENABLE_FAIL2BAN=yes
      ENABLE_JOURNAL_LIMIT=yes
      ENABLE_TIMEZONE=yes
      ENABLE_DISABLE_IPV6=yes
      ENABLE_DOCKER=yes
      ;;
    custom)
      ENABLE_SYSTEM_UPDATE=no
      ENABLE_COMMON_TOOLS=no
      ENABLE_NEXTTRACE_MTR=no
      ENABLE_BBR=no
      ENABLE_SSH_BASELINE=no
      ENABLE_UFW=no
      ENABLE_FAIL2BAN=no
      ENABLE_JOURNAL_LIMIT=no
      ENABLE_TIMEZONE=no
      ENABLE_DISABLE_IPV6=no
      ENABLE_DOCKER=no
      if should_prompt; then
        set_toggle_by_name yes all
      fi
      ;;
    *) print_err "MODE 无效: $MODE。请使用 recommended/minimal/full/custom。"; exit 2 ;;
  esac
}

set_toggle_by_name() {
  local value="$1" name="${2,,}"
  name="${name//_/-}"
  case "$name" in
    all)
      ENABLE_SYSTEM_UPDATE="$value"; ENABLE_COMMON_TOOLS="$value"; ENABLE_NEXTTRACE_MTR="$value"; ENABLE_DISABLE_IPV6="$value"; ENABLE_BBR="$value"; ENABLE_SSH_BASELINE="$value"; ENABLE_UFW="$value"; ENABLE_FAIL2BAN="$value"; ENABLE_JOURNAL_LIMIT="$value"; ENABLE_TIMEZONE="$value"; ENABLE_DOCKER="$value" ;;
    update|upgrade|system-update) ENABLE_SYSTEM_UPDATE="$value" ;;
    tools|common-tools) ENABLE_COMMON_TOOLS="$value" ;;
    nexttrace-mtr|nexttrace|mtr|trace-tools|net-trace|network-trace) ENABLE_NEXTTRACE_MTR="$value" ;;
    ipv6|disable-ipv6) ENABLE_DISABLE_IPV6="$value" ;;
    bbr|bbr-fq) ENABLE_BBR="$value" ;;
    ssh|sshd|ssh-baseline) ENABLE_SSH_BASELINE="$value" ;;
    ufw|firewall) ENABLE_UFW="$value" ;;
    fail2ban|f2b) ENABLE_FAIL2BAN="$value" ;;
    journald|journal|journal-limit|log-limit|systemd-journal) ENABLE_JOURNAL_LIMIT="$value" ;;
    timezone|tz|time-zone) ENABLE_TIMEZONE="$value" ;;
    docker) ENABLE_DOCKER="$value" ;;
    "") ;;
    *) print_err "未知模块名: $2。使用 --help 查看可用模块。"; exit 2 ;;
  esac
}

set_toggles_csv() {
  local value="$1" csv="$2" item
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    set_toggle_by_name "$value" "$(trim "$item")"
  done
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      -y|--yes|--non-interactive) INTERACTIVE_MODE="no"; YES_EXPLICIT=1; shift ;;
      --interactive) INTERACTIVE_MODE="yes"; shift ;;
      --mode) [ "$#" -ge 2 ] || { print_err "--mode 需要模式名"; exit 2; }; set_mode "$2"; shift 2 ;;
      --disable) [ "$#" -ge 2 ] || { print_err "--disable 需要模块列表"; exit 2; }; CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=("$2"); shift 2 ;;
      --enable) [ "$#" -ge 2 ] || { print_err "--enable 需要模块列表"; exit 2; }; CLI_TOGGLE_VALUES+=(yes); CLI_TOGGLE_LISTS+=("$2"); shift 2 ;;
      --ssh-port) [ "$#" -ge 2 ] || { print_err "--ssh-port 需要端口号"; exit 2; }; SSH_PORT="$2"; shift 2 ;;
      --ssh-key) [ "$#" -ge 2 ] || { print_err "--ssh-key 需要公钥"; exit 2; }; SSH_PUBLIC_KEY="$2"; shift 2 ;;
      --timezone) [ "$#" -ge 2 ] || { print_err "--timezone 需要时区"; exit 2; }; TARGET_TIMEZONE="$2"; shift 2 ;;
      --journal-max-use) [ "$#" -ge 2 ] || { print_err "--journal-max-use 需要大小，例如 50M 或 1G"; exit 2; }; JOURNAL_MAX_USE="$2"; shift 2 ;;
      --logfile) [ "$#" -ge 2 ] || { print_err "--logfile 需要路径"; exit 2; }; LOGFILE="$2"; shift 2 ;;
      --check) CHECK_ONLY=1; INTERACTIVE_MODE="no"; shift ;;
      --dry-run) DRY_RUN=1; INTERACTIVE_MODE="no"; shift ;;
      --status) STATUS_ONLY=1; INTERACTIVE_MODE="no"; shift ;;
      --restore) RESTORE_ONLY=1; INTERACTIVE_MODE="no"; shift ;;
      --restore-ipv6) RESTORE_IPV6_ONLY=1; INTERACTIVE_MODE="no"; shift ;;
      --replace-existing-runtime) REPLACE_EXISTING_RUNTIME=1; shift ;;
      --no-update|--no-upgrade) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(update); shift ;;
      --no-tools) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(tools); shift ;;
      --no-nexttrace-mtr|--no-trace-tools|--no-net-trace) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(nexttrace-mtr); shift ;;
      --no-ipv6|--no-disable-ipv6) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(ipv6); shift ;;
      --no-bbr) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(bbr); shift ;;
      --no-ssh) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(ssh); shift ;;
      --no-ufw|--no-firewall) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(ufw); shift ;;
      --no-fail2ban) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(fail2ban); shift ;;
      --no-journal-limit|--no-journald|--no-systemd-journal) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(journald); shift ;;
      --no-timezone) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(timezone); shift ;;
      --no-docker) CLI_TOGGLE_VALUES+=(no); CLI_TOGGLE_LISTS+=(docker); shift ;;
      *) print_err "未知参数: $1。使用 --help 查看用法。"; exit 2 ;;
    esac
  done
}

validate_config() {
  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    print_err "SSH_PORT 无效: $SSH_PORT。必须是 1-65535。"
    exit 2
  fi
  if ! [[ "$JOURNAL_MAX_USE" =~ ^[1-9][0-9]*[KkMmGgTtPpEe]?$ ]]; then
    print_err "JOURNAL_MAX_USE 无效: $JOURNAL_MAX_USE。请使用 50M、1G 或纯字节数这类格式。"
    exit 2
  fi
}

apply_cli_overrides() {
  local index
  for index in "${!CLI_TOGGLE_VALUES[@]}"; do
    set_toggles_csv "${CLI_TOGGLE_VALUES[$index]}" "${CLI_TOGGLE_LISTS[$index]}"
  done
}

apply_environment_overrides() {
  local var_name
  for var_name in "${!ENV_MODULE_OVERRIDES[@]}"; do
    printf -v "$var_name" '%s' "${ENV_MODULE_OVERRIDES[$var_name]}"
  done
}

require_explicit_non_interactive() {
  if { [ "$ORIGINAL_STDIN_IS_TTY" -eq 0 ] || [ "$ORIGINAL_STDOUT_IS_TTY" -eq 0 ]; } && [ "$YES_EXPLICIT" -ne 1 ] &&
     [ "$CHECK_ONLY" -ne 1 ] && [ "$DRY_RUN" -ne 1 ] && [ "$STATUS_ONLY" -ne 1 ]; then
    print_err "检测到管道或其他非交互执行，但没有显式提供 --yes。"
    print_err "需要直接执行时请使用：bash -s -- --yes --mode recommended"
    print_err "需要交互菜单时请先下载脚本，再运行：bash init_setup.sh"
    exit 2
  fi
}

check_runtime_environment() {
  local failed=0 available_kb
  print_section "运行环境检查"
  if [ ! -r /etc/os-release ]; then
    print_err "无法读取 /etc/os-release。"
    failed=1
  else
    local ID="" VERSION_CODENAME="" PRETTY_NAME=""
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
      print_err "当前系统不是 Debian：${PRETTY_NAME:-未知系统}"
      failed=1
    else
      print_ok "系统：${PRETTY_NAME:-Debian}"
    fi
    [ -n "${VERSION_CODENAME:-}" ] || { print_err "系统缺少 VERSION_CODENAME，无法配置部分软件源。"; failed=1; }
  fi
  for command_name in bash apt-get dpkg systemctl timedatectl mktemp install awk sed grep tee flock; do
    if command -v "$command_name" >/dev/null 2>&1; then
      print_ok "命令可用：${command_name}"
    else
      print_err "缺少命令：${command_name}"
      failed=1
    fi
  done
  if [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" != "systemd" ]; then
    print_err "PID 1 不是 systemd，本脚本不支持当前运行环境。"
    failed=1
  else
    print_ok "systemd 正在运行"
  fi
  available_kb="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "$available_kb" =~ ^[0-9]+$ ]] && [ "$available_kb" -lt 524288 ]; then
    print_err "根分区可用空间少于 512 MiB。"
    failed=1
  elif [[ "$available_kb" =~ ^[0-9]+$ ]]; then
    print_ok "根分区可用空间满足最低要求"
  else
    print_err "无法读取根分区可用空间。"
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  print_ok "运行环境检查通过"
}

prepare_logfile() {
  local parent unsafe_parent
  if [[ "$LOGFILE" != /* || "$LOGFILE" == *$'\n'* || "$LOGFILE" == *$'\r'* ]]; then
    print_err "日志路径必须是不含换行的绝对路径：${LOGFILE}"
    return 1
  fi
  parent="$(dirname "$LOGFILE")"
  if [ ! -d "$parent" ]; then
    install -d -m 0755 "$parent" || return 1
  fi
  unsafe_parent="$(find "$parent" -maxdepth 0 -perm /0022 -print 2>/dev/null || true)"
  [ -z "$unsafe_parent" ] || { print_err "日志目录不能允许组用户或其他用户写入：${parent}"; return 1; }
  [ ! -L "$LOGFILE" ] || { print_err "日志文件不能是符号链接：${LOGFILE}"; return 1; }
  if [ -e "$LOGFILE" ] && [ ! -f "$LOGFILE" ]; then
    print_err "日志路径不是普通文件：${LOGFILE}"
    return 1
  fi
  touch "$LOGFILE"
  chmod 0600 "$LOGFILE"
}

acquire_run_lock() {
  local parent
  parent="$(dirname "$LOCKFILE")"
  if [ ! -d "$parent" ]; then
    install -d -m 0755 "$parent" || return 1
  fi
  [ ! -L "$LOCKFILE" ] || { print_err "运行锁不能是符号链接：${LOCKFILE}"; return 1; }
  exec {LOCK_FD}>"$LOCKFILE"
  if ! flock -n "$LOCK_FD"; then
    print_err "已有另一个初始化脚本正在运行：${LOCKFILE}"
    return 1
  fi
}

should_prompt() {
  case "${INTERACTIVE_MODE,,}" in
    yes) return 0 ;;
    no) return 1 ;;
    auto) [ "$ORIGINAL_STDIN_IS_TTY" -eq 1 ] && [ "$ORIGINAL_STDOUT_IS_TTY" -eq 1 ] ;;
    *) print_err "INTERACTIVE_MODE 无效: $INTERACTIVE_MODE。请使用 auto/yes/no。"; exit 2 ;;
  esac
}

prompt_yes_no() {
  local var_name="$1" label="$2" current answer prompt
  current="${!var_name}"
  if is_yes "$current"; then prompt="${label} [Y/n]: "; else prompt="${label} [y/N]: "; fi
  while true; do
    if ! read -r -p "$prompt" answer; then
      print_err "未读取到选择，已停止执行。"
      return 1
    fi
    answer="$(trim "$answer")"
    case "${answer,,}" in
      "") return 0 ;;
      y|yes|1|true|on|enable|enabled|是|启用|开启) printf -v "$var_name" yes; return 0 ;;
      n|no|0|false|off|disable|disabled|否|关闭|跳过) printf -v "$var_name" no; return 0 ;;
      *) echo "请输入 y 或 n；直接回车保持默认值。" ;;
    esac
  done
}

prompt_configuration() {
  should_prompt || return 0
  print_section "0) 运行配置"
  print_info "回车采用大写字母所示默认值：Y 开启，N 关闭；输入 n 可关闭该项。"
  prompt_yes_no ENABLE_SYSTEM_UPDATE "执行系统更新/升级" || return 1
  prompt_yes_no ENABLE_COMMON_TOOLS "安装常用工具" || return 1
  prompt_yes_no ENABLE_NEXTTRACE_MTR "安装 NextTrace 和 mtr" || return 1
  prompt_yes_no ENABLE_BBR "开启 BBR + fq" || return 1
  prompt_yes_no ENABLE_SSH_BASELINE "配置 SSH 安全基线：端口 ${SSH_PORT}，root 密钥登录，禁用密码登录" || return 1
  prompt_yes_no ENABLE_UFW "启用 UFW 防火墙，仅添加 SSH 放行" || return 1
  prompt_yes_no ENABLE_FAIL2BAN "启用 Fail2ban" || return 1
  prompt_yes_no ENABLE_JOURNAL_LIMIT "限制 systemd journal 最大占用为 ${JOURNAL_MAX_USE}" || return 1
  prompt_yes_no ENABLE_TIMEZONE "设置系统时区为 ${TARGET_TIMEZONE}，并安装启用 chrony 做时间同步" || return 1
  prompt_yes_no ENABLE_DISABLE_IPV6 "关闭 IPv6" || return 1
  prompt_yes_no ENABLE_DOCKER "安装 Docker Engine 与 Docker Compose" || return 1
}

prompt_mode_selection() {
  should_prompt || return 0
  [ "$MODE_EXPLICIT" -eq 1 ] && return 0
  print_section "0) 选择运行模式"
  echo "1) 推荐模式：常用工具、网络优化、SSH、防火墙、Fail2ban、日志限制和时间同步"
  echo "2) 精简模式：系统更新、BBR + fq、SSH、防火墙、日志限制和时间同步"
  echo "3) 完整模式：启用全部模块"
  echo "4) 自定义模式：逐项选择模块"
  local answer
  while true; do
    if ! read -r -p "请选择 [1-4，默认 1]: " answer; then
      print_err "未读取到选择，已停止执行。"
      return 1
    fi
    answer="$(trim "$answer")"
    case "$answer" in
      ""|1) MODE="recommended"; return 0 ;;
      2) MODE="minimal"; return 0 ;;
      3) MODE="full"; return 0 ;;
      4) MODE="custom"; return 0 ;;
      *) echo "请输入 1、2、3 或 4。" ;;
    esac
  done
}

state_text() { if is_yes "$1"; then printf '开启'; else printf '关闭/跳过'; fi; }

print_config_summary() {
  print_section "0.5) 本次执行配置摘要"
  printf '脚本版本: %s（作者 %s）\n' "$SCRIPT_VERSION" "$SCRIPT_AUTHOR"
  printf '系统更新/升级: %s\n' "$(state_text "$ENABLE_SYSTEM_UPDATE")"
  printf '常用工具: %s\n' "$(state_text "$ENABLE_COMMON_TOOLS")"
  printf 'NextTrace 和 mtr: %s\n' "$(state_text "$ENABLE_NEXTTRACE_MTR")"
  printf 'BBR + fq: %s\n' "$(state_text "$ENABLE_BBR")"
  printf 'SSH 安全基线: %s\n' "$(state_text "$ENABLE_SSH_BASELINE")"
  printf 'UFW 防火墙: %s\n' "$(state_text "$ENABLE_UFW")"
  printf 'Fail2ban: %s\n' "$(state_text "$ENABLE_FAIL2BAN")"
  printf 'systemd journal 大小限制: %s\n' "$(state_text "$ENABLE_JOURNAL_LIMIT")"
  printf '系统时区 + chrony 时间同步: %s\n' "$(state_text "$ENABLE_TIMEZONE")"
  printf '关闭 IPv6: %s\n' "$(state_text "$ENABLE_DISABLE_IPV6")"
  printf 'Docker: %s\n' "$(state_text "$ENABLE_DOCKER")"
  printf '运行模式: %s\n' "$MODE"
  echo "SSH_PORT: ${SSH_PORT}"
  echo "TARGET_TIMEZONE: ${TARGET_TIMEZONE}"
  echo "JOURNAL_MAX_USE: ${JOURNAL_MAX_USE}"
  echo "日志文件: ${LOGFILE}"
}

record_soft_error() { SOFT_ERRORS+=("$1"); }

on_err() { LAST_ERR_LINE="$1"; LAST_ERR_COMMAND="$2"; }

print_final_summary() {
  local exit_code="$1" end_ts elapsed_min elapsed_sec
  end_ts="$(date +%s)"
  elapsed_sec="$((end_ts - SCRIPT_START_TS))"
  elapsed_min="$((elapsed_sec / 60))"
  elapsed_sec="$((elapsed_sec % 60))"

  echo
  if [ "$RESTORE_IPV6_ONLY" -eq 1 ]; then
    print_section "IPv6 恢复结果"
  else
    print_section "10) 简短结果报告"
  fi
  if [ "$exit_code" -eq 0 ] && [ "${#SOFT_ERRORS[@]}" -eq 0 ]; then
    if [ "$RESTORE_IPV6_ONLY" -eq 1 ] && [ "$IPV6_REBOOT_REQUIRED" -eq 1 ]; then
      echo "执行结果: 恢复配置已完成，重启后生效"
    else
      echo "执行结果: 全部成功"
    fi
    echo "错误部分: 无"
  else
    echo "执行结果: 部分错误"
    echo "错误部分:"
    if [ "${#SOFT_ERRORS[@]}" -gt 0 ]; then
      local msg
      for msg in "${SOFT_ERRORS[@]}"; do echo "- $msg"; done
    fi
    if [ "$exit_code" -ne 0 ]; then
      if [ -n "$LAST_ERR_COMMAND" ]; then
        echo "- 致命错误: 第 ${LAST_ERR_LINE} 行执行失败，命令: ${LAST_ERR_COMMAND}"
      else
        echo "- 致命错误: 脚本异常退出，退出码 ${exit_code}"
      fi
    fi
  fi
  if [ "${#SKIPPED_STEPS[@]}" -gt 0 ]; then
    echo "已跳过模块:"
    local step
    for step in "${SKIPPED_STEPS[@]}"; do echo "- $step"; done
  fi
  printf '总计耗时: %d分%02d秒\n' "$elapsed_min" "$elapsed_sec"
}

on_exit() {
  local exit_code="$1"
  trap - EXIT ERR
  print_final_summary "$exit_code" || true
  if [ "$exit_code" -eq 0 ] && [ "${#SOFT_ERRORS[@]}" -gt 0 ]; then
    exit_code=1
  fi
  exit "$exit_code"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_err "请切换到 root 后运行此脚本，例如: bash $0"
    exit 1
  fi
}

backup_file() {
  local file="$1"
  [ -z "${BACKED_UP_FILES[$file]+x}" ] || return 0
  install -d -m 0700 "$BACKUP_DIR" || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    install -d -m 0700 "${BACKUP_DIR}$(dirname "$file")" || return 1
    cp -a -- "$file" "${BACKUP_DIR}${file}" || return 1
    printf 'present\t%s\n' "$file" >> "${BACKUP_DIR}/manifest" || return 1
    print_ok "已备份 $file"
  else
    printf 'absent\t%s\n' "$file" >> "${BACKUP_DIR}/manifest" || return 1
  fi
  printf '%s\n' "$BACKUP_ID" > "${BACKUP_ROOT}/latest" || return 1
  chmod 0600 "${BACKUP_DIR}/manifest" "${BACKUP_ROOT}/latest" || return 1
  BACKED_UP_FILES["$file"]=1
}

restore_file_from_backup() {
  local backup_dir="$1" file="$2" state
  [ -f "${backup_dir}/manifest" ] || return 1
  state="$(awk -F '\t' -v file="$file" '$2 == file {print $1; exit}' "${backup_dir}/manifest")"
  case "$state" in
    present)
      if [ ! -d "$(dirname "$file")" ]; then
        install -d -m 0755 "$(dirname "$file")" || return 1
      fi
      cp -a -- "${backup_dir}${file}" "$file"
      ;;
    absent)
      rm -f -- "$file"
      ;;
    *) return 1 ;;
  esac
}

backup_ssh_file() {
  local file="$1"
  backup_file "$file" || return 1
  local existing
  for existing in "${SSH_TRANSACTION_FILES[@]}"; do
    [ "$existing" != "$file" ] || return 0
  done
  SSH_TRANSACTION_FILES+=("$file")
}

rollback_ssh_configuration() {
  local index file failed=0
  SSH_READY=0
  [ "${#SSH_TRANSACTION_FILES[@]}" -gt 0 ] || return 0
  print_warn "SSH 配置未完成，正在恢复修改前的文件。"
  for ((index=${#SSH_TRANSACTION_FILES[@]}-1; index>=0; index--)); do
    file="${SSH_TRANSACTION_FILES[$index]}"
    if ! restore_file_from_backup "$BACKUP_DIR" "$file"; then
      print_err "SSH 配置恢复失败：${file}"
      failed=1
    fi
  done
  if [ "$failed" -ne 0 ]; then
    print_err "SSH 原配置未完整恢复，请检查备份目录：${BACKUP_DIR}"
    return 1
  fi
  if [ "$SSH_SERVICE_RELOADED" -eq 1 ]; then
    if ! command -v sshd >/dev/null 2>&1 || ! sshd -t >/dev/null 2>&1; then
      print_err "SSH 原配置已恢复，但语法校验失败，未重载服务。"
      return 1
    fi
    if ! reload_ssh_service >/dev/null 2>&1; then
      print_err "SSH 原配置已恢复，但服务重载失败。"
      return 1
    fi
  fi
}

restore_latest_backup() {
  local backup_id backup_dir state file restored=0 failed=0
  [ -f "${BACKUP_ROOT}/latest" ] || { print_err "没有找到可恢复的备份。"; return 1; }
  backup_id="$(<"${BACKUP_ROOT}/latest")"
  [[ "$backup_id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-[0-9]+$ ]] || { print_err "最近备份标识无效。"; return 1; }
  backup_dir="${BACKUP_ROOT}/${backup_id}"
  [ -f "${backup_dir}/manifest" ] || { print_err "最近备份不完整：${backup_dir}"; return 1; }
  while IFS=$'\t' read -r state file; do
    [ -n "$file" ] || continue
    if restore_file_from_backup "$backup_dir" "$file"; then
      restored=$((restored + 1))
    else
      print_warn "恢复失败：${file}"
      failed=1
    fi
  done < "${backup_dir}/manifest"
  if [ "$failed" -ne 0 ]; then
    print_err "备份恢复未完全成功，请检查：${backup_dir}"
    return 1
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
  fi
  if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || true
  fi
  if command -v sshd >/dev/null 2>&1 && sshd -t >/dev/null 2>&1; then reload_ssh_service >/dev/null 2>&1 || true; fi
  systemctl restart fail2ban >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  print_ok "已从 ${backup_dir} 恢复 ${restored} 个配置项。"
}

apt_install() { apt-get install -y "$@"; }

run_step() {
  local title="$1" enabled="$2" func="$3"
  print_section "$title"
  if is_yes "$enabled"; then
    "$func"
  else
    print_info "已跳过：$title"
    SKIPPED_STEPS+=("$title")
  fi
}

update_system_packages() {
  apt-get update
  apt-get upgrade -y
  print_ok "系统更新完成"
}

install_common_tools() {
  apt_install curl wget git openssh-server iproute2 sudo iperf3
  print_ok "常用工具安装完成"
}

install_nexttrace_mtr() {
  apt_install ca-certificates curl gnupg

  if ! apt_install mtr-tiny; then
    print_warn "mtr-tiny 安装失败，尝试安装 mtr"
    apt_install mtr
  fi

  install -d -m 0755 /etc/apt/keyrings
  local key_tmp
  key_tmp="$(mktemp)"
  if ! curl --connect-timeout 15 --retry 3 --retry-delay 2 -fsSL -o "$key_tmp" https://github.com/nxtrace/nexttrace-debs/releases/latest/download/nexttrace-archive-keyring.gpg; then
    rm -f -- "$key_tmp"
    return 1
  fi
  backup_file /etc/apt/keyrings/nexttrace.gpg
  install -m 0644 "$key_tmp" /etc/apt/keyrings/nexttrace.gpg
  rm -f -- "$key_tmp"

  backup_file /etc/apt/sources.list.d/nexttrace.sources
  cat > /etc/apt/sources.list.d/nexttrace.sources <<EOF_NEXTTRACE
Types: deb
URIs: https://github.com/nxtrace/nexttrace-debs/releases/latest/download/
Suites: ./
Signed-By: /etc/apt/keyrings/nexttrace.gpg
EOF_NEXTTRACE

  apt-get update
  apt_install nexttrace

  local msg nexttrace_ok=0 mtr_ok=0
  if command -v nexttrace >/dev/null 2>&1; then
    nexttrace_ok=1
  else
    msg="NextTrace 安装后未检测到 nexttrace 命令"
    print_warn "$msg"; record_soft_error "$msg"
  fi

  if command -v mtr >/dev/null 2>&1; then
    mtr_ok=1
  else
    msg="mtr 安装后未检测到 mtr 命令"
    print_warn "$msg"; record_soft_error "$msg"
  fi

  if [ "$nexttrace_ok" -eq 1 ] && [ "$mtr_ok" -eq 1 ]; then
    print_ok "NextTrace 和 mtr 安装完成"
  fi
}

kernel_has_ipv6_disable_arg() {
  [ -r /proc/cmdline ] && tr ' ' '\n' < /proc/cmdline | grep -qxF 'ipv6.disable=1'
}

ipv6_interface_map() {
  ip -o link show | awk -F ': ' '{ sub(/@.*/, "", $2); print $1 "\t" $2 }'
}

ipv6_snapshot_matches_boot() {
  local saved_boot_id="${BACKUP_ROOT}/ipv6-runtime/boot-id"
  if [ ! -s "$saved_boot_id" ] || [ ! -r "$saved_boot_id" ] || [ ! -r /proc/sys/kernel/random/boot_id ]; then
    return 1
  fi
  # /proc 文件报告的大小为 0，cmp -s 可能只按大小误判；直接读取内容比较。
  [ "$(<"$saved_boot_id")" = "$(</proc/sys/kernel/random/boot_id)" ]
}

save_ipv6_runtime_state() {
  local state_dir="${BACKUP_ROOT}/ipv6-runtime"
  command -v ip >/dev/null 2>&1 || { print_err "缺少 ip 命令，无法保存 IPv6 地址和路由，已停止关闭 IPv6。"; return 1; }
  [ -d /proc/sys/net/ipv6/conf ] || return 0
  kernel_has_ipv6_disable_arg && return 0
  # 重复关闭时保留第一次的网络状态，防止用空地址覆盖可恢复的数据。
  if ipv6_snapshot_matches_boot; then
    if [ ! -r "$state_dir/addresses" ] || [ ! -r "$state_dir/routes" ] || [ ! -r "$state_dir/interfaces" ]; then
      print_err "已有 IPv6 网络状态备份不完整，已停止关闭 IPv6：${state_dir}"
      return 1
    fi
    return 0
  fi
  [ -r /proc/sys/kernel/random/boot_id ] || { print_err "无法读取本次启动标识，已停止关闭 IPv6。"; return 1; }
  install -d -m 0700 "$state_dir" || return 1
  ipv6_interface_map > "$state_dir/interfaces" || return 1
  ip -6 address save scope global > "$state_dir/addresses" || return 1
  ip -6 route save table all > "$state_dir/routes" || return 1
  cp -- /proc/sys/kernel/random/boot_id "$state_dir/boot-id" || return 1
  chmod 0600 "$state_dir/addresses" "$state_dir/routes" "$state_dir/interfaces" "$state_dir/boot-id" || return 1
  print_ok "已保存 IPv6 地址和路由，供 --restore-ipv6 恢复。"
}

write_ipv6_sysctl_config() {
  backup_file "/etc/sysctl.d/99-disable-ipv6.conf" || return 1
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF_IPV6 || return 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF_IPV6
  chmod 0644 /etc/sysctl.d/99-disable-ipv6.conf
}

disable_ipv6_runtime() {
  local setting iface failed_interfaces=""

  if kernel_has_ipv6_disable_arg; then
    print_info "内核已通过 ipv6.disable=1 关闭 IPv6。"
    return 0
  fi

  if [ ! -d /proc/sys/net/ipv6/conf ]; then
    print_info "内核未提供 IPv6 接口配置，当前无需额外关闭。"
    return 0
  fi

  # 先设置全局和新接口默认值，再逐个关闭现有接口，避免网络管理器留下单独启用的网卡。
  for setting in /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6; do
    [ -e "$setting" ] || continue
    if ! printf '1\n' > "$setting"; then
      iface="${setting#/proc/sys/net/ipv6/conf/}"
      iface="${iface%/disable_ipv6}"
      failed_interfaces="${failed_interfaces}${failed_interfaces:+,}${iface}"
    fi
  done

  for setting in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "$setting" ] || continue
    iface="${setting#/proc/sys/net/ipv6/conf/}"
    iface="${iface%/disable_ipv6}"
    case "$iface" in all|default) continue ;; esac
    if ! printf '1\n' > "$setting"; then
      failed_interfaces="${failed_interfaces}${failed_interfaces:+,}${iface}"
    fi
  done

  if [ -n "$failed_interfaces" ]; then
    print_warn "以下接口无法立即关闭 IPv6：${failed_interfaces}"
    return 1
  fi
  return 0
}

grub_config_has_ipv6_disable_arg() {
  local file="${1:-/etc/default/grub}"
  [ -f "$file" ] || return 1
  awk '/^[[:space:]]*GRUB_CMDLINE_LINUX(_DEFAULT)?=/ &&
       /ipv6[.]disable=1([[:space:]"\047]|$)/ { found=1 }
       END { exit !found }' "$file"
}

configure_ipv6_grub_persistence() {
  local msg

  if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; then
    if kernel_has_ipv6_disable_arg; then
      IPV6_PERSISTENCE_READY=1
      print_ok "当前启动器已经传入 ipv6.disable=1，IPv6 内核启动参数已生效。"
      return 0
    fi
    msg="未检测到可管理的 GRUB 配置；当前已通过 sysctl 关闭 IPv6，但无法保证其他启动器或网络管理器重启后不会重新启用。"
    print_warn "$msg"
    record_soft_error "$msg"
    return 1
  fi

  if ! grub_config_has_ipv6_disable_arg; then
    backup_file "/etc/default/grub" || return 1
    cat >> /etc/default/grub <<'EOF_GRUB_IPV6' || return 1

# init-setup：在内核启动阶段彻底关闭 IPv6，避免网络管理器重新启用具体接口。
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+${GRUB_CMDLINE_LINUX} }ipv6.disable=1"
EOF_GRUB_IPV6
    print_info "已将 ipv6.disable=1 写入 GRUB 内核参数。"
  else
    print_info "GRUB 已包含 ipv6.disable=1，跳过重复写入。"
  fi

  if ! update-grub >/dev/null; then
    msg="update-grub 执行失败；IPv6 已在当前运行时关闭，但内核启动参数尚未可靠更新。"
    print_warn "$msg"
    record_soft_error "$msg"
    return 1
  fi

  IPV6_PERSISTENCE_READY=1
  if kernel_has_ipv6_disable_arg; then
    print_ok "IPv6 内核启动参数已生效。"
  else
    IPV6_REBOOT_REQUIRED=1
    print_ok "IPv6 内核启动参数已更新，重启后完全生效。"
  fi
  return 0
}

verify_ipv6_runtime_disabled() {
  local setting iface value global_addresses default_routes issues=""

  if [ -d /proc/sys/net/ipv6/conf ]; then
    for setting in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
      [ -e "$setting" ] || continue
      iface="${setting#/proc/sys/net/ipv6/conf/}"
      iface="${iface%/disable_ipv6}"
      case "$iface" in all|default) continue ;; esac
      value="$(<"$setting")"
      if [ "$value" != "1" ]; then
        issues="${issues}${issues:+；}${iface}.disable_ipv6=${value}"
      fi
    done
  fi

  if command -v ip >/dev/null 2>&1; then
    global_addresses="$(ip -6 -o address show scope global 2>/dev/null || true)"
    default_routes="$(ip -6 route show default 2>/dev/null || true)"
    [ -z "$global_addresses" ] || issues="${issues}${issues:+；}仍有全局 IPv6 地址"
    [ -z "$default_routes" ] || issues="${issues}${issues:+；}仍有 IPv6 默认路由"
  else
    issues="${issues}${issues:+；}缺少 ip 命令，无法校验 IPv6 地址和路由"
  fi

  if [ -n "$issues" ]; then
    print_warn "IPv6 运行时状态未完全关闭：${issues}"
    return 1
  fi

  print_ok "IPv6 运行时校验通过：所有现有接口均已关闭，且没有全局 IPv6 地址或默认路由。"
  return 0
}

configure_disable_ipv6() {
  local runtime_ok=1 persistence_ok=1 msg

  save_ipv6_runtime_state || return 1
  write_ipv6_sysctl_config || return 1
  disable_ipv6_runtime || runtime_ok=0
  configure_ipv6_grub_persistence || persistence_ok=0
  verify_ipv6_runtime_disabled || runtime_ok=0

  if [ "$runtime_ok" -eq 0 ]; then
    msg="IPv6 未能在所有现有接口上完全关闭，请检查网络管理服务和上方校验结果。"
    record_soft_error "$msg"
  elif [ "$persistence_ok" -eq 1 ]; then
    print_ok "IPv6 当前运行时已关闭，持久化配置已完成。"
  else
    print_warn "IPv6 当前运行时已关闭，但启动阶段持久化配置未完全完成。"
  fi
}

apply_ipv6_config_restore() {
  local file="$1" temporary="$2"
  if cmp -s "$file" "$temporary"; then
    rm -f -- "$temporary"
    return 0
  fi
  if ! backup_file "$file"; then
    rm -f -- "$temporary"
    return 1
  fi
  if [ -s "$temporary" ]; then
    if ! cat "$temporary" > "$file"; then
      rm -f -- "$temporary"
      return 1
    fi
  elif ! rm -f -- "$file"; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
}

restore_ipv6_grub_persistence() {
  local file=/etc/default/grub dropin temporary
  for dropin in /etc/default/grub.d/*.cfg; do
    if grub_config_has_ipv6_disable_arg "$dropin"; then
      print_err "另有 GRUB 配置禁用 IPv6：${dropin}。请先处理该启动参数，再运行恢复。"
      return 1
    fi
  done
  if [ ! -f "$file" ]; then
    if kernel_has_ipv6_disable_arg; then
      print_err "当前内核通过 ipv6.disable=1 启动，但没有可管理的 GRUB 配置；请先从实际启动器中移除此参数。"
      return 1
    fi
    return 0
  fi
  if ! command -v update-grub >/dev/null 2>&1; then
    if grub_config_has_ipv6_disable_arg || kernel_has_ipv6_disable_arg; then
      print_err "缺少 update-grub，无法撤销 IPv6 启动参数。"
      return 1
    fi
    return 0
  fi
  temporary="$(mktemp)" || return 1
  # 删除脚本追加的整行；普通参数行只删除完整的禁用参数，保留其他启动设置。
  if ! awk '
    $0 == "# init-setup：在内核启动阶段彻底关闭 IPv6，避免网络管理器重新启用具体接口。" { next }
    $0 == "GRUB_CMDLINE_LINUX=\"${GRUB_CMDLINE_LINUX:+${GRUB_CMDLINE_LINUX} }ipv6.disable=1\"" { next }
    /^[[:space:]]*GRUB_CMDLINE_LINUX(_DEFAULT)?=/ {
      while (match($0, /(^|[[:space:]"\047])ipv6[.]disable=1([[:space:]"\047]|$)/)) {
        part=substr($0, RSTART, RLENGTH)
        sub(/ipv6[.]disable=1/, "", part)
        $0=substr($0, 1, RSTART-1) part substr($0, RSTART+RLENGTH)
      }
    }
    { print }
  ' "$file" > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if grub_config_has_ipv6_disable_arg "$temporary"; then
    rm -f -- "$temporary"
    print_err "GRUB 中的 IPv6 参数写法无法自动处理，已保留原文件。"
    return 1
  fi
  apply_ipv6_config_restore "$file" "$temporary" || return 1
  # 即使源文件已清理也重新生成，允许重试上一次 update-grub 失败的恢复。
  if ! update-grub >/dev/null; then
    print_err "update-grub 执行失败，启动配置尚未恢复；修复后请重新运行 --restore-ipv6。"
    return 1
  fi
  if [ -r /boot/grub/grub.cfg ] && awk '
    /^[[:space:]]*linux(efi)?[[:space:]]/ && /(^|[[:space:]])ipv6[.]disable=1([[:space:]]|$)/ { found=1 }
    END { exit !found }
  ' /boot/grub/grub.cfg; then
    print_err "生成的 GRUB 配置仍包含 ipv6.disable=1，请检查其他启动配置。"
    return 1
  fi
  print_ok "GRUB 的 IPv6 禁用参数已清理。"
}

restore_ipv6_sysctl_config() {
  local file=/etc/sysctl.d/99-disable-ipv6.conf temporary
  [ -f "$file" ] || return 0
  temporary="$(mktemp)" || return 1
  if ! awk '
    !/^[[:space:]]*net[.]ipv6[.]conf[.](all|default|lo)[.]disable_ipv6[[:space:]]*=[[:space:]]*1([[:space:]]*([#;].*)?)?$/
  ' "$file" > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  apply_ipv6_config_restore "$file" "$temporary" || return 1
  print_ok "脚本写入的 IPv6 禁用系统参数已清理。"
}

restore_ipv6_ufw() {
  local file=/etc/default/ufw temporary
  [ -f "$file" ] || return 0
  temporary="$(mktemp)" || return 1
  if ! sed -E 's/^(IPV6=)no([[:space:]]*(#.*)?)$/\1yes\2/' "$file" > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  apply_ipv6_config_restore "$file" "$temporary" || return 1
  # UFW 的 IPV6=no 会丢弃 IPv6 流量。只重载已经启用的防火墙，保留现有规则。
  if ! kernel_has_ipv6_disable_arg && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    if ! ufw reload; then
      print_err "UFW 的 IPv6 支持重载失败，请修复后重新运行 --restore-ipv6。"
      return 1
    fi
  fi
}

enable_ipv6_runtime() {
  local setting iface failed=0
  [ -d /proc/sys/net/ipv6/conf ] || { print_err "内核未提供 IPv6 配置，无法立即恢复。"; return 1; }
  for setting in /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6 /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "$setting" ] || continue
    if [ "$(<"$setting")" != 0 ] && ! printf '0\n' > "$setting"; then
      iface="${setting#/proc/sys/net/ipv6/conf/}"
      print_err "无法恢复 IPv6 开关：${iface}"
      failed=1
    fi
  done
  return "$failed"
}

parse_ifupdown_ipv6() {
  # ifquery 已处理 source/source-directory；只读取 IPv6 地址、前缀和网关，不执行配置中的命令。
  awk '
    function flush_address() {
      if (address !~ /:/) return
      if (address !~ /\//) {
        if (prefix !~ /^[0-9]+$/ || prefix > 128) { invalid=1; return }
        address=address "/" prefix
      }
      print "address\t" address
      if (gateway ~ /:/) print "gateway\t" gateway "\t" metric
    }
    $1 == "address:" { flush_address(); address=$2; prefix=""; gateway=""; metric="" }
    $1 == "netmask:" { prefix=$2 }
    $1 == "gateway:" { gateway=$2 }
    $1 == "metric:" { metric=$2 }
    END { flush_address(); exit invalid }
  '
}

restore_ifupdown_ipv6() {
  local interfaces iface details records kind value metric restored=0
  if ! command -v ifquery >/dev/null 2>&1 ||
     ! systemctl is-active --quiet networking; then
    print_info "没有可用的 ifupdown 静态配置，等待网络管理服务分配 IPv6。"
    return 0
  fi
  interfaces="$(ifquery --list --no-mappings)" || return 1
  while IFS= read -r iface; do
    if [ -z "$iface" ] || [ "$iface" = lo ]; then
      continue
    fi
    ip link show dev "$iface" >/dev/null 2>&1 || continue
    details="$(ifquery --no-mappings "$iface")" || return 1
    if ! records="$(printf '%s\n' "$details" | parse_ifupdown_ipv6)"; then
      print_err "接口 ${iface} 的 IPv6 静态地址缺少有效前缀，无法自动恢复。"
      return 1
    fi
    while IFS=$'\t' read -r kind value metric; do
      case "$kind" in
        address)
          ip -6 address replace "$value" dev "$iface" || return 1
          restored=$((restored + 1))
          ;;
        gateway)
          local -a route_args=(default via "$value" dev "$iface" onlink)
          if [ -n "$metric" ]; then
            [[ "$metric" =~ ^[0-9]+$ ]] || { print_err "接口 ${iface} 的 IPv6 路由 metric 无效。"; return 1; }
            route_args+=(metric "$metric")
          fi
          ip -6 route replace "${route_args[@]}" || return 1
          ;;
      esac
    done <<< "$records"
  done <<< "$interfaces"
  if [ "$restored" -gt 0 ]; then
    print_ok "已按 ifupdown 配置恢复 ${restored} 个静态 IPv6 地址及其网关。"
  fi
}

restore_ipv6_network_state() {
  local state_dir="${BACKUP_ROOT}/ipv6-runtime" addresses routes interfaces
  if ipv6_snapshot_matches_boot; then
    if [ ! -r "$state_dir/addresses" ] || [ ! -r "$state_dir/routes" ] || [ ! -r "$state_dir/interfaces" ]; then
      print_err "IPv6 网络状态备份不完整：${state_dir}"
      return 1
    fi
    interfaces="$(ipv6_interface_map)" || return 1
    if [ "$interfaces" = "$(<"$state_dir/interfaces")" ]; then
      ip -6 address restore < "$state_dir/addresses" || return 1
      ip -6 route restore < "$state_dir/routes" || return 1
      print_ok "已恢复关闭前保存的 IPv6 地址和路由。"
      return 0
    fi
    print_warn "网卡编号已变化，将按持久网络配置恢复 IPv6。"
  fi
  # ip 的二进制快照使用网卡编号，不跨重启重放；旧版无快照时也使用持久网络配置。
  addresses="$(ip -6 -o address show scope global)" || return 1
  routes="$(ip -6 route show default)" || return 1
  if [ -z "$addresses" ] || [ -z "$routes" ]; then
    restore_ifupdown_ipv6 || return 1
  fi
}

verify_ipv6_runtime_enabled() {
  local setting addresses routes attempt
  for setting in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "$setting" ] || continue
    if [ "$(<"$setting")" != 0 ]; then
      print_err "IPv6 仍被禁用：${setting}"
      return 1
    fi
  done
  # 给地址冲突检测和路由通告留出时间，不把 tentative 地址当作已恢复。
  for ((attempt=0; attempt<10; attempt++)); do
    addresses="$(ip -6 -o address show scope global -tentative -dadfailed)" || return 1
    routes="$(ip -6 route show default)" || return 1
    if [ -n "$addresses" ] && [ -n "$routes" ]; then
      print_ok "IPv6 已启用，已有可用的全局地址和默认路由。"
      printf '%s\n' "$addresses" "$routes"
      return 0
    fi
    sleep 1
  done
  print_err "IPv6 开关已恢复，但尚未取得可用的全局地址和默认路由；请检查持久网络配置及网络管理服务，再重新运行 --restore-ipv6。"
  return 1
}

configure_restore_ipv6() {
  local command_name state_dir="${BACKUP_ROOT}/ipv6-runtime"
  for command_name in ip awk sed grep cmp mktemp cp; do
    command -v "$command_name" >/dev/null 2>&1 || { print_err "缺少恢复 IPv6 所需的命令：${command_name}"; return 1; }
  done
  if grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && ! command -v ufw >/dev/null 2>&1; then
    print_err "UFW 已配置为启用，但缺少 ufw 命令，无法恢复 IPv6 防火墙支持。"
    return 1
  fi
  restore_ipv6_grub_persistence || return 1
  restore_ipv6_sysctl_config || return 1
  restore_ipv6_ufw || return 1
  if kernel_has_ipv6_disable_arg; then
    IPV6_REBOOT_REQUIRED=1
    print_warn "IPv6 禁用配置已撤销；当前内核仍通过 ipv6.disable=1 启动，需要重启服务器才能恢复 IPv6。本脚本不会自动重启。"
    return 0
  fi
  enable_ipv6_runtime || return 1
  restore_ipv6_network_state || return 1
  verify_ipv6_runtime_enabled || return 1
  if [ -d "$state_dir" ]; then
    rm -f -- "$state_dir/addresses" "$state_dir/routes" "$state_dir/interfaces" "$state_dir/boot-id" || return 1
    rmdir -- "$state_dir" || return 1
  fi
}

configure_bbr_fq() {
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
  fi
  backup_file /etc/sysctl.d/99-bbr-fq.conf
  cat > /etc/sysctl.d/99-bbr-fq.conf <<EOF_BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_BBR
  if sysctl -p /etc/sysctl.d/99-bbr-fq.conf >/dev/null; then
    local current_cc current_qdisc msg
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
      print_ok "BBR + fq 已开启并持久化"
    else
      msg="BBR + fq 配置未完全生效，当前 tcp_congestion_control=${current_cc:-未知}, default_qdisc=${current_qdisc:-未知}"
      print_warn "$msg"; record_soft_error "$msg"
    fi
  else
    local msg="sysctl 应用 BBR + fq 配置失败，请检查内核是否支持 tcp_bbr 与 fq"
    print_warn "$msg"; record_soft_error "$msg"
  fi
}

validate_ssh_public_key() {
  local key_tmp
  SSH_PUBLIC_KEY="$(trim "$SSH_PUBLIC_KEY")"
  if [ -z "$SSH_PUBLIC_KEY" ] || [[ "$SSH_PUBLIC_KEY" == *$'\n'* ]] || [[ "$SSH_PUBLIC_KEY" == *$'\r'* ]] ||
     ! [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+ ]]; then
    print_err "SSH_PUBLIC_KEY 必须是一行完整的 SSH 公钥；未修改 SSH 登录配置。"
    return 1
  fi
  command -v ssh-keygen >/dev/null 2>&1 || { print_err "缺少 ssh-keygen，无法校验 SSH 公钥"; return 1; }
  key_tmp="$(mktemp)" || return 1
  if ! printf '%s\n' "$SSH_PUBLIC_KEY" > "$key_tmp" || ! ssh-keygen -lf "$key_tmp" >/dev/null 2>&1; then
    rm -f "$key_tmp"
    print_err "SSH 公钥格式或内容无效；未修改 SSH 登录配置。"
    return 1
  fi
  rm -f "$key_tmp"
}

add_root_ssh_key() {
  validate_ssh_public_key || return 1
  install -d -m 700 /root/.ssh || return 1
  backup_ssh_file /root/.ssh/authorized_keys || return 1
  touch /root/.ssh/authorized_keys || return 1
  chmod 600 /root/.ssh/authorized_keys || return 1
  chown -R root:root /root/.ssh || return 1
  if grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
    print_info "root 公钥已存在，跳过写入"
  else
    # 先换行，兼容已有 authorized_keys 最后一行没有换行符的情况。
    printf '\n%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys || return 1
    print_ok "已写入 root SSH 公钥"
  fi
}

reload_ssh_service() {
  local unit
  for unit in ssh sshd; do
    if systemctl reload "$unit" || systemctl restart "$unit"; then
      SSH_SERVICE_RELOADED=1
      systemctl is-active --quiet "$unit" || return 1
      systemctl enable "$unit" >/dev/null 2>&1 || true
      return 0
    fi
  done
  return 1
}

ensure_sshd_include() {
  install -d -m 755 "$SSH_DROPIN_DIR" || return 1
  [ -f "$SSH_CONFIG" ] || { print_err "未找到 ${SSH_CONFIG}"; return 1; }
  if head -n 1 "$SSH_CONFIG" 2>/dev/null | grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]+.*)?$'; then
    return 0
  fi
  backup_ssh_file "$SSH_CONFIG" || return 1
  local tmpfile
  tmpfile="$(mktemp)" || return 1
  if ! { printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf' &&
         sed -E 's|^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]+.*)?$|# init-setup 已将 Include 移至文件顶部: &|' "$SSH_CONFIG"; } > "$tmpfile"; then
    rm -f -- "$tmpfile"
    return 1
  fi
  if ! cat "$tmpfile" > "$SSH_CONFIG"; then
    rm -f -- "$tmpfile"
    return 1
  fi
  rm -f "$tmpfile"
  print_ok "已将 Include /etc/ssh/sshd_config.d/*.conf 放到 ${SSH_CONFIG} 顶部"
}

neutralize_ssh_conflicting_directives() {
  local file
  shopt -s nullglob
  for file in "$SSH_CONFIG" "$SSH_DROPIN_DIR"/*.conf; do
    [ -f "$file" ] || continue
    [ "$file" = "$SSH_HARDENING_FILE" ] && continue
    if grep -Eq '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|UsePAM)[[:space:]]+' "$file"; then
      if ! backup_ssh_file "$file" ||
         ! sed -ri 's/^([[:space:]]*)(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|UsePAM)([[:space:]]+)/# init-setup 已停用冲突的 SSH 配置: \2\3/I' "$file"; then
        shopt -u nullglob
        return 1
      fi
      print_ok "已注释 $file 中可能覆盖 SSH 加固配置的旧指令"
    fi
  done
  shopt -u nullglob
}

write_ssh_hardening_dropin() {
  install -d -m 755 "$SSH_DROPIN_DIR" || return 1
  backup_ssh_file "$SSH_HARDENING_FILE" || return 1
  if ! cat > "$SSH_HARDENING_FILE" <<EOF_SSH
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF_SSH
  then
    return 1
  fi
  chmod 600 "$SSH_HARDENING_FILE" || return 1
  print_ok "已写入 SSH 加固配置 ${SSH_HARDENING_FILE}"
}

verify_ssh_effective_config() {
  local effective ports_count port_value
  effective="$(sshd -T 2>/dev/null)" || { print_err "无法读取 SSH 生效配置：sshd -T 执行失败"; return 1; }
  ports_count="$(awk '$1 == "port" {count++} END {print count+0}' <<<"$effective")"
  port_value="$(awk '$1 == "port" {print $2}' <<<"$effective" | paste -sd ',' -)"
  if [ "$ports_count" -ne 1 ] || [ "$port_value" != "$SSH_PORT" ]; then
    print_err "SSH 端口校验失败：期望仅监听 ${SSH_PORT}，当前 sshd -T 端口为 ${port_value:-无}"
    return 1
  fi
  grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective" || { print_err "PermitRootLogin 生效校验失败"; return 1; }
  grep -q '^passwordauthentication no$' <<<"$effective" || { print_err "PasswordAuthentication 生效校验失败"; return 1; }
  grep -q '^kbdinteractiveauthentication no$' <<<"$effective" || { print_err "KbdInteractiveAuthentication 生效校验失败"; return 1; }
  grep -q '^pubkeyauthentication yes$' <<<"$effective" || { print_err "PubkeyAuthentication 生效校验失败"; return 1; }
  print_ok "SSH 生效配置校验通过"
}

verify_ssh_port_available() {
  local listeners
  if ! listeners="$(ss -H -tlnp 2>/dev/null)"; then
    print_err "无法读取监听端口，未修改 SSH 配置。"
    return 1
  fi
  if ! awk -v port=":${SSH_PORT}" '$4 ~ port"$" && !/"sshd",pid=/ {conflict=1} END {exit conflict ? 1 : 0}' <<< "$listeners"; then
    print_err "${SSH_PORT}/tcp 已被其他进程占用或无法确认归属，未修改 SSH 配置。"
    return 1
  fi
}

verify_ssh_listening() {
  command -v ss >/dev/null 2>&1 || { print_err "缺少 ss 命令，无法确认 SSH 监听端口"; return 1; }
  local attempt
  for attempt in 1 2 3 4 5; do
    if ss -H -tlnp 2>/dev/null | awk -v port=":${SSH_PORT}" '$4 ~ port"$" && /"sshd",pid=/ {found=1} END {exit found ? 0 : 1}'; then
      print_ok "已确认 sshd 正在监听 ${SSH_PORT}/tcp"
      return 0
    fi
    [ "$attempt" -eq 5 ] || sleep 1
  done
  print_err "SSH 监听校验失败：未确认 sshd 正在监听 ${SSH_PORT}/tcp"
  return 1
}

configure_ssh_baseline() {
  SSH_READY=0
  SSH_SERVICE_RELOADED=0
  apt_install openssh-server iproute2
  if ! add_root_ssh_key; then
    rollback_ssh_configuration
    return 1
  fi
  if ! verify_ssh_port_available; then
    rollback_ssh_configuration
    return 1
  fi
  if ! backup_ssh_file "$SSH_CONFIG" || ! ensure_sshd_include ||
     ! neutralize_ssh_conflicting_directives || ! write_ssh_hardening_dropin ||
     ! install -d -m 755 /run/sshd; then
    print_err "SSH 配置文件写入失败；正在恢复原配置"
    rollback_ssh_configuration
    return 1
  fi
  if ! sshd -t; then
    print_err "SSH 配置语法校验失败；正在恢复原配置"
    rollback_ssh_configuration
    return 1
  fi
  if ! verify_ssh_effective_config; then
    print_err "SSH 生效校验未通过；正在恢复原配置"
    rollback_ssh_configuration
    return 1
  fi
  if ! reload_ssh_service; then
    print_err "SSH 服务重载失败；正在恢复原配置"
    rollback_ssh_configuration
    return 1
  fi
  SSH_SERVICE_RELOADED=1
  if ! verify_ssh_listening; then
    print_err "SSH 监听校验未通过；正在恢复原配置"
    rollback_ssh_configuration
    return 1
  fi
  SSH_READY=1
  print_ok "SSH 已修改为端口 ${SSH_PORT}，root 允许密钥登录，密码登录已关闭"
}

detect_sshd_port_numbers() {
  local mode="${1:-config-fallback}" ports
  # 优先读取实际监听端口，避免磁盘配置与正在运行的服务不一致。
  if command -v ss >/dev/null 2>&1; then
    if ports="$(ss -H -tlnp 2>/dev/null | awk '/"sshd",pid=/ {n=split($4,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]}' | sort -n -u)" && [ -n "$ports" ]; then
      printf '%s\n' "$ports"
      return 0
    fi
  fi
  [ "$mode" != "live" ] || return 1
  if command -v sshd >/dev/null 2>&1; then
    if ports="$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 {print $2}' | sort -n -u)" && [ -n "$ports" ]; then
      printf '%s\n' "$ports"
      return 0
    fi
  fi
  return 1
}

run_ufw_preserving_ipv6_rules() {
  local rules_file=/etc/ufw/user6.rules exit_code=0
  if [ -f "$rules_file" ] && { grep -q '^IPV6=no' /etc/default/ufw 2>/dev/null || kernel_has_ipv6_disable_arg; }; then
    # UFW 在 IPv6 禁用时重写日志设置会清空 user6.rules，保留原规则供恢复使用。
    backup_file "$rules_file" || return 1
    if ufw "$@"; then :; else exit_code=$?; fi
    if ! restore_file_from_backup "$BACKUP_DIR" "$rules_file"; then
      print_err "UFW 操作后未能保留 IPv6 规则，请检查备份：${BACKUP_DIR}"
      return 1
    fi
    return "$exit_code"
  fi
  ufw "$@"
}

configure_ufw_firewall() {
  apt_install ufw iproute2
  local ssh_ports=() port
  if is_yes "$ENABLE_SSH_BASELINE"; then
    [ "$SSH_READY" -eq 1 ] || { print_err "SSH 未确认监听 ${SSH_PORT}/tcp，拒绝启用 UFW，避免锁死远程连接"; return 1; }
    ssh_ports=("$SSH_PORT")
  else
    mapfile -t ssh_ports < <(detect_sshd_port_numbers live || true)
    if [ "${#ssh_ports[@]}" -eq 0 ]; then
      print_err "未能确认 SSH 端口，已停止配置 UFW；请先检查 SSH 服务及监听状态。"
      return 1
    fi
  fi
  if is_yes "$ENABLE_DISABLE_IPV6" && [ -f /etc/default/ufw ]; then
    backup_file /etc/default/ufw || return 1
    sed -ri 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || return 1
  fi
  run_ufw_preserving_ipv6_rules default deny incoming || return 1
  run_ufw_preserving_ipv6_rules default allow outgoing || return 1
  for port in "${ssh_ports[@]}"; do run_ufw_preserving_ipv6_rules allow "${port}/tcp" || return 1; done
  run_ufw_preserving_ipv6_rules --force enable || return 1
  UFW_ALLOWED_SSH_PORTS=("${ssh_ports[@]}")
  print_ok "UFW 已启用，本次仅添加 SSH 放行，已有规则保留"
}

configure_fail2ban() {
  apt_install fail2ban
  backup_file "/etc/fail2ban/jail.local"
  local port_setting ports=() msg
  if is_yes "$ENABLE_SSH_BASELINE"; then
    port_setting="$SSH_PORT"
  else
    mapfile -t ports < <(detect_sshd_port_numbers || true)
    if [ "${#ports[@]}" -gt 0 ]; then port_setting="$(IFS=,; echo "${ports[*]}")"; else port_setting="ssh"; fi
  fi
  cat > /etc/fail2ban/jail.local <<EOF_F2B
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${port_setting}
EOF_F2B

  if ! systemctl restart fail2ban; then
    msg="Fail2ban 重启失败；请检查 systemctl status fail2ban 与 journalctl -u fail2ban"
    print_err "$msg"
    systemctl --no-pager --full status fail2ban 2>/dev/null | sed -n '1,15p' || true
    record_soft_error "$msg"
    return 0
  fi

  systemctl enable fail2ban >/dev/null 2>&1 || true

  if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    print_ok "Fail2ban 已启用并监控 SSH 端口 ${port_setting}"
  else
    msg="Fail2ban 启动后校验失败：服务未保持 active 或 sshd jail 未生效"
    print_err "$msg"
    systemctl --no-pager --full status fail2ban 2>/dev/null | sed -n '1,15p' || true
    fail2ban-client status 2>/dev/null || true
    record_soft_error "$msg"
    return 0
  fi
}

configure_journald_limit() {
  local msg current_usage

  if ! command -v journalctl >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    msg="系统缺少 journalctl 或 systemctl，无法配置 systemd journal 大小限制"
    print_warn "$msg"; record_soft_error "$msg"; return 0
  fi

  install -d -m 0755 "$JOURNALD_DROPIN_DIR"
  backup_file "$JOURNALD_LIMIT_FILE"

  cat > "$JOURNALD_LIMIT_FILE" <<EOF_JOURNALD
[Journal]
SystemMaxUse=${JOURNAL_MAX_USE}
RuntimeMaxUse=${JOURNAL_MAX_USE}
Compress=yes
EOF_JOURNALD

  chmod 0644 "$JOURNALD_LIMIT_FILE"

  if ! systemctl restart systemd-journald; then
    msg="systemd-journald 重启失败；请检查 systemctl status systemd-journald"
    print_warn "$msg"; record_soft_error "$msg"; return 0
  fi

  # 先轮转当前活动日志，再清理归档日志，使新的大小限制尽快生效。
  journalctl --rotate 2>/dev/null || true
  if ! journalctl --vacuum-size="$JOURNAL_MAX_USE"; then
    msg="journal 旧日志清理失败；大小限制已写入配置，但现有占用可能不会立即下降"
    print_warn "$msg"; record_soft_error "$msg"
  fi

  current_usage="$(journalctl --disk-usage 2>/dev/null || true)"
  print_ok "systemd journal 最大占用已限制为 ${JOURNAL_MAX_USE}（持久化和运行时日志）"
  [ -n "$current_usage" ] && print_info "$current_usage"
}

configure_timezone() {
  timedatectl set-timezone "$TARGET_TIMEZONE"
  print_ok "系统时区已设置为 ${TARGET_TIMEZONE}"

  install_enable_chrony
}

install_enable_chrony() {
  # chrony 与 systemd-timesyncd 都会占用 NTP 同步，避免两者冲突，安装 chrony 前先关闭 timesyncd。
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
    timedatectl set-ntp false 2>/dev/null || true
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  fi

  if ! apt_install chrony; then
    local msg="chrony 安装失败；请检查 apt 源或网络"
    print_warn "$msg"; record_soft_error "$msg"; return 0
  fi

  if ! systemctl enable --now chrony 2>/dev/null && ! systemctl enable --now chronyd 2>/dev/null; then
    local msg="chrony 服务启动失败；请检查 systemctl status chrony"
    print_warn "$msg"; record_soft_error "$msg"; return 0
  fi

  print_ok "chrony 已安装并启用，用于系统时间同步"
}

install_docker_engine() {
  local conflict_packages=() existing_packages=() existing_commands=()
  local package runtime_command codename arch key_tmp
  for package in docker.io docker-compose docker-doc podman podman-docker containerd runc \
                 docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io \
                 docker-buildx-plugin docker-compose-plugin; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      existing_packages+=("$package")
      case "$package" in
        docker.io|docker-compose|docker-doc|podman|podman-docker|containerd|runc)
          conflict_packages+=("$package") ;;
      esac
    fi
  done
  for runtime_command in docker podman containerd; do
    if command -v "$runtime_command" >/dev/null 2>&1; then
      existing_commands+=("$runtime_command")
    fi
  done
  if { [ "${#existing_packages[@]}" -gt 0 ] || [ "${#existing_commands[@]}" -gt 0 ]; } &&
     [ "$REPLACE_EXISTING_RUNTIME" -ne 1 ]; then
    [ "${#existing_packages[@]}" -eq 0 ] || print_err "检测到已有容器运行时软件包：${existing_packages[*]}"
    [ "${#existing_commands[@]}" -eq 0 ] || print_err "检测到已有容器运行时命令：${existing_commands[*]}"
    print_err "为避免中断已有容器，Docker 模块已停止。确认需要替换时请添加 --replace-existing-runtime。"
    return 1
  fi
  apt_install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  key_tmp="$(mktemp)"
  if ! curl --connect-timeout 15 --retry 3 --retry-delay 2 -fsSL https://download.docker.com/linux/debian/gpg -o "$key_tmp"; then
    rm -f -- "$key_tmp"
    return 1
  fi
  backup_file /etc/apt/keyrings/docker.asc
  install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc
  rm -f -- "$key_tmp"
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  arch="$(dpkg --print-architecture)"
  backup_file /etc/apt/sources.list.d/docker.sources
  cat > /etc/apt/sources.list.d/docker.sources <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER
  apt-get update
  if [ "${#conflict_packages[@]}" -gt 0 ]; then
    apt-get remove -y "${conflict_packages[@]}"
  fi
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl restart docker
  print_ok "Docker Engine 与 Docker Compose 安装完成"
}

print_first_line_safe() {
  local line=""
  while IFS= read -r line; do printf '%s\n' "$line"; return 0; done
  return 0
}

print_execution_report() {
  local report_mode="${1:-run}"
  echo "主机名: $(hostname 2>/dev/null || true)"
  [ -f /etc/os-release ] && echo "系统版本: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
  if command -v timedatectl >/dev/null 2>&1; then
    echo "当前时间: $(timedatectl | grep 'Local time' | sed 's/^[[:space:]]*//' || true)"
    echo "当前时区: $(timedatectl | grep 'Time zone' | sed 's/^[[:space:]]*//' || true)"
  fi
  echo

  if command -v chronyc >/dev/null 2>&1; then
    echo "chrony 状态:"
    systemctl is-active chrony 2>/dev/null || systemctl is-active chronyd 2>/dev/null || true
    chronyc tracking 2>/dev/null | sed -n '1,6p' || true
    echo
  fi

  if command -v sshd >/dev/null 2>&1; then
    echo "SSH 配置摘要:"
    sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication)' || true
    echo
  fi

  if command -v ss >/dev/null 2>&1; then
    echo "SSH 监听端口:"
    ss -tlnp | grep 'sshd' || true
    echo
  fi

  if [ -f /root/.ssh/authorized_keys ] && command -v ssh-keygen >/dev/null 2>&1; then
    echo "root 公钥指纹:"
    ssh-keygen -lf /root/.ssh/authorized_keys || true
    echo
  fi

  if command -v ufw >/dev/null 2>&1; then
    echo "UFW 状态:"
    ufw status verbose || true
    echo
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "Fail2ban 状态:"
    systemctl --no-pager --full status fail2ban 2>/dev/null | sed -n '1,12p' || true
    echo
    echo "Docker 服务状态:"
    systemctl --no-pager --full status docker 2>/dev/null | sed -n '1,12p' || true
    echo
  fi

  echo "systemd journal 状态:"
  journalctl --disk-usage 2>/dev/null || true
  echo "配置上限: ${JOURNAL_MAX_USE}"
  echo

  echo "Docker 版本:"
  docker --version 2>/dev/null || true
  docker compose version 2>/dev/null || true
  echo

  echo "NextTrace / mtr 版本:"
  nexttrace --version 2>/dev/null | print_first_line_safe || true
  mtr --version 2>/dev/null | print_first_line_safe || true
  echo

  echo "IPv6 状态:"
  if kernel_has_ipv6_disable_arg; then
    echo "内核启动参数: ipv6.disable=1（已生效）"
  elif [ "$IPV6_PERSISTENCE_READY" -eq 1 ]; then
    echo "内核启动参数: ipv6.disable=1（已写入，等待重启）"
  else
    echo "内核启动参数: 未确认持久化"
  fi
  if [ -d /proc/sys/net/ipv6/conf ]; then
    local ipv6_setting ipv6_iface
    for ipv6_setting in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
      [ -e "$ipv6_setting" ] || continue
      ipv6_iface="${ipv6_setting#/proc/sys/net/ipv6/conf/}"
      ipv6_iface="${ipv6_iface%/disable_ipv6}"
      printf '%s.disable_ipv6=%s\n' "$ipv6_iface" "$(<"$ipv6_setting")"
    done
  fi
  if command -v ip >/dev/null 2>&1; then
    echo "全局 IPv6 地址:"
    ip -6 -o address show scope global 2>/dev/null || true
    echo "IPv6 默认路由:"
    ip -6 route show default 2>/dev/null || true
  fi
  echo

  echo "BBR + fq 状态:"
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
  lsmod 2>/dev/null | grep '^tcp_bbr' || true
  echo

  echo "已安装常用工具版本:"
  local cmd
  for cmd in curl wget git sudo iperf3 nexttrace mtr; do
    if command -v "$cmd" >/dev/null 2>&1; then
      "$cmd" --version 2>/dev/null | print_first_line_safe || true
    fi
  done
  echo
  if [ "${#UFW_ALLOWED_SSH_PORTS[@]}" -gt 0 ]; then
    printf '本次确认放行的 SSH 端口:'
    printf ' %s/tcp' "${UFW_ALLOWED_SSH_PORTS[@]}"
    printf '\n'
    echo "已有 UFW 规则已保留。"
  else
    echo "本次未配置 UFW 放行规则。"
  fi
  echo "日志文件: ${LOGFILE}"
  echo
  print_warn "注意: 跳过某模块只代表本次不改动；不会自动恢复该模块以前写入过的系统配置。"
  print_warn "注意: Docker 对外发布的容器端口可能绕过 UFW 规则；部署容器时请额外检查 ports 或 -p 暴露策略。"
  if is_yes "$ENABLE_DISABLE_IPV6"; then
    print_warn "注意: 本脚本已关闭 IPv6；如云厂商网络或应用依赖 IPv6，请先确认不会受影响。"
    if [ "$IPV6_REBOOT_REQUIRED" -eq 1 ]; then
      print_warn "注意: ipv6.disable=1 已写入 GRUB；请在方便时重启，并在重启后重新运行状态检查。"
    fi
  fi
  if [ "$report_mode" = "status" ]; then
    print_ok "状态检查完成"
  else
    print_ok "初始化配置完成"
  fi
}

print_status() {
  print_section "当前系统状态"
  print_execution_report status
}

print_dry_run() {
  print_section "模拟执行"
  printf '运行模式: %s\n' "$MODE"
  local title enabled
  for title in \
    "1) 更新系统软件包" \
    "2) 安装常用工具" \
    "2.5) 安装 NextTrace 和 mtr" \
    "3) 开启 BBR + fq" \
    "4) 配置 SSH 安全基线" \
    "5) 安装并配置 UFW 防火墙" \
    "6) 安装并配置 Fail2ban" \
    "6.5) 限制 systemd journal 日志大小" \
    "7) 设置系统时区并安装启用 chrony" \
    "7.4) 关闭 IPv6" \
    "8) 安装 Docker Engine 与 Docker Compose"; do
    case "$title" in
      "1)"*) enabled="$ENABLE_SYSTEM_UPDATE" ;;
      "2)"*) enabled="$ENABLE_COMMON_TOOLS" ;;
      "2.5)"*) enabled="$ENABLE_NEXTTRACE_MTR" ;;
      "3)"*) enabled="$ENABLE_BBR" ;;
      "4)"*) enabled="$ENABLE_SSH_BASELINE" ;;
      "5)"*) enabled="$ENABLE_UFW" ;;
      "6) 安装"*) enabled="$ENABLE_FAIL2BAN" ;;
      "6.5)"*) enabled="$ENABLE_JOURNAL_LIMIT" ;;
      "7)"*) enabled="$ENABLE_TIMEZONE" ;;
      "7.4)"*) enabled="$ENABLE_DISABLE_IPV6" ;;
      "8)"*) enabled="$ENABLE_DOCKER" ;;
    esac
    printf '%-42s %s\n' "$title" "$(state_text "$enabled")"
  done
}

parse_args "$@"
require_explicit_non_interactive
if [ "$RESTORE_IPV6_ONLY" -eq 1 ]; then
  if [ "$RESTORE_ONLY" -eq 1 ] || [ "$CHECK_ONLY" -eq 1 ] || [ "$STATUS_ONLY" -eq 1 ]; then
    print_err "--restore-ipv6 不能与 --restore、--check 或 --status 同时使用。"
    exit 2
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    print_section "模拟执行：只恢复 IPv6"
    echo "撤销 IPv6 禁用配置，恢复 UFW 的 IPv6 支持，重新启用 IPv6 并恢复地址和路由。"
    echo "若当前内核使用 ipv6.disable=1 启动，配置恢复后需要重启。"
    exit 0
  fi
  require_root
  prepare_logfile
  acquire_run_lock
  exec > >(tee -a "$LOGFILE") 2>&1
  trap 'on_err ${LINENO} "$BASH_COMMAND"' ERR
  trap 'on_exit $?' EXIT
  print_section "只恢复 IPv6"
  configure_restore_ipv6
  exit $?
fi
normalize_all_booleans
prompt_mode_selection
apply_mode_defaults
apply_environment_overrides
apply_cli_overrides
normalize_all_booleans
validate_config

if [ "$STATUS_ONLY" -eq 1 ]; then
  require_root
  print_status
  exit 0
fi
if [ "$CHECK_ONLY" -eq 1 ]; then
  require_root
  check_runtime_environment
  exit $?
fi
if [ "$DRY_RUN" -eq 1 ]; then
  print_dry_run
  exit 0
fi
if [ "$RESTORE_ONLY" -eq 1 ]; then
  require_root
  prepare_logfile
  acquire_run_lock
  restore_latest_backup
  exit $?
fi

require_root
prepare_logfile
acquire_run_lock
exec > >(tee -a "$LOGFILE") 2>&1
trap 'on_err ${LINENO} "$BASH_COMMAND"' ERR
trap 'on_exit $?' EXIT

export DEBIAN_FRONTEND=noninteractive
check_runtime_environment

if [ "$MODE" = "custom" ]; then
  prompt_configuration
fi
apply_cli_overrides
normalize_all_booleans
validate_config
print_config_summary

run_step "1) 更新系统软件包" "$ENABLE_SYSTEM_UPDATE" update_system_packages
run_step "2) 安装常用工具" "$ENABLE_COMMON_TOOLS" install_common_tools
run_step "2.5) 安装 NextTrace 和 mtr" "$ENABLE_NEXTTRACE_MTR" install_nexttrace_mtr
run_step "3) 开启 BBR + fq" "$ENABLE_BBR" configure_bbr_fq
run_step "4) 配置 SSH 安全基线" "$ENABLE_SSH_BASELINE" configure_ssh_baseline
run_step "5) 安装并配置 UFW 防火墙" "$ENABLE_UFW" configure_ufw_firewall
run_step "6) 安装并配置 Fail2ban" "$ENABLE_FAIL2BAN" configure_fail2ban
run_step "6.5) 限制 systemd journal 日志大小" "$ENABLE_JOURNAL_LIMIT" configure_journald_limit
run_step "7) 设置系统时区并安装启用 chrony" "$ENABLE_TIMEZONE" configure_timezone
run_step "7.4) 关闭 IPv6" "$ENABLE_DISABLE_IPV6" configure_disable_ipv6
run_step "8) 安装 Docker Engine 与 Docker Compose" "$ENABLE_DOCKER" install_docker_engine

print_section "9) 输出执行结果"
print_execution_report
