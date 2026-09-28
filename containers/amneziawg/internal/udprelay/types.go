package udprelay

import (
	"log/slog"
	"net"
	"time"
)

const (
	reconnectCooldown        = 10 * time.Second
	dialBackoffBase          = 10 * time.Second
	dialBackoffMax           = 5 * time.Minute
	oneWayOutboundMin        = 20
	oneWaySessionAgeMin      = 5 * time.Second
	associateHealthInterval  = 5 * time.Minute
)

// Config holds SOCKS and session settings for the UDP relay.
type Config struct {
	SocksAddr      string
	SocksUser      string
	SocksPass      string
	BindAddr       string
	SessionTimeout time.Duration
}

// PacketInjector sends reply IPv4/UDP frames back to AWG clients.
type PacketInjector interface {
	SendReply(srcIP, clientIP net.IP, srcPort, clientPort uint16, payload []byte) error
}

// DialFunc dials a SOCKS5 UDP associate. Tests may replace the default implementation.
type DialFunc func(serverAddr, username, password, bindAddr string) (*socks5Client, error)

type clock interface {
	Now() time.Time
}

type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }

// Option configures optional Relay dependencies (tests).
type Option func(*relayOptions)

type relayOptions struct {
	dial  DialFunc
	clock clock
}

// WithDial overrides the SOCKS dial function.
func WithDial(fn DialFunc) Option {
	return func(o *relayOptions) {
		o.dial = fn
	}
}

// WithClock overrides time source (tests).
func WithClock(fn func() time.Time) Option {
	return func(o *relayOptions) {
		o.clock = clockFunc(fn)
	}
}

type clockFunc func() time.Time

func (f clockFunc) Now() time.Time { return f() }

// noopInjector discards injected replies (tests).
type noopInjector struct{}

func (noopInjector) SendReply(_ net.IP, _ net.IP, _, _ uint16, _ []byte) error {
	return nil
}

func applyOptions(opts []Option) relayOptions {
	ro := relayOptions{
		dial:  DialSocks5,
		clock: realClock{},
	}
	for _, opt := range opts {
		opt(&ro)
	}
	return ro
}

// DiscardLogger returns a quiet logger for tests.
func DiscardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(discardLogWriter{}, &slog.HandlerOptions{Level: slog.LevelError}))
}

type discardLogWriter struct{}

func (discardLogWriter) Write(p []byte) (int, error) { return len(p), nil }
