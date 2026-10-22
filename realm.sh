#!/usr/bin/env bash
# Realm deploy manager: beginner-friendly TCP + UDP forwarding manager.
set -Eeuo pipefail
umask 077

SERVICE_NAME=realm-deploy
ETC_DIR="${RLM_ETC_DIR:-/etc/realm-deploy}"
OPT_DIR="${RLM_OPT_DIR:-/opt/realm-deploy}"
ENTRY="${RLM_ENTRY:-/usr/local/bin/rnode}"
HELPER_TARGET="${RLM_HELPER_TARGET:-/usr/local/lib/realm-deploy/realm-data.py}"
CORE_LINK="${RLM_CORE_LINK:-/usr/local/bin/realm-deploy-core}"
UNIT_FILE="${RLM_UNIT_FILE:-/etc/systemd/system/realm-deploy.service}"
OPENRC_FILE="${RLM_OPENRC_FILE:-/etc/init.d/realm-deploy}"
LOG_FILE="${RLM_LOG_FILE:-/var/log/realm-deploy.log}"
STATE="$ETC_DIR/rules.json"
CONFIG="$ETC_DIR/config.toml"
BACKUPS="$ETC_DIR/backups"
VERSIONS="$OPT_DIR/versions"
SOURCE_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_TOOL="${RLM_DATA_TOOL:-$SOURCE_DIR/realm-data.py}"
[[ -f "$DATA_TOOL" ]] || DATA_TOOL="$HELPER_TARGET"
INIT_SYSTEM=''
DISTRO_NAME=unknown
API='https://api.github.com/repos/zhboner/realm/releases'

say() { printf '%s\n' "$*"; }
info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { warn "$*"; return 1; }
data() { python3 "$DATA_TOOL" "$@"; }

color() {
  if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
    printf '\033[%sm%s\033[0m\n' "$1" "$2"
  else
    say "$2"
  fi
}
title() { say ''; color '1;36' "━━━━━━━━━━ $* ━━━━━━━━━━"; say ''; }
item() { printf '  %s）%s\n' "$1" "$2"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail '请使用 root，或在命令前加 sudo。'; }

detect_system() {
  local pid1=''
  [[ $(uname -s) == Linux ]] || { fail '本工具用于 Linux VPS，不能直接在 Windows / macOS 上部署。'; return 1; }
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_NAME="${PRETTY_NAME:-${ID:-unknown}}"
  fi
  [[ ! -r /proc/1/comm ]] || IFS= read -r pid1 < /proc/1/comm || true
  case "${RLM_INIT_SYSTEM:-}" in
    systemd|openrc) INIT_SYSTEM="$RLM_INIT_SYSTEM" ;;
    '')
      if [[ "$pid1" == systemd || -d /run/systemd/system ]]; then INIT_SYSTEM=systemd
      elif [[ "$pid1" == openrc-init || -d /run/openrc ]]; then INIT_SYSTEM=openrc
      else INIT_SYSTEM=unsupported
      fi ;;
    *) fail 'RLM_INIT_SYSTEM 只接受 systemd 或 openrc。'; return 1 ;;
  esac
}

need_service_manager() {
  case "$INIT_SYSTEM" in
    systemd) command -v systemctl >/dev/null || { fail '找不到 systemctl。'; return 1; } ;;
    openrc)
      if ! command -v rc-service >/dev/null || ! command -v rc-update >/dev/null; then
        fail '找不到 OpenRC 的 rc-service / rc-update。'; return 1;
      fi ;;
    *) fail '未检测到 systemd / OpenRC。请使用正常启动的 Linux VPS；普通 Docker 容器不在支持范围内。'; return 1 ;;
  esac
}

ensure_dependencies() {
  local command_name package manager=''
  local -a missing=() packages=(ca-certificates)
  for command_name in python3 curl tar gzip flock; do
    command -v "$command_name" >/dev/null || missing+=("$command_name")
  done
  if ((${#missing[@]})); then
    [[ "${RLM_SKIP_DEP_INSTALL:-0}" != 1 ]] || { fail "缺少依赖：${missing[*]}"; return 1; }
    if command -v apt-get >/dev/null; then manager=apt
    elif command -v dnf >/dev/null; then manager=dnf
    elif command -v yum >/dev/null; then manager=yum
    elif command -v apk >/dev/null; then manager=apk
    elif command -v zypper >/dev/null; then manager=zypper
    elif command -v pacman >/dev/null; then manager=pacman
    else fail "无法自动安装依赖，请手动安装：${missing[*]} 以及 ca-certificates。"; return 1
    fi
    for command_name in "${missing[@]}"; do
      package="$command_name"
      [[ "$command_name" != flock ]] || package=util-linux
      packages+=("$package")
    done
    info "正在安装必要工具：${missing[*]}。请等待软件包管理器完成。"
    case "$manager" in
      apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" || return 1 ;;
      dnf|yum) "$manager" install -y "${packages[@]}" || return 1 ;;
      apk) apk add --no-cache "${packages[@]}" || return 1 ;;
      zypper) zypper --non-interactive install "${packages[@]}" || return 1 ;;
      pacman) pacman -S --noconfirm --needed "${packages[@]}" || return 1 ;;
    esac
  fi
  for command_name in python3 curl tar gzip flock; do
    command -v "$command_name" >/dev/null || { fail "仍缺少 $command_name，请检查系统软件源。"; return 1; }
  done
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || {
    fail '需要 Python 3.9 或更新版本，推荐使用 Debian 12 / Ubuntu 22.04 及更新系统。'; return 1;
  }
  if [[ ! -f "$DATA_TOOL" ]] || ! grep -Fq '# Realm deploy data:' "$DATA_TOOL"; then
    fail '未找到配套 realm-data.py。请重新执行 README 中的一键安装命令，或从完整文件夹运行 sh install.sh。'; return 1;
  fi
}

