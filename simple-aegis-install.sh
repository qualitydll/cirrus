#!/bin/bash
# Simple AEGIS Installer - Downloads from GitHub Release
set -e

echo "=== Simple AEGIS Installer ==="

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported: $ARCH"; exit 1 ;;
esac

echo "Architecture: $ARCH"
echo ""

# Create directory
mkdir -p /opt/aegis
cd /opt/aegis

# Download from GitHub Release
echo "Downloading aegis-linux-$ARCH..."
DOWNLOAD_URL="https://github.com/qualitydll/cirrus/releases/download/aegis-v1.0.1/aegis-linux-$ARCH"

if ! curl -fsSL "$DOWNLOAD_URL" -o aegis; then
    echo "Failed to download from GitHub release"
    echo "Trying alternative method..."
    
    # Fallback: try to get from workflow artifacts
    LATEST_RUN=$(curl -s "https://api.github.com/repos/qualitydll/cirrus/actions/workflows/aegis-build.yml/runs?per_page=1&branch=main&status=success" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['workflow_runs'][0]['id']) if data.get('workflow_runs') else ''")
    
    if [ -n "$LATEST_RUN" ]; then
        echo "Found build: $LATEST_RUN"
        ARTIFACT_ID=$(curl -s "https://api.github.com/repos/qualitydll/cirrus/actions/runs/$LATEST_RUN/artifacts" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('artifacts', []):
    if 'aegis-linux-$ARCH' in a['name']:
        print(a['id'])
        break
")
        
        if [ -n "$ARTIFACT_ID" ]; then
            echo "Downloading artifact $ARTIFACT_ID..."
            curl -fsSL "https://api.github.com/repos/qualitydll/cirrus/actions/artifacts/$ARTIFACT_ID/zip" -o /tmp/aegis.zip
            
            # Extract
            cd /tmp
            python3 -c "
import zipfile
with zipfile.ZipFile('aegis.zip', 'r') as z:
    for name in z.namelist():
        if name.startswith('aegis-'):
            z.extract(name, '/opt/aegis/')
            print(f'Extracted: {name}')
"
            
            mv /opt/aegis/aegis-linux-$ARCH /opt/aegis/aegis
            chmod +x /opt/aegis/aegis
            rm /tmp/aegis.zip
        else
            echo "Artifact not found"
            exit 1
        fi
    else
        echo "No build found"
        exit 1
    fi
else
    chmod +x aegis
    echo "Downloaded from release"
fi

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
ExecStart=/opt/aegis/aegis server -listen :8443 -secret $SECRET
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
