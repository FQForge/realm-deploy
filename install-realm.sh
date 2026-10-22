#!/bin/sh
# Realm deploy bootstrap: one-command installation with an interactive menu.
set -eu

error() { printf '[错误] %s\n' "$*" >&2; exit 1; }
GITHUB_OWNER="${RLM_GITHUB_OWNER:-fengqi0216}"
GITHUB_REPO="${RLM_GITHUB_REPO:-realm-deploy}"
GITHUB_REF="${RLM_GITHUB_REF:-main}"
GITHUB_PATH="${RLM_GITHUB_PATH:-}"
case "$GITHUB_OWNER" in
  '') error 'GitHub 用户名不能为空。' ;;
  *[!a-zA-Z0-9-]*) error 'GitHub 用户名包含非法字符。' ;;
esac
case "$GITHUB_REPO" in ''|*[!a-zA-Z0-9_.-]*) error 'GitHub 仓库名有误。' ;; esac
case "$GITHUB_REF" in ''|*[!a-zA-Z0-9._/-]*) error 'GitHub 分支 / 标签有误。' ;; esac
case "$GITHUB_PATH" in *[!a-zA-Z0-9_./-]*|/*|*..*) error '仓库子目录有误。' ;; esac
[ "$(uname -s)" = Linux ] || error '请在 Linux VPS 上运行。'
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  error '请先安装 curl 或 wget；Debian / Ubuntu 可执行 apt-get update && apt-get install -y curl。'
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/realm-install.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
base="https://raw.githubusercontent.com/$GITHUB_OWNER/$GITHUB_REPO/$GITHUB_REF"
[ -z "$GITHUB_PATH" ] || base="$base/$GITHUB_PATH"
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fLsS --retry 2 --connect-timeout 10 --max-time 90 -o "$2" "$1"
  else wget -q -T 90 -O "$2" "$1"
  fi
}
printf '[+] 正在安装 Realm 中文转发管理：%s/%s（%s）\n' "$GITHUB_OWNER" "$GITHUB_REPO" "$GITHUB_REF"
for filename in install.sh realm.sh; do
  printf '[+] 正在下载 %s\n' "$filename"
  fetch "$base/$filename" "$temporary/$filename" || error "下载 $filename 失败，请检查仓库、分支、子目录和网络。"
  [ -s "$temporary/$filename" ] || error "下载到的 $filename 为空。"
done
grep -Fq '# Realm deploy installer:' "$temporary/install.sh" || error '安装入口内容不符合预期。'
grep -Fq '# Realm deploy manager:' "$temporary/realm.sh" || error '管理脚本内容不符合预期。'
printf '%s\n' '[+] 下载完成，安装后自动打开中文菜单。'
if [ "$(id -u)" -eq 0 ]; then
  sh "$temporary/install.sh" "$@"
elif command -v sudo >/dev/null 2>&1; then
  sudo sh "$temporary/install.sh" "$@"
else error '请先运行 su - 切换到 root，再执行安装命令。'
fi
