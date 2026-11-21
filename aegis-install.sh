#!/bin/bash
# AEGIS Server Installer — installs the AEGIS Go daemon on VPS
set -e

AEGIS_VERSION="latest"
AEGIS_DIR="/opt/aegis"
AEGIS_BIN="$AEGIS_DIR/aegis"
AEGIS_PORT=8443
AEGIS_SECRET=""

echo "=== AEGIS Server Installer ==="
echo "Installing AEGIS daemon..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

# Download appropriate binary
case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

case "$OS" in
    ubuntu|debian|centos|fedora|rhel)
        BINARY_NAME="aegis-linux-$ARCH"
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

echo "Downloading $BINARY_NAME..."
mkdir -p "$AEGIS_DIR"

# Try GitHub releases first, fallback to direct download
DOWNLOAD_URL="https://github.com/qualitydll/aegis/releases/download/aegis-v1/$BINARY_NAME"
if ! curl -fsSL "$DOWNLOAD_URL" -o "$AEGIS_BIN"; then
    echo "GitHub release not found, trying alternative..."
    # For now, user must manually place binary
    echo "Please place aegis binary at $AEGIS_BIN manually"
    exit 1
fi

chmod +x "$AEGIS_BIN"
echo "Binary installed to $AEGIS_BIN"

# Generate secret if not provided
if [ -z "$AEGIS_SECRET" ]; then
    AEGIS_SECRET=$(openssl rand -hex 32)
    echo "Generated secret: $AEGIS_SECRET"
fi

# Create systemd service
if command -v systemctl &> /dev/null; then
    cat > /etc/systemd/system/aegis.service <<EOF
[Unit]
Description=AEGIS VPN Server
After=network.target

[Service]
Type=simple
ExecStart=$AEGIS_BIN server -listen :$AEGIS_PORT -secret $AEGIS_SECRET
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable aegis
    systemctl start aegis
    echo "AEGIS service started on port $AEGIS_PORT"
else
    echo "systemd not found, starting manually..."
    nohup "$AEGIS_BIN" server -listen :$AEGIS_PORT -secret "$AEGIS_SECRET" > /var/log/aegis.log 2>&1 &
    echo "AEGIS started with PID $!"
fi

echo ""
echo "=== Installation Complete ==="
echo "Server: $(hostname -I | awk '{print $1}'):$AEGIS_PORT"
echo "Secret: $AEGIS_SECRET"
echo ""
echo "To connect from client:"
echo "  aegis client -server $(hostname -I | awk '{print $1}'):$AEGIS_PORT -secret $AEGIS_SECRET -listen 127.0.0.1:1080"
