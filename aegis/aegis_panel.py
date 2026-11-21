#!/usr/bin/env python3
"""Aegis Panel — single-file control panel for Aegis VPN nodes.

Runs on the VPS, manages sing-box inbounds and serves:
  /            pretty web UI (token in ?k=)
  /api/state   JSON state
  /api/nodes   create/delete nodes
  /sub/<tok>   base64 subscription (aegis:// + raw links)

Only Python 3 stdlib is required.
"""

import base64
import json
import os
import re
import secrets
import socket
import string
import subprocess
import sys
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path(os.environ.get("AEGIS_HOME", "/etc/aegis"))
STATE_FILE = HOME / "state.json"
SINGBOX_BIN = os.environ.get("SINGBOX_BIN", "/usr/local/bin/sing-box")
SINGBOX_CONF = os.environ.get("SINGBOX_CONF", "/etc/sing-box/config.json")
PANEL_PORT = int(os.environ.get("AEGIS_PANEL_PORT", "8901"))
CERT_DIR = HOME / "certs"
ORIGIN_CERT = CERT_DIR / "origin.crt"
ORIGIN_KEY = CERT_DIR / "origin.key"

PRESETS = {
    "turbo": {
        "label": "UDP · FEC",
        "tier": "turbo",
        "default_port": 443,
        "transport": "hysteria2",
        "desc": "Hysteria2 / UDP / obfs — max speed for PC & TV",
    },
    "eco": {
        "label": "TCP · TLS · REALITY",
        "tier": "eco",
        "default_port": 8443,
        "transport": "vless-reality",
        "desc": "VLESS + REALITY — light mode for phones",
    },
    "cfws": {
        "label": "WS · CF",
        "tier": "eco",
        "default_port": 443,
        "transport": "vless-ws",
        "desc": "VLESS + WebSocket behind Cloudflare",
        "cf_only": True,
    },
    "cfgrpc": {
        "label": "gRPC · CF",
        "tier": "eco",
        "default_port": 443,
        "transport": "vless-grpc",
        "desc": "VLESS + gRPC behind Cloudflare",
        "cf_only": True,
    },
}

REALITY_DEST = {"server": "dl.google.com", "server_port": 443}
REALITY_SNI = "dl.google.com"
MASQUERADE = "https://www.microsoft.com"

_lock = threading.Lock()


def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {"token": secrets.token_urlsafe(24), "sub_token": secrets.token_urlsafe(24),
            "host": "", "nodes": {}}


def save_state(st):
    HOME.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=2))
    tmp.replace(STATE_FILE)


def detect_host():
    """Best-effort public IPv4 of this VPS."""
    try:
        out = subprocess.run(
            ["hostname", "-I"], capture_output=True, text=True, timeout=5
        ).stdout.split()
        for ip in out:
            if not ip.startswith(("127.", "10.", "192.168.", "169.254.")) \
                    and not ip.startswith("172."):
                return ip
    except Exception:
        pass
    try:
        return socket.gethostbyname(socket.gethostname())
    except Exception:
        return "127.0.0.1"


def run(cmd, timeout=30):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def reality_keypair():
    """Generate X25519 keypair via sing-box (falls back to xray)."""
    for cmd in ([SINGBOX_BIN, "generate", "reality-keypair"],
                ["xray", "x25519"]):
        try:
            r = run(cmd, timeout=15)
            if r.returncode == 0:
                priv = pub = None
                for line in r.stdout.splitlines():
                    m = re.search(r'([A-Za-z ]*[Kk]ey)\s*[:=]\s*(\S+)', line)
                    if not m:
                        continue
                    label, val = m.group(1).lower(), m.group(2)
                    if "private" in label:
                        priv = val
                    elif "public" in label:
                        pub = val
                if priv and pub:
                    return priv, pub
        except Exception:
            continue
    raise RuntimeError(
        "Cannot generate REALITY keys. Install sing-box/xray or add keys manually."
    )


