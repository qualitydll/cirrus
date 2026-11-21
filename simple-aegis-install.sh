#!/bin/bash
# Simple AEGIS Installer
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

# Get latest build info
echo "Getting latest build info..."
LATEST_RUN=$(curl -s "https://api.github.com/repos/qualitydll/cirrus/actions/workflows/aegis-build.yml/runs?per_page=1&branch=main&status=success" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['workflow_runs'][0]['id']) if data.get('workflow_runs') else ''")

if [ -z "$LATEST_RUN" ]; then
    echo "No successful build found"
    exit 1
fi

echo "Found build: $LATEST_RUN"

# Get artifact ID
ARTIFACT_ID=$(curl -s "https://api.github.com/repos/qualitydll/cirrus/actions/runs/$LATEST_RUN/artifacts" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('artifacts', []):
    if 'aegis-linux-$ARCH' in a['name']:
        print(a['id'])
        break
")

if [ -z "$ARTIFACT_ID" ]; then
    echo "Artifact not found for $ARCH"
    exit 1
fi

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

# Setup
mv /opt/aegis/aegis-linux-$ARCH /opt/aegis/aegis
chmod +x /opt/aegis/aegis
rm /tmp/aegis.zip

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
