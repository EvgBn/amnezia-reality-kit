package udprelay_test

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestStaleDrainIgnoredAfterReconnect(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	_ = newTestEnv(t, srv)

	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })

	srv.CloseTCP()
	time.Sleep(300 * time.Millisecond)
	if got := srv.DialCount(); got != 2 {
		t.Fatalf("dial count after second close: got %d want 2 (cooldown)", got)
	}
}

func TestStaleReadLoopIgnoredAfterReconnect(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env := newTestEnv(t, srv)

	gen1 := env.relay.Generation()
	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return env.relay.Generation() > gen1 })
	if got := srv.DialCount(); got != 2 {
		t.Fatalf("dial count after reconnect: %d want 2", got)
	}
}
