#!/usr/bin/env bash
# Aegis installer — run on a fresh VPS:
#   curl -fsSL https://raw.githubusercontent.com/qualitydll/brew/main/aegis/install.sh | bash
# or from a local copy:  bash install.sh
set -euo pipefail

AEGIS_HOME="${AEGIS_HOME:-/etc/aegis}"
PANEL_PORT="${AEGIS_PANEL_PORT:-8901}"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_VER="${SINGBOX_VER:-1.12.4}"
PANEL_REPO="${PANEL_REPO:-https://raw.githubusercontent.com/qualitydll/brew/main/aegis}"
PANEL_PY_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]:--}")" 2>/dev/null && pwd)/aegis_panel.py"
if [ -f "$PANEL_PY_LOCAL" ]; then
  PANEL_PY="$PANEL_PY_LOCAL"
else
  PANEL_PY="$(mktemp -d)/aegis_panel.py"
  curl -fsSL -o "$PANEL_PY" "$PANEL_REPO/aegis_panel.py" \
    || die "cannot fetch aegis_panel.py (set PANEL_REPO or run from repo)"
fi

say()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash install.sh)"
command -v python3 >/dev/null || die "python3 not found"
command -v curl >/dev/null || die "curl not found"
command -v openssl >/dev/null || die "openssl not found"

# ------------------------------------------------------------- sing-box
if [ ! -x "$SINGBOX_BIN" ]; then
  say "installing sing-box $SINGBOX_VER"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  sb_arch="amd64" ;;
    aarch64|arm64) sb_arch="arm64" ;;
    *) die "unsupported arch: $arch" ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/sb.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${sb_arch}.tar.gz"
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
  install -m755 "$tmp/sing-box-${SINGBOX_VER}-linux-${sb_arch}/sing-box" "$SINGBOX_BIN"
  rm -rf "$tmp"
else
  ok "sing-box already installed: $($SINGBOX_BIN version | head -1)"
fi

mkdir -p /etc/sing-box
if [ ! -f "$SINGBOX_CONF" ]; then
  cat > "$SINGBOX_CONF" <<'EOF'
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF
fi

cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sing-box >/dev/null 2>&1 || true
ok "sing-box service ready"

# ------------------------------------------------------------- certs
mkdir -p "$AEGIS_HOME/certs" /opt/aegis
if [ ! -f "$AEGIS_HOME/certs/origin.crt" ]; then
  say "generating self-signed origin certificate"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$AEGIS_HOME/certs/origin.key" \
    -out "$AEGIS_HOME/certs/origin.crt" -days 3650 -nodes \
    -subj "/CN=aegis.local" >/dev/null 2>&1
  chmod 600 "$AEGIS_HOME/certs/origin.key"
fi

# ------------------------------------------------------------- panel
cp "$PANEL_PY" /opt/aegis/aegis_panel.py
if [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "-" ]; then
  cp "${BASH_SOURCE[0]}" /opt/aegis/install.sh
fi
chmod 755 /opt/aegis/aegis_panel.py
[ -f /opt/aegis/install.sh ] && chmod 755 /opt/aegis/install.sh || true

cat > /etc/systemd/system/aegis-panel.service <<EOF
[Unit]
Description=Aegis control panel
After=network.target sing-box.service

[Service]
Environment=AEGIS_HOME=$AEGIS_HOME
Environment=AEGIS_PANEL_PORT=$PANEL_PORT
ExecStart=/usr/bin/python3 /opt/aegis/aegis_panel.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now aegis-panel >/dev/null 2>&1 || true
ok "aegis-panel service installed"

# ------------------------------------------------------------- menu
cat > /usr/local/bin/aegis <<'EOF'
#!/usr/bin/env bash
# Aegis menu — VPS control shortcut
STATE=/etc/aegis/state.json
TOKEN=$(python3 -c "import json;print(json.load(open('$STATE'))['token'])" 2>/dev/null || echo "")
SUB=$(python3 -c "import json;print(json.load(open('$STATE'))['sub_token'])" 2>/dev/null || echo "")
IP=$(hostname -I | awk '{print $1}')
PORT=${AEGIS_PANEL_PORT:-8901}
URL="http://${IP}:${PORT}/?k=${TOKEN}"
SUBURL="http://${IP}:${PORT}/sub/${SUB}"

menu() {
  clear
  echo "  ╔═══════════════════════════════════╗"
  echo "  ║            A E G I S              ║"
  echo "  ║        * control panel *         ║"
  echo "  ╚═══════════════════════════════════╝"
  echo
  echo "  1) Open panel URL"
  echo "  2) Copy subscription URL"
  echo "  3) Copy panel URL"
  echo "  4) Restart panel"
  echo "  5) Restart sing-box"
  echo "  6) Panel logs (journalctl -f)"
  echo "  7) sing-box logs"
  echo "  8) Re-run installer / update panel"
  echo "  0) Exit"
  echo
  echo -n "  choose: "
}

while true; do
  menu
  read -r c
  case "$c" in
    1) echo "$URL"; read -rp "press enter" _ ;;
    2) echo "$SUBURL" | tee /dev/tty | xclip -selection clipboard 2>/dev/null || true
       echo "(also copied to clipboard if xclip installed)"; read -rp "press enter" _ ;;
    3) echo "$URL"; read -rp "press enter" _ ;;
    4) systemctl restart aegis-panel && echo "panel restarted"; read -rp "press enter" _ ;;
    5) systemctl restart sing-box && echo "sing-box restarted"; read -rp "press enter" _ ;;
    6) journalctl -u aegis-panel -f --no-pager ;;
    7) journalctl -u sing-box -f --no-pager ;;
    8) bash /opt/aegis/install.sh; read -rp "press enter" _ ;;
    0) exit 0 ;;
    *) echo "?"; sleep 1 ;;
  esac
done
EOF
chmod +x /usr/local/bin/aegis
ok "menu installed: aegis"

# ------------------------------------------------------------- firewall
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "$PANEL_PORT/tcp" >/dev/null 2>&1 || true
  warn "ufw is active — open node ports too, e.g.: ufw allow 443,8443,2053/tcp && ufw allow 443/udp"
fi

# ------------------------------------------------------------- summary
sleep 1
HOST="$(hostname -I | awk '{print $1}')"
TOKEN="$(python3 -c "import json;print(json.load(open('$AEGIS_HOME/state.json'))['token'])")"
SUBT="$(python3 -c "import json;print(json.load(open('$AEGIS_HOME/state.json'))['sub_token'])")"

cat <<EOF

  ╔══════════════════════════════════════════════════════╗
  ║                  AEGIS INSTALLED                     ║
  ╚══════════════════════════════════════════════════════╝

  Panel:        http://${HOST}:${PANEL_PORT}/?k=${TOKEN}
  Subscription: http://${HOST}:${PANEL_PORT}/sub/${SUBT}

  Manage nodes in the panel, or run the menu on the VPS:
      aegis

  Open ports for your nodes (ufw example):
      ufw allow 443/tcp && ufw allow 8443/tcp && ufw allow 443/udp

  Tip: for WS/gRPC (CF) presets put a domain behind Cloudflare
  (orange cloud) and set it as "domain" when creating the node.
EOF
