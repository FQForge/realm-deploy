#!/bin/sh
# Realm deploy installer: install the standalone Shell manager.
set -eu
umask 077

error() { printf '[错误] %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || error '请在 Linux VPS 上运行本安装脚本。'
[ "$(id -u)" -eq 0 ] || error '请使用 sudo sh install.sh，或切换 root 后运行。'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/realm.sh"
[ -f "$SCRIPT" ] || error '请将 install.sh 和 realm.sh 放在同一文件夹。'
grep -Fq '# Realm deploy manager:' "$SCRIPT" || error 'realm.sh 文件标记不匹配。'

if ! command -v bash >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash
  elif command -v dnf >/dev/null 2>&1; then dnf install -y bash
  elif command -v yum >/dev/null 2>&1; then yum install -y bash
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache bash
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install bash
  elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm --needed bash
  else error '未找到 Bash 或支持的软件包管理器，请先安装 Bash。'
  fi
fi
command -v bash >/dev/null 2>&1 || error 'Bash 安装失败，请检查系统软件源。'
bash -n "$SCRIPT" || error '管理脚本语法检查未通过，没有覆盖现有命令。'
# 先验证运行环境，再覆盖已安装的命令。
bash -c 'source "$1"; detect_system && need_service_manager && ensure_dependencies' realm-installer "$SCRIPT"

ENTRY="${RLM_ENTRY:-/usr/local/bin/rnode}"
check_target() {
  case "$1" in
    /*) ;;
    *) error "安装路径必须是绝对路径：$1" ;;
  esac
  [ ! -L "$1" ] || error "发现符号链接，拒绝覆盖：$1"
  if [ -e "$1" ]; then
    if [ ! -f "$1" ] || ! grep -Fq "$2" "$1"; then error "同名文件不属于本工具，拒绝覆盖：$1"; fi
  fi
}
check_target "$ENTRY" '# Realm deploy manager:'
mkdir -p "$(dirname "$ENTRY")"
entry_tmp=$(mktemp "$(dirname "$ENTRY")/.rnode-install.XXXXXX")
cleanup() {
  rm -f "$entry_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
cat "$SCRIPT" > "$entry_tmp"
chmod 700 "$entry_tmp"
mv -f "$entry_tmp" "$ENTRY"
# 升级时清理本工具旧版留下的数据工具；不接管同名文件或符号链接。
legacy_helper="${RLM_HELPER_TARGET:-/usr/local/lib/realm-deploy/realm-data.py}"
if [ -f "$legacy_helper" ] && [ ! -L "$legacy_helper" ] && grep -Fq '# Realm deploy data:' "$legacy_helper"; then
  rm -f "$legacy_helper"
fi
printf '[+] 管理命令安装完成：%s\n' "$ENTRY"
printf '%s\n' '以后输入 rnode 打开中文菜单；普通用户使用 sudo rnode。选择 1 即可创建转发。'
# 运行刚安装的副本，确保移走下载文件夹后仍可使用。
exec bash "$ENTRY" "$@"
