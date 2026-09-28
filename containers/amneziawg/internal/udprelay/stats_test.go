package udprelay

import (
	"log/slog"
	"testing"
	"time"
)

func TestAssociateStatsClassifyXrayNoReturn(t *testing.T) {
	now := time.Unix(1000, 0)
	s := newAssociateStats(1, 12345, now)
	s.outboundSent.Store(50)
	if got := s.classify(now); got != ScenarioXrayNoReturn {
		t.Fatalf("classify = %q want %q", got, ScenarioXrayNoReturn)
	}
}

func TestAssociateStatsClassifySessionMismatch(t *testing.T) {
	now := time.Unix(1000, 0)
	s := newAssociateStats(1, 12345, now)
	s.outboundSent.Store(50)
	s.socksUdpRx.Store(10)
	s.unmatchedReply.Store(3)
	if got := s.classify(now); got != ScenarioSessionMismatch {
		t.Fatalf("classify = %q want %q", got, ScenarioSessionMismatch)
	}
}

func TestAssociateStatsClassifyOKWithInject(t *testing.T) {
	now := time.Unix(1000, 0)
	s := newAssociateStats(1, 12345, now)
	s.outboundSent.Store(50)
	s.injectOK.Store(1)
	if got := s.classify(now); got != ScenarioOK {
		t.Fatalf("classify = %q want %q", got, ScenarioOK)
	}
}

func TestAssociateStatsRecordSocksRxLogsFirstOnce(t *testing.T) {
	now := time.Unix(1000, 0)
	s := newAssociateStats(2, 54321, now)
	logger := slog.New(slog.NewTextHandler(testLogWriter{t}, &slog.HandlerOptions{Level: slog.LevelInfo}))

	s.recordSocksRx(logger, now)
	s.recordSocksRx(logger, now)

	if s.socksUdpRx.Load() != 2 {
		t.Fatalf("rx count = %d want 2", s.socksUdpRx.Load())
	}
	if !s.socksFirstRxLogged.Load() {
		t.Fatal("first rx should be logged")
	}
}

type testLogWriter struct{ t testing.TB }

func (w testLogWriter) Write(p []byte) (int, error) {
	w.t.Log(string(p))
	return len(p), nil
}
