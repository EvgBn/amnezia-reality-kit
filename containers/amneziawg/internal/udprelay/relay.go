package udprelay

import (
	"fmt"
	"log/slog"
	"net"
	"sync/atomic"
	"time"
)

// Relay routes NFQUEUE UDP frames through a shared SOCKS5 UDP associate.
type Relay struct {
	cfg    Config
	logger *slog.Logger
	inject PacketInjector
	clock  clock
	dial   DialFunc

	socks     atomic.Pointer[socks5Client]
	associate *associateManager
	sessions  *sessionTable
}

// New creates a Relay with an initial SOCKS UDP associate.
func New(cfg Config, logger *slog.Logger, inject PacketInjector, opts ...Option) (*Relay, error) {
	if inject == nil {
		return nil, fmt.Errorf("injector is required")
	}
	ro := applyOptions(opts)
	r := &Relay{
		cfg:    cfg,
		logger: logger,
		inject: inject,
		clock:  ro.clock,
		dial:   ro.dial,
	}
	r.associate = newAssociateManager(r)
	r.sessions = newSessionTable(cfg.SessionTimeout, r)

	socks, err := r.dial(cfg.SocksAddr, cfg.SocksUser, cfg.SocksPass, cfg.BindAddr)
	if err != nil {
		return nil, err
	}
	gen := r.associate.initialGeneration()
	r.attachStats(socks, gen)
	r.socks.Store(socks)
	r.startSocksLoops(gen, socks)
	logger.Info("shared socks udp associate ready",
		"local_port", socks.localPort(),
		"gen", gen,
		"path_scenario", ScenarioOK,
	)
	return r, nil
}

// HandlePacket relays one NFQUEUE IPv4/UDP frame.
func (r *Relay) HandlePacket(frame []byte) error {
	info, err := ParseIPv4UDP(frame)
	if err != nil {
		return err
	}
	if len(info.Payload) == 0 {
		return fmt.Errorf("empty udp payload")
	}
	if !IsRoutableDestination(info.DstIP) {
		r.logger.Debug("dropped non-routable udp",
			"dst", net.JoinHostPort(info.DstIP.String(), fmt.Sprintf("%d", info.DstPort)),
		)
		return nil
	}
	sess, err := r.sessions.getOrCreate(info)
	if err != nil {
		return err
	}
	socks := r.socks.Load()
	if socks == nil {
		return fmt.Errorf("no socks associate")
	}
	if err := socks.send(info.DstIP, info.DstPort, info.Payload); err != nil {
		r.logger.Warn("socks send failed",
			"path_scenario", ScenarioSendError,
			"err", err,
			"socks_local_port", r.socksLocalPort(),
			"gen", r.associate.Generation(),
		)
		r.associate.RequestReconnect("send-error")
		return err
	}
	if socks.stats != nil {
		socks.stats.recordOutbound()
	}
	sess.recordOutbound(len(info.Payload))
	return nil
}

// StartSessionCleanup runs periodic session expiry until stop is closed.
func (r *Relay) StartSessionCleanup(stop <-chan struct{}) {
	go r.sessions.cleanupLoop(stop)
}

// StartAssociateHealth emits periodic associate health snapshots until stop is closed.
func (r *Relay) StartAssociateHealth(stop <-chan struct{}) {
	go r.associateHealthLoop(stop)
}

// AssociatePort returns the current local SOCKS UDP relay port.
func (r *Relay) AssociatePort() uint16 {
	return r.socksLocalPort()
}

// SessionCount returns active session table size (tests).
func (r *Relay) SessionCount() int {
	return r.sessions.count()
}

// Generation returns the current associate generation (tests).
func (r *Relay) Generation() uint64 {
	return r.associate.Generation()
}

// TestDialBackoff exposes dial backoff for tests.
func (r *Relay) TestDialBackoff() time.Duration {
	return r.associate.DialBackoff()
}

// Close shuts down the relay.
func (r *Relay) Close() {
	r.sessions.closeAll()
	if socks := r.socks.Load(); socks != nil {
		if socks.stats != nil {
			socks.stats.logClosed(r.logger, "shutdown", r.clock.Now())
		}
		socks.close()
	}
}

func (r *Relay) socksLocalPort() uint16 {
	socks := r.socks.Load()
	if socks == nil {
		return 0
	}
	return socks.localPort()
}

func (r *Relay) currentStats() *associateStats {
	socks := r.socks.Load()
	if socks == nil {
		return nil
	}
	return socks.stats
}

