package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"time"
)

// AEGIS wire protocol v0.2 — TCP with ChaCha20-Poly1305 encryption
// Magic bytes identify AEGIS traffic, version for future compat.

const (
	MagicLen   = 4
	Version    = 0x02 // bumped for encryption
	MaxPayload = 32 * 1024 // 32KB max per message (uint16 safe)
)

var Magic = []byte{0xA3, 0x11, 0x5E, 0x47} // "A3^G" — AEGIS magic

// Message types
const (
	TypeHello      = 0x01 // Client → Server: auth + capabilities
	TypeHelloAck   = 0x02 // Server → Client: session established
	TypeConnect    = 0x03 // Client → Server: request TCP connect to target
	TypeConnectAck = 0x04 // Server → Client: connect result
	TypeData       = 0x05 // Bidirectional: payload data
	TypeClose      = 0x06 // Either side: close stream
	TypePing       = 0x07 // Keepalive
	TypePong       = 0x08 // Keepalive response
)

// Header layout (fixed 8 bytes):
//   [0:4]  Magic (0xA3 0x11 0x5E 0x47)
//   [4]    Version (0x02)
//   [5]    Type (see constants)
//   [6:8]  Encrypted payload length (big-endian uint16)
//   [8:]   Encrypted payload (ChaCha20-Poly1305)

type Message struct {
	Type    byte
	Payload []byte
}

// EncryptedConn wraps a net.Conn with AEGIS encryption.
type EncryptedConn struct {
	conn        net.Conn
	sendKeys    *SessionKeys // for writing
	recvKeys    *SessionKeys // for reading
	readBuf     []byte
	writeBuf    []byte
}

// NewEncryptedConn creates an encrypted connection wrapper.
func NewEncryptedConn(conn net.Conn, sendKeys, recvKeys *SessionKeys) *EncryptedConn {
	return &EncryptedConn{
		conn:     conn,
		sendKeys: sendKeys,
		recvKeys: recvKeys,
	}
}

// ReadMessage reads one encrypted AEGIS message.
func (ec *EncryptedConn) ReadMessage() (*Message, error) {
	// Read header (8 bytes)
	header := make([]byte, 8)
	if _, err := io.ReadFull(ec.conn, header); err != nil {
		return nil, err
	}
	if string(header[:4]) != string(Magic) {
		return nil, fmt.Errorf("bad magic: %x", header[:4])
	}
	if header[4] != Version {
		return nil, fmt.Errorf("unsupported version: %d", header[4])
	}

	encLen := binary.BigEndian.Uint16(header[6:8])
	if encLen > MaxPayload+NonceSize+TagSize {
		return nil, fmt.Errorf("payload too large: %d", encLen)
	}

	// Read encrypted payload
	encPayload := make([]byte, encLen)
	if _, err := io.ReadFull(ec.conn, encPayload); err != nil {
		return nil, err
	}

	// Decrypt
	payload, err := ec.recvKeys.Decrypt(encPayload)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}

	return &Message{Type: header[5], Payload: payload}, nil
}

// WriteMessage writes one encrypted AEGIS message.
func (ec *EncryptedConn) WriteMessage(msg *Message) error {
	// Encrypt payload
	encPayload, err := ec.sendKeys.Encrypt(msg.Payload)
	if err != nil {
		return fmt.Errorf("encrypt: %w", err)
	}

	if len(encPayload) > MaxPayload+NonceSize+TagSize {
		return fmt.Errorf("payload too large after encryption: %d", len(encPayload))
	}

	header := make([]byte, 8)
	copy(header[:4], Magic)
	header[4] = Version
	header[5] = msg.Type
	binary.BigEndian.PutUint16(header[6:8], uint16(len(encPayload)))

	if _, err := ec.conn.Write(header); err != nil {
		return err
	}
	if _, err := ec.conn.Write(encPayload); err != nil {
		return err
	}
	return nil
}

// Legacy unencrypted functions for backward compatibility during handshake
// These are used BEFORE encryption is established.

