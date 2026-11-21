#!/bin/bash
# Quick AEGIS installer for VPS
echo "=== Quick AEGIS Installer ==="

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Downloading aegis-linux-$ARCH..."
mkdir -p /opt/aegis
curl -fsSL "https://github.com/qualitydll/cirrus/releases/download/aegis-v1.0.1/aegis-linux-$ARCH" -o /opt/aegis/aegis
chmod +x /opt/aegis/aegis

# Generate secret
SECRET=$(openssl rand -hex 32)
echo "Secret: $SECRET"

# Create systemd service
cat > /etc/systemd/system/aegis.service <<EOF
[Unit]
Description=AEGIS VPN Server
After=network.target

[Service]
Type=simple
ExecStart=/opt/aegis/aegis server -listen :8443 -secret $SECRET
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable aegis
systemctl start aegis

echo "=== Installation Complete ==="
echo "Server: $(hostname -I | awk '{print $1}'):8443"
echo "Secret: $SECRET"
echo ""
echo "To connect:"
echo "  aegis client -server $(hostname -I | awk '{print $1}'):8443 -secret $SECRET -listen 127.0.0.1:1080"
