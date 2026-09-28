package udprelay

import (
	"bytes"
	"net"
	"testing"
)

func TestEncodeDecodeSocksUDP(t *testing.T) {
	dst := net.ParseIP("149.154.167.51").To4()
	payload := []byte("telegram-udp-payload")
	frame, err := encodeSocksUDPRequest(dst, 3478, payload)
	if err != nil {
		t.Fatal(err)
	}
	remoteIP, remotePort, gotPayload, err := decodeSocksUDPReply(frame)
	if err != nil {
		t.Fatal(err)
	}
	if !remoteIP.Equal(dst) {
		t.Fatalf("remote ip: got %v want %v", remoteIP, dst)
	}
	if remotePort != 3478 {
		t.Fatalf("remote port: got %d want 3478", remotePort)
	}
	if !bytes.Equal(gotPayload, payload) {
		t.Fatalf("payload mismatch")
	}
}

func TestParseIPv4UDP(t *testing.T) {
	frame := BuildTestIPv4UDP(
		net.ParseIP("10.8.0.7").To4(),
		net.ParseIP("8.8.8.8").To4(),
		12345, 53,
		[]byte("dns-query"),
	)
	info, err := ParseIPv4UDP(frame)
	if err != nil {
		t.Fatal(err)
	}
	if info.ClientPort != 12345 || info.DstPort != 53 {
		t.Fatalf("ports: %+v", info)
	}
	if !bytes.Equal(info.Payload, []byte("dns-query")) {
		t.Fatalf("payload: %q", info.Payload)
	}
}

func TestSocksAuthPayloadWithSlash(t *testing.T) {
	user := "vpn-user"
	pass := "rtS1wruVGvD3qG8Uo6JopQ/vOVjUr9pS"
	auth := make([]byte, 0, 3+len(user)+len(pass))
	auth = append(auth, 0x01, byte(len(user)))
	auth = append(auth, user...)
	auth = append(auth, byte(len(pass)))
	auth = append(auth, pass...)
	if auth[1] != byte(len(user)) {
		t.Fatalf("user len byte wrong")
	}
	plenIdx := 2 + len(user)
	if auth[plenIdx] != byte(len(pass)) {
		t.Fatalf("pass len byte wrong: got %d want %d", auth[plenIdx], len(pass))
	}
	if string(auth[plenIdx+1:]) != pass {
		t.Fatalf("password not preserved")
	}
}