check_paths() {
  local path
  for path in "$ETC_DIR" "$OPT_DIR" "$ENTRY" "$HELPER_TARGET" "$CORE_LINK" "$UNIT_FILE" "$OPENRC_FILE" "$LOG_FILE"; do
    [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ && "$path" != / && "$path" != */../* && "$path" != */.. ]] || {
      fail "安装路径必须为普通的绝对路径：$path"; return 1;
    }
  done
  [[ "$ETC_DIR" != "$OPT_DIR" ]] || { fail '配置目录和内核目录必须不同。'; return 1; }
}

owned_dir() {
  local directory="$1"
  [[ ! -L "$directory" ]] || { fail "目录是符号链接，拒绝写入：$directory"; return 1; }
  if [[ -e "$directory" ]]; then
    [[ -d "$directory" ]] || { fail "同名路径不是目录：$directory"; return 1; }
    if [[ ! -f "$directory/.realm-deploy-managed" ]]; then
      [[ -z $(ls -A "$directory") ]] || { fail "目录已有其他文件，拒绝接管：$directory"; return 1; }
    else
      if [[ -L "$directory/.realm-deploy-managed" ]] || ! grep -Fxq 'RLM-MANAGED: realm-deploy' "$directory/.realm-deploy-managed"; then
        fail "目录管理标记不匹配：$directory"; return 1;
      fi
    fi
  fi
  mkdir -p "$directory" || return 1
  chmod 700 "$directory" || return 1
  printf '%s\n' 'RLM-MANAGED: realm-deploy' > "$directory/.realm-deploy-managed" || return 1
}

init_data() {
  local path allow_broken="${1:-0}"
  check_paths || return 1
  owned_dir "$ETC_DIR" && owned_dir "$OPT_DIR" || return 1
  for path in "$BACKUPS" "$VERSIONS" "$STATE" "$CONFIG" "$ETC_DIR/.lock"; do
    [[ ! -L "$path" ]] || { fail "发现符号链接，拒绝写入：$path"; return 1; }
  done
  mkdir -p "$BACKUPS" "$VERSIONS" || return 1
  chmod 700 "$BACKUPS" || return 1
  # 锁由管理进程持有。调用服务管理器和内核时关闭 FD 9，避免后台进程继承锁。
  exec 9>"$ETC_DIR/.lock"
  flock -n 9 || { fail '另一个 rnode 管理窗口正在操作，请先退出那个窗口。'; return 1; }
  if [[ ! -e "$STATE" ]]; then data init "$STATE" || return 1; fi
  if ! data validate "$STATE"; then
    if [[ "$allow_broken" == 1 ]]; then
      warn '当前规则损坏；本次只允许用指定的有效 JSON 备份恢复。'
    else
      fail "现有规则文件损坏。请执行 sudo rnode restore $BACKUPS/有效备份.json 恢复。"; return 1
    fi
  elif [[ ! -e "$CONFIG" ]]; then data render "$STATE" "$CONFIG" || return 1
  fi
}

managed_file() {
  local file="$1" marker="$2"
  [[ ! -e "$file" && ! -L "$file" ]] && return 0
  if [[ ! -f "$file" || -L "$file" ]] || ! grep -Fq "$marker" "$file"; then
    fail "同名文件不属于本工具，拒绝覆盖或删除：$file"; return 1;
  fi
}

