#!/usr/bin/env python3
# Realm deploy data: validated state, official release metadata and diagnostics.
"""rnode 的内部数据工具；配置文件只作为数据读取，不作为 Shell 执行。"""

import concurrent.futures
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import secrets
import socket
import struct
import sys
import threading


class Invalid(ValueError):
    pass


def port(value):
    value = str(value)
    if not re.fullmatch(r"[0-9]{1,5}", value) or not 1 <= int(value) <= 65535:
        raise Invalid("端口请输入 1～65535 之间的整数。")
    return int(value)


def host(value, allow_empty=False, listen=False):
    value = value.strip()
    if allow_empty and not value:
        return ""
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        if listen:
            raise Invalid("监听地址必须是本机 IP，例如 0.0.0.0、:: 或 127.0.0.1。") from None
    else:
        if address.is_multicast or "%" in value:
            raise Invalid("请使用普通 IPv4 / IPv6 地址，不要使用组播地址或区域编号。")
        if not listen and address.is_unspecified:
            raise Invalid("目标或公网地址不能填写 0.0.0.0 / ::，请填写实际 IP 或域名。")
        return str(address)
    if re.fullmatch(r"[0-9.]+", value):
        raise Invalid("IPv4 地址格式有误，例如 203.0.113.10；每段数字不能超过 255。")
    try:
        value = value.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise Invalid("域名格式有误。") from None
    if len(value) > 253 or not value or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in value.split(".")
    ):
        raise Invalid("请输入 IP 或域名，不要带 https://、端口、路径或空格。")
    return value


def name(value):
    value = value.strip()
    if not 1 <= len(value) <= 48 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value):
        raise Invalid("名称请输入 1～48 个字符，可以使用中文，但不能包含控制字符。")
    return value


def version(value):
    if not re.fullmatch(r"v?[0-9]+(?:\.[0-9]+){1,3}(?:-[a-zA-Z0-9.-]+)?", value):
        raise Invalid("版本格式有误，例如 v2.7.0；也可输入 latest 获取最新正式版。")
    return value


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate(state):
    if not isinstance(state, dict) or set(state) != {"version", "rules"} or state["version"] != 1:
        raise Invalid("不是本工具支持的规则备份（需要 version=1 和 rules）。")
    if not integer(state["version"]) or not isinstance(state["rules"], list) or len(state["rules"]) > 1024:
        raise Invalid("规则格式有误，单份配置最多支持 1024 条规则。")
    ids, ports = set(), set()
    fields = {"id", "name", "listen_host", "listen_port", "remote_host", "remote_port", "public_host", "public_port", "enabled"}
    for rule in state["rules"]:
        if not isinstance(rule, dict) or set(rule) != fields:
            raise Invalid("规则字段缺失或包含未知字段，请使用本工具生成的 JSON 备份。")
        if not integer(rule["id"]) or not 1 <= rule["id"] <= 2147483647 or rule["id"] in ids:
            raise Invalid("规则编号有误或重复。")
        ids.add(rule["id"])
        for key in ("name", "listen_host", "remote_host", "public_host"):
            if not isinstance(rule[key], str):
                raise Invalid("名称和地址必须是文本。")
            normalized = name(rule[key]) if key == "name" else host(
                rule[key], allow_empty=key == "public_host", listen=key == "listen_host"
            )
            if normalized != rule[key]:
                raise Invalid("规则地址或名称不是规范格式，请通过菜单重新填写。")
        for key in ("listen_port", "remote_port", "public_port"):
            if not integer(rule[key]) or port(rule[key]) != rule[key]:
                raise Invalid("规则中的端口必须是整数。")
        if not isinstance(rule["enabled"], bool):
            raise Invalid("规则启停状态必须是 true 或 false。")
        if rule["listen_port"] in ports:
            raise Invalid(f"监听端口 {rule['listen_port']} 重复；每条规则请使用不同的入口端口。")
        ports.add(rule["listen_port"])
        if rule["enabled"]:
            remote = rule["remote_host"]
            try:
                address = ipaddress.ip_address(remote)
                local = address.is_loopback or remote == rule["listen_host"]
            except ValueError:
                local = remote == "localhost"
            if local and rule["listen_port"] == rule["remote_port"]:
                raise Invalid("目标指向了本机的同一个监听端口，会形成循环转发，请修改。")
            if remote == rule["public_host"] and rule["remote_port"] == rule["public_port"]:
                raise Invalid("目标和入口的公网地址、端口完全相同，会形成循环转发。")
    return state


