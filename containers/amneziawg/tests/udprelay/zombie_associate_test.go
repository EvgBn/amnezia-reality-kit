// Package udprelay_test contains integration tests for the shared SOCKS UDP associate.
//
// See zombie_associate_test.go for the production incident, PR1 fix, and regression
// tests that guard reconnect behavior after xray connIdle TCP closure.
package udprelay_test

// Zombie SOCKS UDP associate — regression tests for PR1 reconnect.
//
// # Production problem (voice-gate FAIL after idle)
//
// Telegram group voice hung on "Connecting…" while TCP chat still worked.
// Symptom: outbound UDP captured (NFQUEUE +), but relay first inject=0 and
// one-way warns=1 — server replies never reached the phone.
//
// Root cause: shared SOCKS5 UDP associate between udp-relay and xray has two legs:
//   - TCP control connection (handshake + UDP ASSOCIATE lifetime)
//   - local UDP relay socket (actual VoIP frames)
//
// xray closes the control TCP after connIdle (~5 minutes without traffic on that
// associate). Before PR1, udp-relay never read the control TCP after handshake,
// so it did not observe FIN/EOF. The local UDP socket stayed open (zombie):
// outbound writes appeared to succeed, but xray no longer accepted or returned
// traffic on that associate port. inject stayed 0 until refresh-full / pkill.
//
// Evidence from production: ss showed no TCP from udp-relay to :1080 while the
// associate UDP port was still open; same socks_local_port for hours; manual
// udp-relay restart immediately restored inject.
//
// # Fix (PR1 — internal/udprelay)
//
//  1. TCP drain goroutine: blocking Read on control TCP → EOF → reconnect.
//  2. reconnectAssociate: dial new SOCKS associate, atomic swap, bump generation.
//  3. closeAll(): drop stale per-flow sessions so the phone opens fresh mappings.
//  4. Generation gate: old read loops ignore replies after swap (no double inject).
//  5. Additional triggers: send-error, read-loop-exit, one-way (session age ≥ 5s).
//
// Detection is event-driven (Read returns on FIN), not polled on a timer.
// Reconnect itself takes milliseconds; user-visible gap during active voice is
// roughly one VoIP packet RTT, not hours.
//
// # What these tests lock in
//
// If tcp drain, reconnectAssociate, generation gating, or session closeAll() are
// removed or weakened, tests in this file MUST fail. They do not replace live
// voice-gate soak tests; they document and guard the Go-level contract.

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

const (
	// xray SOCKS connIdle default observed in production (~5 min between tcp-eof logs).
	simulatedConnIdle = 5 * time.Minute
	// Compressed 3-hour soak: 36 × 5 min idle cycles without container restart.
	simulatedSoakCycles = 36
)

// TestVoicePathSurvivesRepeatedConnIdle simulates xray closing the SOCKS control TCP
// every connIdle period for a multi-hour idle window, then verifies return path
// (inject) still works after each death — the core regression for zombie associate.
func TestVoicePathSurvivesRepeatedConnIdle(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env, inj := newRecordingTestEnv(t, srv)

	// Baseline: return path works on gen=1.
	env.sendVoice(t, 1)
	waitForInject(t, inj, 1, 2*time.Second)

	for cycle := 1; cycle <= simulatedSoakCycles; cycle++ {
		t.Logf("soak cycle %d/%d: advance %s idle (simulated connIdle)", cycle, simulatedSoakCycles, simulatedConnIdle)
		genBefore := env.relay.Generation()
		portBefore := env.relay.AssociatePort()
		dialsBefore := srv.DialCount()

		env.advance(simulatedConnIdle)
		srv.CloseTCP() // mock xray FIN on control TCP — must trigger drain → reconnect

		waitFor(t, 5*time.Second, func() bool {
			return srv.DialCount() >= dialsBefore+1 &&
				env.relay.Generation() > genBefore &&
				env.relay.AssociatePort() != portBefore
		})

		inj.calls = 0
		env.sendVoice(t, 1)
		waitForInject(t, inj, 1, 2*time.Second)
	}
}

