package mocksocks

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	socksVersion      = 0x05
	socksAuthUserPass = 0x02
	socksCmdUDPAssoc  = 0x03
	socksAtypIPv4     = 0x01
)

// Server is a minimal SOCKS5 UDP associate server for tests.
type Server struct {
	t testing.TB

	user string
	pass string

	tcpLn     net.Listener
	udpConn   *net.UDPConn
	tcpConns  []net.Conn
	tcpMu     sync.Mutex
	dialCount atomic.Uint32
	dialDelay time.Duration

	replyEnabled atomic.Bool
	closed       atomic.Bool

	lastUDPPort atomic.Uint32
}

// New starts a mock SOCKS5 server on localhost.
func New(t testing.TB, user, pass string) *Server {
	t.Helper()
	s := &Server{t: t, user: user, pass: pass}
	s.replyEnabled.Store(true)

	tcpLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen tcp: %v", err)
	}
	s.tcpLn = tcpLn

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		tcpLn.Close()
		t.Fatalf("listen udp: %v", err)
	}
	s.udpConn = udpConn
	s.lastUDPPort.Store(uint32(udpConn.LocalAddr().(*net.UDPAddr).Port))

	go s.acceptLoop()
	go s.udpReadLoop()
	return s
}

func (s *Server) Addr() string {
	return s.tcpLn.Addr().String()
}

func (s *Server) UDPPort() uint16 {
	return uint16(s.lastUDPPort.Load())
}

func (s *Server) DialCount() int {
	return int(s.dialCount.Load())
}

func (s *Server) SetDialDelay(d time.Duration) {
	s.dialDelay = d
}

func (s *Server) SetReplyEnabled(enabled bool) {
	s.replyEnabled.Store(enabled)
}

func (s *Server) CloseTCP() {
	s.tcpMu.Lock()
	conns := append([]net.Conn(nil), s.tcpConns...)
	s.tcpConns = nil
	s.tcpMu.Unlock()
	for _, c := range conns {
		_ = c.Close()
	}
}

func (s *Server) Close() {
	if s.closed.Swap(true) {
		return
	}
	s.CloseTCP()
	if s.tcpLn != nil {
		_ = s.tcpLn.Close()
	}
	if s.udpConn != nil {
		_ = s.udpConn.Close()
	}
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.tcpLn.Accept()
		if err != nil {
			return
		}
		s.tcpMu.Lock()
		s.tcpConns = append(s.tcpConns, conn)
		s.tcpMu.Unlock()
		go s.handleTCP(conn)
	}
}

func (s *Server) handleTCP(conn net.Conn) {
	defer conn.Close()
	if s.dialDelay > 0 {
		time.Sleep(s.dialDelay)
	}
	s.dialCount.Add(1)

	if err := s.handshake(conn); err != nil {
		s.t.Logf("mock socks handshake: %v", err)
		return
	}
	if err := s.udpAssociate(conn); err != nil {
		s.t.Logf("mock socks associate: %v", err)
	}
	_, _ = io.Copy(io.Discard, conn)
}

func (s *Server) handshake(conn net.Conn) error {
	method := make([]byte, 3)
	if _, err := io.ReadFull(conn, method); err != nil {
		return err
	}
	if method[0] != socksVersion || method[1] != 0x01 || method[2] != socksAuthUserPass {
		return fmt.Errorf("unsupported auth method: %v", method)
	}
	if _, err := conn.Write([]byte{socksVersion, socksAuthUserPass}); err != nil {
		return err
	}
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return err
	}
	ulen := int(hdr[1])
	userPass := make([]byte, ulen+1)
	if _, err := io.ReadFull(conn, userPass); err != nil {
		return err
	}
	user := string(userPass[:ulen])
	plen := int(userPass[ulen])
	passBuf := make([]byte, plen)
	if _, err := io.ReadFull(conn, passBuf); err != nil {
		return err
	}
	pass := string(passBuf)
	if user != s.user || pass != s.pass {
		_, _ = conn.Write([]byte{0x01, 0x01})
		return fmt.Errorf("auth failed")
	}
	_, err := conn.Write([]byte{0x01, 0x00})
	return err
}

func (s *Server) udpAssociate(conn net.Conn) error {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return err
	}
	if hdr[1] != socksCmdUDPAssoc {
		return fmt.Errorf("unexpected cmd %d", hdr[1])
	}
	atypRest := make([]byte, 6)
	if _, err := io.ReadFull(conn, atypRest); err != nil {
		return err
	}
	port := s.udpConn.LocalAddr().(*net.UDPAddr).Port
	resp := []byte{socksVersion, 0x00, 0x00, socksAtypIPv4, 127, 0, 0, 1, byte(port >> 8), byte(port)}
	_, err := conn.Write(resp)
	return err
}

func (s *Server) udpReadLoop() {
	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := s.udpConn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if !s.replyEnabled.Load() {
			continue
		}
		if n < 10 {
			continue
		}
		reply := append([]byte(nil), buf[:n]...)
		copy(reply[4:8], reply[4:8])
		_, _ = s.udpConn.WriteToUDP(reply, clientAddr)
	}
}

// WaitDialCount blocks until dial count reaches want or timeout.
func (s *Server) WaitDialCount(want int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s.DialCount() >= want {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return s.DialCount() >= want
}

// EncodeSocksUDPRequest builds a SOCKS UDP frame (tests).
func EncodeSocksUDPRequest(dstIP net.IP, dstPort uint16, payload []byte) []byte {
	ip4 := dstIP.To4()
	buf := make([]byte, 10+len(payload))
	buf[3] = socksAtypIPv4
	copy(buf[4:8], ip4)
	binary.BigEndian.PutUint16(buf[8:10], dstPort)
	copy(buf[10:], payload)
	return buf
}