def load(path):
    source = Path(path)
    if source.stat().st_size > 5 * 1024 * 1024:
        raise Invalid("规则文件过大，请确认选择的是本工具的 JSON 备份。")
    return validate(json.loads(source.read_text(encoding="utf-8")))


def write(path, state):
    validate(state)
    Path(path).write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def find(state, rule_id):
    for rule in state["rules"]:
        if str(rule["id"]) == rule_id:
            return rule
    raise Invalid("没有找到这个规则编号，请先查看规则列表。")


def endpoint(address, number):
    return f"[{address}]:{number}" if ":" in address else f"{address}:{number}"


def render(state):
    lines = [
        "# RLM-MANAGED: realm-deploy; 修改请使用 rnode，直接修改会被覆盖。",
        '[log]', 'level = "warn"', '', '[network]', 'no_tcp = false', 'use_udp = true', '',
    ]
    for rule in state["rules"]:
        if rule["enabled"]:
            lines += [
                f"# rule {rule['id']}", '[[endpoints]]',
                "listen = " + json.dumps(endpoint(rule["listen_host"], rule["listen_port"])),
                "remote = " + json.dumps(endpoint(rule["remote_host"], rule["remote_port"])), '',
            ]
    return "\n".join(lines) + "\n"


def show(rule):
    public = endpoint(rule["public_host"] or "这台转发服务器的公网IP", rule["public_port"])
    print(f"\n规则编号：{rule['id']}　名称：{rule['name']}　状态：{'启用' if rule['enabled'] else '停用'}")
    print(f"客户端 → {public} → {endpoint(rule['remote_host'], rule['remote_port'])}")
    print(f"本机监听：{endpoint(rule['listen_host'], rule['listen_port'])}（TCP + UDP）")
    print(f"客户端服务器地址：{rule['public_host'] or '请填写这台转发服务器的公网 IP / 域名'}")
    print(f"客户端服务器端口：{rule['public_port']}")
    print("其他参数：沿用目标节点的协议、密码 / UUID、加密、Reality 公钥、SNI 等。")
    if rule["listen_port"] != rule["public_port"]:
        print(f"NAT 映射需自行配置：公网 {rule['public_port']} → 本机 {rule['listen_port']}（TCP + UDP）。")
    print(f"本机防火墙：放行 {rule['listen_port']} 的 TCP + UDP；公网安全组 / 上游防火墙：放行 {rule['public_port']}。")


def bind_test(address, number):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    opened = []
    try:
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            sock = socket.socket(family, kind)
            opened.append(sock)
            sock.bind((address, number))
    finally:
        for sock in opened:
            sock.close()


def check_ports(new, old):
    owned = {(r["listen_host"], r["listen_port"]) for r in old["rules"] if r["enabled"]}
    for rule in new["rules"]:
        key = (rule["listen_host"], rule["listen_port"])
        if not rule["enabled"] or key in owned:
            continue
        try:
            bind_test(*key)
        except OSError as exc:
            raise Invalid(f"不能监听 {endpoint(*key)}：{exc.strerror}。请换一个空闲端口或本机 IP。") from None


def listening(state):
    tables = {"tcp": set(), "udp": set()}
    for protocol in tables:
        for suffix in ("", "6"):
            table = Path(f"/proc/net/{protocol}{suffix}")
            if not table.exists():
                continue
            for line in table.read_text().splitlines()[1:]:
                fields = line.split()
                if protocol == "tcp" and fields[3] != "0A":
                    continue
                raw_address, raw_port = fields[1].split(":")
                if suffix:
                    packed = struct.pack("=4I", *(int(raw_address[i:i + 8], 16) for i in range(0, 32, 8)))
                else:
                    packed = struct.pack("=I", int(raw_address, 16))
                tables[protocol].add((str(ipaddress.ip_address(packed)), int(raw_port, 16)))
    return all(
        (rule["listen_host"], rule["listen_port"]) in tables[protocol]
        for rule in state["rules"] if rule["enabled"] for protocol in tables
    )


