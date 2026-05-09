# Rocky Linux 9 Shadowsocks Podman Installer

One-click installer for Shadowsocks Rust server on Rocky Linux 9 using Podman and systemd.

## Features

- Uses Podman instead of Docker
- Supports TCP and UDP
- Generates Clash-compatible YAML config
- Supports systemd auto start
- Works on Rocky Linux 9

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/phpev/rocky9-ss-podman-installer/main/install-ss-podman.sh -o install-ss-podman.sh
chmod +x install-ss-podman.sh
sudo bash install-ss-podman.sh
```

## Notes

Do not commit generated config files containing your server IP or password.

## License

MIT
