# 开发与验证

## 本地安装

将 `install.sh`、`realm.sh`、`realm-data.py` 放在同一文件夹，在入口 Linux VPS 上执行：

```bash
sudo sh install.sh
```

root 用户执行 `sh install.sh` 即可。安装后命令和数据工具会复制到系统目录，移走下载文件夹后仍可使用。

## 使用其他仓库

在线入口默认使用 `fengqi0216/realm-deploy` 的 `main` 分支，无须填写变量。Fork 或使用其他版本时，可给已下载的入口传入：

```bash
RLM_GITHUB_OWNER=你的GitHub用户名 sh install-realm.sh
```

可选变量：`RLM_GITHUB_REPO` 指定仓库，`RLM_GITHUB_REF` 指定分支 / 标签，`RLM_GITHUB_PATH` 指定文件所在的仓库子目录。需要先把完整文件发布到对应位置。

## 验证

运行：

```bash
python3 -m unittest discover -s tests -v
shellcheck realm.sh install.sh install-realm.sh
```

测试使用 Python 标准库，GitHub 下载和服务操作由模拟程序完成，覆盖输入校验、规则备份恢复、失败回滚、安装器保护以及交互创建流程。

测试也包含真实 TCP / UDP 监听和端口占用检查。环境不允许创建套接字时，这三项明确跳过，其余集成测试模拟端口检查。

这些检查不能代替真实 Realm 二进制下载、真实 systemd / OpenRC 启动和跨服务器转发测试；发布前应在 Linux VPS 上用真实客户端验证。
