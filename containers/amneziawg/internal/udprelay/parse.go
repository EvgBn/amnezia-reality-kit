package udprelay

import (
	"encoding/binary"
	"fmt"
	"net"
)

const (
	// IPv4HeaderMinLen is the minimum IPv4 header size in bytes.
	IPv4HeaderMinLen = 20
	// UDPHeaderLen is the UDP header size in bytes.
	UDPHeaderLen = 8
)

// PacketInfo is a parsed IPv4/UDP frame from NFQUEUE.
type PacketInfo struct {
	ClientIP   net.IP
	ClientPort uint16
	DstIP      net.IP
	DstPort    uint16
	Payload    []byte
}

// ParseIPv4UDP parses a raw IPv4/UDP frame.
func ParseIPv4UDP(frame []byte) (PacketInfo, error) {
	if len(frame) < IPv4HeaderMinLen {
		return PacketInfo{}, fmt.Errorf("frame too short for IPv4")
	}
	version := frame[0] >> 4
	if version != 4 {
		return PacketInfo{}, fmt.Errorf("not IPv4")
	}
	ihl := int(frame[0]&0x0f) * 4
	if ihl < IPv4HeaderMinLen || len(frame) < ihl {
		return PacketInfo{}, fmt.Errorf("invalid IPv4 header length")
	}
	if frame[9] != 17 {
		return PacketInfo{}, fmt.Errorf("not UDP protocol")
	}
	totalLen := int(binary.BigEndian.Uint16(frame[2:4]))
	if totalLen > len(frame) {
		totalLen = len(frame)
	}
	if totalLen < ihl+UDPHeaderLen {
		return PacketInfo{}, fmt.Errorf("truncated IPv4/UDP packet")
	}

	udpStart := ihl
	udpLen := int(binary.BigEndian.Uint16(frame[udpStart+4 : udpStart+6]))
	if udpLen < UDPHeaderLen {
		return PacketInfo{}, fmt.Errorf("invalid UDP length")
	}
	if udpStart+udpLen > totalLen {
		udpLen = totalLen - udpStart
	}

	clientIP := net.IP(append([]byte(nil), frame[12:16]...))
	dstIP := net.IP(append([]byte(nil), frame[16:20]...))
	clientPort := binary.BigEndian.Uint16(frame[udpStart : udpStart+2])
	dstPort := binary.BigEndian.Uint16(frame[udpStart+2 : udpStart+4])
	payloadStart := udpStart + UDPHeaderLen
	payloadEnd := udpStart + udpLen
	if payloadStart > payloadEnd {
		return PacketInfo{}, fmt.Errorf("invalid UDP payload bounds")
	}
	if payloadEnd > len(frame) {
		payloadEnd = len(frame)
	}

	return PacketInfo{
		ClientIP:   clientIP,
		ClientPort: clientPort,
		DstIP:      dstIP,
		DstPort:    dstPort,
		Payload:    append([]byte(nil), frame[payloadStart:payloadEnd]...),
	}, nil
}

// BuildTestIPv4UDP builds a raw IPv4/UDP frame for tests.
func BuildTestIPv4UDP(src, dst net.IP, srcPort, dstPort uint16, payload []byte) []byte {
	udpLen := UDPHeaderLen + len(payload)
	totalLen := IPv4HeaderMinLen + udpLen
	frame := make([]byte, totalLen)
	frame[0] = 0x45
	binary.BigEndian.PutUint16(frame[2:4], uint16(totalLen))
	frame[9] = 17
	copy(frame[12:16], src.To4())
	copy(frame[16:20], dst.To4())
	binary.BigEndian.PutUint16(frame[IPv4HeaderMinLen:IPv4HeaderMinLen+2], srcPort)
	binary.BigEndian.PutUint16(frame[IPv4HeaderMinLen+2:IPv4HeaderMinLen+4], dstPort)
	binary.BigEndian.PutUint16(frame[IPv4HeaderMinLen+4:IPv4HeaderMinLen+6], uint16(udpLen))
	copy(frame[IPv4HeaderMinLen+8:], payload)
	binary.BigEndian.PutUint16(frame[10:12], IPChecksum(frame[:IPv4HeaderMinLen]))
	binary.BigEndian.PutUint16(frame[IPv4HeaderMinLen+6:IPv4HeaderMinLen+8], UDPChecksum(src.To4(), dst.To4(), frame[IPv4HeaderMinLen:IPv4HeaderMinLen+udpLen]))
	return frame
}

// IPChecksum computes an IPv4 header checksum.
func IPChecksum(header []byte) uint16 {
	return checksum(header)
}

// UDPChecksum computes a UDP checksum over the pseudo-header and UDP segment.
func UDPChecksum(srcIP, dstIP net.IP, udp []byte) uint16 {
	return udpChecksum(srcIP, dstIP, udp)
}

func ipChecksum(header []byte) uint16 {
	return checksum(header)
}

func udpChecksum(srcIP, dstIP net.IP, udp []byte) uint16 {
	pseudo := make([]byte, 12+len(udp))
	copy(pseudo[0:4], srcIP)
	copy(pseudo[4:8], dstIP)
	pseudo[9] = 17
	binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(udp)))
	copy(pseudo[12:], udp)
	sum := checksum(pseudo)
	if sum == 0 {
		return 0xffff
	}
	return sum
}

func checksum(data []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(data); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(data[i : i+2]))
	}
	if len(data)%2 == 1 {
		sum += uint32(data[len(data)-1]) << 8
	}
	for (sum >> 16) > 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}