// ReadMessagePlain reads unencrypted message (for handshake phase).
func ReadMessagePlain(r io.Reader) (*Message, error) {
	header := make([]byte, 8)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}
	if string(header[:4]) != string(Magic) {
		return nil, fmt.Errorf("bad magic: %x", header[:4])
	}
	if header[4] != Version {
		return nil, fmt.Errorf("unsupported version: %d", header[4])
	}
	length := binary.BigEndian.Uint16(header[6:8])
	if length > MaxPayload {
		return nil, fmt.Errorf("payload too large: %d", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	return &Message{Type: header[5], Payload: payload}, nil
}

// WriteMessagePlain writes unencrypted message (for handshake phase).
func WriteMessagePlain(w io.Writer, msg *Message) error {
	if len(msg.Payload) > MaxPayload {
		return fmt.Errorf("payload too large: %d", len(msg.Payload))
	}
	header := make([]byte, 8)
	copy(header[:4], Magic)
	header[4] = Version
	header[5] = msg.Type
	binary.BigEndian.PutUint16(header[6:8], uint16(len(msg.Payload)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	if len(msg.Payload) > 0 {
		if _, err := w.Write(msg.Payload); err != nil {
			return err
		}
	}
	return nil
}

// HelloPayload is sent by client in TypeHello.
type HelloPayload struct {
	AuthToken   [32]byte // SHA-256 of shared secret
	ClientVer   uint16   // Client protocol version
	Capabilities uint32  // Bitmask of features
	ClientNonce [16]byte // Random nonce for key derivation
}

// EncodeHello serializes HelloPayload.
func (h *HelloPayload) Encode() []byte {
	buf := make([]byte, 32+2+4+16) // auth(32) + ver(2) + caps(4) + nonce(16)
	copy(buf[0:32], h.AuthToken[:])
	binary.BigEndian.PutUint16(buf[32:34], h.ClientVer)
	binary.BigEndian.PutUint32(buf[34:38], h.Capabilities)
	copy(buf[38:54], h.ClientNonce[:])
	return buf
}

// DecodeHello parses HelloPayload.
func DecodeHello(payload []byte) (*HelloPayload, error) {
	if len(payload) < 54 {
		return nil, fmt.Errorf("hello too short: %d", len(payload))
	}
	h := &HelloPayload{}
	copy(h.AuthToken[:], payload[0:32])
	h.ClientVer = binary.BigEndian.Uint16(payload[32:34])
	h.Capabilities = binary.BigEndian.Uint32(payload[34:38])
	copy(h.ClientNonce[:], payload[38:54])
	return h, nil
}

// HelloAckPayload is server's response with session info.
type HelloAckPayload struct {
	SessionID   [16]byte // Unique session identifier
	ServerNonce [16]byte // Server nonce for key derivation
	ServerVer   uint16   // Server protocol version
}

// EncodeHelloAck serializes HelloAckPayload.
func (h *HelloAckPayload) Encode() []byte {
	buf := make([]byte, 16+16+2)
	copy(buf[0:16], h.SessionID[:])
	copy(buf[16:32], h.ServerNonce[:])
	binary.BigEndian.PutUint16(buf[32:34], h.ServerVer)
	return buf
}

// DecodeHelloAck parses HelloAckPayload.
func DecodeHelloAck(payload []byte) (*HelloAckPayload, error) {
	if len(payload) < 34 {
		return nil, fmt.Errorf("hello ack too short: %d", len(payload))
	}
	h := &HelloAckPayload{}
	copy(h.SessionID[:], payload[0:16])
	copy(h.ServerNonce[:], payload[16:32])
	h.ServerVer = binary.BigEndian.Uint16(payload[32:34])
	return h, nil
}

// ConnectPayload requests a TCP connection to target.
type ConnectPayload struct {
	AddrType byte   // 0x01=IPv4, 0x02=IPv6, 0x03=Domain
	Addr     string // IP or domain
	Port     uint16
}

// EncodeConnect serializes ConnectPayload.
func (c *ConnectPayload) Encode() []byte {
	addrBytes := []byte(c.Addr)
	buf := make([]byte, 1+len(addrBytes)+2)
	buf[0] = c.AddrType
	copy(buf[1:], addrBytes)
	binary.BigEndian.PutUint16(buf[1+len(addrBytes):], c.Port)
	return buf
}

// DecodeConnect parses ConnectPayload.
func DecodeConnect(payload []byte) (*ConnectPayload, error) {
	if len(payload) < 3 {
		return nil, fmt.Errorf("connect too short: %d", len(payload))
	}
	c := &ConnectPayload{AddrType: payload[0]}
	addrLen := len(payload) - 3
	c.Addr = string(payload[1 : 1+addrLen])
	c.Port = binary.BigEndian.Uint16(payload[1+addrLen:])
	return c, nil
}

// ConnectAckPayload is server's response to TypeConnect.
type ConnectAckPayload struct {
	Status byte // 0x00=OK, 0x01=FAIL
}

// GenerateSessionID creates a random session identifier.
func GenerateSessionID() [16]byte {
	var id [16]byte
	rand.Read(id[:])
	return id
}

// GenerateNonce creates a random nonce for key derivation.
func GenerateNonce() [16]byte {
	var n [16]byte
	rand.Read(n[:])
	return n
}

// DialTimeout is default timeout for establishing connections.
const DialTimeout = 10 * time.Second
