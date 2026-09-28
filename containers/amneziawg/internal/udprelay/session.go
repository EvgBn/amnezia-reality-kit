package udprelay

import (
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type sessionKey struct {
	clientIP   string
	clientPort uint16
	dstIP      string
	dstPort    uint16
}

func makeSessionKey(clientIP net.IP, clientPort uint16, dstIP net.IP, dstPort uint16) sessionKey {
	return sessionKey{
		clientIP:   clientIP.String(),
		clientPort: clientPort,
		dstIP:      dstIP.String(),
		dstPort:    dstPort,
	}
}

type session struct {
	clientIP      net.IP
	clientPort    uint16
	dstIP         net.IP
	dstPort       uint16
	openedAt      time.Time
	lastSeen      time.Time
	relay         *Relay
	outboundCount atomic.Uint64
	injectCount   atomic.Uint64
	oneWayWarned  atomic.Bool
	oneWayRetry   atomic.Bool
}

type sessionTable struct {
	mu      sync.Mutex
	entries map[sessionKey]*session
	timeout time.Duration
	relay   *Relay
}

func newSessionTable(timeout time.Duration, relay *Relay) *sessionTable {
	return &sessionTable{
		entries: make(map[sessionKey]*session),
		timeout: timeout,
		relay:   relay,
	}
}

func (t *sessionTable) getOrCreate(info PacketInfo) (*session, error) {
	key := makeSessionKey(info.ClientIP, info.ClientPort, info.DstIP, info.DstPort)

	t.mu.Lock()
	if s, ok := t.entries[key]; ok {
		s.lastSeen = t.relay.clock.Now()
		t.mu.Unlock()
		return s, nil
	}
	t.mu.Unlock()

	t.mu.Lock()
	defer t.mu.Unlock()
	if s, ok := t.entries[key]; ok {
		s.lastSeen = t.relay.clock.Now()
		return s, nil
	}
	now := t.relay.clock.Now()
	s := &session{
		clientIP:   append(net.IP(nil), info.ClientIP...),
		clientPort: info.ClientPort,
		dstIP:      append(net.IP(nil), info.DstIP...),
		dstPort:    info.DstPort,
		openedAt:   now,
		lastSeen:   now,
		relay:      t.relay,
	}
	t.entries[key] = s
	t.relay.logger.Info("session opened",
		"session", s.key().String(),
		"socks_local_port", t.relay.socksLocalPort(),
		"gen", t.relay.associate.Generation(),
	)
	return s, nil
}

func (t *sessionTable) deliverReply(remoteIP net.IP, remotePort uint16, payload []byte) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, s := range t.entries {
		if remoteIP.Equal(s.dstIP) && remotePort == s.dstPort {
			s.injectReply(remoteIP, remotePort, payload)
			return
		}
	}
	if stats := t.relay.currentStats(); stats != nil {
		stats.recordUnmatched()
	}
	fields := []any{
		"path_scenario", ScenarioSessionMismatch,
		"remote", fmt.Sprintf("%s:%d", remoteIP, remotePort),
		"bytes", len(payload),
		"socks_local_port", t.relay.socksLocalPort(),
		"gen", t.relay.associate.Generation(),
		"sessions", len(t.entries),
	}
	if stats := t.relay.currentStats(); stats != nil {
		fields = append(fields, "unmatched", stats.unmatchedReply.Load())
	}
	t.relay.logger.Warn("socks reply with no matching session", fields...)
}

func (s *session) key() sessionKey {
	return makeSessionKey(s.clientIP, s.clientPort, s.dstIP, s.dstPort)
}

func (s *session) recordOutbound(payloadLen int) {
	out := s.outboundCount.Add(1)
	in := s.injectCount.Load()

	s.relay.logger.Debug("relayed outbound udp",
		"session", s.key().String(),
		"bytes", payloadLen,
		"socks_local_port", s.relay.socksLocalPort(),
		"gen", s.relay.associate.Generation(),
		"outbound_total", out,
		"inject_total", in,
	)

	if out == 1 {
		s.relay.logger.Info("session first outbound",
			"session", s.key().String(),
			"bytes", payloadLen,
			"socks_local_port", s.relay.socksLocalPort(),
			"gen", s.relay.associate.Generation(),
		)
	}

	if out >= oneWayOutboundMin && in == 0 && !s.oneWayWarned.Swap(true) {
		// Outbound without inject: return path likely dead (zombie or half-open associate).
		stats := s.relay.currentStats()
		if stats != nil {
			stats.logOneWay(s.relay.logger, s.key().String(), out, in, s.relay.clock.Now())
		} else {
			s.relay.logger.Warn("session one-way: high outbound, zero inject",
				"session", s.key().String(),
				"outbound", out,
				"inject", in,
				"path_scenario", ScenarioUnknown,
			)
		}
		s.relay.associate.tryOneWayReconnect(s)
	}
}

