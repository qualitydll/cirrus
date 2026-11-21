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
	"time"
)

// runServer starts the AEGIS TCP server with encryption.
// Usage: aegis server -listen :8443 -secret <password>
func runServer(listenAddr, secret string) error {
	authHash := sha256.Sum256([]byte(secret))

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", listenAddr, err)
	}
	defer ln.Close()

	log.Printf("[AEGIS] server listening on %s (v%s, encrypted)", listenAddr, "0.2")
	log.Printf("[AEGIS] auth token: %x", authHash[:8])

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
		go handleClient(conn, authHash)
	}
}

func handleClient(conn net.Conn, authHash [32]byte) {
	defer conn.Close()
	remote := conn.RemoteAddr().String()
	log.Printf("[AEGIS] new connection from %s", remote)

	conn.SetDeadline(time.Now().Add(30 * time.Second))

	// === HANDSHAKE PHASE (unencrypted) ===
	// 1. Read Hello (plaintext)
	hello, err := ReadMessagePlain(conn)
	if err != nil {
		log.Printf("[AEGIS] %s: read hello: %v", remote, err)
		return
	}
	if hello.Type != TypeHello {
		log.Printf("[AEGIS] %s: expected hello, got type %d", remote, hello.Type)
		return
	}

	helloPayload, err := DecodeHello(hello.Payload)
	if err != nil {
		log.Printf("[AEGIS] %s: decode hello: %v", remote, err)
		return
	}

	// Validate auth
	if helloPayload.AuthToken != authHash {
		log.Printf("[AEGIS] %s: auth failed", remote)
		WriteMessagePlain(conn, &Message{Type: TypeClose, Payload: []byte("auth failed")})
		return
	}

	log.Printf("[AEGIS] %s: authenticated, ver=%d caps=%x", remote, helloPayload.ClientVer, helloPayload.Capabilities)

	// 2. Send HelloAck with session ID and server nonce (plaintext)
	sessionID := GenerateSessionID()
	serverNonce := GenerateNonce()
	ackPayload := &HelloAckPayload{
		SessionID:   sessionID,
		ServerNonce: serverNonce,
		ServerVer:   0x0200,
	}
	WriteMessagePlain(conn, &Message{Type: TypeHelloAck, Payload: ackPayload.Encode()})

	// 3. Derive session keys
	// masterSecret = authHash (SHA256 of password)
	// clientNonce from client, serverNonce from server
	clientToServer, serverToClient, err := DeriveSessionKeys(
		authHash[:],
		helloPayload.ClientNonce[:],
		serverNonce[:],
	)
	if err != nil {
		log.Printf("[AEGIS] %s: derive keys: %v", remote, err)
		return
	}

	log.Printf("[AEGIS] %s: session %x established, keys derived", remote, sessionID[:8])

	// === ENCRYPTED PHASE ===
	// Create encrypted connection wrapper with obfuscation
	encryptedConn := NewEncryptedConn(conn, serverToClient, clientToServer)
	obfuscation := DefaultObfuscation()
	obfuscatedConn := NewObfuscatedConn(encryptedConn, obfuscation)

	conn.SetDeadline(time.Time{})

	// 4. Main loop: handle Connect requests and data (all encrypted + obfuscated)
	for {
		msg, err := obfuscatedConn.ReadMessage()
		if err != nil {
			if err != io.EOF {
				log.Printf("[AEGIS] %s: read: %v", remote, err)
			}
			return
		}

		switch msg.Type {
		case TypeConnect:
			handleConnect(obfuscatedConn, remote, msg.Payload)
		case TypePing:
			obfuscatedConn.WriteMessage(&Message{Type: TypePong})
		case TypeClose:
			log.Printf("[AEGIS] %s: client closed", remote)
			return
		default:
			log.Printf("[AEGIS] %s: unknown type %d", remote, msg.Type)
		}
	}
}

func handleConnect(clientConn *ObfuscatedConn, clientRemote string, payload []byte) {
	connectReq, err := DecodeConnect(payload)
	if err != nil {
		log.Printf("[AEGIS] %s: decode connect: %v", clientRemote, err)
		clientConn.WriteMessage(&Message{Type: TypeConnectAck, Payload: []byte{0x01, 'b', 'a', 'd', ' ', 'r', 'e', 'q'}})
		return
	}

	target := net.JoinHostPort(connectReq.Addr, fmt.Sprintf("%d", connectReq.Port))
	log.Printf("[AEGIS] %s: connecting to %s", clientRemote, target)

	targetConn, err := net.DialTimeout("tcp", target, DialTimeout)
	if err != nil {
		log.Printf("[AEGIS] %s: dial %s failed: %v", clientRemote, target, err)
		clientConn.WriteMessage(&Message{Type: TypeConnectAck, Payload: []byte{0x01, 'd', 'i', 'a', 'l', ' ', 'f', 'a', 'i', 'l', 'e', 'd'}})
		return
	}
	defer targetConn.Close()

	clientConn.WriteMessage(&Message{Type: TypeConnectAck, Payload: []byte{0x00}})
	log.Printf("[AEGIS] %s: connected to %s", clientRemote, target)

	done := make(chan struct{}, 2)

	// client → target: read encrypted AEGIS Data, write raw to target
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			msg, err := clientConn.ReadMessage()
			if err != nil {
				return
			}
			switch msg.Type {
			case TypeData:
				if _, err := targetConn.Write(msg.Payload); err != nil {
					return
				}
			case TypeClose:
				return
			}
		}
	}()

	// target → client: read raw from target, encrypt and send as AEGIS Data
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 32*1024)
		for {
			n, err := targetConn.Read(buf)
			if n > 0 {
				payload := make([]byte, n)
				copy(payload, buf[:n])
				if err := clientConn.WriteMessage(&Message{Type: TypeData, Payload: payload}); err != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	<-done
	<-done
	log.Printf("[AEGIS] %s: tunnel to %s closed", clientRemote, target)
}
