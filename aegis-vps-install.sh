#!/bin/bash
# AEGIS VPS Installer - Downloads from GitHub Actions artifacts
set -e

echo "=== AEGIS VPS Installer ==="

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Downloading aegis-linux-$ARCH..."
mkdir -p /opt/aegis

# Get latest successful build
LATEST_RUN=$(curl -s "https://api.github.com/repos/qualitydll/cirrus/actions/workflows/aegis-build.yml/runs?per_page=1&branch=main&status=success" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['workflow_runs'][0]['id']) if data.get('workflow_runs') else ''")

if [ -z "$LATEST_RUN" ]; then
    echo "No successful build found"
    exit 1
fi

echo "Found build: $LATEST_RUN"

# Get artifacts
ARTIFACTS=$(curl -s "https://api.github.com/repos/qualitydll/cirrus/actions/runs/$LATEST_RUN/artifacts")
ARTIFACT_ID=$(echo "$ARTIFACTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('artifacts', []):
    if 'aegis-linux-$ARCH' in a['name']:
        print(a['id'])
        break
")

if [ -z "$ARTIFACT_ID" ]; then
    echo "Artifact not found"
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

# Rename and setup
mv /opt/aegis/aegis-linux-$ARCH /opt/aegis/aegis
chmod +x /opt/aegis/aegis
rm /tmp/aegis.zip

# Generate secret
SECRET=$(openssl rand -hex 32)
echo "Secret: $SECRET"

# Create service
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
echo "Connect with:"
echo "  aegis client -server $(hostname -I | awk '{print $1}'):8443 -secret $SECRET -listen 127.0.0.1:1080"
