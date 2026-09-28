package udprelay

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/EvgBn/amnezia-reality-kit/amneziawg/internal/udprelay/mocksocks"
)

func TestSendErrorTriggersReconnect(t *testing.T) {
	srv := mocksocks.New(t, "vpn-user", "test-pass")
	defer srv.Close()

	sendFail := errors.New("send failed")
	relay, err := New(Config{
		SocksAddr:      srv.Addr(),
		SocksUser:      "vpn-user",
		SocksPass:      "test-pass",
		BindAddr:       "127.0.0.1",
		SessionTimeout: time.Minute,
	}, DiscardLogger(), noopInjector{}, WithDial(func(addr, user, pass, bind string) (*socks5Client, error) {
		c, err := DialSocks5(addr, user, pass, bind)
		if err != nil {
			return nil, err
		}
		c.sendHook = func(net.IP, uint16, []byte) error { return sendFail }
		return c, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()

	frame := BuildTestIPv4UDP(net.ParseIP("10.8.0.9").To4(), net.ParseIP("91.108.9.99").To4(), 52013, 32003, []byte("x"))
	_ = relay.HandlePacket(frame)

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if srv.DialCount() >= 2 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("dial count after send error: %d", srv.DialCount())
}