def free_port(used, preferred):
    p = preferred
    while p in used or p > 65535:
        p += 1
        if p > 65535:
            raise RuntimeError("No free ports")
    return p


# ---------------------------------------------------------------- sing-box

def _tls(cert=True):
    if cert:
        return {
            "enabled": True,
            "server_name": REALITY_SNI,
            "certificate_path": str(ORIGIN_CERT),
            "key_path": str(ORIGIN_KEY),
        }
    return {"enabled": False}


def inbound_for(node):
    """Build a sing-box 1.11+ inbound dict for a stored node."""
    p = node["preset"]
    tag = f"aegis-{node['id']}"
    base = {
        "type": PRESETS[p]["transport"].split("-")[0] if p != "turbo" else "hysteria2",
        "tag": tag,
        "listen": "::",
        "listen_port": node["port"],
    }
    if p == "turbo":
        return {
            **base,
            "type": "hysteria2",
            "users": [{"name": "u", "password": node["password"]}],
            "tls": {
                "enabled": True,
                "certificate_path": str(ORIGIN_CERT),
                "key_path": str(ORIGIN_KEY),
            },
            "masquerade": MASQUERADE,
        }
    # vless family
    users = [{"name": "u", "uuid": node["uuid"]}]
    if p == "eco":
        return {
            **base,
            "type": "vless",
            "users": users,
            "tls": {
                "enabled": True,
                "server_name": REALITY_SNI,
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": REALITY_DEST["server"],
                        "server_port": REALITY_DEST["server_port"],
                    },
                    "private_key": node["reality_private"],
                    "short_id": [node["reality_sid"]],
                },
            },
        }
    # cfws / cfgrpc — TLS with origin cert, optional transport
    tls = {
        "enabled": True,
        "server_name": node.get("sni") or node["host"],
        "certificate_path": str(ORIGIN_CERT),
        "key_path": str(ORIGIN_KEY),
    }
    inbound = {**base, "type": "vless", "users": users, "tls": tls}
    if p == "cfws":
        inbound["transport"] = {
            "type": "ws",
            "ws_settings": {
                "path": node["path"],
                "headers": {"Host": node.get("sni") or node["host"]},
            },
        }
    else:
        inbound["transport"] = {
            "type": "grpc",
            "grpc_settings": {"service_name": node["service_name"]},
        }
    return inbound


def singbox_config(st):
    return {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [inbound_for(n) for n in st["nodes"].values()],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"final": "direct"},
    }


def apply_singbox(st):
    """Write config, validate with sing-box, restart service."""
    try:
        conf_path = Path(SINGBOX_CONF)
        conf_path.parent.mkdir(parents=True, exist_ok=True)
        conf_path.write_text(json.dumps(singbox_config(st), indent=2))
        chk = run([SINGBOX_BIN, "check", "-c", str(conf_path)], timeout=30)
        if chk.returncode != 0:
            return False, (chk.stderr or chk.stdout).strip()[:800]
        r = run(["systemctl", "restart", "sing-box"], timeout=30)
        if r.returncode != 0:
            return False, f"systemctl restart failed: {r.stderr.strip()[:300]}"
        return True, "ok"
    except Exception as e:
        return False, str(e)[:400]


# ------------------------------------------------------------------ links

def aegis_link(st, node):
    host = node["host"]
    p = node["preset"]
    frag = urllib.parse.quote(node.get("label") or node["name"])
    if p == "turbo":
        q = {
            "sni": node.get("sni") or "www.bing.com",
            "obfs": "salamander",
            "obfs-password": node["obfs_password"],
            "insecure": "1",
        }
        auth = node["password"]
    elif p == "eco":
        q = {
            "sni": REALITY_SNI,
            "pbk": node["reality_public"],
            "sid": node["reality_sid"],
            "fp": "chrome",
        }
        auth = node["uuid"]
    elif p == "cfws":
        q = {
            "sni": node.get("sni") or host,
            "path": node["path"],
            "host": node.get("sni") or host,
            "alpn": "h2,http/1.1",
        }
        auth = node["uuid"]
    else:  # cfgrpc
        q = {
            "sni": node.get("sni") or host,
            "serviceName": node["service_name"],
            "alpn": "h2",
        }
        auth = node["uuid"]
    qs = urllib.parse.urlencode(q)
    return f"aegis://{p}.{urllib.parse.quote(auth)}@{host}:{node['port']}?{qs}#{frag}"


