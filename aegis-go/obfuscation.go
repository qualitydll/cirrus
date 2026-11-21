package main

import (
	"crypto/rand"
	"encoding/binary"
	"math/big"
	"time"
)

// AEGIS Obfuscation Layer — makes traffic look less like VPN protocol
//
// Techniques:
//   1. Random padding: add 0-512 bytes of random data to messages
//   2. Timing jitter: add 0-50ms delay before sending
//   3. Fake packets: send occasional garbage packets to confuse DPI
//   4. Variable message sizes: pad to common sizes (512, 1024, 1460, 1500)

const (
	MaxPadding      = 512
	MinPadding      = 0
	JitterMaxMs     = 50
	FakePacketProb  = 0.02 // 2% chance of fake packet
	PaddingEnabled  = true
	JitterEnabled   = true
	FakePacketsOn   = true
)

// ObfuscationConfig holds obfuscation settings.
type ObfuscationConfig struct {
	PaddingEnabled bool
	JitterEnabled  bool
	FakePackets    bool
	MaxPadding     int
	JitterMaxMs    int
	FakePacketProb float64
}

// DefaultObfuscation returns default obfuscation config.
func DefaultObfuscation() *ObfuscationConfig {
	return &ObfuscationConfig{
		PaddingEnabled: PaddingEnabled,
		JitterEnabled:  JitterEnabled,
		FakePackets:    FakePacketsOn,
		MaxPadding:     MaxPadding,
		JitterMaxMs:    JitterMaxMs,
		FakePacketProb: FakePacketProb,
	}
}

// AddPadding adds random padding to payload.
// Returns padded payload and padding length.
func (o *ObfuscationConfig) AddPadding(payload []byte) ([]byte, int) {
	if !o.PaddingEnabled {
		return payload, 0
	}

	// Random padding length: 0 to MaxPadding
	padLen, _ := rand.Int(rand.Reader, big.NewInt(int64(o.MaxPadding)))
	padLenInt := int(padLen.Int64())

	if padLenInt == 0 {
		return payload, 0
	}

	// Create padded payload: [original][padding]
	padded := make([]byte, len(payload)+padLenInt)
	copy(padded, payload)

	// Fill padding with random bytes
	padBytes := make([]byte, padLenInt)
	rand.Read(padBytes)
	copy(padded[len(payload):], padBytes)

	// Store padding length in first 2 bytes of padding (for removal)
	// Actually, we'll use a different approach: send padding length in header
	// For now, just append padding and let receiver know via separate field
	// Simpler: prepend padding length to payload

	// Rebuild: [pad_len(2)][payload][padding]
	final := make([]byte, 2+len(payload)+padLenInt)
	binary.BigEndian.PutUint16(final[:2], uint16(padLenInt))
	copy(final[2:2+len(payload)], payload)
	copy(final[2+len(payload):], padBytes)

	return final, padLenInt
}

// RemovePadding removes padding from payload.
func (o *ObfuscationConfig) RemovePadding(data []byte) ([]byte, error) {
	if len(data) < 2 {
		return nil, nil
	}

	padLen := int(binary.BigEndian.Uint16(data[:2]))
	if padLen == 0 {
		return data[2:], nil
	}

	if len(data) < 2+padLen {
		return nil, nil
	}

	return data[2 : len(data)-padLen], nil
}

// ApplyJitter adds random delay before sending.
func (o *ObfuscationConfig) ApplyJitter() {
	if !o.JitterEnabled {
		return
	}

	// Random delay: 0 to JitterMaxMs
	delayMs, _ := rand.Int(rand.Reader, big.NewInt(int64(o.JitterMaxMs)))
	if delayMs.Int64() > 0 {
		time.Sleep(time.Duration(delayMs.Int64()) * time.Millisecond)
	}
}

// ShouldSendFakePacket determines if we should send a fake packet.
func (o *ObfuscationConfig) ShouldSendFakePacket() bool {
	if !o.FakePackets {
		return false
	}

	// Random probability check
	r, _ := rand.Int(rand.Reader, big.NewInt(1000))
	return float64(r.Int64())/1000.0 < o.FakePacketProb
}

// GenerateFakePacket creates a random-looking packet for obfuscation.
func GenerateFakePacket() []byte {
	// Generate random packet that looks like random TCP data
	size, _ := rand.Int(rand.Reader, big.NewInt(1400))
	packet := make([]byte, size.Int64())
	rand.Read(packet)
	return packet
}

// ObfuscatedConn wraps EncryptedConn with obfuscation.
type ObfuscatedConn struct {
	*EncryptedConn
	config *ObfuscationConfig
}

// NewObfuscatedConn creates an obfuscated connection.
func NewObfuscatedConn(ec *EncryptedConn, config *ObfuscationConfig) *ObfuscatedConn {
	return &ObfuscatedConn{
		EncryptedConn: ec,
		config:       config,
	}
}

// WriteMessage writes message with obfuscation (padding + jitter).
func (oc *ObfuscatedConn) WriteMessage(msg *Message) error {
	// Apply jitter before sending
	oc.config.ApplyJitter()

	// Add padding to payload
	paddedPayload, _ := oc.config.AddPadding(msg.Payload)

	// Create padded message
	paddedMsg := &Message{
		Type:    msg.Type,
		Payload: paddedPayload,
	}

	return oc.EncryptedConn.WriteMessage(paddedMsg)
}

// ReadMessage reads message and removes padding.
func (oc *ObfuscatedConn) ReadMessage() (*Message, error) {
	msg, err := oc.EncryptedConn.ReadMessage()
	if err != nil {
		return nil, err
	}

	// Remove padding from payload
	cleanPayload, err := oc.config.RemovePadding(msg.Payload)
	if err != nil {
		return nil, err
	}

	return &Message{
		Type:    msg.Type,
		Payload: cleanPayload,
	}, nil
}