check_core_link() {
  local target=''
  [[ -e "$CORE_LINK" || -L "$CORE_LINK" ]] || return 0
  [[ -L "$CORE_LINK" ]] || { fail "同名内核路径已被其他文件占用：$CORE_LINK"; return 1; }
  target=$(readlink "$CORE_LINK") || return 1
  [[ "$target" == "$VERSIONS/"*/realm && "$target" != */../* ]] || {
    fail "内核链接不属于本工具，拒绝更改：$CORE_LINK"; return 1;
  }
}

install_service() {
  local service_tmp
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    managed_file "$UNIT_FILE" '# RLM-MANAGED: realm-deploy' || return 1
    mkdir -p "$(dirname "$UNIT_FILE")" || return 1
    service_tmp=$(mktemp "$(dirname "$UNIT_FILE")/.realm-service.XXXXXX") || return 1
    if ! cat > "$service_tmp" <<EOF
# RLM-MANAGED: realm-deploy
[Unit]
Description=Realm TCP and UDP forwarding (rnode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="$CORE_LINK" -c "$CONFIG"
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
    then rm -f "$service_tmp"; return 1
    fi
    if ! { chmod 644 "$service_tmp" && mv -f "$service_tmp" "$UNIT_FILE"; }; then rm -f "$service_tmp"; return 1; fi
    systemctl daemon-reload 9>&- || return 1
  else
    managed_file "$OPENRC_FILE" '# RLM-MANAGED: realm-deploy' || return 1
    [[ ! -L "$LOG_FILE" ]] || { fail "日志路径不能是符号链接：$LOG_FILE"; return 1; }
    mkdir -p "$(dirname "$OPENRC_FILE")" "$(dirname "$LOG_FILE")" || return 1
    service_tmp=$(mktemp "$(dirname "$OPENRC_FILE")/.realm-service.XXXXXX") || return 1
    if ! cat > "$service_tmp" <<EOF
#!/sbin/openrc-run
# RLM-MANAGED: realm-deploy
description="Realm TCP and UDP forwarding (rnode)"
command="$CORE_LINK"
command_args="-c $CONFIG"
supervisor="supervise-daemon"
pidfile="/run/realm-deploy.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"
respawn_delay=3
respawn_max=5
respawn_period=60
depend() {
  need net
  after firewall
}
EOF
    then rm -f "$service_tmp"; return 1
    fi
    if ! { chmod 755 "$service_tmp" && mv -f "$service_tmp" "$OPENRC_FILE"; }; then rm -f "$service_tmp"; return 1; fi
  fi
}

service_exists() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then [[ -f "$UNIT_FILE" ]]; else [[ -f "$OPENRC_FILE" ]]; fi
}
service_active() {
  service_exists || return 1
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl is-active --quiet "$SERVICE_NAME.service" 9>&-
  else rc-service "$SERVICE_NAME" status >/dev/null 2>&1 9>&-
  fi
}
service_enabled() {
  service_exists || return 1
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl is-enabled --quiet "$SERVICE_NAME.service" 9>&-
  else rc-update show default 2>/dev/null 9>&- | awk '$1 == "realm-deploy" { found=1 } END { exit !found }'
  fi
}
service_enable() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl enable "$SERVICE_NAME.service" 9>&-
  else rc-update add "$SERVICE_NAME" default 9>&-
  fi
}
service_disable() {
  service_exists || return 0
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl disable "$SERVICE_NAME.service" 9>&-
  elif service_enabled; then rc-update del "$SERVICE_NAME" default 9>&-
  fi
}
service_stop() {
  service_exists || return 0
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl stop "$SERVICE_NAME.service" 9>&-
  elif service_active; then rc-service "$SERVICE_NAME" stop 9>&-
  fi
}
service_restart() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl restart "$SERVICE_NAME.service" 9>&-
  else
    service_stop || return 1
    rc-service "$SERVICE_NAME" start 9>&-
  fi
}

wait_service() {
  local attempt
  # 先给崩溃、配置解析错误留出时间，再检查 TCP 和 UDP 监听是否都已建立。
  for ((attempt=0; attempt<5; attempt++)); do
    sleep 1
    if service_active && data listening "$STATE"; then return 0; fi
  done
  fail '服务没有正常建立全部 TCP / UDP 监听，请查看 rnode logs。'
}

show_logs() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    journalctl -u "$SERVICE_NAME.service" -n 60 --no-pager 9>&-
  elif [[ -f "$LOG_FILE" ]]; then tail -n 60 "$LOG_FILE"
  else say '还没有运行日志。请先创建规则并启动服务。'
  fi
}

fetch() {
  curl --proto '=https' --tlsv1.2 -fLsS --retry 2 --connect-timeout 10 --max-time 180 -o "$2" "$1"
}

install_core() (
  local requested="${1:-latest}" temporary tag url asset expected manifest member target old='' link_tmp detected
  local was_active=0 changed=0 done=0
  local -a release_info=()
  check_core_link || exit 1
  managed_file "$UNIT_FILE" '# RLM-MANAGED: realm-deploy' || exit 1
  managed_file "$OPENRC_FILE" '# RLM-MANAGED: realm-deploy' || exit 1
  if [[ "$requested" != latest ]]; then
    data field version "$requested" >/dev/null || exit 1
    requested="v${requested#v}"
  fi
  temporary=$(mktemp -d "$OPT_DIR/.download.XXXXXX") || exit 1
  link_tmp="${CORE_LINK}.new.$$"
  cleanup_core() {
    local result=$?
    trap - EXIT
    if ((changed && !done)); then
      warn '新内核未能启动，正在恢复原来的内核。'
      if [[ -n "$old" ]]; then
        if ! { ln -s "$old" "$link_tmp" && mv -f "$link_tmp" "$CORE_LINK"; }; then warn '恢复内核链接失败，请检查磁盘权限。'; fi
        (( !was_active )) || service_restart || warn '旧内核重新启动失败，请查看日志。'
      else
        rm -f "$CORE_LINK"
      fi
    fi
    rm -f "$link_tmp"
    rm -rf "$temporary"
    return "$result"
  }
  trap cleanup_core EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  info '正在查询 zhboner/realm 官方发布版本……'
  if [[ "$requested" == latest ]]; then url="$API/latest"; else url="$API/tags/$requested"; fi
  fetch "$url" "$temporary/release.json" || {
    fail '无法访问 GitHub。请检查 VPS 的 DNS、网络和 GitHub API 限流情况，原配置已保留。'; exit 1;
  }
  data release "$temporary/release.json" "$(uname -m)" > "$temporary/release-info" || exit 1
  mapfile -t release_info < "$temporary/release-info"
  tag="${release_info[0]}"; url="${release_info[1]}"; asset="${release_info[2]}"
  expected="${release_info[3]}"; manifest="${release_info[4]}"
  target="$VERSIONS/$tag/realm"
  if [[ ! -x "$target" ]]; then
    info "正在下载 Realm $tag：$asset"
    fetch "$url" "$temporary/realm.tar.gz" || { fail '内核下载失败，请稍后重试。'; exit 1; }
    if [[ -z "$expected" && -n "$manifest" ]]; then
      fetch "$manifest" "$temporary/checksums" || exit 1
      expected=$(data checksum "$temporary/checksums" "$asset") || exit 1
    fi
    if [[ -n "$expected" ]]; then
      [[ "$(data sha256 "$temporary/realm.tar.gz")" == "${expected,,}" ]] || {
        fail 'SHA256 校验失败，下载文件已丢弃，没有替换当前内核。'; exit 1;
      }
      info '安装包 SHA256 校验通过。'
    else
      warn '该官方版本没有提供 SHA256；本次只能确认通过 HTTPS 下载，无法进行官方哈希校验。'
    fi
    tar -tzf "$temporary/realm.tar.gz" > "$temporary/members" || exit 1
    member=$(data archive-member "$temporary/members") || exit 1
    tar -xOzf "$temporary/realm.tar.gz" -- "$member" > "$temporary/realm" || exit 1
    [[ -s "$temporary/realm" ]] || { fail '安装包中的 realm 文件为空。'; exit 1; }
    chmod 755 "$temporary/realm" || exit 1
    detected=$("$temporary/realm" --version 9>&-) || { fail '内核无法执行，可能是 CPU / 系统库不兼容。'; exit 1; }
    [[ "$detected" =~ ^[Rr]ealm[[:space:]]+[0-9]+\. ]] || { fail '内核没有返回有效的 Realm 版本信息。'; exit 1; }
    info "内核可执行：$detected"
    mkdir -p "$VERSIONS/$tag" || exit 1
    mv -f "$temporary/realm" "$target" || exit 1
  else
    "$target" --version >/dev/null 9>&- || { fail '已缓存的内核无法执行。'; exit 1; }
  fi
  install_service || exit 1
  [[ ! -L "$CORE_LINK" ]] || old=$(readlink "$CORE_LINK")
  if service_active; then was_active=1; fi
  mkdir -p "$(dirname "$CORE_LINK")" || exit 1
  ln -s "$target" "$link_tmp" || exit 1
  # 先记录回滚状态；信号在 mv 前到达时恢复旧链接也不会影响旧内核。
  changed=1
  mv -f "$link_tmp" "$CORE_LINK" || exit 1
  if ((was_active)); then
    if ! { service_restart && wait_service; }; then show_logs >&2 || true; exit 1; fi
  fi
  done=1
  info "Realm $tag 已安装。已有规则保持不变。"
)

ensure_core() {
  check_core_link || return 1
  if [[ ! -x "$CORE_LINK" ]]; then
    info '首次使用会自动安装 Realm 官方最新正式版。'
    install_core latest || return 1
  else
    install_service || return 1
  fi
}

backup_state() {
  local destination
  destination=$(mktemp "$BACKUPS/$(date +%Y%m%d-%H%M%S)-XXXXXX.json") || return 1
  if ! cp "$STATE" "$destination"; then rm -f "$destination"; return 1; fi
  chmod 600 "$destination" || return 1
  printf '%s\n' "$destination"
}

apply_state() (
  local candidate="$1" recovery="${2:-0}" temporary active=0 enabled=0 committed=0 done=0 count
  data validate "$candidate" || exit 1
  if [[ "$recovery" != 1 ]]; then data check-ports "$candidate" "$STATE" || exit 1; fi
  temporary=$(mktemp -d "$ETC_DIR/.apply.XXXXXX") || exit 1
  cleanup_apply() {
    local result=$?
    trap - EXIT
    if ((committed && !done)); then
      warn '应用失败，正在恢复修改前的规则和服务状态。'
      if ! { cp "$temporary/old-state" "$STATE" && cp "$temporary/old-config" "$CONFIG"; }; then warn '恢复文件失败，请使用 backups 目录中的备份。'; fi
      if ((enabled)); then service_enable || warn '恢复开机自启失败。'; else service_disable || true; fi
      if ((active)); then service_restart || warn '恢复服务失败，请查看 rnode logs。'; else service_stop || true; fi
    fi
    rm -rf "$temporary"
    return "$result"
  }
  trap cleanup_apply EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  cp "$STATE" "$temporary/old-state" || exit 1
  if [[ -f "$CONFIG" ]]; then cp "$CONFIG" "$temporary/old-config" || exit 1
  else : > "$temporary/old-config"
  fi
  cp "$candidate" "$temporary/new-state" && data render "$candidate" "$temporary/new-config" || exit 1
  backup_state >/dev/null || { fail '无法保存备份，没有修改现有规则。'; exit 1; }
  if service_active; then active=1; fi
  if service_enabled; then enabled=1; fi
  count=$(data count "$candidate" enabled) || exit 1
  committed=1
  mv -f "$temporary/new-state" "$STATE" && mv -f "$temporary/new-config" "$CONFIG" || exit 1
  if ((count)); then
    if ! { service_enable && service_restart && wait_service; }; then show_logs >&2 || true; exit 1; fi
  else
    service_stop && service_disable || exit 1
  fi
  done=1
  info '规则已保存并生效，修改前的 JSON 已自动备份。'
)

prompt() {
  local destination="$1" label="$2" fallback="$3" kind="$4" answer normalized
  while :; do
    if [[ -n "$fallback" ]]; then
      IFS= read -r -p "$label [$fallback]：" answer || return 2
    else
      IFS= read -r -p "$label：" answer || return 2
    fi
    [[ "$answer" != q && "$answer" != Q ]] || return 2
    answer="${answer:-$fallback}"
    if normalized=$(data field "$kind" "$answer"); then
      printf -v "$destination" '%s' "$normalized"
      return 0
    fi
  done
}

confirm() {
  local answer
  IFS= read -r -p "$1 [y/N]：" answer || return 1
  [[ "$answer" == y || "$answer" == Y || "$answer" == 是 ]]
}

choose_rule() {
  local selected
  data list "$STATE" >&2 || return 1
  [[ $(data count "$STATE") != 0 ]] || return 2
  while :; do
    IFS= read -r -p '输入左侧规则编号（0 返回）：' selected || return 2
    [[ "$selected" != 0 && "$selected" != q ]] || return 2
    if data get "$STATE" "$selected" >/dev/null; then say "$selected"; return 0; fi
  done
}

rule_wizard() {
  local rule_id="${1:-}" mode="${2:-quick}" rule_name='' listen_host=0.0.0.0 listen_port='' remote_host='' remote_port=''
  local public_host='' public_port='' enabled=true temporary suggested
  local -a fields=()
  if [[ -n "$rule_id" ]]; then
    mode=custom
    temporary=$(mktemp "$ETC_DIR/.fields.XXXXXX") || return 1
    if ! data get "$STATE" "$rule_id" > "$temporary"; then rm -f "$temporary"; return 1; fi
    mapfile -t fields < "$temporary"
    rm -f "$temporary"
    rule_name="${fields[0]}"; listen_host="${fields[1]}"; listen_port="${fields[2]}"
    remote_host="${fields[3]}"; remote_port="${fields[4]}"; public_host="${fields[5]}"
    public_port="${fields[6]}"; enabled="${fields[7]}"
    title "修改规则 #$rule_id"
  else
    rule_id=$(data next-id "$STATE") || return 1
    rule_name="转发-$rule_id"
    if [[ "$mode" == custom ]]; then title '自定义创建转发（NAT / IPv6 / 名称）'
    else title '快速创建转发（普通 VPS）'
    fi
  fi
  say '  入口 = 当前这台转发服务器；目标 = 已经运行节点或其他服务的服务器。'
  say '  例如：客户端 → 入口:20000 → 目标:443。两边端口可以不同。'
  say '  每一步输入 q 都可以取消，直接回车采用方括号中的默认值。'
  if [[ "$mode" == quick ]]; then
    say '  只需填写下面 4 项，名称自动生成；NAT / IPv6 请到主菜单 7 → 4。'
  fi
  say ''
  prompt remote_host '目标服务器 IP / 域名（不带端口和 https://）' "$remote_host" host || return 0
  prompt remote_port '目标服务端口（就是原节点的端口）' "$remote_port" port || return 0
  if [[ "$mode" == custom ]]; then
    prompt listen_host '本机监听 IP（0.0.0.0 接受所有 IPv4；:: 用于 IPv6）' "$listen_host" listen || return 0
  fi
  suggested="$listen_port"
  [[ -n "$suggested" ]] || suggested=$(data auto-port "$STATE" "$listen_host") || return 1
  prompt listen_port '入口服务器本机监听端口（回车使用空闲端口）' "$suggested" port || return 0
  if ((${#fields[@]})) && [[ "$public_port" == "${fields[2]}" ]]; then public_port="$listen_port"; fi
  say '  公网地址通常是 SSH 登录这台服务器时使用的 IP / 域名；也可以稍后补填。'
  prompt public_host '入口公网 IP / 域名（可以留空）' "$public_host" public || return 0
  if [[ "$mode" == custom ]]; then
    prompt public_port '入口公网端口（普通 VPS 直接回车；NAT 填服务商分配的公网端口）' "${public_port:-$listen_port}" port || return 0
    prompt rule_name '给这条规则起个名称' "$rule_name" name || return 0
  else
    public_port="$listen_port"
  fi
  temporary=$(mktemp "$ETC_DIR/.rule.XXXXXX") || return 1
  if ! data put "$STATE" "$temporary" "$rule_id" "$rule_name" "$listen_host" "$listen_port" "$remote_host" "$remote_port" "$public_host" "$public_port" "$enabled"; then
    rm -f "$temporary"; return 1
  fi
  data show "$temporary" "$rule_id" || { rm -f "$temporary"; return 1; }
  say ''
  if ! confirm '确认保存并应用？已有转发可能会短暂重连'; then rm -f "$temporary"; say '已取消，没有保存。'; return 0; fi
  if ! data check-ports "$temporary" "$STATE"; then rm -f "$temporary"; return 1; fi
  if [[ $(data count "$temporary" enabled) != 0 ]] && ! ensure_core; then rm -f "$temporary"; return 1; fi
  if apply_state "$temporary"; then
    rm -f "$temporary"
    data show "$STATE" "$rule_id"
    say ''
    say '  下一步：1. 按上面的端口放行防火墙和服务商安全组。'
    say '          2. 在客户端复制一份原节点，修改“服务器地址”和“服务器端口”，其他参数保持原样。'
  else rm -f "$temporary"; return 1
  fi
}

change_rule() {
  local action="$1" rule_id="$2" temporary
  if [[ "$action" == remove ]]; then
    data show "$STATE" "$rule_id" || return 1
    confirm '确认删除这条规则？对应连接会中断' || return 0
  fi
  temporary=$(mktemp "$ETC_DIR/.change.XXXXXX") || return 1
  if ! data "$action" "$STATE" "$temporary" "$rule_id"; then rm -f "$temporary"; return 1; fi
  if [[ $(data count "$temporary" enabled) != 0 ]] && ! ensure_core; then rm -f "$temporary"; return 1; fi
  if apply_state "$temporary"; then rm -f "$temporary"; else rm -f "$temporary"; return 1; fi
}

rule_menu() {
  local rule_id choice
  rule_id=$(choose_rule) || return 0
  while :; do
    title "管理规则 #$rule_id"
    data show "$STATE" "$rule_id" || return 1
    say ''
    item 1 '修改地址 / 端口 / 名称 / 监听 IP'
    item 2 '启用 / 停用当前规则'
    item 3 '删除当前规则'
    item 0 '返回主菜单'
    IFS= read -r -p '请选择 [0-3]：' choice || return 0
    case "$choice" in
      1) rule_wizard "$rule_id" || true ;;
      2) change_rule toggle "$rule_id" || true ;;
      3) change_rule remove "$rule_id" || return 1
         data get "$STATE" "$rule_id" >/dev/null 2>&1 || return 0 ;;
      0) return 0 ;;
      *) warn '请输入 0～3。' ;;
    esac
  done
}

status() {
  title '服务状态'
  say "系统：$DISTRO_NAME；服务管理器：$INIT_SYSTEM"
  if [[ -x "$CORE_LINK" ]]; then "$CORE_LINK" --version 9>&- || true; else say 'Realm 内核：尚未安装（创建规则时自动安装）。'; fi
  if service_active; then say '运行状态：运行中'; else say '运行状态：已停止 / 尚未创建服务'; fi
  if service_enabled; then say '开机自启：开启'; else say '开机自启：关闭'; fi
  say "规则数量：$(data count "$STATE")；启用数量：$(data count "$STATE" enabled)"
  data list "$STATE"
}

start_service() {
  [[ $(data count "$STATE" enabled) != 0 ]] || { fail '没有启用的规则，请先创建规则或在“管理规则”中启用一条。'; return 1; }
  ensure_core || return 1
  apply_state "$STATE"
}

stop_service() {
  service_stop && service_disable || return 1
  info '全部转发已停止，开机自启已关闭。规则保留，执行 rnode start 可以恢复。'
}

diagnose() {
  status || return 1
  say ''
  [[ $(data count "$STATE" enabled) != 0 ]] || { fail '没有启用的规则，请先创建或启用规则。'; return 1; }
  data diagnose "$STATE"
}

service_menu() {
  local choice
  while :; do
    title '服务管理'
    item 1 '查看运行状态'
    item 2 '启动 / 重启服务，并开启开机自启'
    item 3 '停止全部转发，并关闭开机自启（保留规则）'
    item 4 '查看最近 60 条日志'
    item 5 '诊断连接问题'
    item 0 '返回主菜单'
    IFS= read -r -p '请选择 [0-5]：' choice || return 0
    case "$choice" in
      1) status || true ;;
      2) start_service || true ;;
      3) if confirm '确认停止全部转发'; then stop_service || true; fi ;;
      4) show_logs || true ;;
      5) diagnose || true ;;
      0) return 0 ;;
      *) warn '请输入 0～5。' ;;
    esac
  done
}

restore_state() {
  local source="$1" recovery=0
  [[ -f "$source" ]] || { fail '没有找到这份 JSON 备份。'; return 1; }
  data validate "$source" && data list "$source" || return 1
  say '恢复会替换当前所有规则；启用的规则会立即启动，恢复前也会自动备份。'
  confirm '确认恢复以上规则' || return 0
  if data validate "$STATE" >/dev/null 2>&1; then data check-ports "$source" "$STATE" || return 1
  else recovery=1
  fi
  if [[ $(data count "$source" enabled) != 0 ]]; then ensure_core || return 1; fi
  apply_state "$source" "$recovery"
}

backup_menu() {
  local choice selected index path
  local -a files=()
  title '备份与恢复'
  item 1 '立即备份规则（JSON）'
  item 2 '选择自动备份恢复'
  item 0 '返回主菜单'
  IFS= read -r -p '请选择 [0-2]：' choice || return 0
  case "$choice" in
    1) path=$(backup_state) && info "备份已保存：$path。请下载到自己电脑保存。" ;;
    2)
      shopt -s nullglob
      files=("$BACKUPS/"*.json)
      shopt -u nullglob
      ((${#files[@]})) || { say '还没有备份。'; return 0; }
      for ((index=${#files[@]}-1; index>=0; index--)); do
        printf '  %s）%s\n' "$((${#files[@]}-index))" "${files[index]##*/}"
      done
      IFS= read -r -p '输入备份序号（0 返回）：' selected || return 0
      [[ "$selected" != 0 ]] || return 0
      if [[ "$selected" =~ ^[0-9]{1,5}$ ]] && ((10#$selected >= 1 && 10#$selected <= ${#files[@]})); then
        restore_state "${files[${#files[@]}-10#$selected]}"
      else fail '备份序号无效。'; return 1
      fi ;;
    0) return 0 ;;
    *) fail '请输入 0～2。' ;;
  esac
}

check_system() {
  local command_name missing_count=0
  detect_system || return 1
  say "Linux 系统：$DISTRO_NAME"
  say "CPU 架构：$(uname -m)；内核包以 Realm 官方实际发布为准。"
  say "服务管理器：$INIT_SYSTEM"
  for command_name in bash python3 curl tar gzip flock; do
    if command -v "$command_name" >/dev/null; then say "[通过] $command_name"
    else warn "缺少 $command_name；安装时将尝试自动补齐。"; missing_count=1
    fi
  done
  need_service_manager || return 1
  (( !missing_count )) || say '请确保系统软件源和 HTTPS 网络可用。'
  say '该检查不下载内核、不修改系统，也不能代替真实部署和客户端测试。'
}

uninstall() {
  local answer backup_copy
  managed_file "$UNIT_FILE" '# RLM-MANAGED: realm-deploy' && managed_file "$OPENRC_FILE" '# RLM-MANAGED: realm-deploy' || return 1
  managed_file "$ENTRY" '# Realm deploy manager:' && managed_file "$HELPER_TARGET" '# Realm deploy data:' || return 1
  check_core_link || return 1
  say '这将停止全部转发，删除本工具的服务、内核、配置、内部备份及 rnode 命令。'
  say '确认后会在配置目录旁保留最后一份规则 JSON；原始下载文件夹保留。'
  IFS= read -r -p '若确定，请完整输入「确认卸载」：' answer || return 1
  [[ "$answer" == 确认卸载 ]] || { say '已取消。'; return 1; }
  backup_copy=$(mktemp "$(dirname "$ETC_DIR")/realm-deploy-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX.json") || return 1
  cp "$STATE" "$backup_copy" && chmod 600 "$backup_copy" || return 1
  service_stop && service_disable || return 1
  rm -f "$UNIT_FILE" "$OPENRC_FILE" "$CORE_LINK" "$ENTRY" "$HELPER_TARGET" || return 1
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl daemon-reload 9>&- || return 1; fi
  rm -rf "$ETC_DIR" "$OPT_DIR" || return 1
  info "卸载完成。最后的规则备份保存在：$backup_copy"
}

advanced_menu() {
  local choice requested
  title '更多功能'
  item 1 '更新 / 切换 Realm 官方内核（保留规则）'
  item 2 '检查系统兼容性'
  item 3 '完全卸载（会要求再次确认）'
  item 4 '自定义创建转发（NAT / IPv6 / 自定义名称）'
  item 0 '返回主菜单'
  IFS= read -r -p '请选择 [0-4]：' choice || return 0
  case "$choice" in
    1)
      IFS= read -r -p '输入版本号，或直接回车使用最新正式版 [latest]：' requested || return 0
      [[ "$requested" != q ]] || return 0
      install_core "${requested:-latest}" ;;
    2) check_system ;;
    3) if uninstall; then return 10; else return 1; fi ;;
    4) rule_wizard '' custom ;;
    0) return 0 ;;
    *) fail '请输入 0～4。' ;;
  esac
}

