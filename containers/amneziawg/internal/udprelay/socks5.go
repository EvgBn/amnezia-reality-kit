package udprelay

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"time"
)

const (
	socksVersion      = 0x05
	socksAuthUserPass = 0x02
	socksCmdUDPAssoc  = 0x03
	socksAtypIPv4     = 0x01
	socksAtypDomain   = 0x03
	socksAtypIPv6     = 0x04
)

type socks5Client struct {
	serverAddr string
	username   string
	password   string
	bindAddr   string
	tcpConn    net.Conn
	relayConn  *net.UDPConn
	relayAddr  *net.UDPAddr
	sendHook   func(dstIP net.IP, dstPort uint16, payload []byte) error
	stats      *associateStats
}

// DialSocks5 establishes a SOCKS5 UDP associate.
func DialSocks5(serverAddr, username, password, bindAddr string) (*socks5Client, error) {
	tcpConn, err := net.DialTimeout("tcp", serverAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("socks tcp dial: %w", err)
	}
	c := &socks5Client{
		serverAddr: serverAddr,
		username:   username,
		password:   password,
		bindAddr:   bindAddr,
		tcpConn:    tcpConn,
	}
	if err := c.handshake(); err != nil {
		tcpConn.Close()
		return nil, err
	}
	if err := c.udpAssociate(); err != nil {
		tcpConn.Close()
		return nil, err
	}
	return c, nil
}

func (c *socks5Client) handshake() error {
	if _, err := c.tcpConn.Write([]byte{socksVersion, 0x01, socksAuthUserPass}); err != nil {
		return fmt.Errorf("socks method write: %w", err)
	}
	resp := make([]byte, 2)
	if _, err := io.ReadFull(c.tcpConn, resp); err != nil {
		return fmt.Errorf("socks method read: %w", err)
	}
	if resp[0] != socksVersion || resp[1] != socksAuthUserPass {
		return fmt.Errorf("socks method rejected: %v", resp)
	}

	user := []byte(c.username)
	pass := []byte(c.password)
	auth := make([]byte, 0, 3+len(user)+len(pass))
	auth = append(auth, 0x01, byte(len(user)))
	auth = append(auth, user...)
	auth = append(auth, byte(len(pass)))
	auth = append(auth, pass...)
	if _, err := c.tcpConn.Write(auth); err != nil {
		return fmt.Errorf("socks auth write: %w", err)
	}
	authResp := make([]byte, 2)
	if _, err := io.ReadFull(c.tcpConn, authResp); err != nil {
		return fmt.Errorf("socks auth read: %w", err)
	}
	if authResp[1] != 0x00 {
		return fmt.Errorf("socks auth failed status=%d", authResp[1])
	}
	return nil
}

func (c *socks5Client) udpAssociate() error {
	req := []byte{socksVersion, socksCmdUDPAssoc, 0x00, socksAtypIPv4, 0, 0, 0, 0, 0, 0}
	if _, err := c.tcpConn.Write(req); err != nil {
		return fmt.Errorf("socks udp associate write: %w", err)
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(c.tcpConn, header); err != nil {
		return fmt.Errorf("socks udp associate read header: %w", err)
	}
	if header[0] != socksVersion || header[1] != 0x00 {
		return fmt.Errorf("socks udp associate rejected: %v", header[:2])
	}
	addr, port, err := readSocksAddr(c.tcpConn, header[3])
	if err != nil {
		return err
	}
	relayHost := addr
	if ip := net.ParseIP(addr); ip != nil && ip.IsUnspecified() {
		host, _, splitErr := net.SplitHostPort(c.serverAddr)
		if splitErr != nil {
			return fmt.Errorf("parse socks server host: %w", splitErr)
		}
		relayHost = host
	}
	relayAddr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(relayHost, port))
	if err != nil {
		return fmt.Errorf("resolve relay udp addr: %w", err)
	}
	localAddr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(c.bindAddr, "0"))
	if err != nil {
		return fmt.Errorf("resolve local udp bind: %w", err)
	}
	relayConn, err := net.ListenUDP("udp", localAddr)
	if err != nil {
		return fmt.Errorf("listen local udp for relay: %w", err)
	}
	c.relayConn = relayConn
	c.relayAddr = relayAddr
	return nil
}

func readSocksAddr(r io.Reader, atyp byte) (host string, port string, err error) {
	switch atyp {
	case socksAtypIPv4:
		buf := make([]byte, 4+2)
		if _, err = io.ReadFull(r, buf); err != nil {
			return "", "", err
		}
		host = net.IP(buf[:4]).String()
		port = fmt.Sprintf("%d", binary.BigEndian.Uint16(buf[4:6]))
	case socksAtypIPv6:
		buf := make([]byte, 16+2)
		if _, err = io.ReadFull(r, buf); err != nil {
			return "", "", err
		}
		host = net.IP(buf[:16]).String()
		port = fmt.Sprintf("%d", binary.BigEndian.Uint16(buf[16:18]))
	case socksAtypDomain:
		lenBuf := make([]byte, 1)
		if _, err = io.ReadFull(r, lenBuf); err != nil {
			return "", "", err
		}
		buf := make([]byte, int(lenBuf[0])+2)
		if _, err = io.ReadFull(r, buf); err != nil {
			return "", "", err
		}
		host = string(buf[:len(buf)-2])
		port = fmt.Sprintf("%d", binary.BigEndian.Uint16(buf[len(buf)-2:]))
	default:
		err = fmt.Errorf("unsupported socks atyp %d", atyp)
	}
	return host, port, err
}

