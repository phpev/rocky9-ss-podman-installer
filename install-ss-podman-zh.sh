#!/usr/bin/env bash

set -euo pipefail

# ==========================================================
# Rocky Linux 9 + Podman + Shadowsocks Rust + ClashX Config
# ==========================================================

SS_DIR="/opt/shadowsocks"
SS_CONFIG="${SS_DIR}/config.json"
CLASH_CONFIG="${SS_DIR}/rocky9-vps-backup.yaml"

CONTAINER_NAME="ssserver"
SERVICE_NAME="ssserver.service"
IMAGE_NAME="ghcr.io/shadowsocks/ssserver-rust:latest"

DEFAULT_PORT="8388"
DEFAULT_METHOD="aes-256-gcm"

echo "=========================================================="
echo " Rocky Linux 9 Shadowsocks Podman 一键安装脚本"
echo " 自动安装服务端，并生成 ClashX 备用配置文件"
echo "=========================================================="
echo

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 用户执行，或者使用 sudo："
  echo
  echo "sudo bash install-ss-podman-clashx.sh"
  exit 1
fi

echo "==> 1. 安装基础依赖..."
dnf install -y podman firewalld curl openssl python3 nano

echo
echo "==> 2. 启动 firewalld..."
systemctl enable --now firewalld

echo
echo "请输入 Shadowsocks 监听端口，直接回车默认 ${DEFAULT_PORT}:"
read -r INPUT_PORT
SS_PORT="${INPUT_PORT:-$DEFAULT_PORT}"

if ! [[ "${SS_PORT}" =~ ^[0-9]+$ ]] || [[ "${SS_PORT}" -lt 1 ]] || [[ "${SS_PORT}" -gt 65535 ]]; then
  echo "端口不合法：${SS_PORT}"
  exit 1
fi

echo
echo "请输入加密方式，直接回车默认 ${DEFAULT_METHOD}:"
echo "常用推荐："
echo "  1. aes-256-gcm"
echo "  2. chacha20-ietf-poly1305"
read -r INPUT_METHOD
SS_METHOD="${INPUT_METHOD:-$DEFAULT_METHOD}"

echo
echo "请输入 Shadowsocks 密码，直接回车自动生成强密码:"
echo "提示：如果手动输入，建议只使用字母、数字、下划线、短横线，避免引号。"
read -r INPUT_PASSWORD

if [[ -z "${INPUT_PASSWORD}" ]]; then
  SS_PASSWORD="$(openssl rand -base64 24)"
else
  SS_PASSWORD="${INPUT_PASSWORD}"
fi

echo
echo "请输入你的 VPS 公网 IPv4，直接回车自动获取:"
read -r INPUT_PUBLIC_IP

if [[ -n "${INPUT_PUBLIC_IP}" ]]; then
  PUBLIC_IP="${INPUT_PUBLIC_IP}"
else
  echo "正在尝试自动获取公网 IPv4..."
  PUBLIC_IP="$(
    curl -4fsS https://api.ipify.org 2>/dev/null \
    || curl -4fsS https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
  )"
fi

if [[ -z "${PUBLIC_IP}" ]]; then
  echo "无法自动获取公网 IP，请重新运行脚本并手动输入。"
  exit 1
fi

echo
echo "请选择 ClashX 备用配置的流量模式："
echo "  1. 几乎所有流量走 VPS，仅局域网直连"
echo "  2. 国内和局域网直连，其余流量走 VPS"
echo
echo "直接回车默认选择 1:"
read -r INPUT_RULE_MODE
RULE_MODE="${INPUT_RULE_MODE:-1}"

if [[ "${RULE_MODE}" != "1" && "${RULE_MODE}" != "2" ]]; then
  echo "选择不合法，默认使用模式 1。"
  RULE_MODE="1"
fi

