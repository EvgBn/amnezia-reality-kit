package udprelay

import (
	"net"
	"testing"
)

func TestIsRoutableDestination(t *testing.T) {
	tests := []struct {
		ip   string
		want bool
	}{
		{"91.108.9.90", true},
		{"8.8.8.8", true},
		{"192.168.0.21", false},
		{"10.8.0.9", false},
		{"172.16.0.1", false},
		{"100.64.0.1", false},
		{"127.0.0.1", false},
	}
	for _, tc := range tests {
		got := IsRoutableDestination(net.ParseIP(tc.ip))
		if got != tc.want {
			t.Fatalf("%s: got %v want %v", tc.ip, got, tc.want)
		}
	}
}
