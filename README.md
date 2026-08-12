# Fedora-NAS Config

Fedora Server 44 NAS（`fedora-nas`，内网 IP 已模糊为 192.168.x.x）的**全套配置快照**（脱敏版），供灾难恢复与日常维护参考。

配套维护手册（含恢复流程、故障排查、硬件记录）保存在个人笔记库：《Fedora Server 系统安装与维护手册》。

## 目录结构

```
config/
├── dnf/
│   ├── dnf.conf                  # DNF 加速（max_parallel_downloads/fastestmirror）
│   └── yum.repos.d/              # TUNA 清华换源后的 fedora.repo / fedora-updates.repo
├── fstab/                        # 磁盘挂载表（XFS 全盘，UUID 直挂）
├── samba/smb.conf                # Samba 共享（仅 ywpc 可读写）
├── containers/containers.conf    # Podman 引擎用户配置
├── ssh/sshd_config               # SSH 服务配置（默认）
├── selinux/
│   ├── config                    # SELinux 模式（Enforcing）
│   └── booleans.txt              # 全部布尔值快照（getsebool -a）
├── firewalld/                    # 防火墙 zones + 24 个自定义服务定义
│   ├── zones/                    # FedoraServer.xml（默认 zone）
│   └── services/                 # qBE/scrutiny/Syncthing/V2ray_proxy 等
├── crontab/
│   ├── root.txt                  # root crontab（每日 04:30 EFU 目录树扫描）
│   └── user.txt                  # 用户 crontab（上传清理）
└── systemd/
    ├── podman-restart.service   # 系统级：rootful 容器开机自启
    ├── override.conf.bak.20260808  # 已弃用的用户级 podman 代理 override 备份
    ├── localsend-update.{service,timer}  # LocalSend 每周一 04:00 自动更新
    └── upload-cleanup.{service,timer}    # 每日 06:00 清理 OpenWebUI 旧上传
Podman/
├── <容器名>/docker-compose.yml  # 各容器编排文件（对应 ~/Podman/）
├── Frpc/config/frpc.toml        # frp 隧道配置（token 已脱敏）
├── Ubuntu-Xfce/                 # 代理核心容器（V2rayN，1145 出口）
├── minecraft/                   # MC 服务端 + 三方 frp（按需启动）
└── LocalSend/                   # 见独立仓库 100pangci/localsend-cli-container
Tools/*.sh                       # 运维脚本（~/Tools）
Scripts/generate_efu_and_tree.py # 每日目录树/EFU 生成（~/Scripts）
```

## 脱敏说明

以下文件中的敏感值已替换为 `<REDACTED-...>` 占位符，恢复时需手动填入：

| 文件 | 脱敏项 |
|------|--------|
| `Podman/Frpc/config/frpc.toml` | frp 服务端 token |
| `Podman/Ubuntu-Xfce/docker-compose.yml` | webtop VNC 密码 |
| `Podman/Openlist/docker-compose.yml` | MySQL root 密码 |
| `Podman/OpenWebUI/docker-compose.yml` | WEBUI_SECRET_KEY |
| `Podman/minecraft/mefrp/docker-compose.yml` | 三方 frp 令牌 |
| `Tools/rar_background_archive.sh` / `_vn.sh` / `rar_background_unpacker.sh` | RAR 压缩密码 / SMB 账户密码 |

**不包含**（敏感，仅本地保管）：

- `~/.ssh/authorized_keys`（SSH 公钥）
- `~/Podman/LocalSend/.env`（LocalSend 相关，见独立仓库）
- `~/Podman/Ubuntu-Xfce/config/Software/v2rayN/`（订阅与代理配置）
- VeraCrypt 加密卷（挂载点不公开，仓库中以 `Vault-1`/`Vault-2` 指代）的密码

## 恢复用法

```bash
git clone https://github.com/100pangci/fedora-nas-config.git
# 对照《Fedora Server 系统安装与维护手册》Phase 2~7 逐步还原
# 将各文件拷回目标路径后，填入所有 <REDACTED-...> 占位符
```

## 关联仓库

- **localsend-cli-container**：<https://github.com/100pangci/localsend-cli-container>（LocalSend CLI 自建镜像与构建脚本）
