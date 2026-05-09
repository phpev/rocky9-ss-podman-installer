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
echo " Rocky Linux 9 Shadowsocks Podman One-Click Install Script"
echo " Automatically installs server and generates ClashX backup config"
echo "=========================================================="
echo

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root user or use sudo:"
  echo
  echo "sudo bash install-ss-podman-clashx.sh"
  exit 1
fi

echo "==> 1. Installing basic dependencies..."
dnf install -y podman firewalld curl openssl python3 nano

echo
echo "==> 2. Starting firewalld..."
systemctl enable --now firewalld

echo
echo "Enter Shadowsocks listening port, press Enter for default ${DEFAULT_PORT}:"
read -r INPUT_PORT
SS_PORT="${INPUT_PORT:-$DEFAULT_PORT}"

if ! [[ "${SS_PORT}" =~ ^[0-9]+$ ]] || [[ "${SS_PORT}" -lt 1 ]] || [[ "${SS_PORT}" -gt 65535 ]]; then
  echo "Invalid port: ${SS_PORT}"
  exit 1
fi

echo
echo "Enter encryption method, press Enter for default ${DEFAULT_METHOD}:"
echo "Recommended options:"
echo "  1. aes-256-gcm"
echo "  2. chacha20-ietf-poly1305"
read -r INPUT_METHOD
SS_METHOD="${INPUT_METHOD:-$DEFAULT_METHOD}"

echo
echo "Enter Shadowsocks password, press Enter to generate strong password automatically:"
echo "Tip: If entering manually, use only letters, numbers, underscores, hyphens - avoid quotes."
read -r INPUT_PASSWORD

if [[ -z "${INPUT_PASSWORD}" ]]; then
  SS_PASSWORD="$(openssl rand -base64 24)"
else
  SS_PASSWORD="${INPUT_PASSWORD}"
fi

echo
echo "Enter your VPS public IPv4, press Enter to auto-detect:"
read -r INPUT_PUBLIC_IP

if [[ -n "${INPUT_PUBLIC_IP}" ]]; then
  PUBLIC_IP="${INPUT_PUBLIC_IP}"
else
  echo "Attempting to auto-detect public IPv4..."
  PUBLIC_IP="$(
    curl -4fsS https://api.ipify.org 2>/dev/null \
    || curl -4fsS https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
  )"
fi

if [[ -z "${PUBLIC_IP}" ]]; then
  echo "Failed to auto-detect public IP, please re-run script and enter manually."
  exit 1
fi

echo
echo "Select traffic mode for ClashX backup config:"
echo "  1. Route almost all traffic through VPS, only local LAN direct"
echo "  2. Route China and LAN direct, all other traffic through VPS"
echo
echo "Press Enter for default option 1:"
read -r INPUT_RULE_MODE
RULE_MODE="${INPUT_RULE_MODE:-1}"

if [[ "${RULE_MODE}" != "1" && "${RULE_MODE}" != "2" ]]; then
  echo "Invalid selection, using mode 1 by default."
  RULE_MODE="1"
fi

echo
echo "Using the following configuration:"
echo "----------------------------------------------------------"
echo "VPS Public IP: ${PUBLIC_IP}"
echo "Shadowsocks Port: ${SS_PORT}"
echo "Encryption Method: ${SS_METHOD}"
echo "Shadowsocks Password: ${SS_PASSWORD}"
echo "Podman Image: ${IMAGE_NAME}"
echo "Config Directory: ${SS_DIR}"
echo "ClashX Config: ${CLASH_CONFIG}"
if [[ "${RULE_MODE}" == "1" ]]; then
  echo "ClashX Mode: Route almost all traffic through VPS, only local LAN direct"
else
  echo "ClashX Mode: Route China and LAN direct, all other traffic through VPS"
fi
echo "----------------------------------------------------------"
echo

echo "Confirm installation? Enter y to continue, any other key to exit:"
read -r CONFIRM

if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "Installation cancelled."
  exit 0
fi

echo
echo "==> 3. Creating config directory..."
mkdir -p "${SS_DIR}"
chmod 700 "${SS_DIR}"

echo
echo "==> 4. Generating Shadowsocks server config..."

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
echo "==> 5. Pulling Shadowsocks Rust image..."
podman pull "${IMAGE_NAME}"

echo
echo "==> 6. Stopping and cleaning old services and containers..."

systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
podman rm -f "${CONTAINER_NAME}" 2>/dev/null || true

echo
echo "==> 7. Generating systemd service file..."

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
echo "==> 8. Opening ports in system firewall..."
firewall-cmd --permanent --add-port="${SS_PORT}/tcp"
firewall-cmd --permanent --add-port="${SS_PORT}/udp"
firewall-cmd --reload

echo
echo "==> 9. Starting Shadowsocks systemd service..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo
echo "==> 10. Generating ClashX backup config file..."

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

# Use json.dumps to generate safe strings for YAML
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

  # Popular international services
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

  # Local LAN direct
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
'''

if rule_mode == "2":
    base += '''
  # China IP direct
  - GEOIP,CN,DIRECT
'''

base += '''
  # All other traffic through VPS
  - MATCH,Final
'''

with open(clash_config, "w", encoding="utf-8") as f:
  f.write(base)
PY

chmod 600 "${CLASH_CONFIG}"

echo
echo "==> 11. Checking service status..."
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "systemd service running normally: ${SERVICE_NAME}"
else
  echo "systemd service not running properly, check with:"
  echo "systemctl status ${SERVICE_NAME}"
  echo "journalctl -u ${SERVICE_NAME} -e --no-pager"
  exit 1
fi

if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Podman container running normally: ${CONTAINER_NAME}"
else
  echo "Podman container may not be running, check with:"
  echo "podman ps -a"
  echo "journalctl -u ${SERVICE_NAME} -e --no-pager"
  exit 1
fi

echo
echo "=========================================================="
echo "Installation completed!"
echo "=========================================================="
echo
echo "Shadowsocks Server Information:"
echo "----------------------------------------------------------"
echo "Server IP: ${PUBLIC_IP}"
echo "Port: ${SS_PORT}"
echo "Encryption Method: ${SS_METHOD}"
echo "Password: ${SS_PASSWORD}"
echo "Protocol: Shadowsocks"
echo "UDP: true"
echo "----------------------------------------------------------"
echo
echo "ClashX config file generated:"
echo
echo "${CLASH_CONFIG}"
echo
echo "Copy config file to your Mac with this command:"
echo
echo "scp root@${PUBLIC_IP}:${CLASH_CONFIG} ~/Desktop/rocky9-vps-backup.yaml"
echo
echo "Then import ~/Desktop/rocky9-vps-backup.yaml into ClashX."
echo
echo "Important Note:"
echo "You must allow these ports in your VPS provider firewall/security group:"
echo
echo "TCP ${SS_PORT}"
echo "UDP ${SS_PORT}"
echo
echo "Common Management Commands:"
echo "----------------------------------------------------------"
echo "Check service status: systemctl status ${SERVICE_NAME}"
echo "View live logs: journalctl -u ${SERVICE_NAME} -f"
echo "List containers: podman ps"
echo "Restart service: systemctl restart ${SERVICE_NAME}"
echo "Stop service: systemctl stop ${SERVICE_NAME}"
echo "View config: cat ${SS_CONFIG}"
echo "View ClashX config: cat ${CLASH_CONFIG}"
echo "----------------------------------------------------------"
echo
