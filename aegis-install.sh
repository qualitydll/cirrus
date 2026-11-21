#!/bin/bash
# AEGIS Server Installer — installs the AEGIS Go daemon on VPS
set -e

AEGIS_VERSION="latest"
AEGIS_DIR="/opt/aegis"
AEGIS_BIN="$AEGIS_DIR/aegis"
AEGIS_PORT=8443
AEGIS_SECRET=""
AEGIS_TRANSPORT="tcp"
AEGIS_FEC="false"
AEGIS_PORT=8443

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            AEGIS_PORT="$2"
            shift 2
            ;;
        --transport)
            AEGIS_TRANSPORT="$2"
            shift 2
            ;;
        --fec)
            AEGIS_FEC="true"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== AEGIS Server Installer ==="
echo "Transport: $AEGIS_TRANSPORT"
echo "FEC: $AEGIS_FEC"
echo "Port: $AEGIS_PORT"
echo "Installing AEGIS daemon..."

# Detect OS and architecture
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Determine binary name
case "$OS" in
    ubuntu|debian|centos|fedora|rhel|alpine)
        BINARY_NAME="aegis-linux-$ARCH"
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

echo "Downloading $BINARY_NAME for $OS/$ARCH..."
mkdir -p "$AEGIS_DIR"

# Try GitHub releases first
DOWNLOAD_URL="https://github.com/qualitydll/cirrus/releases/download/aegis-v5/$BINARY_NAME"
if ! curl -fsSL "$DOWNLOAD_URL" -o "$AEGIS_BIN"; then
    echo "GitHub release not found, trying artifacts..."
    # Fallback: try to get from latest workflow artifacts
    # For now, we'll provide manual instructions
    echo "Please download $BINARY_NAME manually and place it at $AEGIS_BIN"
    echo "Or run this script with the binary already in place."
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
Description=AEGIS VPN Server ($AEGIS_TRANSPORT)
After=network.target

[Service]
Type=simple
ExecStart=$AEGIS_BIN server -listen :$AEGIS_PORT -secret $AEGIS_SECRET -transport $AEGIS_TRANSPORT $(if [ "$AEGIS_FEC" = "true" ]; then echo "-fec"; fi)
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable aegis
    systemctl start aegis
    echo "AEGIS service started on port $AEGIS_PORT ($AEGIS_TRANSPORT)"
else
    echo "systemd not found, starting manually..."
    nohup "$AEGIS_BIN" server -listen :$AEGIS_PORT -secret "$AEGIS_SECRET" -transport "$AEGIS_TRANSPORT" $(if [ "$AEGIS_FEC" = "true" ]; then echo "-fec"; fi) > /var/log/aegis.log 2>&1 &
    echo "AEGIS started with PID $!"
fi

echo ""
echo "=== Installation Complete ==="
echo "Server: $(hostname -I | awk '{print $1}'):$AEGIS_PORT"
echo "Secret: $AEGIS_SECRET"
echo ""
echo "To connect from client:"
echo "  aegis client -server $(hostname -I | awk '{print $1}'):$AEGIS_PORT -secret $AEGIS_SECRET -listen 127.0.0.1:1080"
