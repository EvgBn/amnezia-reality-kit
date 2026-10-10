package udprelay

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

// newTestRelayWithMockSocks starts a mock SOCKS server and a relay for package tests.
func newTestRelayWithMockSocks(t *testing.T) (*Relay, *mocksocks.Server) {
	t.Helper()
	srv := mocksocks.New(t, "vpn-user", "test-pass")
	t.Cleanup(srv.Close)

	relay, err := New(Config{
		SocksAddr:      srv.Addr(),
		SocksUser:      "vpn-user",
		SocksPass:      "test-pass",
		BindAddr:       "127.0.0.1",
		SessionTimeout: time.Minute,
	}, DiscardLogger(), noopInjector{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(relay.Close)
	return relay, srv
}
