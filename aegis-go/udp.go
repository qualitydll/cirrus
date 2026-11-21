package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"sync"
	"time"
)

// UDP Protocol Constants
const (
	UDPVersion      = 0x01
	UDPMagic1       = 0xA3
	UDPMagic2       = 0x11
	UDPMagic3       = 0x5E
	UDPMagic4       = 0x47

	// UDP Message Types
	UDPTypeSYN     = 0x01 // Session initiation
	UDPTypeSYNACK  = 0x02 // Session acknowledgment
	UDPTypeDATA    = 0x03 // Data packet
	UDPTypeACK     = 0x04 // Acknowledgment
	UDPTypeFIN     = 0x05 // Session end
	UDPTypePING    = 0x06 // Keepalive
	UDPTypePONG    = 0x07 // Keepalive response
	UDPTypeFECData = 0x08 // FEC parity packet

	// UDP Flags
	UDPFlagFEC      = 0x01 // FEC enabled
	UDPFlagEncrypted = 0x02 // Encrypted payload
	UDPFlagCompressed = 0x04 // Compressed payload
)

// UDPPacket represents a UDP packet in AEGIS protocol
type UDPPacket struct {
	Magic      [4]byte // A3 11 5E 47
	Version    byte    // Protocol version
	Type       byte    // Message type
	Flags      byte    // Flags (FEC, encrypted, etc.)
	SessionID  uint32  // Session identifier
	Sequence   uint32  // Packet sequence number
	Timestamp  uint64  // Nanoseconds since epoch
	PayloadLen uint16  // Encrypted payload length
	FECGroup   uint16  // FEC group ID (0 if no FEC)
	FECIndex   uint8   // FEC index within group
	Reserved   uint8   // Reserved for future use
	Payload    []byte  // Encrypted payload
}

// UDPHeaderSize is the fixed header size for UDP packets
const UDPHeaderSize = 4 + 1 + 1 + 1 + 4 + 4 + 8 + 2 + 2 + 1 + 1 // 29 bytes

// UDPSession represents a UDP session
type UDPSession struct {
	ID           uint32
	ClientAddr   *net.UDPAddr
	ServerAddr   *net.UDPAddr
	CreatedAt    time.Time
	LastActivity time.Time
	SendQueue    chan *UDPPacket
	RecvQueue    chan *UDPPacket
	Closed       bool
	mu           sync.RWMutex
}

// NewUDPSession creates a new UDP session
func NewUDPSession(clientAddr, serverAddr *net.UDPAddr) *UDPSession {
	return &UDPSession{
		ID:           uint32(time.Now().UnixNano() & 0xFFFFFFFF),
		ClientAddr:   clientAddr,
		ServerAddr:   serverAddr,
		CreatedAt:    time.Now(),
		LastActivity: time.Now(),
		SendQueue:    make(chan *UDPPacket, 256),
		RecvQueue:    make(chan *UDPPacket, 256),
	}
}

// MarshalUDP serializes a UDP packet
func MarshalUDP(pkt *UDPPacket) ([]byte, error) {
	buf := make([]byte, UDPHeaderSize+len(pkt.Payload))
	offset := 0

	// Magic
	copy(buf[offset:], pkt.Magic[:])
	offset += 4

	// Version
	buf[offset] = pkt.Version
	offset++

	// Type
	buf[offset] = pkt.Type
	offset++

	// Flags
	buf[offset] = pkt.Flags
	offset++

	// Session ID
	binary.BigEndian.PutUint32(buf[offset:], pkt.SessionID)
	offset += 4

	// Sequence
	binary.BigEndian.PutUint32(buf[offset:], pkt.Sequence)
	offset += 4

	// Timestamp
	binary.BigEndian.PutUint64(buf[offset:], pkt.Timestamp)
	offset += 8

	// Payload length
	binary.BigEndian.PutUint16(buf[offset:], uint16(len(pkt.Payload)))
	offset += 2

	// FEC group
	binary.BigEndian.PutUint16(buf[offset:], pkt.FECGroup)
	offset += 2

	// FEC index
	buf[offset] = pkt.FECIndex
	offset++

	// Reserved
	buf[offset] = pkt.Reserved
	offset++

	// Payload
	copy(buf[offset:], pkt.Payload)

	return buf, nil
}

