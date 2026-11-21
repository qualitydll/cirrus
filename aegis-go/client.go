package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

// runClient starts the AEGIS client as a local SOCKS5 proxy with encryption.
// Usage: aegis client -server <host:port> -secret <password> -listen 127.0.0.1:1080
func runClient(serverAddr, secret, listenAddr string) error {
	authHash := sha256.Sum256([]byte(secret))

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", listenAddr, err)
	}
	defer ln.Close()

	log.Printf("[AEGIS] client SOCKS5 listening on %s", listenAddr)
	log.Printf("[AEGIS] connecting to server %s (v%s, encrypted)", serverAddr, "0.2")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("[AEGIS] shutting down...")
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return fmt.Errorf("accept: %w", err)
		}
		go handleSOCKS5(conn, serverAddr, authHash)
	}
}

// handleSOCKS5 implements a minimal SOCKS5 proxy that tunnels via AEGIS.
func handleSOCKS5(clientConn net.Conn, serverAddr string, authHash [32]byte) {
	defer clientConn.Close()
	clientRemote := clientConn.RemoteAddr().String()

	// SOCKS5 handshake
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(clientConn, greeting); err != nil {
		return
	}
	if greeting[0] != 0x05 {
		return
	}
	nmethods := int(greeting[1])
	methods := make([]byte, nmethods)
	if _, err := io.ReadFull(clientConn, methods); err != nil {
		return
	}

	supported := false
	for _, m := range methods {
		if m == 0x00 {
			supported = true
			break
		}
	}
	if !supported {
		clientConn.Write([]byte{0x05, 0xFF})
		return
	}
	clientConn.Write([]byte{0x05, 0x00})

	// Read request
	req := make([]byte, 4)
	if _, err := io.ReadFull(clientConn, req); err != nil {
		return
	}
	if req[0] != 0x05 || req[1] != 0x01 {
		clientConn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	// Parse address
	var targetAddr string
	var targetPort uint16
	switch req[3] {
	case 0x01:
		addr := make([]byte, 4)
		io.ReadFull(clientConn, addr)
		targetAddr = fmt.Sprintf("%d.%d.%d.%d", addr[0], addr[1], addr[2], addr[3])
	case 0x03:
		lenBuf := make([]byte, 1)
		io.ReadFull(clientConn, lenBuf)
		domain := make([]byte, lenBuf[0])
		io.ReadFull(clientConn, domain)
		targetAddr = string(domain)
	case 0x04:
		addr := make([]byte, 16)
		io.ReadFull(clientConn, addr)
		targetAddr = net.IP(addr).String()
	default:
		clientConn.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	portBuf := make([]byte, 2)
	io.ReadFull(clientConn, portBuf)
	targetPort = uint16(portBuf[0])<<8 | uint16(portBuf[1])

	log.Printf("[AEGIS] SOCKS5 %s → %s:%d", clientRemote, targetAddr, targetPort)

	// Connect to AEGIS server
	serverConn, err := net.DialTimeout("tcp", serverAddr, DialTimeout)
	if err != nil {
		log.Printf("[AEGIS] %s: connect to server %s failed: %v", clientRemote, serverAddr, err)
		clientConn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer serverConn.Close()

	// === HANDSHAKE PHASE (unencrypted) ===
	// Send Hello with client nonce
	clientNonce := GenerateNonce()
	hello := &HelloPayload{
		AuthToken:   authHash,
		ClientVer:   0x0200,
		Capabilities: 0x00000001,
		ClientNonce: clientNonce,
	}
	if err := WriteMessagePlain(serverConn, &Message{Type: TypeHello, Payload: hello.Encode()}); err != nil {
		log.Printf("[AEGIS] %s: send hello: %v", clientRemote, err)
		return
	}

	// Read HelloAck with server nonce
	ack, err := ReadMessagePlain(serverConn)
	if err != nil {
		log.Printf("[AEGIS] %s: read ack: %v", clientRemote, err)
		return
	}
	if ack.Type != TypeHelloAck {
		log.Printf("[AEGIS] %s: expected ack, got %d", clientRemote, ack.Type)
		return
	}

	ackPayload, err := DecodeHelloAck(ack.Payload)
	if err != nil {
		log.Printf("[AEGIS] %s: decode ack: %v", clientRemote, err)
		return
	}

	log.Printf("[AEGIS] %s: session %x established", clientRemote, ackPayload.SessionID[:8])

	// Derive session keys
	clientToServer, serverToClient, err := DeriveSessionKeys(
		authHash[:],
		clientNonce[:],
		ackPayload.ServerNonce[:],
	)
	if err != nil {
		log.Printf("[AEGIS] %s: derive keys: %v", clientRemote, err)
		return
	}

	// === ENCRYPTED PHASE ===
	encryptedConn := NewEncryptedConn(serverConn, clientToServer, serverToClient)
	obfuscation := DefaultObfuscation()
	obfuscatedConn := NewObfuscatedConn(encryptedConn, obfuscation)

	// Send Connect request (encrypted + obfuscated)
	connectPayload := &ConnectPayload{
		AddrType: 0x03,
		Addr:     targetAddr,
		Port:     targetPort,
	}
	if ip := net.ParseIP(targetAddr); ip != nil {
		if ip.To4() != nil {
			connectPayload.AddrType = 0x01
		} else {
			connectPayload.AddrType = 0x02
		}
	}

	if err := obfuscatedConn.WriteMessage(&Message{Type: TypeConnect, Payload: connectPayload.Encode()}); err != nil {
		log.Printf("[AEGIS] %s: send connect: %v", clientRemote, err)
		return
	}

	// Read ConnectAck (encrypted + obfuscated)
	connectAck, err := obfuscatedConn.ReadMessage()
	if err != nil {
		log.Printf("[AEGIS] %s: read connect ack: %v", clientRemote, err)
		return
	}
	if connectAck.Type != TypeConnectAck {
		log.Printf("[AEGIS] %s: expected connect ack, got %d", clientRemote, connectAck.Type)
		return
	}
	if len(connectAck.Payload) == 0 || connectAck.Payload[0] != 0x00 {
		log.Printf("[AEGIS] %s: connect failed: %s", clientRemote, string(connectAck.Payload[1:]))
		clientConn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	// Send SOCKS5 success
	clientConn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	log.Printf("[AEGIS] %s: tunnel established to %s:%d", clientRemote, targetAddr, targetPort)

	// Pipe data bidirectionally
	done := make(chan struct{}, 2)

	// client → server: read raw, encrypt, send as AEGIS Data
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 32*1024)
		for {
			n, err := clientConn.Read(buf)
			if n > 0 {
				payload := make([]byte, n)
				copy(payload, buf[:n])
				if err := obfuscatedConn.WriteMessage(&Message{Type: TypeData, Payload: payload}); err != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	// server → client: read encrypted AEGIS Data, write raw to client
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			msg, err := obfuscatedConn.ReadMessage()
			if err != nil {
				return
			}
			switch msg.Type {
			case TypeData:
				if _, err := clientConn.Write(msg.Payload); err != nil {
					return
				}
			case TypeClose:
				return
			case TypePing:
				obfuscatedConn.WriteMessage(&Message{Type: TypePong})
			}
		}
	}()

	<-done
	<-done
	log.Printf("[AEGIS] %s: tunnel to %s:%d closed", clientRemote, targetAddr, targetPort)
}
