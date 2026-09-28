// Package udprelay routes client VoIP UDP through one shared SOCKS5 UDP associate to xray.
//
// # Why reconnect exists
//
// A SOCKS5 UDP associate has two legs: a TCP control connection (handshake + lifetime)
// and a local UDP relay socket. xray closes the control TCP after connIdle (~5 minutes
// without traffic on that associate). If udp-relay does not notice, the UDP socket stays
// open locally but xray no longer accepts or returns traffic — a zombie associate:
// outbound appears to work, inject (return path to the phone) stays 0, Telegram voice
// hangs on Connecting… until refresh-full or process restart.
//
// # Triggers (event-driven, not polled)
//
//   - tcp-eof: runTCPDrain observes FIN/RST on the control TCP (primary path)
//   - send-error: WriteToUDP on a dead associate
//   - read-loop-exit: shared UDP read loop returns an error
//   - one-way: high outbound with zero inject on a session (session age ≥ 5s)
//
// # What reconnect does
//
// Dial a fresh associate, atomic.Pointer swap, bump generation (stale read loops
// ignore replies), sessions.closeAll() (drop stale flow mappings), close old sockets.
//
// # Without reconnect
//
// After the first xray connIdle close the path degrades permanently for that process
// lifetime: same socks_local_port, inject=0, voice-gate FAIL. See tests/udprelay/
// zombie_associate_test.go for regression coverage.
package udprelay
