package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
	"golang.org/x/crypto/sha3"
)

// AEGIS Encryption Layer — ChaCha20-Poly1305 with HKDF key derivation
//
// Key hierarchy:
//   master_secret (from auth token) → HKDF → session_keys
//   session_keys → encrypt/decrypt each message
//
// Nonce management:
//   Each direction has independent nonce counter (big-endian uint96)
//   Nonce = 4-byte random prefix + 8-byte counter (96 bits total)
//   ChaCha20-Poly1305 requires 12-byte nonce

const (
	KeySize   = 32 // ChaCha20-Poly1305 key size
	NonceSize = chacha20poly1305.NonceSize // 12 bytes
	TagSize   = chacha20poly1305.Overhead  // 16 bytes
)

// SessionKeys holds encryption state for one direction.
type SessionKeys struct {
	key     []byte
	nonce   []byte // current nonce (12 bytes)
	counter uint64 // message counter for nonce derivation
}

// NewSessionKeys derives session keys from master secret.
// salt should be unique per session (e.g., session ID or timestamp).
func NewSessionKeys(masterSecret []byte, salt []byte, info string) (*SessionKeys, error) {
	// Derive 32-byte key using HKDF-SHA3-256
	hkdfReader := hkdf.New(sha3.New256, masterSecret, salt, []byte(info))
	key := make([]byte, KeySize)
	if _, err := io.ReadFull(hkdfReader, key); err != nil {
		return nil, fmt.Errorf("hkdf derive: %w", err)
	}

	// Generate random nonce prefix (first 4 bytes)
	noncePrefix := make([]byte, 4)
	if _, err := rand.Read(noncePrefix); err != nil {
		return nil, fmt.Errorf("nonce prefix: %w", err)
	}

	// Initial nonce: 4-byte prefix + 8-byte counter (starts at 0)
	nonce := make([]byte, NonceSize)
	copy(nonce[:4], noncePrefix)
	// counter stays 0 for first message

	return &SessionKeys{
		key:     key,
		nonce:   nonce,
		counter: 0,
	}, nil
}

// NextNonce returns the next nonce and increments counter.
func (s *SessionKeys) NextNonce() []byte {
	// Build nonce: 4-byte prefix + 8-byte counter (big-endian)
	nonce := make([]byte, NonceSize)
	copy(nonce[:4], s.nonce[:4])
	binary.BigEndian.PutUint64(nonce[4:], s.counter)
	s.counter++
	return nonce
}

// Encrypt encrypts plaintext and returns ciphertext+tag.
func (s *SessionKeys) Encrypt(plaintext []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(s.key)
	if err != nil {
		return nil, err
	}

	nonce := s.NextNonce()
	// Seal appends tag to ciphertext
	ciphertext := aead.Seal(nil, nonce, plaintext, nil)

	// Prepend nonce to ciphertext for transmission
	// Format: [nonce(12)][ciphertext+tag]
	out := make([]byte, NonceSize+len(ciphertext))
	copy(out[:NonceSize], nonce)
	copy(out[NonceSize:], ciphertext)

	return out, nil
}

// Decrypt decrypts ciphertext (which includes nonce prefix) and returns plaintext.
func (s *SessionKeys) Decrypt(data []byte) ([]byte, error) {
	if len(data) < NonceSize+TagSize {
		return nil, fmt.Errorf("ciphertext too short: %d", len(data))
	}

	aead, err := chacha20poly1305.New(s.key)
	if err != nil {
		return nil, err
	}

	nonce := data[:NonceSize]
	ciphertext := data[NonceSize:]

	// Open verifies tag and decrypts
	plaintext, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}

	// Update counter based on received nonce
	// Extract counter from nonce (bytes 4-12)
	counter := binary.BigEndian.Uint64(nonce[4:])
	if counter >= s.counter {
		s.counter = counter + 1
	}

	return plaintext, nil
}

// DeriveSessionKeysFromAuth creates session keys for both directions.
// masterSecret is the auth token (SHA256 of password).
// clientNonce and serverNonce should be exchanged during handshake.
func DeriveSessionKeys(masterSecret []byte, clientNonce, serverNonce []byte) (clientToServer, serverToClient *SessionKeys, err error) {
	// Client → Server keys
	clientToServer, err = NewSessionKeys(masterSecret, clientNonce, "c2s")
	if err != nil {
		return nil, nil, err
	}

	// Server → Client keys
	serverToClient, err = NewSessionKeys(masterSecret, serverNonce, "s2c")
	if err != nil {
		return nil, nil, err
	}

	return clientToServer, serverToClient, nil
}
