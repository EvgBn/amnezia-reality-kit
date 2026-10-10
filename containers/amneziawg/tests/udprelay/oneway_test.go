package udprelay_test

import (
	"net"
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
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

func TestOneWayHealthyAssociateEvictsSessionOnly(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env, inj := newRecordingTestEnv(t, srv)

	genBefore := env.relay.Generation()
	dialsBefore := srv.DialCount()

	// Session B: replies on — associate gets injectOK > 0.
	env.sendVoice(t, 5)
	waitForInject(t, inj, 1, 2*time.Second)

	dstA := net.ParseIP("8.8.8.8").To4()
	frameA := udprelay.BuildTestIPv4UDP(clientA, dstA, 52013, 53, []byte("a"))
	srv.SetReplyEnabled(false)
	sendOneWayThresholdOnSession(t, env, frameA)

	if got := srv.DialCount(); got != dialsBefore {
		t.Fatalf("dial count: %d want %d (no associate reconnect)", got, dialsBefore)
	}
	if got := env.relay.Generation(); got != genBefore {
		t.Fatalf("generation: %d want %d", got, genBefore)
	}
	if got := env.relay.SessionCount(); got != 1 {
		t.Fatalf("session count: %d want 1 (only B remains)", got)
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