// UnmarshalUDP deserializes a UDP packet
func UnmarshalUDP(data []byte) (*UDPPacket, error) {
	if len(data) < UDPHeaderSize {
		return nil, fmt.Errorf("packet too short: %d < %d", len(data), UDPHeaderSize)
	}

	pkt := &UDPPacket{}
	offset := 0

	// Magic
	copy(pkt.Magic[:], data[offset:offset+4])
	offset += 4

	if pkt.Magic != [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4} {
		return nil, fmt.Errorf("invalid magic: %x", pkt.Magic)
	}

	// Version
	pkt.Version = data[offset]
	offset++
	if pkt.Version != UDPVersion {
		return nil, fmt.Errorf("unsupported version: %d", pkt.Version)
	}

	// Type
	pkt.Type = data[offset]
	offset++

	// Flags
	pkt.Flags = data[offset]
	offset++

	// Session ID
	pkt.SessionID = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	// Sequence
	pkt.Sequence = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	// Timestamp
	pkt.Timestamp = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	// Payload length
	pkt.PayloadLen = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	// FEC group
	pkt.FECGroup = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	// FEC index
	pkt.FECIndex = data[offset]
	offset++

	// Reserved
	pkt.Reserved = data[offset]
	offset++

	// Payload
	payloadLen := int(pkt.PayloadLen)
	if offset+payloadLen > len(data) {
		return nil, fmt.Errorf("payload length exceeds packet size")
	}
	pkt.Payload = make([]byte, payloadLen)
	copy(pkt.Payload, data[offset:offset+payloadLen])

	return pkt, nil
}

// UDPServer handles UDP connections
type UDPServer struct {
	listenAddr *net.UDPAddr
	secret     string
	conn       *net.UDPConn
	sessions   map[uint32]*UDPSession
	mu         sync.RWMutex
	closed     bool
	logger     func(string, ...interface{})
}

// NewUDPServer creates a new UDP server
func NewUDPServer(listenAddr *net.UDPAddr, secret string) *UDPServer {
	return &UDPServer{
		listenAddr: listenAddr,
		secret:     secret,
		sessions:   make(map[uint32]*UDPSession),
		logger:     func(format string, args ...interface{}) { fmt.Printf(format+"\n", args...) },
	}
}

// Listen starts the UDP server
func (s *UDPServer) Listen() error {
	conn, err := net.ListenUDP("udp", s.listenAddr)
	if err != nil {
		return fmt.Errorf("failed to listen on UDP %v: %w", s.listenAddr, err)
	}
	s.conn = conn

	go s.acceptLoop()
	s.logger("[UDP] Server listening on %s", s.listenAddr)
	return nil
}

// acceptLoop handles incoming UDP packets
func (s *UDPServer) acceptLoop() {
	buffer := make([]byte, 65535)
	for !s.closed {
		n, addr, err := s.conn.ReadFromUDP(buffer)
		if err != nil {
			if !s.closed {
				s.logger("[UDP] Read error: %v", err)
			}
			continue
		}

		go s.handlePacket(buffer[:n], addr)
	}
}

// handlePacket processes a single UDP packet
func (s *UDPServer) handlePacket(data []byte, addr *net.UDPAddr) {
	pkt, err := UnmarshalUDP(data)
	if err != nil {
		// Ignore invalid packets (could be fake traffic)
		return
	}

	s.mu.Lock()
	session, exists := s.sessions[pkt.SessionID]
	if !exists {
		// Create new session for SYN packets
		if pkt.Type == UDPTypeSYN {
			session = NewUDPSession(addr, s.listenAddr)
			session.ID = pkt.SessionID // Use client's session ID
			s.sessions[pkt.SessionID] = session
			s.logger("[UDP] New session from %s (ID: %d)", addr, pkt.SessionID)
		} else {
			s.mu.Unlock()
			return // No session, ignore
		}
	}
	s.mu.Unlock()

	// Handle packet based on type
	switch pkt.Type {
	case UDPTypeSYN:
		s.handleSYN(session, pkt, addr)
	case UDPTypeDATA:
		s.handleData(session, pkt, addr)
	case UDPTypeACK:
		s.handleACK(session, pkt, addr)
	case UDPTypeFIN:
		s.handleFIN(session, pkt, addr)
	case UDPTypePING:
		s.handlePING(session, pkt, addr)
	}
}