// TestTCPDrainDetectsClosureImmediately verifies reconnect is driven by control-TCP
// EOF (event), not a periodic health poll. xray FIN must be observed within hundreds
// of milliseconds, not on a multi-minute timer.
func TestTCPDrainDetectsClosureImmediately(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env, inj := newRecordingTestEnv(t, srv)

	env.sendVoice(t, 1)
	waitForInject(t, inj, 1, 2*time.Second)

	dialsBefore := srv.DialCount()
	start := time.Now()
	srv.CloseTCP()

	waitFor(t, 2*time.Second, func() bool { return srv.DialCount() >= dialsBefore+1 })
	elapsed := time.Since(start)
	if elapsed > 750*time.Millisecond {
		t.Fatalf("reconnect after tcp eof took %s; want event-driven detection << connIdle poll", elapsed)
	}

	inj.calls = 0
	env.sendVoice(t, 1)
	waitForInject(t, inj, 1, 2*time.Second)
}

// TestZombieAssociateSessionsResetOnReconnect documents that stale session mappings
// must not survive associate death — closeAll() forces fresh flows on the new gen.
func TestZombieAssociateSessionsResetOnReconnect(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env := newTestEnv(t, srv)

	env.sendVoice(t, 3)
	if got := env.relay.SessionCount(); got != 1 {
		t.Fatalf("sessions before reconnect: %d want 1", got)
	}

	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })
	if got := env.relay.SessionCount(); got != 0 {
		t.Fatalf("sessions after reconnect: %d want 0 (closeAll on associate swap)", got)
	}

	env.sendVoice(t, 1)
	if got := env.relay.SessionCount(); got != 1 {
		t.Fatalf("sessions after voice on new associate: %d want 1", got)
	}
}

// TestZombieAssociateGenerationMonotonic ensures each tcp-eof produces a new
// associate generation so stale read loops cannot deliver to reset sessions.
func TestZombieAssociateGenerationMonotonic(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env, inj := newRecordingTestEnv(t, srv)

	const cycles = 5
	gen := env.relay.Generation()
	for i := 0; i < cycles; i++ {
		env.advance(simulatedConnIdle)
		srv.CloseTCP()
		waitFor(t, 5*time.Second, func() bool {
			return env.relay.Generation() > gen && srv.DialCount() >= i+2
		})
		gen = env.relay.Generation()

		inj.calls = 0
		env.sendVoice(t, 1)
		waitForInject(t, inj, 1, 2*time.Second)
	}
	if gen != uint64(cycles+1) {
		t.Fatalf("generation after %d reconnects: %d want %d", cycles, gen, cycles+1)
	}
}

// TestZombieAssociateWithoutReconnectWouldBreakReturnPath is a living spec: mock
// CloseTCP simulates xray connIdle; if production regresses to pre-PR1 behavior
// (no tcp drain / no reconnect), inject after CloseTCP stays 0 and this test fails.
func TestZombieAssociateWithoutReconnectWouldBreakReturnPath(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env, inj := newRecordingTestEnv(t, srv)

	env.sendVoice(t, 1)
	waitForInject(t, inj, 1, 2*time.Second)

	srv.CloseTCP()
	waitFor(t, 5*time.Second, func() bool { return srv.DialCount() >= 2 })

	inj.calls = 0
	env.sendVoice(t, 1)
	waitForInject(t, inj, 1, 2*time.Second)
	if inj.calls != 1 {
		t.Fatalf("inject after associate death+reconnect: %d want 1 — pre-PR1 zombie left inject=0", inj.calls)
	}
}

func waitForInject(t *testing.T, inj *recordingInjector, want int, timeout time.Duration) {
	t.Helper()
	waitFor(t, timeout, func() bool { return inj.calls >= want })
	if inj.calls < want {
		t.Fatalf("inject calls: %d want >= %d (return path dead — zombie associate regression?)", inj.calls, want)
	}
}
