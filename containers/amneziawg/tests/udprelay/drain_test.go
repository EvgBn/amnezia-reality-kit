package udprelay_test

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestTCPDrainFiresReconnectOnServerClose(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	defer srv.Close()
	env := newTestEnv(t, srv)

	port1 := env.relay.AssociatePort()
	srv.CloseTCP()

	waitFor(t, 5*time.Second, func() bool {
		return srv.DialCount() >= 2 && env.relay.AssociatePort() != port1
	})
}
