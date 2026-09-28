package main

import (
	"context"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
)

func main() {
	cfg := parseConfig()
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.logLevel}))
	logger.Info("starting udp-relay",
		"queue", cfg.queue,
		"socks", cfg.socksAddr,
		"iface", cfg.iface,
	)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	inject, err := newInjector(cfg.iface)
	if err != nil {
		logger.Error("inject init failed", "err", err)
		os.Exit(1)
	}
	defer func() { _ = inject.close() }()

	relay, err := udprelay.New(udprelay.Config{
		SocksAddr:      cfg.socksAddr,
		SocksUser:      cfg.socksUser,
		SocksPass:      cfg.socksPass,
		BindAddr:       cfg.bindAddr,
		SessionTimeout: cfg.sessionTimeout,
	}, logger, &injectAdapter{inject: inject})
	if err != nil {
		logger.Error("relay init failed", "err", err)
		os.Exit(1)
	}
	defer relay.Close()

	stopSessions := make(chan struct{})
	relay.StartSessionCleanup(stopSessions)
	relay.StartAssociateHealth(stopSessions)

	nfq, err := openNFQueue(cfg, relay, logger, ctx)
	if err != nil {
		logger.Error("nfqueue init failed", "err", err)
		os.Exit(1)
	}
	defer nfq.close()

	<-ctx.Done()
	logger.Info("shutdown signal received")
	close(stopSessions)
	logger.Info("udp-relay stopped")
}

type injectAdapter struct {
	inject *injector
}

func (a *injectAdapter) SendReply(srcIP, clientIP net.IP, srcPort, clientPort uint16, payload []byte) error {
	return a.inject.sendReply(srcIP, clientIP, srcPort, clientPort, payload)
}
