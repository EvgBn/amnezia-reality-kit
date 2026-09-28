package udprelay

import (
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"
)

// Path scenario codes — used in logs for automated triage (voice-path-probe / fail-snapshot).
const (
	ScenarioOK              = "SCEN-OK"
	ScenarioXrayNoReturn    = "SCEN-B-XRAY-NO-RETURN"    // outbound>0, socks_udp_rx=0
	ScenarioSessionMismatch = "SCEN-C-SESSION-MISMATCH"  // socks_udp_rx>0, unmatched>0, inject=0
	ScenarioSocksDecode     = "SCEN-D-SOCKS-DECODE"      // decode_err>0
	ScenarioInjectFailed    = "SCEN-E-INJECT-FAILED"     // inject_failed>0
	ScenarioReconnectSkip   = "SCEN-F-RECONNECT-SKIPPED" // one-way but reconnect blocked
	ScenarioStaleReply      = "SCEN-G-STALE-REPLY"       // stale_reply_ignored>0, inject=0
	ScenarioReadLoopExit    = "SCEN-H-READ-LOOP-EXIT"    // read loop died on live gen
	ScenarioSendError       = "SCEN-I-SEND-ERROR"        // socks send failed
	ScenarioUnknown         = "SCEN-Z-UNKNOWN"
)

type associateStats struct {
	gen     uint64
	port    uint16
	readyAt time.Time

	socksUdpRx         atomic.Uint64
	socksFirstRxLogged atomic.Bool
	socksDecodeErr     atomic.Uint64
	staleReplyIgnored  atomic.Uint64
	unmatchedReply     atomic.Uint64
	outboundSent       atomic.Uint64
	injectOK           atomic.Uint64
	injectFailed       atomic.Uint64
	readLoopStarted    atomic.Bool
	readLoopExited     atomic.Bool
	tcpDrainExited     atomic.Bool
}

func newAssociateStats(gen uint64, port uint16, readyAt time.Time) *associateStats {
	return &associateStats{gen: gen, port: port, readyAt: readyAt}
}

func (s *associateStats) age(now time.Time) time.Duration {
	if s.readyAt.IsZero() {
		return 0
	}
	return now.Sub(s.readyAt)
}

func (s *associateStats) logFields(now time.Time) []any {
	return []any{
		"gen", s.gen,
		"port", s.port,
		"age", s.age(now).Round(time.Second),
		"outbound", s.outboundSent.Load(),
		"socks_udp_rx", s.socksUdpRx.Load(),
		"inject", s.injectOK.Load(),
		"inject_failed", s.injectFailed.Load(),
		"decode_err", s.socksDecodeErr.Load(),
		"unmatched", s.unmatchedReply.Load(),
		"stale_ignored", s.staleReplyIgnored.Load(),
		"read_loop_exited", s.readLoopExited.Load(),
		"tcp_drain_exited", s.tcpDrainExited.Load(),
	}
}

func (s *associateStats) classify(now time.Time) string {
	inject := s.injectOK.Load()
	if inject > 0 {
		return ScenarioOK
	}
	if s.outboundSent.Load() == 0 {
		return ScenarioOK
	}
	if s.socksUdpRx.Load() == 0 {
		return ScenarioXrayNoReturn
	}
	if s.unmatchedReply.Load() > 0 {
		return ScenarioSessionMismatch
	}
	if s.socksDecodeErr.Load() > 0 {
		return ScenarioSocksDecode
	}
	if s.injectFailed.Load() > 0 {
		return ScenarioInjectFailed
	}
	if s.staleReplyIgnored.Load() > 0 {
		return ScenarioStaleReply
	}
	if s.readLoopExited.Load() {
		return ScenarioReadLoopExit
	}
	_ = now
	return ScenarioUnknown
}

func (s *associateStats) recordSocksRx(logger *slog.Logger, now time.Time) {
	n := s.socksUdpRx.Add(1)
	if s.socksFirstRxLogged.CompareAndSwap(false, true) {
		fields := append([]any{"path_scenario", ScenarioOK}, s.logFields(now)...)
		logger.Info("socks first udp rx", fields...)
	}
	if n == 100 || n == 1000 {
		fields := append([]any{"path_scenario", s.classify(now)}, s.logFields(now)...)
		logger.Info("socks udp rx milestone", fields...)
	}
}

func (s *associateStats) recordDecodeErr() {
	s.socksDecodeErr.Add(1)
}

func (s *associateStats) recordStaleReply() {
	s.staleReplyIgnored.Add(1)
}

func (s *associateStats) recordUnmatched() {
	s.unmatchedReply.Add(1)
}

func (s *associateStats) recordOutbound() {
	s.outboundSent.Add(1)
}

func (s *associateStats) recordInjectOK() {
	s.injectOK.Add(1)
}

func (s *associateStats) recordInjectFailed() {
	s.injectFailed.Add(1)
}

func (s *associateStats) logClosed(logger *slog.Logger, reason string, now time.Time) {
	scenario := s.classify(now)
	fields := append([]any{
		"reason", reason,
		"path_scenario", scenario,
	}, s.logFields(now)...)
	logger.Info("associate closed", fields...)
}

func (s *associateStats) logHealth(logger *slog.Logger, now time.Time) {
	scenario := s.classify(now)
	fields := append([]any{
		"path_scenario", scenario,
	}, s.logFields(now)...)
	logger.Info("associate health", fields...)
}

func (s *associateStats) logOneWay(logger *slog.Logger, session string, outbound, inject uint64, now time.Time) {
	scenario := s.classify(now)
	fields := append([]any{
		"session", session,
		"outbound", outbound,
		"inject", inject,
		"path_scenario", scenario,
	}, s.logFields(now)...)
	logger.Warn("session one-way: high outbound, zero inject", fields...)
}

func formatSkipDetail(cooldownRem, backoffRem, sessionAge, sessionNeed time.Duration) string {
	return fmt.Sprintf("cooldown_rem=%s backoff_rem=%s session_age=%s session_need=%s",
		cooldownRem.Round(time.Millisecond),
		backoffRem.Round(time.Millisecond),
		sessionAge.Round(time.Millisecond),
		sessionNeed.Round(time.Millisecond),
	)
}