menu() {
  local choice result rule_id state_text
  while :; do
    title 'Realm 中文转发管理'
    if service_active; then state_text=运行中; else state_text=已停止; fi
    say "  服务：$state_text　规则：$(data count "$STATE")　启用：$(data count "$STATE" enabled)"
    say ''
    color '1;32' '  1）快速创建转发（新手从这里开始）'
    item 2 '查看全部规则'
    item 3 '查看客户端该填的地址 / 端口'
    item 4 '管理规则（修改 / 启用 / 停用 / 删除）'
    item 5 '服务管理（状态 / 启停 / 日志 / 诊断）'
    item 6 '备份 / 恢复'
    item 7 '更多功能（NAT / IPv6 / 更新 / 卸载）'
    item 0 '退出'
    say ''
    say '  新手：选 1 → 填目标地址与端口 → 保存 → 放行入口端口 → 修改客户端。'
    say '  Realm 负责 TCP + UDP 转发；请先准备已经可用的目标服务 / 节点。'
    say ''
    IFS= read -r -p '请选择 [0-7]：' choice || return 0
    case "$choice" in
      1) rule_wizard || true ;;
      2) data list "$STATE" || true ;;
      3) if rule_id=$(choose_rule); then data show "$STATE" "$rule_id" || true; fi ;;
      4) rule_menu || true ;;
      5) service_menu ;;
      6) backup_menu || true ;;
      7)
        if advanced_menu; then :
        else result=$?; [[ "$result" != 10 ]] || return 0
        fi ;;
      0) return 0 ;;
      *) warn '请输入 0～7。' ;;
    esac
  done
}

