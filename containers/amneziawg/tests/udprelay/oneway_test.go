package udprelay_test

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestOneWayTriggersReconnectAfterSessionAge(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	srv.SetReplyEnabled(false)
	env := newTestEnv(t, srv)

	env.sendVoice(t, 1)
	env.advance(6 * time.Second)
	env.sendVoice(t, 24)

	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })
}

func TestOneWayDoesNotTriggerWhenInjectPresent(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env := newTestEnv(t, srv)

	env.advance(6 * time.Second)
	env.sendVoice(t, 5)
	time.Sleep(200 * time.Millisecond)
	if got := srv.DialCount(); got != 1 {
		t.Fatalf("dial count with inject: %d want 1", got)
	}
}

func TestOneWaySkippedWhenSessionTooYoung(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	srv.SetReplyEnabled(false)
	env := newTestEnv(t, srv)

	env.sendVoice(t, 25)
	time.Sleep(500 * time.Millisecond)
	if got := srv.DialCount(); got != 1 {
		t.Fatalf("dial count young session: %d want 1", got)
	}
}