def raw_link(st, node):
    """Underlying hysteria2:// or vless:// link for non-Aegis clients."""
    p = node["preset"]
    host = node["host"]
    frag = urllib.parse.quote(node.get("label") or node["name"])
    if p == "turbo":
        q = urllib.parse.urlencode({
            "sni": node.get("sni") or "www.bing.com",
            "obfs": "salamander",
            "obfs-password": node["obfs_password"],
            "insecure": "1",
        })
        return (f"hy2://{urllib.parse.quote(node['password'])}"
                f"@{host}:{node['port']}?{q}#{frag}")
    if p == "eco":
        q = urllib.parse.urlencode({
            "security": "reality", "sni": REALITY_SNI,
            "pbk": node["reality_public"], "sid": node["reality_sid"],
            "fp": "chrome", "type": "tcp",
        })
        return (f"vless://{node['uuid']}@{host}:{node['port']}?{q}#{frag}")
    net = "ws" if p == "cfws" else "grpc"
    q = {
        "security": "tls", "sni": node.get("sni") or host,
        "type": net, "alpn": "h2,http/1.1" if p == "cfws" else "h2",
    }
    if p == "cfws":
        q["path"] = node["path"]
        q["host"] = node.get("sni") or host
    else:
        q["serviceName"] = node["service_name"]
    return (f"vless://{node['uuid']}@{host}:{node['port']}?"
            f"{urllib.parse.urlencode(q)}#{frag}")


def subscription_body(st):
    lines = []
    for n in st["nodes"].values():
        lines.append(aegis_link(st, n))
        lines.append(raw_link(st, n))
    return base64.b64encode("\n".join(lines).encode()).decode()


# -------------------------------------------------------------------- HTTP

