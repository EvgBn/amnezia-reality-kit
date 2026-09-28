package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"sync/atomic"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
	"golang.org/x/sys/unix"
)

type injector struct {
	fd   int
	ipID atomic.Uint32
}

func newInjector(iface string) (*injector, error) {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_RAW, unix.IPPROTO_RAW)
	if err != nil {
		return nil, fmt.Errorf("raw socket: %w", err)
	}
	if err := unix.SetsockoptString(fd, unix.SOL_SOCKET, unix.SO_BINDTODEVICE, iface); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("bind to device %s: %w", iface, err)
	}
	if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_HDRINCL, 1); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("ip hdrincl: %w", err)
	}
	return &injector{fd: fd}, nil
}

func (i *injector) close() error {
	if i.fd >= 0 {
		return unix.Close(i.fd)
	}
	return nil
}

func (i *injector) sendReply(srcIP, dstIP net.IP, srcPort, dstPort uint16, payload []byte) error {
	src4 := srcIP.To4()
	dst4 := dstIP.To4()
	if src4 == nil || dst4 == nil {
		return fmt.Errorf("only IPv4 injection supported")
	}

	udpLen := udprelay.UDPHeaderLen + len(payload)
	totalLen := udprelay.IPv4HeaderMinLen + udpLen
	packet := make([]byte, totalLen)

	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:4], uint16(totalLen))
	binary.BigEndian.PutUint16(packet[4:6], uint16(i.ipID.Add(1)))
	packet[8] = 64
	packet[9] = 17
	copy(packet[12:16], src4)
	copy(packet[16:20], dst4)

	udpOffset := udprelay.IPv4HeaderMinLen
	binary.BigEndian.PutUint16(packet[udpOffset:udpOffset+2], srcPort)
	binary.BigEndian.PutUint16(packet[udpOffset+2:udpOffset+4], dstPort)
	binary.BigEndian.PutUint16(packet[udpOffset+4:udpOffset+6], uint16(udpLen))
	copy(packet[udpOffset+8:], payload)

	binary.BigEndian.PutUint16(packet[10:12], udprelay.IPChecksum(packet[:udprelay.IPv4HeaderMinLen]))
	binary.BigEndian.PutUint16(packet[udpOffset+6:udpOffset+8], udprelay.UDPChecksum(src4, dst4, packet[udpOffset:udpOffset+udpLen]))

	addr := &unix.SockaddrInet4{Port: int(dstPort)}
	copy(addr.Addr[:], dst4)
	return unix.Sendto(i.fd, packet, 0, addr)
}
