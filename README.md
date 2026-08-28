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
├── samba/smb.conf                # Samba 共享（仅 ywpc 可读写；VeraCrypt 卷以 Vault-1/Vault-2 指代）
├── containers/containers.conf    # Podman 引擎用户配置
├── firewalld/                    # 防火墙 zones + 自定义服务定义
│   ├── zones/                    # FedoraServer.xml（默认 zone）
│   └── services/                 # qBE/scrutiny/Syncthing/V2ray_proxy 等
├── crontab/
│   ├── root.txt                  # root crontab（每日 04:30 EFU 目录树扫描）
│   └── user.txt                  # 用户 crontab（06:00 上传清理 + 00:00 archivebox 存档）
└── systemd/
    ├── podman-restart.service   # 系统级：rootful 容器开机自启
    └── upload-cleanup.{service,timer}    # 每日 06:00 清理 OpenWebUI 旧上传
Podman/
├── ArchiveBox/                  # 网页存档（8000，归档实体在机械盘）
├── Antigravity-Manager/         # AI 网关（8045，账号管理 + 协议代理）
├── Bili-Sync/ FluxDown/ Frpc/ Jellyfin/ Openlist/ OpenWebUI/
├── PeerBanHelper/ qBittorrent-Enhanced-Edition/ Scrutiny/ Syncthing/
├── Ubuntu-Xfce/                 # 代理核心容器（V2rayN，1145 出口，rootful）
├── LocalSend/                   # 自建镜像 ywpc05/localsend-cli（构建见独立仓库）
├── Minecraft/                   # MC 服务端 + Mefrp-MC 三方 frp（按需启动）
├── Terraria/                    # Terraria 服务端 + Mefrp-TR 三方 frp（按需启动）
└── Frpc/config/frpc.toml        # frp 隧道配置（token 已脱敏）
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
| `Podman/Antigravity-Manager/docker-compose.yml` | API_KEY / WEB_PASSWORD |
| `Podman/Minecraft/Mefrp-MC/docker-compose.yml` | 三方 frp 令牌 |
| `Podman/Terraria/Mefrp-TR/docker-compose.yml` | 三方 frp 令牌 |
| `Podman/Terraria/Trlatest/config/serverconfig.txt` | 服务器密码 |
| `Tools/rar_background_archive.sh` / `_vn.sh` / `rar_background_unpacker.sh` | RAR 压缩密码 / SMB 账户密码 |
| `Tools/wakeup_pc.sh` | WoL 目标 MAC |

**不包含**（敏感或未改动，仅本地保管）：

- `~/.ssh/authorized_keys`（SSH 公钥）
- `~/Podman/Ubuntu-Xfce/config/Software/v2rayN/`（订阅与代理配置）
- `~/Podman/Terraria/Trlatest/config/` 中的世界文件 `*.wld` 与 `banlist.txt`（游戏数据）
- VeraCrypt 加密卷（挂载点不公开，仓库中以 `Vault-1`/`Vault-2` 指代）的密码
- `/etc/ssh/sshd_config`、`/etc/selinux/`（均为发行版默认，未做改动）
- 已弃用的 podman 代理 override.conf 备份（无需还原，见维护手册 3.2 节）
- 已移除：`localsend-update.{service,timer}`（镜像已发布 Docker Hub，更新走 `check_container_updates.sh`）

## 恢复用法

```bash
git clone https://github.com/100pangci/fedora-nas-config.git
# 对照《Fedora Server 系统安装与维护手册》Phase 2~7 逐步还原
# 将各文件拷回目标路径后，填入所有 <REDACTED-...> 占位符
```

## 关联仓库

- **localsend-cli-container**：<https://github.com/100pangci/localsend-cli-container>（LocalSend CLI 自建镜像与构建发布流水线）