def release(metadata, architecture):
    content = json.loads(Path(metadata).read_text(encoding="utf-8"))
    if not isinstance(content, dict) or not isinstance(content.get("assets"), list) or not all(isinstance(asset, dict) for asset in content["assets"]):
        raise Invalid("GitHub 返回的发布信息格式有误，请检查 API 限流或稍后重试。")
    tag = version(content.get("tag_name", ""))
    targets = {
        "x86_64": ["x86_64-unknown-linux-musl", "x86_64-unknown-linux-gnu"],
        "aarch64": ["aarch64-unknown-linux-musl", "aarch64-unknown-linux-gnu"],
        "armv7l": ["armv7-unknown-linux-musleabihf", "armv7-unknown-linux-gnueabihf"],
        "armv6l": ["arm-unknown-linux-musleabihf", "arm-unknown-linux-musleabi"],
        "i686": ["i686-unknown-linux-musl", "i686-unknown-linux-gnu"],
        "riscv64": ["riscv64gc-unknown-linux-gnu"],
    }
    assets = content.get("assets", [])
    selected = None
    for target in targets.get(architecture, []):
        selected = next((asset for asset in assets if asset.get("name") in (
            f"realm-{target}.tar.gz", f"realm-{tag}-{target}.tar.gz",
            f"realm-{tag.lstrip('v')}-{target}.tar.gz",
        )), None)
        if selected:
            break
    if not selected:
        raise Invalid(f"Realm {tag} 没有找到适用于 {architecture} 的官方安装包；没有修改当前内核。")
    asset_name = selected["name"]
    prefix = f"https://github.com/zhboner/realm/releases/download/{tag}/"

    def official_url(asset):
        url = asset.get("browser_download_url", "")
        if url != prefix + asset["name"] or not re.fullmatch(r"[a-zA-Z0-9._-]+", asset["name"]):
            raise Invalid("下载链接不是预期的 Realm 官方发布地址，已停止下载。")
        return url

    digest = selected.get("digest") or ""
    if digest and not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", digest):
        raise Invalid("官方 API 的文件校验字段格式有误。")
    checksum = next((asset for checksum_name in (
        asset_name + ".sha256", asset_name + ".sha256sum", asset_name + ".sha256.txt",
        "SHA256SUMS", "SHA256SUMS.txt", "sha256sums.txt", "checksums.txt", "checksums.sha256",
    ) for asset in assets if asset.get("name") == checksum_name), None)
    for value in (tag, official_url(selected), asset_name, digest.removeprefix("sha256:"), official_url(checksum) if checksum else ""):
        print(value)


def checksum(manifest, asset_name):
    for line in Path(manifest).read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"\s*([a-fA-F0-9]{64})(?:\s+\*?(.+))?\s*", line)
        if match and (not match[2] or match[2].strip().removeprefix("./") == asset_name):
            print(match[1].lower())
            return
        match = re.fullmatch(r"SHA256\s*\((.+)\)\s*=\s*([a-fA-F0-9]{64})", line)
        if match and match[1] == asset_name:
            print(match[2].lower())
            return
    raise Invalid("校验文件中没有找到对应安装包的 SHA256。")


def resolve_bounded(address, number):
    # getaddrinfo 不接受超时。守护线程让 DNS 超时时不会阻塞整个诊断命令退出。
    result = concurrent.futures.Future()

    def lookup():
        try:
            result.set_result(socket.getaddrinfo(address, number, type=socket.SOCK_STREAM))
        except Exception as exc:  # DNS errors are displayed by the caller.
            result.set_exception(exc)

    threading.Thread(target=lookup, daemon=True).start()
    return result.result(timeout=5)


def diagnose(state):
    failures = 0
    for rule in state["rules"]:
        if not rule["enabled"]:
            print(f"[跳过] #{rule['id']} {rule['name']}：规则已停用。")
            continue
        print(f"\n检查 #{rule['id']} {rule['name']}：")
        try:
            resolved = resolve_bounded(rule["remote_host"], rule["remote_port"])
            print("[通过] 目标地址解析成功。")
            last_error = None
            for family, kind, proto, _, address in resolved[:2]:
                try:
                    with socket.socket(family, kind, proto) as sock:
                        sock.settimeout(3)
                        sock.connect(address)
                    last_error = None
                    break
                except OSError as exc:
                    last_error = exc
            if not resolved or last_error:
                raise Invalid(f"目标 TCP 连接失败：{last_error or '没有解析结果'}")
            print("[通过] 转发服务器可以连接目标 TCP 端口。")
        except (OSError, Invalid, concurrent.futures.TimeoutError) as exc:
            failures += 1
            print(f"[失败] {exc or '目标 DNS 解析超时'}；请检查目标地址、端口、落地服务和防火墙。")
        local = {"0.0.0.0": "127.0.0.1", "::": "::1"}.get(rule["listen_host"], rule["listen_host"])
        try:
            with socket.create_connection((local, rule["listen_port"]), timeout=3):
                pass
            print("[通过] 本机入口 TCP 端口正在接受连接。")
        except OSError as exc:
            failures += 1
            print(f"[失败] 本机入口连接失败：{exc}；请查看服务日志。")
    print("\nTCP 连接检查不代表协议握手通过。UDP 请用真实客户端验证。")
    print("公网入站还需要安全组、防火墙及 NAT 映射正确；本机检查无法确认这些设置。")
    return 1 if failures else 0