echo
echo "即将使用以下配置："
echo "----------------------------------------------------------"
echo "VPS 公网 IP: ${PUBLIC_IP}"
echo "Shadowsocks 端口: ${SS_PORT}"
echo "加密方式: ${SS_METHOD}"
echo "Shadowsocks 密码: ${SS_PASSWORD}"
echo "Podman 镜像: ${IMAGE_NAME}"
echo "配置目录: ${SS_DIR}"
echo "ClashX 配置: ${CLASH_CONFIG}"
if [[ "${RULE_MODE}" == "1" ]]; then
  echo "ClashX 模式: 几乎所有流量走 VPS，仅局域网直连"
else
  echo "ClashX 模式: 国内和局域网直连，其余流量走 VPS"
fi
echo "----------------------------------------------------------"
echo

echo "确认继续安装？输入 y 继续，其他任意键退出："
read -r CONFIRM

if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "已取消。"
  exit 0
fi

echo
echo "==> 3. 创建配置目录..."
mkdir -p "${SS_DIR}"
chmod 700 "${SS_DIR}"

echo
echo "==> 4. 生成 Shadowsocks 服务端配置..."

export SS_CONFIG
export SS_PORT
export SS_PASSWORD
export SS_METHOD

python3 <<'PY'
import json
import os

config_path = os.environ["SS_CONFIG"]

data = {
    "server": "0.0.0.0",
    "server_port": int(os.environ["SS_PORT"]),
    "password": os.environ["SS_PASSWORD"],
    "method": os.environ["SS_METHOD"],
    "timeout": 300,
    "mode": "tcp_and_udp"
}

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

chmod 600 "${SS_CONFIG}"

echo
echo "==> 5. 拉取 Shadowsocks Rust 镜像..."
podman pull "${IMAGE_NAME}"

echo
echo "==> 6. 停止并清理旧服务和旧容器..."

systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
podman rm -f "${CONTAINER_NAME}" 2>/dev/null || true

echo
echo "==> 7. 生成 systemd 服务文件..."

PODMAN_BIN="$(command -v podman)"

cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Shadowsocks Rust Server by Podman
Wants=network-online.target
After=network-online.target firewalld.service

[Service]
Type=simple
Restart=always
RestartSec=5

ExecStartPre=-${PODMAN_BIN} rm -f ${CONTAINER_NAME}

ExecStart=${PODMAN_BIN} run \\
  --name ${CONTAINER_NAME} \\
  --rm \\
  -p ${SS_PORT}:${SS_PORT}/tcp \\
  -p ${SS_PORT}:${SS_PORT}/udp \\
  -v ${SS_CONFIG}:/etc/shadowsocks-rust/config.json:ro,Z \\
  ${IMAGE_NAME} \\
  ssserver -c /etc/shadowsocks-rust/config.json

ExecStop=${PODMAN_BIN} stop ${CONTAINER_NAME}
ExecStopPost=-${PODMAN_BIN} rm -f ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF

echo
echo "==> 8. 开放系统防火墙端口..."
firewall-cmd --permanent --add-port="${SS_PORT}/tcp"
firewall-cmd --permanent --add-port="${SS_PORT}/udp"
firewall-cmd --reload

echo
echo "==> 9. 启动 Shadowsocks systemd 服务..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo
echo "==> 10. 生成 ClashX 备用配置文件..."

export CLASH_CONFIG
export PUBLIC_IP
export RULE_MODE

python3 <<'PY'
import os
import json

clash_config = os.environ["CLASH_CONFIG"]
public_ip = os.environ["PUBLIC_IP"]
ss_port = os.environ["SS_PORT"]
ss_method = os.environ["SS_METHOD"]
ss_password = os.environ["SS_PASSWORD"]
rule_mode = os.environ["RULE_MODE"]

# 用 json.dumps 生成 YAML 中安全可用的字符串
node_name = "Rocky9-VPS-Backup"
node_name_q = json.dumps(node_name, ensure_ascii=False)
public_ip_q = json.dumps(public_ip, ensure_ascii=False)
ss_method_q = json.dumps(ss_method, ensure_ascii=False)
ss_password_q = json.dumps(ss_password, ensure_ascii=False)

