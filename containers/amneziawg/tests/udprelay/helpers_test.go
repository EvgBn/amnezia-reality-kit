package udprelay_test

import (
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

const (
	testUser = "vpn-user"
	testPass = "test-pass"
)

var (
	clientA  = net.ParseIP("10.8.0.9").To4()
	telegram = net.ParseIP("91.108.9.99").To4()
)

type testEnv struct {
	server *mocksocks.Server
	relay  *udprelay.Relay
	nowMu  sync.Mutex
	now    time.Time
}

func (e *testEnv) clockNow() time.Time {
	e.nowMu.Lock()
	t := e.now
	e.nowMu.Unlock()
	return t
}

func newRecordingTestEnv(t *testing.T, srv *mocksocks.Server) (*testEnv, *recordingInjector) {
	t.Helper()
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
		udprelay.WithClock(env.clockNow),
	)
	if err != nil {
		t.Fatalf("new relay: %v", err)
	}
	t.Cleanup(relay.Close)
	env.relay = relay
	return env, inj
}

func newTestEnv(t *testing.T, srv *mocksocks.Server) *testEnv {
	t.Helper()
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
	}, udprelay.DiscardLogger(), noopInjector{},
		udprelay.WithClock(env.clockNow),
	)
	if err != nil {
		t.Fatalf("new relay: %v", err)
	}
	t.Cleanup(relay.Close)
	env.relay = relay
	return env
}

func (e *testEnv) advance(d time.Duration) {
	e.nowMu.Lock()
	e.now = e.now.Add(d)
	e.nowMu.Unlock()
}

func (e *testEnv) sendVoice(t *testing.T, count int) {
	t.Helper()
	frame := udprelay.BuildTestIPv4UDP(clientA, telegram, 52013, 32003, []byte("voice-pkt"))
	for i := 0; i < count; i++ {
		if err := e.relay.HandlePacket(frame); err != nil {
			t.Fatalf("handle packet %d: %v", i, err)
		}
	}
}

// sendOneWayThresholdOnSession sends enough outbound on frame to trigger session one-way
// (first packet opens the session, then advance session age, then outboundMin-1 more packets).
func sendOneWayThresholdOnSession(t *testing.T, env *testEnv, frame []byte) {
	t.Helper()
	outboundMin, sessionAgeMin := udprelay.OneWayThresholds()
	if err := env.relay.HandlePacket(frame); err != nil {
		t.Fatal(err)
	}
	env.advance(sessionAgeMin)
	for i := 0; i < outboundMin-1; i++ {
		if err := env.relay.HandlePacket(frame); err != nil {
			t.Fatalf("one-way threshold packet %d: %v", i, err)
		}
	}
}

type noopInjector struct{}

func (noopInjector) SendReply(_ net.IP, _ net.IP, _, _ uint16, _ []byte) error {
	return nil
}

type recordingInjector struct {
	calls atomic.Int32
}

func (r *recordingInjector) SendReply(_ net.IP, _ net.IP, _, _ uint16, _ []byte) error {
	r.calls.Add(1)
	return nil
}

func (r *recordingInjector) callCount() int {
	return int(r.calls.Load())
}

func (r *recordingInjector) resetCalls() {
	r.calls.Store(0)
}

func waitForInject(t *testing.T, inj *recordingInjector, want int, timeout time.Duration) {
	t.Helper()
	waitFor(t, timeout, func() bool { return inj.callCount() >= want })
	if inj.callCount() < want {
		t.Fatalf("inject calls: %d want >= %d (return path dead — zombie associate regression?)", inj.callCount(), want)
	}
}

func waitFor(t *testing.T, timeout time.Duration, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("condition not met within %s", timeout)
}
