package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
)

// WebSocket Protocol Constants
const (
	WSVersion = "13"
	WSMagicKey = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
)

// WSFrame represents a WebSocket frame
type WSFrame struct {
	FIN     bool
	Opcode  byte
	Masked  bool
	Payload []byte
}

// WSConnection represents a WebSocket connection
type WSConnection struct {
	conn       net.Conn
	reader     *bufio.Reader
	writer     *bufio.Writer
	isServer   bool
	closed     bool
	mu         sync.Mutex
	writeMu    sync.Mutex
	closeCh    chan struct{}
	onMessage  func([]byte)
	logger     func(string, ...interface{})
}

// NewWSConnection creates a new WebSocket connection
func NewWSConnection(conn net.Conn, isServer bool) *WSConnection {
	return &WSConnection{
		conn:     conn,
		reader:   bufio.NewReader(conn),
		writer:   bufio.NewWriter(conn),
		isServer: isServer,
		closeCh:  make(chan struct{}),
		logger:   func(format string, args ...interface{}) { fmt.Printf(format+"\n", args...) },
	}
}

// WSHandshake performs WebSocket handshake
func (ws *WSConnection) WSHandshake(path, host string) error {
	if ws.isServer {
		return ws.handleServerHandshake()
	}
	return ws.handleClientHandshake(path, host)
}

// handleServerHandshake handles server-side WebSocket handshake
func (ws *WSConnection) handleServerHandshake() error {
	// Read HTTP request
	req, err := http.ReadRequest(ws.reader)
	if err != nil {
		return fmt.Errorf("failed to read HTTP request: %w", err)
	}

	// Validate WebSocket upgrade
	if req.Header.Get("Upgrade") != "websocket" {
		return fmt.Errorf("not a WebSocket request")
	}

	key := req.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		return fmt.Errorf("missing Sec-WebSocket-Key")
	}

	// Compute accept key
	accept := computeAcceptKey(key)

	// Send HTTP response
	response := fmt.Sprintf("HTTP/1.1 101 Switching Protocols\r\n"+
		"Upgrade: websocket\r\n"+
		"Connection: Upgrade\r\n"+
		"Sec-WebSocket-Accept: %s\r\n"+
		"\r\n", accept)

	_, err = ws.conn.Write([]byte(response))
	if err != nil {
		return fmt.Errorf("failed to send handshake response: %w", err)
	}

	ws.logger("[WS] Handshake completed")
	return nil
}

// handleClientHandshake performs client-side WebSocket handshake
func (ws *WSConnection) handleClientHandshake(path string, host string) error {
	// Generate random key
	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		return fmt.Errorf("failed to generate key: %w", err)
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)

	// Send HTTP request
	request := fmt.Sprintf("GET %s HTTP/1.1\r\n"+
		"Host: %s\r\n"+
		"Upgrade: websocket\r\n"+
		"Connection: Upgrade\r\n"+
		"Sec-WebSocket-Key: %s\r\n"+
		"Sec-WebSocket-Version: %s\r\n"+
		"\r\n", path, host, key, WSVersion)

	_, err := ws.conn.Write([]byte(request))
	if err != nil {
		return fmt.Errorf("failed to send handshake request: %w", err)
	}

	// Read HTTP response
	resp, err := http.ReadResponse(ws.reader, nil)
	if err != nil {
		return fmt.Errorf("failed to read handshake response: %w", err)
	}

	if resp.StatusCode != 101 {
		return fmt.Errorf("handshake failed: %s", resp.Status)
	}

	ws.logger("[WS] Handshake completed")
	return nil
}