// handleSYN processes session initiation
func (s *UDPServer) handleSYN(session *UDPSession, pkt *UDPPacket, addr *net.UDPAddr) {
	// TODO: Implement authentication and session setup
	s.logger("[UDP] SYN from %s", addr)

	// Send SYN-ACK
	resp := &UDPPacket{
		Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
		Version:    UDPVersion,
		Type:       UDPTypeSYNACK,
		Flags:      UDPFlagFEC,
		SessionID:  pkt.SessionID,
		Sequence:   0,
		Timestamp:  uint64(time.Now().UnixNano()),
		PayloadLen: 0,
	}

	respData, err := MarshalUDP(resp)
	if err != nil {
		s.logger("[UDP] Failed to marshal SYNACK: %v", err)
		return
	}

	_, err = s.conn.WriteToUDP(respData, addr)
	if err != nil {
		s.logger("[UDP] Failed to send SYNACK: %v", err)
	}
}

// handleData processes data packets
func (s *UDPServer) handleData(session *UDPSession, pkt *UDPPacket, addr *net.UDPAddr) {
	s.logger("[UDP] DATA from %s (seq: %d, len: %d)", addr, pkt.Sequence, pkt.PayloadLen)

	// TODO: Implement FEC recovery and data processing
	// For now, just acknowledge
	s.sendACK(session, pkt.Sequence, addr)
}

// handleACK processes acknowledgments
func (s *UDPServer) handleACK(session *UDPSession, pkt *UDPPacket, addr *net.UDPAddr) {
	s.logger("[UDP] ACK from %s (seq: %d)", addr, pkt.Sequence)
	// TODO: Implement congestion control and retransmission
}

// handleFIN processes session termination
func (s *UDPServer) handleFIN(session *UDPSession, pkt *UDPPacket, addr *net.UDPAddr) {
	s.logger("[UDP] FIN from %s", addr)
	s.mu.Lock()
	delete(s.sessions, pkt.SessionID)
	s.mu.Unlock()
}

// handlePING processes keepalive
func (s *UDPServer) handlePING(session *UDPSession, pkt *UDPPacket, addr *net.UDPAddr) {
	// Send PONG
	resp := &UDPPacket{
		Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
		Version:    UDPVersion,
		Type:       UDPTypePONG,
		Flags:      0,
		SessionID:  pkt.SessionID,
		Sequence:   pkt.Sequence,
		Timestamp:  uint64(time.Now().UnixNano()),
	}

	respData, err := MarshalUDP(resp)
	if err != nil {
		return
	}

	_, err = s.conn.WriteToUDP(respData, addr)
	if err != nil {
		s.logger("[UDP] Failed to send PONG: %v", err)
	}
}

// sendACK sends an acknowledgment
func (s *UDPServer) sendACK(session *UDPSession, sequence uint32, addr *net.UDPAddr) {
	resp := &UDPPacket{
		Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
		Version:    UDPVersion,
		Type:       UDPTypeACK,
		Flags:      0,
		SessionID:  session.ID,
		Sequence:   sequence,
		Timestamp:  uint64(time.Now().UnixNano()),
	}

	respData, err := MarshalUDP(resp)
	if err != nil {
		return
	}

	_, err = s.conn.WriteToUDP(respData, addr)
	if err != nil {
		s.logger("[UDP] Failed to send ACK: %v", err)
	}
}

// Close stops the UDP server
func (s *UDPServer) Close() error {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()

	if s.conn != nil {
		return s.conn.Close()
	}
	return nil
}

// UDPClient handles UDP client connections
type UDPClient struct {
	serverAddr *net.UDPAddr
	secret     string
	conn       *net.UDPConn
	localAddr  *net.UDPAddr
	sessionID  uint32
	sequence   uint32
	closed     bool
	mu         sync.RWMutex
	logger     func(string, ...interface{})
}

// NewUDPClient creates a new UDP client
func NewUDPClient(serverAddr *net.UDPAddr, secret string) *UDPClient {
	return &UDPClient{
		serverAddr: serverAddr,
		secret:     secret,
		sequence:   0,
		logger:     func(format string, args ...interface{}) { fmt.Printf(format+"\n", args...) },
	}
}