func encodeSocksUDPRequest(dstIP net.IP, dstPort uint16, payload []byte) ([]byte, error) {
	ip4 := dstIP.To4()
	if ip4 == nil {
		return nil, fmt.Errorf("only IPv4 destinations supported")
	}
	buf := make([]byte, 3+1+4+2+len(payload))
	buf[0], buf[1], buf[2] = 0x00, 0x00, 0x00
	buf[3] = socksAtypIPv4
	copy(buf[4:8], ip4)
	binary.BigEndian.PutUint16(buf[8:10], dstPort)
	copy(buf[10:], payload)
	return buf, nil
}

func decodeSocksUDPReply(data []byte) (remoteIP net.IP, remotePort uint16, payload []byte, err error) {
	if len(data) < 10 {
		return nil, 0, nil, fmt.Errorf("socks udp reply too short")
	}
	if data[2] != 0x00 {
		return nil, 0, nil, fmt.Errorf("unsupported socks udp fragment")
	}
	atyp := data[3]
	offset := 4
	switch atyp {
	case socksAtypIPv4:
		if len(data) < offset+4+2 {
			return nil, 0, nil, fmt.Errorf("truncated socks ipv4 header")
		}
		remoteIP = net.IP(append([]byte(nil), data[offset:offset+4]...))
		offset += 4
	case socksAtypIPv6:
		if len(data) < offset+16+2 {
			return nil, 0, nil, fmt.Errorf("truncated socks ipv6 header")
		}
		remoteIP = net.IP(append([]byte(nil), data[offset:offset+16]...))
		offset += 16
	case socksAtypDomain:
		if len(data) < offset+1 {
			return nil, 0, nil, fmt.Errorf("truncated socks domain length")
		}
		dlen := int(data[offset])
		offset++
		if len(data) < offset+dlen+2 {
			return nil, 0, nil, fmt.Errorf("truncated socks domain header")
		}
		remoteIP = net.ParseIP(string(data[offset : offset+dlen]))
		offset += dlen
	default:
		return nil, 0, nil, fmt.Errorf("unsupported reply atyp %d", atyp)
	}
	remotePort = binary.BigEndian.Uint16(data[offset : offset+2])
	offset += 2
	payload = append([]byte(nil), data[offset:]...)
	return remoteIP, remotePort, payload, nil
}

func (c *socks5Client) localPort() uint16 {
	if c.relayConn == nil {
		return 0
	}
	addr, ok := c.relayConn.LocalAddr().(*net.UDPAddr)
	if !ok || addr == nil {
		return 0
	}
	return uint16(addr.Port)
}

func (c *socks5Client) send(dstIP net.IP, dstPort uint16, payload []byte) error {
	if c.sendHook != nil {
		return c.sendHook(dstIP, dstPort, payload)
	}
	frame, err := encodeSocksUDPRequest(dstIP, dstPort, payload)
	if err != nil {
		return err
	}
	_, err = c.relayConn.WriteToUDP(frame, c.relayAddr)
	return err
}

func (c *socks5Client) readLoop(
	handler func(remoteIP net.IP, remotePort uint16, payload []byte),
	onDecodeError func(rawLen int, err error),
) error {
	buf := make([]byte, 65535)
	for {
		n, _, err := c.relayConn.ReadFromUDP(buf)
		if err != nil {
			return err
		}
		remoteIP, remotePort, payload, err := decodeSocksUDPReply(buf[:n])
		if err != nil {
			if onDecodeError != nil {
				onDecodeError(n, err)
			}
			continue
		}
		handler(remoteIP, remotePort, payload)
	}
}

// runTCPDrain blocks reading the SOCKS control TCP until EOF/error.
// SOCKS5 UDP ASSOCIATE requires this leg; xray closes it on connIdle. Without a reader
// udp-relay never learns the associate died and keeps sending into a zombie UDP socket.
func (c *socks5Client) runTCPDrain(gen uint64, currentGen func() uint64, onEOF func()) {
	go func() {
		buf := make([]byte, 256)
		for {
			_, err := c.tcpConn.Read(buf)
			if err != nil {
				if c.stats != nil {
					c.stats.tcpDrainExited.Store(true)
				}
				if currentGen() == gen {
					onEOF()
				}
				return
			}
		}
	}()
}

func (c *socks5Client) close() {
	if c.relayConn != nil {
		c.relayConn.Close()
	}
	if c.tcpConn != nil {
		c.tcpConn.Close()
	}
}
