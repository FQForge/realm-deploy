#!/usr/bin/env bash
# Realm deploy manager: beginner-friendly TCP + UDP forwarding manager.
set -Eeuo pipefail
umask 077

SERVICE_NAME=realm-deploy
ETC_DIR="${RLM_ETC_DIR:-/etc/realm-deploy}"
OPT_DIR="${RLM_OPT_DIR:-/opt/realm-deploy}"
ENTRY="${RLM_ENTRY:-/usr/local/bin/rnode}"
CORE_LINK="${RLM_CORE_LINK:-/usr/local/bin/realm-deploy-core}"
UNIT_FILE="${RLM_UNIT_FILE:-/etc/systemd/system/realm-deploy.service}"
OPENRC_FILE="${RLM_OPENRC_FILE:-/etc/init.d/realm-deploy}"
LOG_FILE="${RLM_LOG_FILE:-/var/log/realm-deploy.log}"
STATE="$ETC_DIR/rules.json"
CONFIG="$ETC_DIR/config.toml"
BACKUPS="$ETC_DIR/backups"
VERSIONS="$OPT_DIR/versions"
INIT_SYSTEM=''
DISTRO_NAME=unknown
API='https://api.github.com/repos/zhboner/realm/releases'

say() { printf '%s\n' "$*"; }
info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { warn "$*"; return 1; }

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

