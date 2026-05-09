# Rocky Linux 9 Shadowsocks Podman 一键安装脚本

这是一个适用于 **Rocky Linux 9** 的 Shadowsocks Rust 一键安装脚本。

脚本使用 **Podman** 部署 Shadowsocks Rust 服务，并自动生成适用于 **Clash / ClashX / Clash Verge / Clash Meta** 的 YAML 配置文件。

项目地址：

```text
https://github.com/phpev/rocky9-ss-podman-installer
```

---

## 功能特性

- 支持 Rocky Linux 9
- 使用 Podman 部署 Shadowsocks Rust
- 不依赖 Docker
- 自动安装必要依赖
- 自动创建 Shadowsocks 配置文件
- 自动生成 Clash 兼容配置文件
- 支持 TCP 和 UDP
- 使用 systemd 设置开机自启
- 自动配置 firewalld 防火墙端口
- 支持随机生成密码
- 支持自定义端口、密码和加密方式

---

## 系统要求

- 操作系统：Rocky Linux 9
- 架构：x86_64
- 权限：root 用户或 sudo 权限
- 内存：建议 1GB 以上
- 磁盘：建议至少 2GB 可用空间
- 网络：服务器可以访问 Rocky Linux 官方软件源和容器镜像仓库

---

## 快速安装

请先切换到 root 用户：

```bash
sudo -i
```

下载脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/phpev/rocky9-ss-podman-installer/main/install-ss-podman-zh.sh -o install-ss-podman-zh.sh
```

赋予执行权限：

```bash
chmod +x install-ss-podman-zh.sh
```

运行安装脚本：

```bash
bash install-ss-podman-zh.sh
```

---

## 一行命令安装

也可以使用下面的一行命令直接安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/phpev/rocky9-ss-podman-installer/main/install-ss-podman-zh.sh)
```

推荐先下载脚本并检查内容后再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/phpev/rocky9-ss-podman-installer/main/install-ss-podman-zh.sh -o install-ss-podman-zh.sh
less install-ss-podman-zh.sh
bash install-ss-podman-zh.sh
```

---

## 安装完成后

脚本运行完成后，通常会输出以下信息：

- Shadowsocks 服务器地址
- 端口
- 加密方式
- 密码
- Clash 配置文件路径
- 服务状态检查命令

示例：

```text
服务器地址：1.2.3.4
端口：8388
加密方式：2022-blake3-aes-256-gcm
密码：xxxxxxxxxxxx
Clash 配置文件：/root/rocky9-vps-backup.yaml
```

---

## ClashX 使用方法

安装完成后，将服务器上生成的 YAML 配置文件下载到本地电脑。

默认配置文件路径：

```bash
/root/rocky9-vps-backup.yaml
```

可以使用 `scp` 下载：

```bash
scp root@你的服务器IP:/root/rocky9-vps-backup.yaml .
```

然后在 ClashX / Clash Verge / Clash Meta 中导入该 YAML 文件即可。

---

## 常用管理命令

查看正在运行的容器：

```bash
podman ps
```

查看所有容器：

```bash
podman ps -a
```

查看 Shadowsocks 日志：

```bash
podman logs shadowsocks-rust
```

重启服务：

```bash
systemctl restart container-shadowsocks-rust.service
```

查看 systemd 服务状态：

```bash
systemctl status container-shadowsocks-rust.service
```

停止服务：

```bash
systemctl stop container-shadowsocks-rust.service
```

启动服务：

```bash
systemctl start container-shadowsocks-rust.service
```

设置开机自启：

```bash
systemctl enable container-shadowsocks-rust.service
```

取消开机自启：

```bash
systemctl disable container-shadowsocks-rust.service
```

---

## 防火墙说明

脚本会自动放行 Shadowsocks 使用的端口。

如果你手动设置端口，例如 `8388`，可以手动放行：

```bash
firewall-cmd --permanent --add-port=8388/tcp
firewall-cmd --permanent --add-port=8388/udp
firewall-cmd --reload
```

查看已开放端口：

```bash
firewall-cmd --list-ports
```

如果使用云服务器，还需要在云厂商控制台的安全组中放行对应端口的 TCP 和 UDP。

---

## 卸载方法

停止服务：

```bash
systemctl stop container-shadowsocks-rust.service
```

取消开机自启：

```bash
systemctl disable container-shadowsocks-rust.service
```

删除 systemd 服务文件：

```bash
rm -f /etc/systemd/system/container-shadowsocks-rust.service
systemctl daemon-reload
```

删除容器：

```bash
podman rm -f shadowsocks-rust
```

删除 Shadowsocks 配置文件：

```bash
rm -rf /etc/shadowsocks-rust
```

删除 Clash 配置文件：

```bash
rm -f /root/rocky9-vps-backup.yaml
```

如需删除 Podman：

```bash
dnf remove -y podman
```

---

## 常见问题

### 1. dnf 报 SSL certificate problem: certificate is not yet valid

这通常是服务器系统时间不正确导致的。

检查时间：

```bash
date
timedatectl status
```

启用 NTP 时间同步：

```bash
timedatectl set-ntp true
```

如果时间仍然不正确，可以先手动设置时间。

设置 UTC 时间示例：

```bash
timedatectl set-ntp false
timedatectl set-timezone UTC
timedatectl set-time "2026-05-09 18:10:00"
hwclock --systohc
```

然后清理缓存：

```bash
dnf clean all
rm -rf /var/cache/dnf
dnf makecache
```

### 2. dnf makecache 出现 Killed

这通常是服务器内存不足导致的，可以添加 swap。

创建 2GB swap：

```bash
dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