def main(args):
    command, *args = args
    if command == "field":
        kind, value = args
        if kind == "port":
            print(port(value))
        elif kind == "name":
            print(name(value))
        elif kind == "version":
            print(version(value))
        else:
            print(host(value, allow_empty=kind == "public", listen=kind == "listen"))
        return 0
    if command == "release":
        release(*args)
        return 0
    if command == "checksum":
        checksum(*args)
        return 0
    if command == "archive-member":
        members = Path(args[0]).read_text().splitlines()
        matches = [part for part in members if part.split("/")[-1] == "realm" and not part.startswith("/") and ".." not in part.split("/")]
        if len(matches) != 1:
            raise Invalid("安装包中未找到唯一的 realm 可执行文件。")
        print(matches[0])
        return 0
    if command == "sha256":
        with open(args[0], "rb") as source:
            digest = hashlib.sha256()
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        print(digest.hexdigest())
        return 0
    if command == "init":
        write(args[0], {"version": 1, "rules": []})
        return 0
    state = load(args[0])
    if command == "validate":
        return 0
    if command == "render":
        Path(args[1]).write_text(render(state), encoding="utf-8")
    elif command == "count":
        print(sum(r["enabled"] for r in state["rules"]) if len(args) > 1 else len(state["rules"]))
    elif command == "next-id":
        print(max((r["id"] for r in state["rules"]), default=0) + 1)
    elif command == "list":
        if not state["rules"]:
            print("还没有转发规则。主菜单选择 1 即可创建。")
        for rule in state["rules"]:
            print(f"{rule['id']:>3}）{rule['name']} [{'启用' if rule['enabled'] else '停用'}]  {endpoint(rule['listen_host'], rule['listen_port'])} → {endpoint(rule['remote_host'], rule['remote_port'])}  TCP+UDP")
    elif command == "show":
        show(find(state, args[1]))
    elif command == "get":
        rule = find(state, args[1])
        for key in ("name", "listen_host", "listen_port", "remote_host", "remote_port", "public_host", "public_port", "enabled"):
            print(str(rule[key]).lower() if isinstance(rule[key], bool) else rule[key])
    elif command == "put":
        _, output, rule_id, rule_name, listen_host, listen_port, remote_host, remote_port, public_host, public_port, enabled = args
        normalized = {
            "id": int(rule_id), "name": name(rule_name), "listen_host": host(listen_host, listen=True),
            "listen_port": port(listen_port), "remote_host": host(remote_host), "remote_port": port(remote_port),
            "public_host": host(public_host, allow_empty=True), "public_port": port(public_port), "enabled": enabled == "true",
        }
        state["rules"] = [r for r in state["rules"] if r["id"] != normalized["id"]] + [normalized]
        state["rules"].sort(key=lambda rule: rule["id"])
        write(output, state)
    elif command in ("remove", "toggle"):
        rule = find(state, args[2])
        if command == "remove":
            state["rules"].remove(rule)
        else:
            rule["enabled"] = not rule["enabled"]
        write(args[1], state)
    elif command == "check-ports":
        check_ports(state, load(args[1]))
    elif command == "listening":
        return 0 if listening(state) else 1
    elif command == "auto-port":
        address = host(args[1], listen=True)
        reserved = {rule["listen_port"] for rule in state["rules"]}
        for _ in range(128):
            number = 20000 + secrets.randbelow(40001)
            if number in reserved:
                continue
            try:
                bind_test(address, number)
            except OSError:
                continue
            print(number)
            break
        else:
            raise Invalid("未找到空闲端口，请手动填写。")
    elif command == "diagnose":
        return diagnose(state)
    else:
        raise Invalid("未知的数据操作。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (Invalid, OSError, ValueError, KeyError, TypeError) as error:
        print(f"[错误] {error}", file=sys.stderr)
        sys.exit(1)