# 数据只交给 jq 解析，不 source 配置文件，也不把用户输入作为命令执行。
normalize_ipv4() {
  local value="$1" part
  local -a parts=()
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((10#$part <= 255)) || return 1
  done
  ((10#${parts[0]} < 224 || 10#${parts[0]} > 239)) || return 1
  printf '%s\n' "$value"
}

normalize_ipv6() {
  local value="${1,,}" left right part tail prefix expanded='' result='' index start=-1 length=0 best=-1 longest=1 missing
  local -a before=() after=() groups=() octets=()
  if [[ "$value" == *.* ]]; then
    tail=$(normalize_ipv4 "${value##*:}") || return 1
    IFS=. read -r -a octets <<< "$tail"
    printf -v tail '%x:%x' "$((10#${octets[0]}*256+10#${octets[1]}))" "$((10#${octets[2]}*256+10#${octets[3]}))"
    value="${value%:*}:$tail"
  fi
  [[ "$value" =~ ^[0-9a-f:]+$ && "$value" != *:::* ]] || return 1
  if [[ "$value" == *::* ]]; then
    left="${value%%::*}"; right="${value#*::}"
    [[ "$right" != *::* && "$right" != *: ]] || return 1
    [[ -z "$left" ]] || IFS=: read -r -a before <<< "$left"
    [[ -z "$right" ]] || IFS=: read -r -a after <<< "$right"
    missing=$((8-${#before[@]}-${#after[@]}))
    ((missing >= 1)) || return 1
    groups=("${before[@]}")
    for ((index=0; index<missing; index++)); do groups+=(0); done
    groups+=("${after[@]}")
  else
    [[ "$value" != :* && "$value" != *: ]] || return 1
    IFS=: read -r -a groups <<< "$value"
    ((${#groups[@]} == 8)) || return 1
  fi
  for index in "${!groups[@]}"; do
    part="${groups[index]}"
    [[ "$part" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf -v 'groups[index]' '%x' "$((16#$part))"
    if [[ "${groups[index]}" == 0 ]]; then
      ((start >= 0)) || start=$index
      length=$((index-start+1))
      if ((length > longest)); then best=$start; longest=$length; fi
    else start=-1
    fi
  done
  ((16#${groups[0]} < 65280)) || return 1
  for ((index=0; index<8; index++)); do
    if ((index == best)); then
      result+='::'
      index=$((index+longest-1))
    else
      [[ -z "$result" || "$result" == *: ]] || result+=:
      result+="${groups[index]}"
    fi
  done
  # 保留一份展开格式给 /proc/net 地址转换使用。
  for part in "${groups[@]}"; do printf -v prefix '%04x' "$((16#$part))"; expanded+="$prefix"; done
  if [[ "${2:-}" == expanded ]]; then printf '%s\n' "$expanded"; else printf '%s\n' "$result"; fi
}

normalize_host() {
  local value="$1" kind="${2:-host}" normalized label
  local -a labels=()
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$kind" == public && -z "$value" ]]; then say ''; return 0; fi
  if [[ "$value" == '['*']' ]]; then value="${value:1:${#value}-2}"; fi
  [[ "$value" =~ ^[a-zA-Z0-9:._-]+$ ]] || {
    fail '请输入 IP 或域名，不带 https://、端口、路径或空格；中文域名请使用 Punycode。'; return 1;
  }
  if [[ "$value" == *:* ]]; then
    normalized=$(normalize_ipv6 "$value") || { fail 'IPv6 地址格式有误，请不要带端口或区域编号。'; return 1; }
  elif [[ "$value" =~ ^[0-9.]+$ ]]; then
    normalized=$(normalize_ipv4 "$value") || { fail 'IPv4 地址格式有误，例如 203.0.113.10。'; return 1; }
  else
    [[ "$kind" != listen ]] || { fail '监听地址必须是本机 IP，例如 0.0.0.0 或 ::。'; return 1; }
    value="${value,,}"; value="${value%.}"
    [[ -n "$value" && ${#value} -le 253 && "$value" != .* && "$value" != *. ]] || { fail 'IP / 域名格式有误。'; return 1; }
    IFS=. read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
      [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || {
        fail '请输入 IP 或域名，不带 https://、端口、路径或空格；中文域名请使用 Punycode。'; return 1;
      }
    done
    normalized="$value"
  fi
  if [[ "$kind" != listen && ( "$normalized" == 0.0.0.0 || "$normalized" == :: ) ]]; then
    fail '目标或公网地址不能填写 0.0.0.0 / ::，请填写实际 IP 或域名。'; return 1
  fi
  say "$normalized"
}

# 从内核读取本机地址，不依赖 ip / hostname，也不把 NAT 出口 IP 当成本机地址。
local_ip_addresses() {
  local family="${1:-4}" address rest expanded index
  if [[ "$family" == 4 ]]; then
    [[ -r /proc/net/fib_trie ]] || return 0
    awk '$1 == "|--" { address=$2 }
         $1 == "/32" && $2 == "host" && $3 == "LOCAL" && !seen[address]++ { print address }' /proc/net/fib_trie
  else
    [[ -r /proc/net/if_inet6 ]] || return 0
    while read -r address rest; do
      expanded=''
      for ((index=0; index<32; index+=4)); do expanded+="${address:index:4}:"; done
      normalize_ipv6 "${expanded%:}" || true
    done < /proc/net/if_inet6
  fi
}

is_local_ip() {
  local address="$1" family=4 candidate
  [[ "$address" != *:* ]] || family=6
  while IFS= read -r candidate; do
    [[ "$address" != "$candidate" ]] || return 0
  done < <(local_ip_addresses "$family")
  return 1
}

normalize_public_ip() {
  local address="$1" expanded first second
  if [[ "$address" == *:* ]]; then
    address=$(normalize_ipv6 "$address") || return 1
    expanded=$(normalize_ipv6 "$address" expanded) || return 1
    # 自动识别只接受全球单播地址，排除文档示例地址。
    [[ "$expanded" == [23]* && "$expanded" != 20010db8* && "$expanded" != 3fff0* ]] || return 1
  else
    address=$(normalize_ipv4 "$address") || return 1
    case "$address" in
      0.*|10.*|127.*|169.254.*|192.0.0.*|192.0.2.*|192.168.*|192.88.99.*|198.51.100.*|203.0.113.*) return 1 ;;
    esac
    IFS=. read -r first second _ <<< "$address"
    ((first < 224 && (first != 100 || second < 64 || second > 127) &&
      (first != 172 || second < 16 || second > 31) && (first != 198 || second < 18 || second > 19))) || return 1
  fi
  say "$address"
}

detect_local_public_ip() {
  local family="${1:-4}" addresses address ssh_host=''
  addresses=$(local_ip_addresses "$family") || return 1
  read -r _ _ ssh_host _ <<< "${SSH_CONNECTION:-}"
  # 多公网 IP 的服务器优先使用当前 SSH 连接到的本机地址。
  if address=$(normalize_public_ip "$ssh_host") && [[ $'\n'"$addresses"$'\n' == *$'\n'"$address"$'\n'* ]]; then
    say "$address"; return 0
  fi
  while IFS= read -r address; do
    if address=$(normalize_public_ip "$address"); then say "$address"; return 0; fi
  done <<< "$addresses"
  return 1
}

detect_public_ip() {
  local family="${1:-4}" address url
  if address=$(detect_local_public_ip "$family"); then say "$address"; return 0; fi
  for url in https://api64.ipify.org https://icanhazip.com; do
    # 绕过代理，避免识别成代理服务器的 IP；失败最多等待数秒，仍可手动填写。
    address=$(curl "-$family" --noproxy '*' -fsS --connect-timeout 2 --max-time 3 --max-filesize 64 "$url" 2>/dev/null) || continue
    address=$(normalize_public_ip "$address") || continue
    if [[ "$family" == 4 && "$address" != *:* || "$family" == 6 && "$address" == *:* ]]; then
      say "$address"; return 0
    fi
  done
  return 1
}

data_field() {
  local kind="$1" value="$2"
  case "$kind" in
    port)
      if ! { [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535)); }; then
        fail '端口请输入 1～65535 之间的整数。'; return 1;
      fi
      printf '%s\n' "$((10#$value))" ;;
    name)
      value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
      jq -en --arg value "$value" '$value | length >= 1 and length <= 48 and all(explode[]; . >= 32 and (. < 127 or . > 159))' >/dev/null || {
        fail '名称请输入 1～48 个字符，不能包含控制字符。'; return 1;
      }
      say "$value" ;;
    version)
      [[ "$value" =~ ^v?[0-9]+(\.[0-9]+){1,3}(-[a-zA-Z0-9.-]+)?$ ]] || {
        fail '版本格式有误，例如 v2.7.0。'; return 1;
      }
      say "$value" ;;
    host|public|listen) normalize_host "$value" "$kind" ;;
    *) fail '未知的输入类型。'; return 1 ;;
  esac
}

data_validate() {
  local file="$1" kind value normalized size
  [[ -f "$file" ]] || { fail '没有找到规则 JSON 文件。'; return 1; }
  size=$(wc -c < "$file") || return 1
  ((size <= 5242880)) || { fail '规则文件过大，最大支持 5 MiB。'; return 1; }
  if ! jq -es '
    def integer: type == "number" and floor == .;
    def port: integer and . >= 1 and . <= 65535;
    def rule:
      type == "object" and keys == ["enabled","id","listen_host","listen_port","name","public_host","public_port","remote_host","remote_port"] and
      (.id | integer and . >= 1 and . <= 2147483647) and
      (.name | type == "string" and length >= 1 and length <= 48 and all(explode[]; . >= 32 and (. < 127 or . > 159))) and
      all(.listen_host, .remote_host, .public_host; type == "string") and
      all(.listen_port, .remote_port, .public_port; port) and (.enabled | type == "boolean") and
      (if .enabled then
        (((.remote_host == "localhost" or .remote_host == "::1" or (.remote_host | test("^127[.][0-9]+[.][0-9]+[.][0-9]+$")) or .remote_host == .listen_host) and .remote_port == .listen_port) | not) and
        ((.remote_host == .public_host and .remote_port == .public_port) | not)
       else true end);
    length == 1 and (.[0] |
      type == "object" and keys == ["rules","version"] and .version == 1 and
      (.rules | type == "array" and length <= 1024) and all(.rules[]; rule) and
      ([.rules[].id] | length == (unique | length)) and
      ([.rules[].listen_port] | length == (unique | length)))
  ' "$file" >/dev/null 2>&1; then
    fail '规则 JSON 格式有误：请检查字段、端口、重复编号 / 监听端口，以及循环转发。'; return 1
  fi
  while IFS=$'\t' read -r kind value; do
    normalized=$(data_field "$kind" "$value") || return 1
    [[ "$value" == "$normalized" ]] || { fail '规则地址不是规范格式，请通过菜单重新填写。'; return 1; }
  done < <(jq -r '.rules[] | ["listen",.listen_host], ["host",.remote_host], ["public",.public_host] | @tsv' "$file")
}

# 直接读取内核套接字表，不需要额外开启端口或运行后台探测进程。
socket_snapshot() {
  local mode="$1" protocol suffix file found=0
  for protocol in tcp udp; do
    for suffix in '' 6; do
      file="/proc/net/$protocol$suffix"
      [[ -r "$file" ]] || continue
      found=1
      awk -v protocol="$protocol" -v mode="$mode" 'NR > 1 && (mode != "listen" || protocol != "tcp" || $4 == "0A") { print protocol, $2 }' "$file" || return 1
    done
  done
  ((found)) || { fail '无法读取 /proc/net，不能检查端口。'; return 1; }
}

ip_socket_hex() {
  local address="$1" expanded='' part word order result='' index
  local -a octets=()
  if [[ "$address" == *:* ]]; then expanded=$(normalize_ipv6 "$address" expanded) || return 1
  else
    IFS=. read -r -a octets <<< "$address"
    for part in "${octets[@]}"; do printf -v word '%02X' "$((10#$part))"; expanded+="$word"; done
  fi
  order=$(printf '\001\000' | od -An -tu2) || return 1
  for ((index=0; index<${#expanded}; index+=8)); do
    word="${expanded:index:8}"
    if [[ "$order" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
      word="${word:6:2}${word:4:2}${word:2:2}${word:0:2}"
    fi
    result+="$word"
  done
  say "${result^^}"
}

data_check_ports() {
  local file="$1" old="$2" snapshot address number hex
  snapshot=$(socket_snapshot all) || return 1
  while IFS=$'\t' read -r address number; do
    if jq -e --arg host "$address" --argjson port "$number" 'any(.rules[]; .enabled and .listen_host == $host and .listen_port == $port)' "$old" >/dev/null; then continue; fi
    printf -v hex '%04X' "$number"
    if [[ "$snapshot" == *":$hex"$'\n'* || "$snapshot" == *":$hex" ]]; then
      fail "监听端口 $number 已有 TCP / UDP 连接占用，请换一个空闲端口。"; return 1
    fi
  done < <(jq -r '.rules[] | select(.enabled) | [.listen_host,.listen_port] | @tsv' "$file")
}

data_listening() {
  local file="$1" snapshot address number hex address_hex protocol
  snapshot=$(socket_snapshot listen) || return 1
  snapshot=$'\n'"$snapshot"$'\n'
  while IFS=$'\t' read -r address number; do
    address_hex=$(ip_socket_hex "$address") || return 1
    printf -v hex '%04X' "$number"
    for protocol in tcp udp; do
      [[ "$snapshot" == *$'\n'"$protocol $address_hex:$hex"$'\n'* ]] || return 1
    done
  done < <(jq -r '.rules[] | select(.enabled) | [.listen_host,.listen_port] | @tsv' "$file")
}

data_release() {
  local file="$1" architecture="$2" tag target selected='' asset url digest checksum='' checksum_name prefix
  local -a targets=()
  jq -e 'type == "object" and (.assets | type == "array") and all(.assets[]; type == "object")' "$file" >/dev/null || {
    fail 'GitHub 返回的发布信息格式有误，请检查 API 限流或稍后重试。'; return 1;
  }
  tag=$(jq -er '.tag_name | select(type == "string")' "$file") && data_field version "$tag" >/dev/null || return 1
  case "$architecture" in
    x86_64) targets=(x86_64-unknown-linux-musl x86_64-unknown-linux-gnu) ;;
    aarch64) targets=(aarch64-unknown-linux-musl aarch64-unknown-linux-gnu) ;;
    armv7l) targets=(armv7-unknown-linux-musleabihf armv7-unknown-linux-gnueabihf) ;;
    armv6l) targets=(arm-unknown-linux-musleabihf arm-unknown-linux-musleabi) ;;
    i686) targets=(i686-unknown-linux-musl i686-unknown-linux-gnu) ;;
    riscv64) targets=(riscv64gc-unknown-linux-gnu) ;;
  esac
  for target in "${targets[@]}"; do
    selected=$(jq -c --arg target "$target" --arg tag "$tag" '
      first(.assets[] | select(.name == ("realm-"+$target+".tar.gz") or .name == ("realm-"+$tag+"-"+$target+".tar.gz") or .name == ("realm-"+($tag|ltrimstr("v"))+"-"+$target+".tar.gz"))) // empty
    ' "$file") || return 1
    [[ -z "$selected" ]] || break
  done
  [[ -n "$selected" ]] || { fail "Realm $tag 没有适用于 $architecture 的官方安装包，没有修改当前内核。"; return 1; }
  asset=$(jq -r '.name' <<< "$selected")
  url=$(jq -r '.browser_download_url' <<< "$selected")
  prefix="https://github.com/zhboner/realm/releases/download/$tag/"
  [[ "$url" == "$prefix$asset" ]] || { fail '下载链接不是预期的 Realm 官方发布地址。'; return 1; }
  digest=$(jq -er '(.digest // "") | if type == "string" then . else error("invalid digest") end' <<< "$selected") || return 1
  [[ -z "$digest" || "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || { fail '官方 API 的文件校验字段格式有误。'; return 1; }
  for checksum_name in "$asset.sha256" "$asset.sha256sum" "$asset.sha256.txt" SHA256SUMS SHA256SUMS.txt sha256sums.txt checksums.txt checksums.sha256; do
    selected=$(jq -c --arg name "$checksum_name" 'first(.assets[] | select(.name == $name)) // empty' "$file") || return 1
    if [[ -n "$selected" ]]; then
      checksum=$(jq -r '.browser_download_url' <<< "$selected")
      [[ "$checksum" == "$prefix$checksum_name" ]] || { fail '校验文件不是预期的 Realm 官方发布地址。'; return 1; }
      break
    fi
  done
  printf '%s\n' "$tag" "$url" "$asset" "${digest#sha256:}" "$checksum"
}

data_checksum() {
  local file="$1" asset="$2" line hash filename
  local gnu='^[[:space:]]*([a-fA-F0-9]{64})([[:space:]]+\*?(.+))?[[:space:]]*$'
  local bsd='^SHA256[[:space:]]*\((.+)\)[[:space:]]*=[[:space:]]*([a-fA-F0-9]{64})[[:space:]]*$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ $gnu ]]; then
      hash="${BASH_REMATCH[1]}"; filename="${BASH_REMATCH[3]:-}"
      filename="${filename#./}"; filename="${filename%"${filename##*[![:space:]]}"}"
      if [[ -z "$filename" || "$filename" == "$asset" ]]; then say "${hash,,}"; return 0; fi
    elif [[ "$line" =~ $bsd && "${BASH_REMATCH[1]}" == "$asset" ]]; then
      say "${BASH_REMATCH[2],,}"; return 0
    fi
  done < "$file"
  fail '校验文件中没有找到对应安装包的 SHA256。'
}

data_archive_member() {
  local line selected='' count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "${line##*/}" == realm && "$line" != /* && "/$line/" != */../* ]] || continue
    selected="$line"; count=$((count+1))
  done < "$1"
  ((count == 1)) || { fail '安装包中未找到唯一的 realm 可执行文件。'; return 1; }
  say "$selected"
}

tcp_probe() {
  # 位置参数在受超时限制的子 Shell 中展开。
  # shellcheck disable=SC2016
  timeout 6 bash -c 'exec 3<>"/dev/tcp/$1/$2"' realm-probe "$1" "$2" 9>&- 2>/dev/null
}

data_diagnose() {
  local file="$1" rule_id local_host failures=0
  local -a fields=()
  while IFS= read -r rule_id; do
    mapfile -t fields < <(data get "$file" "$rule_id")
    if [[ "${fields[7]}" != true ]]; then say "[跳过] #$rule_id ${fields[0]}：规则已停用。"; continue; fi
    say "检查 #$rule_id ${fields[0]}："
    if tcp_probe "${fields[3]}" "${fields[4]}"; then
      say '[通过] 目标 TCP 可达（域名已完成解析）。'
    else
      say '[失败] 无法连接目标 TCP，请检查目标地址、DNS、端口和防火墙。'; failures=$((failures+1))
    fi
    local_host="${fields[1]}"
    case "$local_host" in 0.0.0.0) local_host=127.0.0.1 ;; ::) local_host=::1 ;; esac
    if tcp_probe "$local_host" "${fields[2]}"; then
      say '[通过] 本机入口 TCP 正在接受连接。'
    else
      say '[失败] 本机入口连接失败，请查看服务日志。'; failures=$((failures+1))
    fi
  done < <(jq -r '.rules[].id' "$file")
  say 'TCP 连接检查不代表协议握手通过；UDP 请用真实客户端验证。'
  say '公网安全组、防火墙和 NAT 映射也需要正确配置。'
  ((failures == 0))
}

data() {
  local command="$1" file rule_id json rule_name listen_host listen_port remote_host remote_port public_host public_port enabled snapshot number hex attempt
  shift
  case "$command" in
    field) data_field "$@"; return $? ;;
    release) data_release "$@"; return $? ;;
    checksum) data_checksum "$@"; return $? ;;
    archive-member) data_archive_member "$@"; return $? ;;
    sha256) sha256sum -- "$1" | awk '{ print $1 }'; return $? ;;
    init) printf '%s\n' '{"version":1,"rules":[]}' > "$1"; return $? ;;
  esac
  file="$1"; shift
  data_validate "$file" || return 1
  case "$command" in
    validate) return 0 ;;
    render)
      jq -r '
        def ep($h;$p): (if $h | contains(":") then "["+$h+"]" else $h end)+":"+($p|tostring);
        ["# RLM-MANAGED: realm-deploy; 修改请使用 rnode，直接修改会被覆盖。", "[log]", "level = \"warn\"", "", "[network]", "no_tcp = false", "use_udp = true", "",
         (.rules[] | select(.enabled) | "# rule \(.id)", "[[endpoints]]", ("listen = "+(ep(.listen_host;.listen_port)|tojson)), ("remote = "+(ep(.remote_host;.remote_port)|tojson)), "") ] | join("\n")
      ' "$file" > "$1" ;;
    count)
      if [[ "${1:-}" == enabled ]]; then jq '[.rules[] | select(.enabled)] | length' "$file"
      else jq '.rules | length' "$file"; fi ;;
    next-id) jq '([.rules[].id] | max // 0)+1' "$file" ;;
    list)
      jq -r '
        def ep($h;$p): (if $h | contains(":") then "["+$h+"]" else $h end)+":"+($p|tostring);
        if .rules | length == 0 then "还没有转发规则。主菜单选择 1 即可创建。"
        else .rules[] | "\(.id)）\(.name) [\(if .enabled then "启用" else "停用" end)]  \(ep(.listen_host;.listen_port)) → \(ep(.remote_host;.remote_port))  TCP+UDP" end
      ' "$file" ;;
    get|show)
      rule_id="$1"
      json=$(jq -ec --arg id "$rule_id" 'first(.rules[] | select((.id|tostring) == $id)) // empty' "$file") || { fail '没有找到这个规则编号，请先查看规则列表。'; return 1; }
      if [[ "$command" == get ]]; then
        jq -r '.name,.listen_host,(.listen_port|tostring),.remote_host,(.remote_port|tostring),.public_host,(.public_port|tostring),(.enabled|tostring)' <<< "$json"
      else
        jq -r '
          def ep($h;$p): (if $h | contains(":") then "["+$h+"]" else $h end)+":"+($p|tostring);
          "", "规则编号：\(.id)　名称：\(.name)　状态：\(if .enabled then "启用" else "停用" end)",
          "客户端 → \(ep((if .public_host == "" then "这台转发服务器的公网IP" else .public_host end);.public_port)) → \(ep(.remote_host;.remote_port))",
          "本机监听：\(ep(.listen_host;.listen_port))（TCP + UDP）",
          "客户端服务器地址：\(if .public_host == "" then "请填写这台转发服务器的公网 IP / 域名" else .public_host end)",
          "客户端服务器端口：\(.public_port)", "其他参数：沿用目标节点的协议、密码 / UUID、加密、Reality 公钥、SNI 等。",
          (if .listen_port != .public_port then "NAT 映射需自行配置：公网 \(.public_port) → 本机 \(.listen_port)（TCP + UDP）。" else empty end),
          "本机防火墙：放行 \(.listen_port) 的 TCP + UDP；公网安全组 / 上游防火墙：放行 \(.public_port)。"
        ' <<< "$json"
      fi ;;
    put)
      rule_id="$2"
      if ! { [[ "$rule_id" =~ ^[1-9][0-9]{0,9}$ ]] && ((rule_id <= 2147483647)); }; then fail '规则编号无效。'; return 1; fi
      rule_name=$(data_field name "$3") && listen_host=$(data_field listen "$4") && listen_port=$(data_field port "$5") &&
        remote_host=$(data_field host "$6") && remote_port=$(data_field port "$7") && public_host=$(data_field public "$8") && public_port=$(data_field port "$9") || return 1
      enabled="${10}"
      [[ "$enabled" == true || "$enabled" == false ]] || { fail '规则启停状态无效。'; return 1; }
      jq --argjson id "$rule_id" --arg name "$rule_name" --arg lh "$listen_host" --argjson lp "$listen_port" --arg rh "$remote_host" --argjson rp "$remote_port" --arg ph "$public_host" --argjson pp "$public_port" --argjson enabled "$enabled" '
        .rules = ([.rules[] | select(.id != $id)] + [{id:$id,name:$name,listen_host:$lh,listen_port:$lp,remote_host:$rh,remote_port:$rp,public_host:$ph,public_port:$pp,enabled:$enabled}] | sort_by(.id))
      ' "$file" > "$1" && data_validate "$1" ;;
    remove|toggle)
      data get "$file" "$2" >/dev/null || return 1
      if [[ "$command" == remove ]]; then
        jq --arg id "$2" '.rules |= map(select((.id|tostring) != $id))' "$file" > "$1"
      else
        jq --arg id "$2" '(.rules[] | select((.id|tostring) == $id) | .enabled) |= not' "$file" > "$1"
      fi && data_validate "$1" ;;
    check-ports) data_validate "$1" && data_check_ports "$file" "$1" ;;
    listening) data_listening "$file" ;;
    auto-port)
      data_field listen "$1" >/dev/null || return 1
      snapshot=$(socket_snapshot all) || return 1
      for ((attempt=0; attempt<128; attempt++)); do
        number=$((20000+((RANDOM*32768+RANDOM)%40001)))
        if jq -e --argjson port "$number" 'any(.rules[]; .listen_port == $port)' "$file" >/dev/null; then continue; fi
        printf -v hex '%04X' "$number"
        if [[ "$snapshot" != *":$hex"$'\n'* && "$snapshot" != *":$hex" ]]; then say "$number"; return 0; fi
      done
      fail '未找到空闲端口，请手动填写。' ;;
    diagnose) data_diagnose "$file" ;;
    *) fail '未知的数据操作。'; return 1 ;;
  esac
}

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
  for command_name in jq curl tar gzip flock timeout sha256sum od; do
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
      case "$command_name" in timeout|sha256sum|od) package=coreutils ;; esac
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
  for command_name in jq curl tar gzip flock timeout sha256sum od; do
    command -v "$command_name" >/dev/null || { fail "仍缺少 $command_name，请检查系统软件源。"; return 1; }
  done
}

check_paths() {
  local path
  for path in "$ETC_DIR" "$OPT_DIR" "$ENTRY" "$CORE_LINK" "$UNIT_FILE" "$OPENRC_FILE" "$LOG_FILE"; do
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

backup_state() (
  local directory="${1:-$BACKUPS}" prefix="${2:-$(date +%Y%m%d-%H%M%S)}" temporary='' destination
  cleanup_backup() { [[ -z "$temporary" ]] || rm -f "$temporary"; }
  trap cleanup_backup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  # BusyBox 要求模板以 XXXXXX 结尾；复制完成后再添加 .json 扩展名。
  temporary=$(mktemp "$directory/$prefix-XXXXXX") || exit 1
  destination="$temporary.json"
  cp "$STATE" "$temporary" && chmod 600 "$temporary" && mv -nT "$temporary" "$destination" || exit 1
  # mv -n 在目标已存在时也可能返回成功，必须确认临时文件确实已移走。
  [[ ! -e "$temporary" ]] || { fail '备份文件名已存在，没有覆盖原备份。'; exit 1; }
  printf '%s\n' "$destination"
)

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
  local public_host='' public_port='' enabled=true temporary suggested family=4
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
  if ((${#fields[@]} == 0)); then
    listen_host=$(detect_local_public_ip 4) || listen_host=0.0.0.0
  fi
  if [[ "$mode" == custom ]]; then
    prompt listen_host '本机监听 IP（本机公网 IP；NAT 可用 0.0.0.0；IPv6 可用 ::）' "$listen_host" listen || return 0
  fi
  suggested="$listen_port"
  [[ -n "$suggested" ]] || suggested=$(data auto-port "$STATE" "$listen_host") || return 1
  prompt listen_port '入口服务器本机监听端口（回车使用空闲端口）' "$suggested" port || return 0
  if ((${#fields[@]})) && [[ "$public_port" == "${fields[2]}" ]]; then public_port="$listen_port"; fi
  if ((${#fields[@]} == 0)); then
    if normalize_public_ip "$listen_host" >/dev/null && is_local_ip "$listen_host"; then
      public_host="$listen_host"
    else
      [[ "$listen_host" != *:* ]] || family=6
      info '正在自动识别入口公网 IP…'
      public_host=$(detect_public_ip "$family") || public_host=''
    fi
  fi
  if [[ -n "$public_host" ]]; then
    say '  公网地址已填好，直接回车确认；也可以改成自己的公网 IP / 域名。'
    prompt public_host '入口公网 IP / 域名' "$public_host" public || return 0
  else
    say '  请填写 SSH 登录这台服务器时使用的公网 IP / 域名；暂时不知道也可稍后补填。'
    prompt public_host '入口公网 IP / 域名（可以留空）' '' public || return 0
  fi
  if [[ "$mode" == quick ]]; then
    if is_local_ip "$public_host"; then listen_host="$public_host"; fi
    if [[ "$listen_host" == 0.0.0.0 ]]; then
      say '  本机未识别到可直接监听的公网 IP，使用 0.0.0.0 接收连接；客户端填写入口公网地址。'
    fi
  fi
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
  for command_name in bash jq curl tar gzip flock timeout sha256sum od; do
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
  managed_file "$ENTRY" '# Realm deploy manager:' || return 1
  check_core_link || return 1
  say '这将停止全部转发，删除本工具的服务、内核、配置、内部备份及 rnode 命令。'
  say '确认后会在配置目录旁保留最后一份规则 JSON；原始下载文件夹保留。'
  IFS= read -r -p '若确定，请完整输入「确认卸载」：' answer || return 1
  [[ "$answer" == 确认卸载 ]] || { say '已取消。'; return 1; }
  backup_copy=$(backup_state "$(dirname "$ETC_DIR")" "realm-deploy-backup-$(date +%Y%m%d-%H%M%S)") || return 1
  service_stop && service_disable || return 1
  rm -f "$UNIT_FILE" "$OPENRC_FILE" "$CORE_LINK" "$ENTRY" || return 1
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
