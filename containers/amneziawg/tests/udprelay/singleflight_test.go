package udprelay_test

import (
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestDialBackoffOnRepeatedFailure(t *testing.T) {
	srv := mocksocks.New(t, testUser, testPass)
	env := newTestEnv(t, srv)
	before := env.relay.TestDialBackoff()

	srv.Close()
	srv.CloseTCP()

	waitFor(t, 5*time.Second, func() bool {
		return env.relay.TestDialBackoff() > before
	})
}
