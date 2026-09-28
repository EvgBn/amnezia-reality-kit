package main

import (
	"context"
	"fmt"
	"log/slog"

	nfqueue "github.com/florianl/go-nfqueue"
	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay"
)

type nfqueueHandler struct {
	nfq    *nfqueue.Nfqueue
	relay  *udprelay.Relay
	logger *slog.Logger
	cancel context.CancelFunc
}

func openNFQueue(cfg config, relay *udprelay.Relay, logger *slog.Logger, parent context.Context) (*nfqueueHandler, error) {
	nfCfg := &nfqueue.Config{
		NfQueue:      cfg.queue,
		MaxPacketLen: 0xFFFF,
		MaxQueueLen:  0xFF,
		Copymode:     nfqueue.NfQnlCopyPacket,
	}
	nfq, err := nfqueue.Open(nfCfg)
	if err != nil {
		return nil, fmt.Errorf("open nfqueue: %w", err)
	}

	ctx, cancel := context.WithCancel(parent)
	hook := func(a nfqueue.Attribute) int {
		if a.Payload == nil || a.PacketID == nil {
			return 0
		}
		id := *a.PacketID
		payload := *a.Payload
		if err := relay.HandlePacket(payload); err != nil {
			logger.Warn("packet relay failed", "err", err)
		}
		if err := nfq.SetVerdict(id, nfqueue.NfDrop); err != nil {
			logger.Warn("set verdict failed", "err", err)
		}
		return 0
	}
	errfn := func(err error) int {
		if parent.Err() != nil {
			return 1
		}
		logger.Warn("nfqueue receive error", "err", err)
		return 0
	}
	if err := nfq.RegisterWithErrorFunc(ctx, hook, errfn); err != nil {
		cancel()
		nfq.Close()
		return nil, fmt.Errorf("register nfqueue: %w", err)
	}
	logger.Info("nfqueue listening", "queue", cfg.queue)
	return &nfqueueHandler{nfq: nfq, relay: relay, logger: logger, cancel: cancel}, nil
}

func (h *nfqueueHandler) close() error {
	if h.cancel != nil {
		h.cancel()
	}
	if h.nfq != nil {
		return h.nfq.Close()
	}
	return nil
}
