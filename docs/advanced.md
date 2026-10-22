# 详细用法与排错

日常使用先看 [首页新手说明](../README.md)。

## 入口与目标

入口服务器是安装 Realm 的这台 VPS；目标服务器是原来运行 SS、VLESS、游戏服等服务的服务器。两边端口可以不同，目标服务需要已经能正常使用。

转发代理节点时，客户端只修改服务器地址和端口。协议、密码、UUID、加密方式、Reality 公钥、SNI、证书校验名称等参数沿用原节点。Realm 不生成新的节点链接，也不会为连接额外加密。

## 自定义创建、NAT 和 IPv6

主菜单 **1** 用于普通公网 VPS，自动生成名称，公网端口与本机监听端口相同。**7 → 4** 可自定义监听 IP、公网端口和名称；已有规则在 **4 → 修改** 中调整这些设置。

NAT 示例：服务商给你 `nat.example.com:31415 → 本机 20000`，填写目标地址和端口后，本机监听 IP 通常保留 `0.0.0.0`，监听端口填 `20000`，入口公网地址填 `nat.example.com`，公网端口填 `31415`。客户端连接 `nat.example.com:31415`。

脚本不会创建上游映射，TCP 和 UDP 都需要服务商或路由器支持；没有分配入站映射的 NAT 服务器无法直接作为公网入口。本机防火墙放行本机端口，公网安全组放行公网端口。

IPv6 目标地址可以直接填写，配置会自动添加方括号。新规则默认监听 `0.0.0.0`，接受 IPv4 入口连接。如需 IPv6 入口，把监听 IP 改为 `::` 或本机 IPv6 地址。IPv6 监听是否同时接受 IPv4 由系统和 Realm 行为决定，请分别测试。

## 域名与 DDNS

入口和目标地址都可以填域名，DDNS 更新需由已有 DDNS 工具负责。填写入口域名只用于展示客户端连接信息，不会自动创建 DNS 记录。普通 Cloudflare 橙云不能直接代理任意 TCP / UDP 端口，请使用“仅 DNS”。

目标域名的解析刷新取决于 Realm；目标 IP 变化后可执行 `sudo rnode start` 重启刷新。

## 防火墙与连接排错

入口服务器的本机防火墙和服务商安全组都需要放行入口端口的 TCP + UDP。脚本不会关闭防火墙或修改安全组。

如果使用 UFW，入口监听端口为 `20000` 时，可以执行：

```bash
sudo ufw allow 20000/tcp
sudo ufw allow 20000/udp
```

请替换为自己的端口，服务商安全组仍需在网页控制台放行。

连接失败时，先运行：

```bash
sudo rnode diagnose
sudo rnode logs
```

依次检查：

1. 原节点 / 目标服务本来能否正常使用？目标地址和端口是否填反？
2. 入口安全组和本机防火墙，是否放行了正确的 TCP + UDP 端口？
3. 目标服务器是否允许入口服务器访问目标端口？服务是否只监听了 `127.0.0.1`？
4. 客户端是否使用入口的公网地址和公网端口，并保留原节点其他参数？
5. NAT 的公网端口到本机监听端口的映射是否真实存在？

诊断检查目标 DNS、目标 TCP 可达性和本机 TCP 入口，无法确认公网安全组、客户端协议握手或 UDP 实际转发成功。UDP 需要用真实客户端测试。

## 命令与服务行为

普通用户在命令前加 `sudo`；root 可直接执行。

| 命令 | 用途 |
| --- | --- |
| `rnode` | 打开中文菜单 |
| `rnode add` | 快速创建转发 |
| `rnode list` | 查看全部规则 |
| `rnode show 1` | 查看规则 1 的客户端连接信息 |
| `rnode status` | 查看服务状态 |
| `rnode start` | 启动 / 重启，并开启开机自启 |
| `rnode stop` | 停止全部转发并关闭开机自启，保留规则 |
| `rnode logs` | 查看最近日志 |
| `rnode diagnose` | 诊断 TCP 连接 |
| `rnode backup` | 备份并输出文件路径 |
| `rnode restore /完整路径/备份.json` | 确认后恢复备份 |
| `rnode install` | 更新到最新 Realm 正式版 |
| `rnode install v2.7.0` | 安装指定的官方版本 |
| `rnode uninstall` | 确认后卸载，保留最后一份规则备份 |
| `rnode check` | 只读检查系统，无须 root |