func (r *Relay) attachStats(socks *socks5Client, gen uint64) {
	socks.stats = newAssociateStats(gen, socks.localPort(), r.clock.Now())
}

func (r *Relay) startSocksLoops(gen uint64, socks *socks5Client) {
	if socks.stats != nil {
		socks.stats.readLoopStarted.Store(true)
	}
	r.logger.Info("associate read loop started",
		"gen", gen,
		"port", socks.localPort(),
	)
	go r.runSocksReadLoop(gen, socks)
	socks.runTCPDrain(gen, r.associate.Generation, func() {
		// xray closed control TCP (connIdle). Was invisible before PR1 — zombie associate.
		r.logger.Info("socks tcp control eof",
			"gen", gen,
			"port", socks.localPort(),
			"path_scenario", ScenarioOK,
		)
		r.associate.RequestReconnect("tcp-eof")
	})
}

func (r *Relay) runSocksReadLoop(gen uint64, socks *socks5Client) {
	err := socks.readLoop(
		func(remoteIP net.IP, remotePort uint16, payload []byte) {
			stats := socks.stats
			if stats != nil {
				stats.recordSocksRx(r.logger, r.clock.Now())
			}
			if r.associate.Generation() != gen {
				if stats != nil {
					stats.recordStaleReply()
				}
				r.logger.Warn("stale reply ignored",
					"path_scenario", ScenarioStaleReply,
					"gen", gen,
					"current", r.associate.Generation(),
					"remote", fmt.Sprintf("%s:%d", remoteIP, remotePort),
					"bytes", len(payload),
				)
				return
			}
			r.sessions.deliverReply(remoteIP, remotePort, payload)
		},
		func(rawLen int, decodeErr error) {
			if socks.stats != nil {
				socks.stats.recordDecodeErr()
			}
			fields := []any{
				"path_scenario", ScenarioSocksDecode,
				"socks_local_port", socks.localPort(),
				"gen", gen,
				"raw_len", rawLen,
				"err", decodeErr,
			}
			if socks.stats != nil {
				fields = append(fields, "decode_err", socks.stats.socksDecodeErr.Load())
			}
			r.logger.Warn("socks udp decode failed", fields...)
		},
	)
	if socks.stats != nil {
		socks.stats.readLoopExited.Store(true)
	}
	if err != nil && r.associate.Generation() == gen {
		fields := []any{
			"path_scenario", ScenarioReadLoopExit,
			"socks_local_port", socks.localPort(),
			"gen", gen,
			"err", err,
		}
		if socks.stats != nil {
			fields = append(fields, "socks_udp_rx", socks.stats.socksUdpRx.Load())
		}
		r.logger.Warn("shared socks read loop exited", fields...)
		r.associate.RequestReconnect("read-loop-exit")
	}
}

// reconnectAssociate replaces the shared SOCKS UDP associate after control-TCP death
// or other failure. Without this, xray connIdle leaves a zombie UDP socket (inject=0).
// Order: dial → swap pointer → bump gen → closeAll sessions → start loops → close old.
func (r *Relay) reconnectAssociate(reason string) error {
	newSocks, err := r.dial(r.cfg.SocksAddr, r.cfg.SocksUser, r.cfg.SocksPass, r.cfg.BindAddr)
	if err != nil {
		r.associate.onDialError()
		return err
	}
	r.associate.onDialSuccess()

	old := r.socks.Swap(newSocks)
	gen := r.associate.bumpGeneration()
	r.attachStats(newSocks, gen)

	oldPort := uint16(0)
	oldGen := uint64(0)
	if old != nil {
		oldPort = old.localPort()
		if old.stats != nil {
			oldGen = old.stats.gen
			old.stats.logClosed(r.logger, reason, r.clock.Now())
		}
	}

	r.sessions.closeAll()
	r.startSocksLoops(gen, newSocks)
	if old != nil {
		old.close()
	}

	r.logger.Info("associate reconnected",
		"reason", reason,
		"old_port", oldPort,
		"old_gen", oldGen,
		"new_port", newSocks.localPort(),
		"gen", gen,
		"path_scenario", ScenarioOK,
	)
	return nil
}

func (r *Relay) associateHealthLoop(stop <-chan struct{}) {
	ticker := time.NewTicker(associateHealthInterval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			stats := r.currentStats()
			if stats == nil {
				continue
			}
			stats.logHealth(r.logger, r.clock.Now())
		}
	}
}
