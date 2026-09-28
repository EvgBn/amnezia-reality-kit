package udprelay_test

import (
	"net"
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestReconnectClosesAllSessions(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env := newTestEnv(t, srv)

	dstB := net.ParseIP("8.8.8.8").To4()
	for _, dst := range []net.IP{telegram, dstB, net.ParseIP("1.1.1.1").To4()} {
		frame := udprelay.BuildTestIPv4UDP(clientA, dst, 52013, 53, []byte("q"))
		if err := env.relay.HandlePacket(frame); err != nil {
			t.Fatal(err)
		}
	}
	if got := env.relay.SessionCount(); got != 3 {
		t.Fatalf("sessions before reconnect: %d", got)
	}

	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })
	if got := env.relay.SessionCount(); got != 0 {
		t.Fatalf("sessions after reconnect: %d want 0", got)
	}
}

func TestHandlePacketNotBlockedDuringSlowDial(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	srv.SetDialDelay(2 * time.Second)
	env := newTestEnv(t, srv)

	srv.CloseTCP()
	time.Sleep(100 * time.Millisecond)

	start := time.Now()
	env.sendVoice(t, 1)
	elapsed := time.Since(start)
	if elapsed > 500*time.Millisecond {
		t.Fatalf("handle packet blocked too long: %s", elapsed)
	}
}

func TestHandlePacketUsesNewSocketAfterReconnect(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env := newTestEnv(t, srv)

	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })

	port2 := env.relay.AssociatePort()
	if port2 == 0 {
		t.Fatal("associate port zero after reconnect")
	}
	env.sendVoice(t, 1)
}