// Connect establishes a UDP session
func (c *UDPClient) Connect() error {
	// Create UDP socket
	localAddr, err := net.ResolveUDPAddr("udp", "0.0.0.0:0")
	if err != nil {
		return fmt.Errorf("failed to resolve local address: %w", err)
	}

	conn, err := net.ListenUDP("udp", localAddr)
	if err != nil {
		return fmt.Errorf("failed to create UDP socket: %w", err)
	}
	c.conn = conn
	c.localAddr = conn.LocalAddr().(*net.UDPAddr)

	// Generate session ID
	c.sessionID = uint32(time.Now().UnixNano() & 0xFFFFFFFF)

	// Send SYN
	syn := &UDPPacket{
		Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
		Version:    UDPVersion,
		Type:       UDPTypeSYN,
		Flags:      UDPFlagFEC,
		SessionID:  c.sessionID,
		Sequence:   0,
		Timestamp:  uint64(time.Now().UnixNano()),
		Payload:    []byte(c.secret), // Simple auth for now
	}

	synData, err := MarshalUDP(syn)
	if err != nil {
		return fmt.Errorf("failed to marshal SYN: %w", err)
	}

	_, err = c.conn.WriteToUDP(synData, c.serverAddr)
	if err != nil {
		return fmt.Errorf("failed to send SYN: %w", err)
	}

	// Wait for SYN-ACK
	buffer := make([]byte, 65535)
	c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, _, err := c.conn.ReadFromUDP(buffer)
	if err != nil {
		return fmt.Errorf("failed to receive SYN-ACK: %w", err)
	}

	pkt, err := UnmarshalUDP(buffer[:n])
	if err != nil {
		return fmt.Errorf("failed to parse SYN-ACK: %w", err)
	}

	if pkt.Type != UDPTypeSYNACK {
		return fmt.Errorf("expected SYN-ACK, got type %d", pkt.Type)
	}

	c.logger("[UDP] Connected to %s (session: %d)", c.serverAddr, c.sessionID)
	return nil
}

// Send sends data over UDP
func (c *UDPClient) Send(data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return fmt.Errorf("client is closed")
	}

	c.sequence++
	pkt := &UDPPacket{
		Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
		Version:    UDPVersion,
		Type:       UDPTypeDATA,
		Flags:      UDPFlagFEC | UDPFlagEncrypted,
		SessionID:  c.sessionID,
		Sequence:   c.sequence,
		Timestamp:  uint64(time.Now().UnixNano()),
		Payload:    data,
	}

	pktData, err := MarshalUDP(pkt)
	if err != nil {
		return fmt.Errorf("failed to marshal packet: %w", err)
	}

	_, err = c.conn.WriteToUDP(pktData, c.serverAddr)
	if err != nil {
		return fmt.Errorf("failed to send packet: %w", err)
	}

	return nil
}

// Receive receives data from UDP
func (c *UDPClient) Receive() ([]byte, error) {
	buffer := make([]byte, 65535)
	c.conn.SetReadDeadline(time.Now().Add(10 * time.Second))

	n, _, err := c.conn.ReadFromUDP(buffer)
	if err != nil {
		return nil, fmt.Errorf("failed to receive packet: %w", err)
	}

	pkt, err := UnmarshalUDP(buffer[:n])
	if err != nil {
		return nil, fmt.Errorf("failed to parse packet: %w", err)
	}

	switch pkt.Type {
	case UDPTypeDATA:
		return pkt.Payload, nil
	case UDPTypeACK:
		return nil, nil // Acknowledgment, no data
	case UDPTypePING:
		// Respond with PONG
		c.sendPONG(pkt.Sequence)
		return nil, nil
	case UDPTypePONG:
		return nil, nil // Keepalive response
	default:
		return nil, fmt.Errorf("unexpected packet type: %d", pkt.Type)
	}
}

// sendPONG sends a PONG response
func (c *UDPClient) sendPONG(sequence uint32) {
	pkt := &UDPPacket{
		Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
		Version:    UDPVersion,
		Type:       UDPTypePONG,
		Flags:      0,
		SessionID:  c.sessionID,
		Sequence:   sequence,
		Timestamp:  uint64(time.Now().UnixNano()),
	}

	pktData, err := MarshalUDP(pkt)
	if err != nil {
		return
	}

	c.conn.WriteToUDP(pktData, c.serverAddr)
}

