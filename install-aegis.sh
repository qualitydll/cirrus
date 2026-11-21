#!/bin/bash
# AEGIS Installer - Downloads from GitHub Release
set -e

echo "=== AEGIS Installer ==="

# Detect OS and architecture
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Determine binary name
echo "OS: $OS, Architecture: $ARCH"

if [[ "$OS" == *"windows"* ]] || [[ "$OS" == *"mingw"* ]]; then
    BINARY_NAME="aegis-windows-amd64.exe"
    AEGIS_DIR="/c/aegis"
else
    case "$OS" in
        ubuntu|debian|centos|fedora|rhel|alpine)
            BINARY_NAME="aegis-linux-$ARCH"
            ;;
        darwin)
            if [ "$ARCH" = "amd64" ]; then
                BINARY_NAME="aegis-darwin-amd64"
            else
                BINARY_NAME="aegis-darwin-arm64"
            fi
            ;;
        *)
            echo "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    AEGIS_DIR="/opt/aegis"
fi

echo "Downloading $BINARY_NAME..."
mkdir -p "$AEGIS_DIR"
cd "$AEGIS_DIR"

# Download from GitHub Release
DOWNLOAD_URL="https://github.com/qualitydll/cirrus/releases/download/aegis-v1.0.1/$BINARY_NAME"

if curl -fsSL "$DOWNLOAD_URL" -o aegis 2>/dev/null || curl -fsSL "$DOWNLOAD_URL" -o aegis.exe 2>/dev/null; then
    if [ -f "aegis.exe" ]; then
        chmod +x aegis.exe
        echo "✓ Downloaded aegis.exe"
    else
        chmod +x aegis
        echo "✓ Downloaded aegis"
    fi
else
    echo "✗ Failed to download $BINARY_NAME"
    echo "Please download manually from:"
    echo "  https://github.com/qualitydll/cirrus/releases/tag/aegis-v1.0.1"
    exit 1
fi

# For Linux, create systemd service
if [ -f /etc/os-release ] && command -v systemctl &> /dev/null; then
    # Generate secret
    SECRET=$(openssl rand -hex 32)
    echo "Secret: $SECRET"
    echo ""

    # Create service
    cat > /etc/systemd/system/aegis.service <<EOFSERVICE
[Unit]
Description=AEGIS VPN Server
After=network.target

[Service]
Type=simple
ExecStart=$AEGIS_DIR/aegis server -listen :8443 -secret $SECRET
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOFSERVICE

    systemctl daemon-reload
    systemctl enable aegis
    systemctl start aegis

    echo ""
    echo "=== Installation Complete ==="
    echo "Server: $(hostname -I | awk '{print $1}'):8443"
    echo "Secret: $SECRET"
    echo ""
    echo "Connect:"
    echo "  aegis client -server $(hostname -I | awk '{print $1}'):8443 -secret $SECRET -listen 127.0.0.1:1080"
else
    echo ""
    echo "=== Installation Complete ==="
    echo "Binary installed to: $AEGIS_DIR"
    echo ""
    echo "To run server:"
    echo "  $AEGIS_DIR/aegis server -listen :8443 -secret YOUR_SECRET"
    echo ""
    echo "To run client:"
    echo "  $AEGIS_DIR/aegis client -server VPS_IP:8443 -secret YOUR_SECRET -listen 127.0.0.1:1080"
fi