设置开机自动启用：

```bash
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

检查 swap：

```bash
free -h
swapon --show
```

如果 EPEL 元数据导致内存占用过高，可以临时禁用 EPEL：

```bash
dnf makecache --disablerepo=epel
```

### 3. dnf install ntp 找不到软件包

Rocky Linux 9 默认使用 `chrony`，不是 `ntp`。

安装 chrony：

```bash
dnf install -y chrony
systemctl enable --now chronyd
timedatectl set-ntp true
chronyc makestep
```

### 4. 客户端无法连接

请检查以下内容：

1. VPS 系统防火墙是否放行端口
2. 云厂商安全组是否放行 TCP 和 UDP
3. Shadowsocks 容器是否正在运行
4. 服务器 IP、端口、密码、加密方式是否一致
5. 本地 Clash 配置是否导入正确

检查容器：

```bash
podman ps
```

检查监听端口：

```bash
ss -tunlp | grep 8388
```

查看日志：

```bash
podman logs shadowsocks-rust
```

### 5. Podman 拉取镜像失败

可以检查网络连接和镜像仓库访问情况：

```bash
podman pull ghcr.io/shadowsocks/ssserver-rust:latest
```

如果无法访问 GitHub Container Registry，可以尝试更换网络环境或使用其他可用镜像源。

---

## 安全提醒

请不要将以下文件上传到 GitHub 或公开网络：

```text
/etc/shadowsocks-rust/config.json
/root/rocky9-vps-backup.yaml
.env
*.key
*.pem
```

这些文件可能包含：

- 服务器 IP
- Shadowsocks 端口
- Shadowsocks 密码
- Clash 代理配置
- 私钥或 Token

如果误传了密码或配置文件，请立即更换 Shadowsocks 密码，并清理仓库历史记录中的敏感信息。

---

## 推荐的 .gitignore

建议仓库中添加 `.gitignore`：

```gitignore
# generated configs
*.yaml
*.yml
config.json
rocky9-vps-backup.yaml

# secrets
*.key
*.pem
*.env
.env

# logs
*.log

# macOS
.DS_Store
```

---

## 免责声明

本项目仅用于学习、测试和个人服务器管理用途。

使用本项目时，请遵守所在国家或地区的法律法规，以及云服务器服务商的使用条款。

作者不对因使用本项目造成的任何直接或间接损失负责。

---

## License

MIT