base = f'''port: 7890
socks-port: 7891
mixed-port: 7893
allow-lan: false
unified-delay: true
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090

dns:
  enable: true
  ipv6: false
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - localhost.ptlogin2.qq.com
    - "*.srv.nintendo.net"
    - "*.stun.playstation.net"
    - xbox.*.microsoft.com
    - "*.xboxlive.com"
  nameserver:
    - 119.29.29.29
    - 223.5.5.5
    - 1.1.1.1
    - 8.8.8.8
  fallback:
    - tls://1.1.1.1:853
    - tls://8.8.8.8:853
  fallback-filter:
    geoip: true
    geoip-code: CN

proxies:
  - name: {node_name_q}
    type: ss
    server: {public_ip_q}
    port: {ss_port}
    cipher: {ss_method_q}
    password: {ss_password_q}
    udp: true

proxy-groups:
  - name: Proxies
    type: select
    proxies:
      - {node_name_q}
      - DIRECT

  - name: OpenAI
    type: select
    proxies:
      - {node_name_q}
      - Proxies
      - DIRECT

  - name: YouTube
    type: select
    proxies:
      - {node_name_q}
      - Proxies
      - DIRECT

  - name: Netflix
    type: select
    proxies:
      - {node_name_q}
      - Proxies
      - DIRECT

  - name: Telegram
    type: select
    proxies:
      - {node_name_q}
      - Proxies
      - DIRECT

  - name: Apple
    type: select
    proxies:
      - DIRECT
      - {node_name_q}
      - Proxies

  - name: Final
    type: select
    proxies:
      - {node_name_q}
      - Proxies
      - DIRECT

rules:
  # OpenAI / ChatGPT
  - DOMAIN-SUFFIX,openai.com,OpenAI
  - DOMAIN-SUFFIX,chatgpt.com,OpenAI
  - DOMAIN-SUFFIX,oaistatic.com,OpenAI
  - DOMAIN-SUFFIX,oaiusercontent.com,OpenAI
  - DOMAIN-SUFFIX,auth0.com,OpenAI
  - DOMAIN-SUFFIX,arkoselabs.com,OpenAI
  - DOMAIN-SUFFIX,intercom.io,OpenAI
  - DOMAIN-SUFFIX,intercomcdn.com,OpenAI
  - DOMAIN-SUFFIX,statsig.com,OpenAI
  - DOMAIN-SUFFIX,featuregates.org,OpenAI
  - DOMAIN-KEYWORD,openai,OpenAI

  # Google / YouTube
  - DOMAIN-SUFFIX,youtube.com,YouTube
  - DOMAIN-SUFFIX,youtu.be,YouTube
  - DOMAIN-SUFFIX,ytimg.com,YouTube
  - DOMAIN-SUFFIX,googlevideo.com,YouTube
  - DOMAIN-SUFFIX,youtubei.googleapis.com,YouTube
  - DOMAIN-SUFFIX,youtube.googleapis.com,YouTube
  - DOMAIN-KEYWORD,youtube,YouTube

  # Netflix
  - DOMAIN-SUFFIX,netflix.com,Netflix
  - DOMAIN-SUFFIX,netflix.net,Netflix
  - DOMAIN-SUFFIX,nflxvideo.net,Netflix
  - DOMAIN-SUFFIX,nflximg.net,Netflix
  - DOMAIN-SUFFIX,nflxso.net,Netflix
  - DOMAIN-SUFFIX,nflxext.com,Netflix
  - DOMAIN-SUFFIX,fast.com,Netflix

  # Telegram
  - DOMAIN-SUFFIX,t.me,Telegram
  - DOMAIN-SUFFIX,telegram.org,Telegram
  - DOMAIN-SUFFIX,telegram.me,Telegram
  - DOMAIN-SUFFIX,telegram-cdn.org,Telegram
  - DOMAIN-SUFFIX,telegra.ph,Telegram
  - IP-CIDR,91.108.0.0/16,Telegram,no-resolve
  - IP-CIDR,149.154.160.0/20,Telegram,no-resolve

  # Apple
  - DOMAIN-SUFFIX,apple.com,Apple
  - DOMAIN-SUFFIX,icloud.com,Apple
  - DOMAIN-SUFFIX,icloud-content.com,Apple
  - DOMAIN-SUFFIX,aaplimg.com,Apple
  - DOMAIN-SUFFIX,cdn-apple.com,Apple

  # 常用国外服务
  - DOMAIN-SUFFIX,google.com,Proxies
  - DOMAIN-SUFFIX,gstatic.com,Proxies
  - DOMAIN-SUFFIX,gmail.com,Proxies
  - DOMAIN-SUFFIX,github.com,Proxies
  - DOMAIN-SUFFIX,githubusercontent.com,Proxies
  - DOMAIN-SUFFIX,githubassets.com,Proxies
  - DOMAIN-SUFFIX,x.com,Proxies
  - DOMAIN-SUFFIX,twitter.com,Proxies
  - DOMAIN-SUFFIX,facebook.com,Proxies
  - DOMAIN-SUFFIX,instagram.com,Proxies
  - DOMAIN-SUFFIX,discord.com,Proxies
  - DOMAIN-SUFFIX,reddit.com,Proxies

  # 局域网直连
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
'''