// Close closes the UDP client
func (c *UDPClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return nil
	}

	c.closed = true

	// Send FIN
	if c.conn != nil {
		fin := &UDPPacket{
			Magic:      [4]byte{UDPMagic1, UDPMagic2, UDPMagic3, UDPMagic4},
			Version:    UDPVersion,
			Type:       UDPTypeFIN,
			Flags:      0,
			SessionID:  c.sessionID,
			Sequence:   c.sequence,
			Timestamp:  uint64(time.Now().UnixNano()),
		}

		finData, err := MarshalUDP(fin)
		if err == nil {
			c.conn.WriteToUDP(finData, c.serverAddr)
		}

		return c.conn.Close()
	}
	return nil
}

// UDPProxyServer provides a UDP proxy interface
type UDPProxyServer struct {
	listenAddr *net.UDPAddr
	serverAddr *net.UDPAddr
	secret     string
	client     *UDPClient
	closed     bool
	mu         sync.RWMutex
	logger     func(string, ...interface{})
}

// NewUDPProxyServer creates a new UDP proxy server
func NewUDPProxyServer(listenAddr, serverAddr *net.UDPAddr, secret string) *UDPProxyServer {
	return &UDPProxyServer{
		listenAddr: listenAddr,
		serverAddr: serverAddr,
		secret:     secret,
		logger:     func(format string, args ...interface{}) { fmt.Printf(format+"\n", args...) },
	}
}

// Listen starts the UDP proxy server
func (p *UDPProxyServer) Listen() error {
	// Create UDP client to AEGIS server
	client := NewUDPClient(p.serverAddr, p.secret)
	if err := client.Connect(); err != nil {
		return fmt.Errorf("failed to connect to AEGIS server: %w", err)
	}
	p.client = client

	// Listen on local UDP address
	conn, err := net.ListenUDP("udp", p.listenAddr)
	if err != nil {
		return fmt.Errorf("failed to listen on %v: %w", p.listenAddr, err)
	}

	go p.proxyLoop(conn)
	p.logger("[UDP] Proxy listening on %s -> %s", p.listenAddr, p.serverAddr)
	return nil
}

// proxyLoop handles UDP proxying
func (p *UDPProxyServer) proxyLoop(conn *net.UDPConn) {
	buffer := make([]byte, 65535)
	for !p.closed {
		n, _, err := conn.ReadFromUDP(buffer)
		if err != nil {
			if !p.closed {
				p.logger("[UDP] Read error: %v", err)
			}
			continue
		}

		// Forward to AEGIS server
		if err := p.client.Send(buffer[:n]); err != nil {
			p.logger("[UDP] Failed to send to AEGIS: %v", err)
			continue
		}

		// TODO: Implement proper UDP proxying with destination resolution
		// For now, this is a simple relay
	}
}

// Close closes the UDP proxy server
func (p *UDPProxyServer) Close() error {
	p.mu.Lock()
	p.closed = true
	p.mu.Unlock()

	if p.client != nil {
		p.client.Close()
	}
	return nil
}

// runUDPServer starts the UDP server
func runUDPServer(listenAddr, secret string, fec bool) error {
	addr, err := net.ResolveUDPAddr("udp", listenAddr)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}

	server := NewUDPServer(addr, secret)
	if err := server.Listen(); err != nil {
		return err
	}

	fmt.Printf("[UDP] AEGIS server listening on %s (FEC: %v)\n", listenAddr, fec)
	fmt.Println("Press Ctrl+C to stop")

	// Block forever
	select {}
}

// runUDPClient starts the UDP client
func runUDPClient(serverAddr, secret, listenAddr string, fec bool) error {
	serverUDP, err := net.ResolveUDPAddr("udp", serverAddr)
	if err != nil {
		return fmt.Errorf("invalid server address: %w", err)
	}

	listenUDP, err := net.ResolveUDPAddr("udp", listenAddr)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}

	proxy := NewUDPProxyServer(listenUDP, serverUDP, secret)
	if err := proxy.Listen(); err != nil {
		return err
	}

	fmt.Printf("[UDP] AEGIS client proxy listening on %s -> %s (FEC: %v)\n", listenAddr, serverAddr, fec)
	fmt.Println("Press Ctrl+C to stop")

	// Block forever
	select {}
}
