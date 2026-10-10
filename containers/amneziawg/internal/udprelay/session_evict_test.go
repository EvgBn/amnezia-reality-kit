package udprelay

import (
	"net"
	"testing"
)

func TestEvictIfSameDoesNotRemoveReplacement(t *testing.T) {
	relay, _ := newTestRelayWithMockSocks(t)

	client := net.ParseIP("10.8.0.9").To4()
	dst := net.ParseIP("8.8.8.8").To4()
	frame := BuildTestIPv4UDP(client, dst, 52013, 10001, []byte("x"))
	info, err := ParseIPv4UDP(frame)
	if err != nil {
		t.Fatal(err)
	}
	s1, err := relay.sessions.getOrCreate(info)
	if err != nil {
		t.Fatal(err)
	}
	if !relay.sessions.evictIfSame(s1.key(), s1) {
		t.Fatal("expected evict of s1")
	}
	if relay.SessionCount() != 0 {
		t.Fatalf("session count after evict s1: %d want 0", relay.SessionCount())
	}

	s2, err := relay.sessions.getOrCreate(info)
	if err != nil {
		t.Fatal(err)
	}
	if s1 == s2 {
		t.Fatal("expected new session after recreate")
	}
	if relay.sessions.evictIfSame(s2.key(), s1) {
		t.Fatal("stale pointer must not evict replacement")
	}
	if relay.SessionCount() != 1 {
		t.Fatalf("session count after stale evict: %d want 1", relay.SessionCount())
	}
}