INDEX_HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aegis Panel</title>
<style>
:root{--bg:#060b14;--card:#0b1524;--line:#16304a;--txt:#dbeafe;--dim:#7d9bbd;
--acc:#38bdf8;--acc2:#0ea5e9;--ok:#34d399;--warn:#fbbf24;--bad:#f87171}
*{box-sizing:border-box;margin:0}
body{background:radial-gradient(1200px 600px at 80% -10%,#0e3a5c55,transparent),var(--bg);
color:var(--txt);font:15px/1.5 'Segoe UI',system-ui,sans-serif;min-height:100vh}
.wrap{max-width:980px;margin:0 auto;padding:28px 20px 60px}
header{display:flex;align-items:center;gap:14px;margin-bottom:26px}
.logo{width:52px;height:52px;border-radius:16px;display:grid;place-items:center;
font-size:30px;font-weight:800;color:#04121f;
background:linear-gradient(135deg,#7dd3fc,#0ea5e9 55%,#0369a1);
box-shadow:0 0 30px #38bdf855}
h1{font-size:22px;letter-spacing:.5px}
.sub{color:var(--dim);font-size:13px}
.card{background:linear-gradient(180deg,#0d1a2c,#0a1424);border:1px solid var(--line);
border-radius:18px;padding:20px;margin-bottom:16px}
.card h2{font-size:15px;color:var(--acc);margin-bottom:14px;letter-spacing:.4px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
input,select{background:#0a1626;border:1px solid var(--line);color:var(--txt);
border-radius:10px;padding:9px 12px;font:inherit;min-width:0}
input:focus,select:focus{outline:1px solid var(--acc)}
button{background:linear-gradient(135deg,var(--acc2),#0284c7);border:0;color:#fff;
border-radius:10px;padding:9px 16px;font:inherit;font-weight:600;cursor:pointer}
button.ghost{background:#12233a;border:1px solid var(--line);color:var(--txt)}
button.danger{background:#3a1420;border:1px solid #7f1d3a;color:var(--bad)}
.tag{display:inline-block;padding:2px 10px;border-radius:99px;font-size:11px;
font-weight:700;letter-spacing:.5px}
.t-turbo{background:#0c4a6e;color:#7dd3fc}.t-eco{background:#134e4a;color:#5eead4}
.node{border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin-top:12px}
.node .top{display:flex;justify-content:space-between;align-items:center;gap:10px}
.node .name{font-weight:600}
.node .meta{color:var(--dim);font-size:12.5px;margin-top:4px}
.links{margin-top:10px;display:grid;gap:6px}
.lnk{display:flex;gap:8px;align-items:center;background:#081120;border:1px solid var(--line);
border-radius:9px;padding:7px 10px;font-family:Consolas,monospace;font-size:12px;
word-break:break-all}
.lnk .k{color:var(--acc);font-weight:700;flex:none}
.copy{margin-left:auto;flex:none;background:#12233a;border:1px solid var(--line);
color:var(--acc);border-radius:7px;padding:3px 10px;font-size:11px;cursor:pointer}
.toast{position:fixed;bottom:22px;left:50%;transform:translateX(-50%);
background:#0d1a2c;border:1px solid var(--acc);color:var(--txt);
padding:10px 18px;border-radius:12px;display:none;z-index:9}
.warn{color:var(--warn);font-size:12.5px}
code{color:var(--acc)}
</style></head><body><div class="wrap">
<header>
<div class="logo">*</div>
<div><h1>AEGIS PANEL</h1><div class="sub">profile-driven VPN nodes · sing-box backend</div></div>
</header>

<div class="card"><h2>SERVER</h2><div class="row">
<label class="sub">Public host / domain</label>
<input id="host" style="flex:1;min-width:200px" placeholder="auto-detected IP or domain">
<button class="ghost" onclick="saveHost()">Save</button>
</div><div class="sub" id="hostInfo" style="margin-top:8px"></div></div>

<div class="card"><h2>NEW NODE</h2>
<div class="row" style="margin-bottom:12px">
<select id="preset"></select>
<input id="nname" placeholder="name (optional)" style="width:170px">
<input id="nport" type="number" placeholder="port" style="width:90px">
<input id="ndomain" placeholder="domain for CF / SNI (optional)" style="flex:1;min-width:180px">
<button onclick="createNode()">+ Create</button>
</div>
<div class="warn" id="presetDesc"></div></div>

<div class="card"><h2>NODES</h2><div id="nodes"><div class="sub">loading…</div></div></div>

<div class="card"><h2>SUBSCRIPTION</h2>
<div class="row"><code id="suburl"></code>
<button class="ghost" onclick="copyText(document.getElementById('suburl').textContent)">Copy URL</button></div>
<div class="sub" style="margin-top:8px">Import this URL into Cirrus. — it contains both <code>aegis://</code> and raw <code>vless://</code>/<code>hy2://</code> links.</div></div>
</div>
<div class="toast" id="toast"></div>
<script>
const K=new URLSearchParams(location.search).get('k')||'';
const api=(p,o)=>fetch(p+(p.includes('?')?'&':'?')+'k='+K,o?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o)}:{}).then(r=>r.json());
const $=id=>document.getElementById(id);
function toast(m){const t=$('toast');t.textContent=m;t.style.display='block';setTimeout(()=>t.style.display='none',2200)}
function copyText(t){navigator.clipboard.writeText(t).then(()=>toast('copied'))}
let PRESETS={};
async function refresh(){
 const s=await api('/api/state');
 PRESETS=s.presets;
 $('host').value=s.host;
 $('hostInfo').textContent='detected: '+(s.detected||'—');
 const sel=$('preset');
 if(!sel.options.length){for(const[id,p]of Object.entries(s.presets)){const o=document.createElement('option');o.value=id;o.textContent='AEGIS · '+p.label;sel.appendChild(o)}}
 updDesc();
 $('suburl').textContent=location.origin+'/sub/'+s.sub_token;
 const box=$('nodes');box.innerHTML='';
 for(const n of s.nodes){
  const d=document.createElement('div');d.className='node';
  const tier=n.preset==='turbo'?'t-turbo':'t-eco';
  const pl=PRESETS[n.preset]||{};
  const top=document.createElement('div');top.className='top';
  const left=document.createElement('div');
  const nm=document.createElement('span');nm.className='name';nm.textContent=n.label||n.name;
  const tg=document.createElement('span');tg.className='tag '+tier;
  tg.textContent='AEGIS · '+(pl.label||n.preset);
  left.append(nm,' ',tg);
  const del=document.createElement('button');del.className='danger';del.textContent='Delete';
  del.onclick=()=>delNode(n.id);top.append(left,del);d.appendChild(top);
  const meta=document.createElement('div');meta.className='meta';
  meta.textContent=`${n.host}:${n.port} · ${pl.desc||''}`;d.appendChild(meta);
  const links=document.createElement('div');links.className='links';
  for(const[k,v]of[['AEGIS',n.aegis],['RAW',n.raw]]){
   const l=document.createElement('div');l.className='lnk';
   const kk=document.createElement('span');kk.className='k';kk.textContent=k;
   const tx=document.createElement('span');tx.textContent=v;
   const cp=document.createElement('button');cp.className='copy';cp.textContent='copy';
   cp.onclick=()=>copyText(v);
   l.append(kk,tx,cp);links.appendChild(l);
  }
  d.appendChild(links);box.appendChild(d);
 }
 if(!s.nodes.length)box.innerHTML='<div class="sub">no nodes yet</div>';
}
function updDesc(){const p=PRESETS[$('preset').value];$('presetDesc').textContent=p?p.desc:''}
$('preset').onchange=updDesc;
async function saveHost(){const r=await api('/api/host',{host:$('host').value});toast(r.ok?'saved':'error: '+(r.error||''));refresh()}
async function createNode(){
 const r=await api('/api/nodes',{preset:$('preset').value,name:$('nname').value,port:+$('nport').value||0,domain:$('ndomain').value});
 if(r.ok){toast('node created');$('nname').value='';$('nport').value='';$('ndomain').value='';refresh()}
 else toast('error: '+(r.error||''));
}
async function delNode(id){if(!confirm('Delete node?'))return;const r=await api('/api/nodes/'+id+'/delete',{});if(r.ok)refresh();else toast('error: '+(r.error||''))}
refresh();setInterval(refresh,8000);
</script></body></html>"""


def node_public(n, st):
    return {**n, "aegis": aegis_link(st, n), "raw": raw_link(st, n)}


class Handler(BaseHTTPRequestHandler):
    server_version = "AegisPanel/1.0"

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, text, code=200):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _token(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        return (q.get("k") or [""])[0]

    def _st(self):
        return load_state()

    def _authed(self):
        return secrets.compare_digest(self._token(), self._st()["token"])

    def log_message(self, *a):
        pass

    # ------------------------------------------------------------- GET
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        st = self._st()
        if path == "/healthz":
            return self._json({"ok": True})
        if path.startswith("/sub/"):
            tok = path[len("/sub/"):]
            if not secrets.compare_digest(tok, st["sub_token"]):
                return self._json({"error": "forbidden"}, 403)
            body = subscription_body(st).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Subscription-Userinfo",
                             "upload=0; download=0; total=0; expire=0")
            self.send_header("profile-update-interval", "24")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/" or path == "/index.html":
            if not self._authed():
                return self._html(
                    "<h2 style='font-family:sans-serif'>Aegis Panel</h2>"
                    "<p>Append <code>?k=TOKEN</code> — token is printed by the "
                    "installer or shown by the <code>aegis</code> menu.</p>",
                    403)
            return self._html(INDEX_HTML)
        if path == "/api/state":
            if not self._authed():
                return self._json({"error": "forbidden"}, 403)
            host = st.get("host") or detect_host()
            return self._json({
                "host": host,
                "detected": detect_host(),
                "sub_token": st["sub_token"],
                "presets": PRESETS,
                "nodes": [node_public(n, st) for n in st["nodes"].values()],
            })
        self._json({"error": "not found"}, 404)

    # ------------------------------------------------------------ POST
    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        st = self._st()
        if not self._authed():
            return self._json({"error": "forbidden"}, 403)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            body = {}

        with _lock:
            if path == "/api/host":
                st["host"] = (body.get("host") or "").strip()
                save_state(st)
                return self._json({"ok": True})

            if path == "/api/nodes":
                preset = body.get("preset", "")
                if preset not in PRESETS:
                    return self._json({"error": "unknown preset"}, 400)
                cfg = PRESETS[preset]
                # Cloudflare modes share TCP 443 on the origin — allow one.
                if cfg.get("cf_only") and any(
                        n["preset"].startswith("cf")
                        for n in st["nodes"].values()):
                    return self._json(
                        {"error": "a CF node already exists — CF origin "
                                  "can only expose one TCP/443 inbound"}, 400)
                host = (st.get("host") or detect_host()).strip()
                if not host:
                    return self._json({"error": "no host"}, 400)
                used = {n["port"] for n in st["nodes"].values()}
                try:
                    port = free_port(used, int(body.get("port") or 0)
                                      or cfg["default_port"])
                except Exception as e:
                    return self._json({"error": str(e)}, 400)
                node = {
                    "id": uuid.uuid4().hex[:8],
                    "preset": preset,
                    "name": (body.get("name") or "").strip()
                            or f"{preset}-{port}",
                    "label": (body.get("name") or "").strip(),
                    "host": host,
                    "port": port,
                    "created": int(__import__("time").time()),
                }
                try:
                    if preset == "turbo":
                        node["password"] = secrets.token_urlsafe(18)
                        node["obfs_password"] = secrets.token_urlsafe(18)
                        node["sni"] = "www.bing.com"
                    elif preset == "eco":
                        node["uuid"] = str(uuid.uuid4())
                        priv, pub = reality_keypair()
                        node["reality_private"] = priv
                        node["reality_public"] = pub
                        node["reality_sid"] = secrets.token_hex(4)
                    else:
                        node["uuid"] = str(uuid.uuid4())
                        node["sni"] = (body.get("domain") or "").strip()
                        if preset == "cfws":
                            node["path"] = "/" + secrets.token_urlsafe(9)
                        else:
                            node["service_name"] = "aegis-" + \
                                secrets.token_urlsafe(6)
                except Exception as e:
                    return self._json({"error": str(e)}, 500)
                st["nodes"][node["id"]] = node
                ok, msg = apply_singbox(st)
                if not ok:
                    del st["nodes"][node["id"]]
                    save_state(st)
                    return self._json({"error": "sing-box: " + (msg or "check failed")}, 500)
                save_state(st)
                return self._json({"ok": True, "node": node_public(node, st)})

            m = re.fullmatch(r"/api/nodes/([0-9a-f]{8})/delete", path)
            if m:
                nid = m.group(1)
                if nid not in st["nodes"]:
                    return self._json({"error": "not found"}, 404)
                del st["nodes"][nid]
                ok, msg = apply_singbox(st)
                save_state(st)
                if not ok:
                    return self._json({"error": "sing-box: " + (msg or "check failed")}, 500)
                return self._json({"ok": True})

        self._json({"error": "not found"}, 404)


def main():
    HOME.mkdir(parents=True, exist_ok=True)
    st = load_state()
    if not STATE_FILE.exists():
        save_state(st)
    if not ORIGIN_CERT.exists():
        print("[aegis] WARNING: origin cert missing — run install.sh",
              file=sys.stderr)
    host = st.get("host") or detect_host()
    print(f"[aegis] panel on http://{host}:{PANEL_PORT}/?k={st['token']}")
    print(f"[aegis] subscription: http://{host}:{PANEL_PORT}/sub/{st['sub_token']}")
    ThreadingHTTPServer(("0.0.0.0", PANEL_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
