# AEGIS Go Implementation

Custom VPN protocol implementation in Go — encrypted, obfuscated, and ready for production use.

## Features

- **AEGIS TCP** — Custom TCP protocol with ChaCha20-Poly1305 encryption
- **Obfuscation** — Random padding, timing jitter, fake packets
- **SOCKS5 Interface** — Local proxy for mihomo/other clients
- **Cross-platform** — Linux, Windows, macOS

## Quick Start

### Build

```bash
cd aegis-go
go mod tidy
go build -o aegis .
```

### Server (on VPS)

```bash
./aegis server -listen :8443 -secret your_secret_here
```

### Client (on local machine)

```bash
./aegis client -server VPS_IP:8443 -secret your_secret_here -listen 127.0.0.1:1080
```

### Use with mihomo/clash

Add to your mihomo config:

```yaml
proxies:
  - name: AEGIS
    type: socks5
    server: 127.0.0.1
    port: 1080
    udp: true
```

## Protocol Details

### Wire Format

```
┌─────────┬─────────┬──────────┬─────────────────┐
│ Magic   │ Version │   Type   │    Payload      │
│ 4 bytes │ 1 byte  │ 1 byte   │  0-32KB         │
│ A3 11   │   02    │ 01-08    │                 │
│ 5E 47   │         │          │                 │
└─────────┴─────────┴──────────┴─────────────────┘
```

### Message Types

- `0x01` Hello — Client authentication
- `0x02` HelloAck — Server session confirmation
- `0x03` Connect — Request TCP connection to target
- `0x04` ConnectAck — Connection result
- `0x05` Data — Encrypted payload data
- `0x06` Close — Close tunnel
- `0x07/0x08` Ping/Pong — Keepalive

### Encryption

- **Algorithm**: ChaCha20-Poly1305 (AEAD)
- **Key Derivation**: HKDF-SHA3-256
- **Nonce**: 4-byte random prefix + 8-byte counter
- **Handshake**: Unencrypted auth exchange, then encrypted session

### Obfuscation

- **Padding**: 0-512 random bytes per message
- **Jitter**: 0-50ms random delay before sending
- **Fake Packets**: 2% chance of sending garbage data

## Integration with Cirrus

The Cirrus app can automatically download and manage the AEGIS daemon:

1. Place `aegis` binary in app data directory
2. Add AEGIS Native profile with server details
3. App starts daemon automatically when connecting
4. Mihomo uses local SOCKS5 proxy as upstream

## Security Notes

- All payload data is encrypted with ChaCha20-Poly1305
- Authentication uses SHA256 of shared secret
- Session keys derived via HKDF with unique nonces
- Perfect forward secrecy via session key rotation

## Roadmap

- [ ] AEGIS UDP variant with FEC
- [ ] Auto-download binaries from GitHub releases
- [ ] Windows service support
- [ ] Android integration
- [ ] TLS fingerprint mimicry for TCP variant