usage() {
  cat <<'TXT'
Realm 中文转发管理（TCP + UDP）
用法：sudo rnode                     打开中文菜单
      sudo rnode add                 创建转发规则
      sudo rnode list                查看规则
      sudo rnode show [规则编号]      查看客户端连接信息
      sudo rnode status              查看服务状态
      sudo rnode start               启动 / 重启并开启开机自启
      sudo rnode stop                停止并关闭开机自启，保留规则
      sudo rnode logs                查看最近日志
      sudo rnode diagnose            检查本机入口和目标 TCP 连接
      sudo rnode backup              备份规则，输出备份路径
      sudo rnode restore /路径.json  确认后恢复备份
      sudo rnode install [版本号]    安装官方内核，默认 latest
      sudo rnode uninstall           确认后卸载，保留最后一份规则备份
      bash realm.sh check            只读检查，无须 root
      bash realm.sh --help           查看帮助
新手请使用菜单选项 1。推荐 Debian 12 / 13、Ubuntu 22.04 / 24.04。
TXT
}

main() {
  local command_name="${1:-}" rule_id
  case "$command_name" in
    --help|-h|help) usage; return 0 ;;
    check) check_system; return $? ;;
    ''|add|list|show|status|start|stop|logs|diagnose|backup|restore|install|uninstall) ;;
    *) usage; return 1 ;;
  esac
  [[ "$command_name" != restore || $# -eq 2 ]] || { fail '用法：sudo rnode restore /完整路径/备份.json'; return 1; }
  require_root && detect_system && need_service_manager && ensure_dependencies || return 1
  if [[ "$command_name" == restore ]]; then init_data 1 || return 1; else init_data || return 1; fi
  case "$command_name" in
    '') menu ;;
    add) rule_wizard ;;
    list) data list "$STATE" ;;
    show)
      rule_id="${2:-}"
      [[ -n "$rule_id" ]] || rule_id=$(choose_rule) || return 0
      data show "$STATE" "$rule_id" ;;
    status) status ;;
    start) start_service ;;
    stop) stop_service ;;
    logs) show_logs ;;
    diagnose) diagnose ;;
    backup) backup_state ;;
    restore) restore_state "$2" ;;
    install) install_core "${2:-latest}" ;;
    uninstall) uninstall ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
