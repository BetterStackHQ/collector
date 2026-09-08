package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
)

// Keeping a real net/http client in the harness makes Go-specific probes
// available. Raw-syscall scenarios still exercise sk_msg, while these requests
// check the Go HTTP path also propagates exactly once.
func goHTTPClient(selfcheck bool) error {
	for _, serverHigher := range []bool{false, true} {
		if err := goHTTPClientPorts(selfcheck, serverHigher); err != nil {
			return fmt.Errorf("server port higher=%t: %w", serverHigher, err)
		}
	}
	return nil
}

func goHTTPClientPorts(selfcheck, serverHigher bool) error {
	// Reserve available ephemeral ports in both orderings. The Go probe must
	// retract the same sorted key that the socket injector reads.
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		listener.Close()
		return err
	}
	if (listener.Addr().(*net.TCPAddr).Port > reservation.Addr().(*net.TCPAddr).Port) != serverHigher {
		listener, reservation = reservation, listener
	}
	localAddr := reservation.Addr().(*net.TCPAddr)
	reservation.Close()
	server := &http.Server{
		ReadHeaderTimeout: ioTimeout,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, "%d", len(r.Header.Values("Traceparent")))
		}),
	}
	defer server.Close()
	go server.Serve(listener)
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext:       (&net.Dialer{LocalAddr: localAddr}).DialContext,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Timeout: ioTimeout, Transport: transport}
	resp, err := client.Get("http://" + listener.Addr().String() + "/go-control")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	want := "1"
	if selfcheck {
		want = "0"
	}
	if string(body) != want {
		return fmt.Errorf("Go HTTP client: wanted %s traceparents, got %s", want, body)
	}
	return nil
}