if rule_mode == "2":
    base += '''
  # 国内 IP 直连
  - GEOIP,CN,DIRECT
'''

base += '''
  # 其余流量走 VPS
  - MATCH,Final
'''

with open(clash_config, "w", encoding="utf-8") as f:
    f.write(base)
PY

chmod 600 "${CLASH_CONFIG}"

echo
echo "==> 11. 检查服务状态..."
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "systemd 服务运行正常：${SERVICE_NAME}"
else
  echo "systemd 服务未正常运行，请查看："
  echo "systemctl status ${SERVICE_NAME}"
  echo "journalctl -u ${SERVICE_NAME} -e --no-pager"
  exit 1
fi

if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Podman 容器运行正常：${CONTAINER_NAME}"
else
  echo "Podman 容器可能未运行，请查看："
  echo "podman ps -a"
  echo "journalctl -u ${SERVICE_NAME} -e --no-pager"
  exit 1
fi

echo
echo "=========================================================="
echo "安装完成！"
echo "=========================================================="
echo
echo "Shadowsocks 服务端信息："
echo "----------------------------------------------------------"
echo "服务器 IP: ${PUBLIC_IP}"
echo "端口: ${SS_PORT}"
echo "加密方式: ${SS_METHOD}"
echo "密码: ${SS_PASSWORD}"
echo "协议: Shadowsocks"
echo "UDP: true"
echo "----------------------------------------------------------"
echo
echo "ClashX 配置文件已生成："
echo
echo "${CLASH_CONFIG}"
echo
echo "你可以在 Mac 上执行以下命令复制配置文件："
echo
echo "scp root@${PUBLIC_IP}:${CLASH_CONFIG} ~/Desktop/rocky9-vps-backup.yaml"
echo
echo "然后把 ~/Desktop/rocky9-vps-backup.yaml 导入 ClashX。"
echo
echo "重要提醒："
echo "你还需要去 VPS 服务商后台安全组/防火墙放行："
echo
echo "TCP ${SS_PORT}"
echo "UDP ${SS_PORT}"
echo
echo "常用管理命令："
echo "----------------------------------------------------------"
echo "查看服务状态： systemctl status ${SERVICE_NAME}"
echo "查看运行日志： journalctl -u ${SERVICE_NAME} -f"
echo "查看容器：     podman ps"
echo "重启服务：     systemctl restart ${SERVICE_NAME}"
echo "停止服务：     systemctl stop ${SERVICE_NAME}"
echo "查看配置：     cat ${SS_CONFIG}"
echo "查看 ClashX：  cat ${CLASH_CONFIG}"
echo "----------------------------------------------------------"
echo
