package udprelay

import (
	"sync"
	"sync/atomic"
	"time"
)

type reconnectSkipReason int

const (
	skipNone reconnectSkipReason = iota
	skipCoalesced
	skipCooldown
	skipBackoff
	skipSessionYoung
)

type associateManager struct {
	relay *Relay

	mu            sync.Mutex
	reconnecting  bool
	generation    atomic.Uint64
	lastReconnect time.Time
	lastDialError time.Time
	dialBackoff   time.Duration
}

func newAssociateManager(relay *Relay) *associateManager {
	return &associateManager{
		relay:       relay,
		dialBackoff: dialBackoffBase,
	}
}

func (a *associateManager) Generation() uint64 {
	return a.generation.Load()
}

func (a *associateManager) bumpGeneration() uint64 {
	return a.generation.Add(1)
}

func (a *associateManager) initialGeneration() uint64 {
	a.generation.Store(1)
	return 1
}

// RequestReconnect schedules an associate swap. Safe to call from any goroutine.
//
// Reasons: tcp-eof, send-error, read-loop-exit, one-way — see package doc.
// Coalesced when a reconnect is already in flight; subject to cooldown/backoff.
func (a *associateManager) RequestReconnect(reason string) {
	a.mu.Lock()
	if a.reconnecting {
		a.mu.Unlock()
		a.relay.logger.Warn("reconnect coalesced",
			"reason", reason,
			"path_scenario", ScenarioReconnectSkip,
			"skip_reason", "already_reconnecting",
			"gen", a.generation.Load(),
		)
		return
	}
	skip, detail := a.skipCooldownLocked()
	if skip != skipNone {
		a.mu.Unlock()
		a.logReconnectSkipped(reason, skip, detail)
		return
	}
	a.reconnecting = true
	a.mu.Unlock()

	a.relay.logger.Info("reconnect started",
		"reason", reason,
		"gen", a.generation.Load(),
		"port", a.relay.socksLocalPort(),
	)
	go func() {
		defer a.finishReconnect()
		if err := a.relay.reconnectAssociate(reason); err != nil {
			a.relay.logger.Warn("reconnect failed",
				"reason", reason,
				"path_scenario", ScenarioUnknown,
				"err", err,
				"gen", a.generation.Load(),
			)
		}
	}()
}

func (a *associateManager) tryOneWayReconnect(sess *session) {
	now := a.relay.clock.Now()
	sessionAge := now.Sub(sess.openedAt)
	if sessionAge < oneWaySessionAgeMin {
		a.logReconnectSkipped("one-way", skipSessionYoung,
			formatSkipDetail(0, 0, sessionAge, oneWaySessionAgeMin))
		sess.scheduleOneWayReconnect()
		return
	}
	a.mu.Lock()
	skip, detail := a.skipCooldownLocked()
	a.mu.Unlock()
	if skip != skipNone {
		a.logReconnectSkipped("one-way", skip, detail)
		return
	}
	a.relay.logger.Info("one-way reconnect triggered",
		"session", sess.key().String(),
		"session_age", sessionAge.Round(time.Millisecond),
		"gen", a.generation.Load(),
	)
	a.RequestReconnect("one-way")
}

func (a *associateManager) skipCooldownLocked() (reconnectSkipReason, string) {
	now := a.relay.clock.Now()
	if !a.lastReconnect.IsZero() {
		if rem := reconnectCooldown - now.Sub(a.lastReconnect); rem > 0 {
			return skipCooldown, formatSkipDetail(rem, 0, 0, 0)
		}
	}
	if !a.lastDialError.IsZero() {
		if rem := a.dialBackoff - now.Sub(a.lastDialError); rem > 0 {
			return skipBackoff, formatSkipDetail(0, rem, 0, 0)
		}
	}
	return skipNone, ""
}

func (a *associateManager) logReconnectSkipped(reason string, skip reconnectSkipReason, detail string) {
	skipReason := "unknown"
	switch skip {
	case skipCooldown:
		skipReason = "reconnect_cooldown"
	case skipBackoff:
		skipReason = "dial_backoff"
	case skipSessionYoung:
		skipReason = "session_too_young"
	}
	a.relay.logger.Warn("reconnect skipped",
		"reason", reason,
		"path_scenario", ScenarioReconnectSkip,
		"skip_reason", skipReason,
		"detail", detail,
		"gen", a.generation.Load(),
		"port", a.relay.socksLocalPort(),
	)
}

func (a *associateManager) allowReconnectLocked() bool {
	skip, _ := a.skipCooldownLocked()
	return skip == skipNone
}

func (a *associateManager) finishReconnect() {
	a.mu.Lock()
	a.reconnecting = false
	a.lastReconnect = a.relay.clock.Now()
	a.mu.Unlock()
}

func (a *associateManager) onDialSuccess() {
	a.mu.Lock()
	a.dialBackoff = dialBackoffBase
	a.mu.Unlock()
}

func (a *associateManager) onDialError() {
	a.mu.Lock()
	now := a.relay.clock.Now()
	a.lastDialError = now
	if a.dialBackoff < dialBackoffMax {
		next := a.dialBackoff * 2
		if next > dialBackoffMax {
			next = dialBackoffMax
		}
		a.dialBackoff = next
	}
	backoff := a.dialBackoff
	a.mu.Unlock()
	a.relay.logger.Warn("reconnect dial backoff increased",
		"path_scenario", ScenarioUnknown,
		"backoff", backoff,
		"gen", a.generation.Load(),
	)
}

// DialBackoff returns current dial backoff (tests).
func (a *associateManager) DialBackoff() time.Duration {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.dialBackoff
}

// LastDialError returns last dial error time (tests).
func (a *associateManager) LastDialError() time.Time {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.lastDialError
}