// computeAcceptKey computes the Sec-WebSocket-Accept value
func computeAcceptKey(key string) string {
	h := sha1.New()
	h.Write([]byte(key + WSMagicKey))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// ReadFrame reads a WebSocket frame
func (ws *WSConnection) ReadFrame() (*WSFrame, error) {
	ws.mu.Lock()
	defer ws.mu.Unlock()

	// Read frame header
	header := make([]byte, 2)
	if _, err := io.ReadFull(ws.reader, header); err != nil {
		return nil, err
	}

	fin := header[0]&0x80 != 0
	opcode := header[0] & 0x0F
	masked := header[1]&0x80 != 0
	payloadLen := int64(header[1] & 0x7F)

	// Extended payload length
	if payloadLen == 126 {
		extLen := make([]byte, 2)
		if _, err := io.ReadFull(ws.reader, extLen); err != nil {
			return nil, err
		}
		payloadLen = int64(binary.BigEndian.Uint16(extLen))
	} else if payloadLen == 127 {
		extLen := make([]byte, 8)
		if _, err := io.ReadFull(ws.reader, extLen); err != nil {
			return nil, err
		}
		payloadLen = int64(binary.BigEndian.Uint64(extLen))
	}

	// Read masking key
	var maskKey []byte
	if masked {
		maskKey = make([]byte, 4)
		if _, err := io.ReadFull(ws.reader, maskKey); err != nil {
			return nil, err
		}
	}

	// Read payload
	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(ws.reader, payload); err != nil {
		return nil, err
	}

	// Unmask payload
	if masked {
		for i := range payload {
			payload[i] ^= maskKey[i%4]
		}
	}

	return &WSFrame{
		FIN:     fin,
		Opcode:  opcode,
		Masked:  masked,
		Payload: payload,
	}, nil
}

// WriteFrame writes a WebSocket frame
func (ws *WSConnection) WriteFrame(opcode byte, payload []byte) error {
	ws.writeMu.Lock()
	defer ws.writeMu.Unlock()

	// Prepare frame header
	frame := make([]byte, 0, 14+len(payload))

	// First byte: FIN + opcode
	frame = append(frame, 0x80|opcode) // FIN = true

	// Second byte: MASK + payload length
	masked := !ws.isServer // Client must mask
	payloadLen := len(payload)

	if payloadLen < 126 {
		frame = append(frame, byte(payloadLen))
	} else if payloadLen < 65536 {
		frame = append(frame, 126)
		lenBytes := make([]byte, 2)
		binary.BigEndian.PutUint16(lenBytes, uint16(payloadLen))
		frame = append(frame, lenBytes...)
	} else {
		frame = append(frame, 127)
		lenBytes := make([]byte, 8)
		binary.BigEndian.PutUint64(lenBytes, uint64(payloadLen))
		frame = append(frame, lenBytes...)
	}

	if masked {
		frame[1] |= 0x80
	}

	// Generate masking key
	var maskKey []byte
	if masked {
		maskKey = make([]byte, 4)
		if _, err := rand.Read(maskKey); err != nil {
			return fmt.Errorf("failed to generate mask key: %w", err)
		}
		frame = append(frame, maskKey...)
	}

	// Mask payload
	maskedPayload := make([]byte, len(payload))
	copy(maskedPayload, payload)
	if masked {
		for i := range maskedPayload {
			maskedPayload[i] ^= maskKey[i%4]
		}
	}

	frame = append(frame, maskedPayload...)

	// Write frame
	_, err := ws.writer.Write(frame)
	if err != nil {
		return fmt.Errorf("failed to write frame: %w", err)
	}
	return ws.writer.Flush()
}

// WriteMessage writes a text or binary message
func (ws *WSConnection) WriteMessage(opcode byte, data []byte) error {
	return ws.WriteFrame(opcode, data)
}

// ReadMessage reads a complete message
func (ws *WSConnection) ReadMessage() ([]byte, error) {
	var message []byte
	for {
		frame, err := ws.ReadFrame()
		if err != nil {
			return nil, err
		}

		message = append(message, frame.Payload...)

		if frame.FIN {
			break
		}
	}
	return message, nil
}

// SendText sends a text message
func (ws *WSConnection) SendText(text string) error {
	return ws.WriteMessage(0x1, []byte(text))
}

// SendBinary sends a binary message
func (ws *WSConnection) SendBinary(data []byte) error {
	return ws.WriteMessage(0x2, data)
}

// Close closes the WebSocket connection
func (ws *WSConnection) Close() error {
	ws.mu.Lock()
	defer ws.mu.Unlock()

	if ws.closed {
		return nil
	}
	ws.closed = true

	// Send close frame
	closeFrame := []byte{0x88, 0x00} // FIN + close opcode, no payload
	_, err := ws.conn.Write(closeFrame)
	if err != nil {
		ws.logger("[WS] Failed to send close frame: %v", err)
	}

	close(ws.closeCh)
	return ws.conn.Close()
}

// WSServer handles WebSocket server connections
type WSServer struct {
	listenAddr *net.TCPAddr
	secret     string
	listener   net.Listener
	conns      map[*WSConnection]bool
	mu         sync.RWMutex
	closed     bool
	logger     func(string, ...interface{})
}

// NewWSServer creates a new WebSocket server
func NewWSServer(listenAddr *net.TCPAddr, secret string) *WSServer {
	return &WSServer{
		listenAddr: listenAddr,
		secret:     secret,
		conns:      make(map[*WSConnection]bool),
		logger:     func(format string, args ...interface{}) { fmt.Printf(format+"\n", args...) },
	}
}

// Listen starts the WebSocket server
func (s *WSServer) Listen() error {
	listener, err := net.ListenTCP("tcp", s.listenAddr)
	if err != nil {
		return fmt.Errorf("failed to listen on %v: %w", s.listenAddr, err)
	}
	s.listener = listener

	go s.acceptLoop()
	s.logger("[WS] Server listening on %s", s.listenAddr)
	return nil
}

// acceptLoop accepts incoming connections
func (s *WSServer) acceptLoop() {
	for !s.closed {
		conn, err := s.listener.Accept()
		if err != nil {
			if !s.closed {
				s.logger("[WS] Accept error: %v", err)
			}
			continue
		}

		go s.handleConnection(conn)
	}
}

// handleConnection handles a single WebSocket connection
func (s *WSServer) handleConnection(conn net.Conn) {
	ws := NewWSConnection(conn, true)
	ws.onMessage = func(data []byte) {
		s.handleMessage(ws, data)
	}

	// Perform handshake
	if err := ws.WSHandshake("/aegis", ""); err != nil {
		s.logger("[WS] Handshake failed: %v", err)
		conn.Close()
		return
	}

	s.mu.Lock()
	s.conns[ws] = true
	s.mu.Unlock()

	// Read messages
	for !s.closed {
		data, err := ws.ReadMessage()
		if err != nil {
			if !s.closed {
				s.logger("[WS] Read error: %v", err)
			}
			break
		}

		if ws.onMessage != nil {
			ws.onMessage(data)
		}
	}

	s.mu.Lock()
	delete(s.conns, ws)
	s.mu.Unlock()
	ws.Close()
}

// handleMessage processes a WebSocket message
func (s *WSServer) handleMessage(ws *WSConnection, data []byte) {
	// TODO: Implement AEGIS protocol over WebSocket
	// For now, just echo back
	ws.SendBinary(data)
}

// Close closes the WebSocket server
func (s *WSServer) Close() error {
	s.mu.Lock()
	s.closed = true
	conns := make([]*WSConnection, 0, len(s.conns))
	for conn := range s.conns {
		conns = append(conns, conn)
	}
	s.mu.Unlock()

	for _, conn := range conns {
		conn.Close()
	}

	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}

// WSClient handles WebSocket client connections
type WSClient struct {
	serverAddr *net.TCPAddr
	secret     string
	conn       net.Conn
	ws         *WSConnection
	closed     bool
	mu         sync.RWMutex
	logger     func(string, ...interface{})
}

// NewWSClient creates a new WebSocket client
func NewWSClient(serverAddr *net.TCPAddr, secret string) *WSClient {
	return &WSClient{
		serverAddr: serverAddr,
		secret:     secret,
		logger:     func(format string, args ...interface{}) { fmt.Printf(format+"\n", args...) },
	}
}

// Connect establishes a WebSocket connection
func (c *WSClient) Connect() error {
	conn, err := net.DialTCP("tcp", nil, c.serverAddr)
	if err != nil {
		return fmt.Errorf("failed to connect to %v: %w", c.serverAddr, err)
	}
	c.conn = conn

	ws := NewWSConnection(conn, false)
	path := "/aegis"
	host := c.serverAddr.String()

	if err := ws.handleClientHandshake(path, host); err != nil {
		conn.Close()
		return fmt.Errorf("WebSocket handshake failed: %w", err)
	}

	c.ws = ws
	c.logger("[WS] Connected to %s", c.serverAddr)
	return nil
}

// Send sends data over WebSocket
func (c *WSClient) Send(data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed || c.ws == nil {
		return fmt.Errorf("client is closed")
	}

	return c.ws.SendBinary(data)
}

// Receive receives data from WebSocket
func (c *WSClient) Receive() ([]byte, error) {
	if c.ws == nil {
		return nil, fmt.Errorf("not connected")
	}

	return c.ws.ReadMessage()
}

// Close closes the WebSocket client
func (c *WSClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return nil
	}
	c.closed = true

	if c.ws != nil {
		return c.ws.Close()
	}
	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

// runWSServer starts the WebSocket server
func runWSServer(listenAddr, secret string) error {
	addr, err := net.ResolveTCPAddr("tcp", listenAddr)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}

	server := NewWSServer(addr, secret)
	if err := server.Listen(); err != nil {
		return err
	}

	fmt.Printf("[WS] AEGIS WebSocket server listening on %s\n", listenAddr)
	fmt.Println("Press Ctrl+C to stop")

	// Block forever
	select {}
}

// runWSClient starts the WebSocket client
func runWSClient(serverAddr, secret, listenAddr string) error {
	serverTCP, err := net.ResolveTCPAddr("tcp", serverAddr)
	if err != nil {
		return fmt.Errorf("invalid server address: %w", err)
	}

	// TODO: Implement WebSocket proxy server
	// For now, just create a client connection
	client := NewWSClient(serverTCP, secret)
	if err := client.Connect(); err != nil {
		return err
	}

	fmt.Printf("[WS] AEGIS WebSocket client connected to %s\n", serverAddr)
	fmt.Println("Press Ctrl+C to stop")

	// Block forever
	select {}
}
