package udprelay_test

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestInjectAfterTCPReconnect(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	inj := &recordingInjector{}
	env := &testEnv{
		server: srv,
		now:    time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC),
	}
	relay, err := udprelay.New(udprelay.Config{
		SocksAddr:      srv.Addr(),
		SocksUser:      testUser,
		SocksPass:      testPass,
		BindAddr:       "127.0.0.1",
		SessionTimeout: time.Minute,
	}, udprelay.DiscardLogger(), inj,
		udprelay.WithClock(func() time.Time { return env.now }),
	)
	if err != nil {
		t.Fatalf("new relay: %v", err)
	}
	t.Cleanup(relay.Close)
	env.relay = relay

	env.sendVoice(t, 1)
	waitFor(t, 2*time.Second, func() bool { return inj.calls >= 1 })
	if inj.calls != 1 {
		t.Fatalf("inject before reconnect: %d want 1", inj.calls)
	}

	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })

	inj.calls = 0
	env.sendVoice(t, 1)
	waitFor(t, 2*time.Second, func() bool { return inj.calls >= 1 })
	if inj.calls != 1 {
		t.Fatalf("inject after reconnect: %d want 1", inj.calls)
	}
}