func (s *session) scheduleOneWayReconnect() {
	if !s.oneWayRetry.CompareAndSwap(false, true) {
		return
	}
	wait := oneWaySessionAgeMin - s.relay.clock.Now().Sub(s.openedAt)
	if wait < 0 {
		wait = 0
	}
	s.relay.logger.Warn("one-way reconnect deferred",
		"path_scenario", ScenarioReconnectSkip,
		"session", s.key().String(),
		"retry_in", wait.Round(time.Millisecond),
		"gen", s.relay.associate.Generation(),
	)
	go func() {
		if wait > 0 {
			time.Sleep(wait)
		}
		if s.injectCount.Load() > 0 {
			s.relay.logger.Info("one-way reconnect cancelled",
				"session", s.key().String(),
				"reason", "inject_received",
			)
			return
		}
		if s.outboundCount.Load() < oneWayOutboundMin {
			return
		}
		s.relay.logger.Info("one-way reconnect retry",
			"session", s.key().String(),
			"outbound", s.outboundCount.Load(),
			"inject", s.injectCount.Load(),
		)
		s.relay.associate.tryOneWayReconnect(s)
	}()
}

func (s *session) injectReply(remoteIP net.IP, remotePort uint16, payload []byte) {
	now := s.relay.clock.Now()
	s.lastSeen = now
	in := s.injectCount.Add(1)

	if in == 1 {
		fields := []any{
			"session", s.key().String(),
			"remote", fmt.Sprintf("%s:%d", remoteIP, remotePort),
			"socks_local_port", s.relay.socksLocalPort(),
			"gen", s.relay.associate.Generation(),
			"bytes", len(payload),
			"path_scenario", ScenarioOK,
		}
		if stats := s.relay.currentStats(); stats != nil {
			fields = append(fields, "socks_udp_rx", stats.socksUdpRx.Load())
		}
		s.relay.logger.Info("session first inject", fields...)
	}

	if stats := s.relay.currentStats(); stats != nil {
		stats.recordInjectOK()
	}

	if err := s.relay.inject.SendReply(remoteIP, s.clientIP, remotePort, s.clientPort, payload); err != nil {
		if stats := s.relay.currentStats(); stats != nil {
			stats.recordInjectFailed()
		}
		s.relay.logger.Warn("inject reply failed",
			"path_scenario", ScenarioInjectFailed,
			"err", err,
			"session", s.key().String(),
			"socks_local_port", s.relay.socksLocalPort(),
			"gen", s.relay.associate.Generation(),
		)
		return
	}
	if !remoteIP.Equal(s.dstIP) || remotePort != s.dstPort {
		s.relay.logger.Debug("injected reply with remapped source",
			"session", s.key().String(),
			"remote", fmt.Sprintf("%s:%d", remoteIP, remotePort),
			"socks_local_port", s.relay.socksLocalPort(),
			"bytes", len(payload),
		)
		return
	}
	s.relay.logger.Debug("injected reply",
		"session", s.key().String(),
		"socks_local_port", s.relay.socksLocalPort(),
		"bytes", len(payload),
		"inject_total", in,
	)
}

func (s *session) close() {
	out := s.outboundCount.Load()
	in := s.injectCount.Load()
	if out > 0 || in > 0 {
		scenario := ScenarioOK
		if out > 0 && in == 0 {
			if stats := s.relay.currentStats(); stats != nil {
				scenario = stats.classify(s.relay.clock.Now())
			} else {
				scenario = ScenarioUnknown
			}
		}
		s.relay.logger.Info("session closed",
			"session", s.key().String(),
			"socks_local_port", s.relay.socksLocalPort(),
			"gen", s.relay.associate.Generation(),
			"outbound", out,
			"inject", in,
			"path_scenario", scenario,
		)
	}
}

func (t *sessionTable) closeAll() {
	// Stale session→remote mappings must not survive associate swap; phone opens fresh flows.
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, s := range t.entries {
		s.close()
		delete(t.entries, key)
	}
}

func (t *sessionTable) count() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.entries)
}

func (t *sessionTable) cleanupLoop(stop <-chan struct{}) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			cutoff := t.relay.clock.Now().Add(-t.timeout)
			t.mu.Lock()
			for key, s := range t.entries {
				if s.lastSeen.Before(cutoff) {
					s.close()
					delete(t.entries, key)
				}
			}
			t.mu.Unlock()
		}
	}
}

func (k sessionKey) String() string {
	return fmt.Sprintf("%s:%d->%s:%d", k.clientIP, k.clientPort, k.dstIP, k.dstPort)
}