每条规则同时转发 TCP + UDP，同一个监听端口只能属于一条规则。停用的规则保留原设置；停用最后一条规则会停止服务并关闭开机自启。

所有规则由同一个服务管理。修改规则通过重启 Realm 生效，已有连接可能需要重连。修改后的服务若无法建立全部 TCP / UDP 监听，脚本会恢复修改前的规则，并尝试恢复原来的服务状态。

## 备份、恢复和更新

每次修改规则都会在 `/etc/realm-deploy/backups` 保存修改前的 JSON。主菜单 **6 → 1** 或 `sudo rnode backup` 可手动备份，建议再下载一份到自己的电脑。

主菜单 **6 → 2** 可选择备份恢复，也可使用 `sudo rnode restore /完整路径/备份.json`。恢复会替换整份规则，并启动其中启用的规则。当前 `rules.json` 损坏时，仍可通过命令指定有效备份恢复。

备份包含规则和连接地址，不包含 Realm 内核、防火墙、安全组、NAT 映射或 DNS 记录。

更新工具可重新执行首页的一键安装命令；本地安装可用新版文件替换下载文件夹后，重新执行 `sudo sh install.sh`。两种方式都保留现有规则。

更新内核使用 **7 → 1** 或 `sudo rnode install`。指定版本需在官方仓库存在，并提供对应 CPU 的安装包。运行中的服务会重启，新版本启动失败时尝试恢复旧版本。下载包提供 GitHub SHA256 字段或官方校验文件时会自动验证；没有提供时会提示。内核始终从 [zhboner/realm 官方发布](https://github.com/zhboner/realm/releases)获取。

卸载使用 **7 → 3** 或 `sudo rnode uninstall`，完整输入 `确认卸载`。卸载会停止本工具的转发并删除受管文件，最后一份 JSON 备份保存在 `/etc/realm-deploy-backup-时间-随机值.json`，实际路径会打印出来。原始下载文件夹和系统日志保留。

## 文件位置

| 文件 | 用途 |
| --- | --- |
| `/usr/local/bin/rnode` | 管理命令 |
| `/usr/local/lib/realm-deploy/realm-data.py` | 配套数据工具 |
| `/etc/realm-deploy/rules.json` | 规则数据 |
| `/etc/realm-deploy/config.toml` | 自动生成的 Realm 配置 |
| `/etc/realm-deploy/backups/` | 自动 / 手动备份 |
| `/opt/realm-deploy/versions/` | 已下载内核 |
| `/usr/local/bin/realm-deploy-core` | 当前内核链接 |
| `/etc/systemd/system/realm-deploy.service` | systemd 服务 |
| `/etc/init.d/realm-deploy` | OpenRC 服务 |

请通过菜单修改规则，直接编辑 TOML 会在下次保存规则时被覆盖。本工具使用独立目录、`rnode` 命令和 `realm-deploy` 服务名，可与 `xray-deploy` 同时安装；两者需要使用不同的监听端口。

## 系统支持

支持 **systemd / OpenRC**，要求 **Bash、Python ≥ 3.9**。自动补齐依赖的包管理器包括 apt、dnf、yum、apk、zypper 和 pacman。主要面向常规 Debian / Ubuntu VPS，其他发行版和 CPU 未逐一实测。安装包按官方实际发布的 CPU 架构选择，优先使用 musl 包。

不提供 SysVinit、runit、OpenWrt procd 或普通 Docker 容器中的手动后台模式。安装前可以在本地文件夹执行 `bash realm.sh check` 只读检查。
