package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"
)

type config struct {
	queue          uint16
	socksAddr      string
	socksUser      string
	socksPass      string
	bindAddr       string
	iface          string
	sessionTimeout time.Duration
	logLevel       slog.Level
}

func parseConfig() config {
	var cfg config
	var timeoutSec int
	var level string
	var queue int

	flag.IntVar(&queue, "queue", 100, "NFQUEUE number")
	flag.StringVar(&cfg.socksAddr, "socks", "10.200.97.4:1080", "SOCKS5 server address")
	flag.StringVar(&cfg.socksUser, "user", "", "SOCKS5 username")
	flag.StringVar(&cfg.socksPass, "pass", "", "SOCKS5 password")
	flag.StringVar(&cfg.bindAddr, "bind", "0.0.0.0", "local bind address for SOCKS UDP relay")
	flag.StringVar(&cfg.iface, "iface", "awg0", "interface for injected reply packets")
	flag.IntVar(&timeoutSec, "session-timeout", 60, "UDP session idle timeout in seconds")
	flag.StringVar(&level, "log-level", "info", "log level: debug, info, warn, error")
	flag.Parse()

	cfg.sessionTimeout = time.Duration(timeoutSec) * time.Second
	cfg.logLevel = parseLogLevel(level)
	cfg.queue = uint16(queue)

	if cfg.socksUser == "" || cfg.socksPass == "" {
		fmt.Fprintln(os.Stderr, "user and pass are required")
		os.Exit(2)
	}
	if queue < 0 || queue > 65535 {
		fmt.Fprintln(os.Stderr, "invalid queue number")
		os.Exit(2)
	}
	return cfg
}

func parseLogLevel(s string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
