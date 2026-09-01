package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	traceparentSize = 70
	ioTimeout       = 10 * time.Second
	watchdogTimeout = 120 * time.Second
)

var (
	traceparentLine  = regexp.MustCompile(`^Traceparent: 00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\r\n$`)
	progressScenario atomic.Value
	progressSent     atomic.Int64
	progressReceived atomic.Int64
)

type recordingConn struct {
	net.Conn
	clientSide   bool
	read, written bytes.Buffer
}

func (c *recordingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.read.Write(p[:n])
	if !c.clientSide {
		progressReceived.Add(int64(n))
	}
	return n, err
}

func (c *recordingConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.written.Write(p[:n])
	if c.clientSide {
		progressSent.Add(int64(n))
	}
	return n, err
}

func (c *recordingConn) CloseWrite() error {
	return c.Conn.(*net.TCPConn).CloseWrite()
}

type exchange struct {
	sent, received []byte
	serverValue   any
}

func setConnDeadlines(c net.Conn) error {
	deadline := time.Now().Add(ioTimeout)
	if err := c.SetReadDeadline(deadline); err != nil {
		return fmt.Errorf("set read deadline: %w", err)
	}
	if err := c.SetWriteDeadline(deadline); err != nil {
		return fmt.Errorf("set write deadline: %w", err)
	}
	return nil
}

func exchangeError(name, side string, expected int, err error) error {
	return fmt.Errorf("%s %s failed: client wrote %d bytes; server received %d/%d expected bytes: %w",
		name, side, progressSent.Load(), progressReceived.Load(), expected, err)
}

func runExchange(name string, expected int, server func(*recordingConn) (any, error), client func(*recordingConn) error) (exchange, error) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return exchange{}, exchangeError(name, "listen", expected, err)
	}
	defer ln.Close()

	type serverResult struct {
		value    any
		received []byte
		err      error
	}
	serverDone := make(chan serverResult, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			serverDone <- serverResult{err: err}
			return
		}
		rc := &recordingConn{Conn: conn}
		if err := setConnDeadlines(rc); err != nil {
			_ = rc.Close()
			serverDone <- serverResult{err: err}
			return
		}
		value, err := server(rc)
		_ = rc.Close()
		serverDone <- serverResult{value: value, received: bytes.Clone(rc.read.Bytes()), err: err}
	}()

	conn, err := net.DialTimeout("tcp4", ln.Addr().String(), 5*time.Second)
	if err != nil {
		return exchange{}, exchangeError(name, "dial", expected, err)
	}
	rc := &recordingConn{Conn: conn, clientSide: true}
	if err := setConnDeadlines(rc); err != nil {
		_ = rc.Close()
		return exchange{}, exchangeError(name, "client", expected, err)
	}
	clientErr := client(rc)
	_ = rc.Close()
	result := <-serverDone
	if clientErr != nil {
		return exchange{}, exchangeError(name, "client", expected, clientErr)
	}
	if result.err != nil {
		return exchange{}, exchangeError(name, "server", expected, result.err)
	}
	return exchange{sent: bytes.Clone(rc.written.Bytes()), received: result.received, serverValue: result.value}, nil
}

func writeAll(w io.Writer, p []byte) error {
	_, err := io.Copy(w, bytes.NewReader(p))
	return err
}

func readHeader(r *bufio.Reader) error {
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" {
			return nil
		}
	}
}

func frame(frameType byte, payload []byte) []byte {
	header := make([]byte, 5)
	header[0] = frameType
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	return append(header, payload...)
}

func sendFrame(c *recordingConn, frameType byte, payload []byte) error {
	f := frame(frameType, payload)
	if err := writeAll(c, f[:5]); err != nil {
		return err
	}
	// Separate writes make the opaque payload begin at sk_msg offset zero.
	return writeAll(c, f[5:])
}

func byteDiff(want, got []byte) error {
	at := 0
	for at < len(want) && at < len(got) && want[at] == got[at] {
		at++
	}
	if at == len(want) && at == len(got) {
		return nil
	}
	lo := max(0, at-16)
	return fmt.Errorf("first byte divergence at offset %d (want len=%d, got len=%d)\nwant[%d:]: % x\n got[%d:]: % x",
		at, len(want), len(got), lo, want[lo:min(len(want), at+32)], lo, got[lo:min(len(got), at+32)])
}

func upgradeThenBinary() error {
	request := []byte("GET /derp HTTP/1.1\r\nHost: x\r\nUpgrade: DERP\r\nConnection: Upgrade\r\n\r\n")
	payloads := [][]byte{
		{0xde, 0xad, 0xbe, 0xef},
		[]byte("GET / HTTP/1.1\r\nopaque DERP payload"),
		[]byte("POST /h HTTP/1.1\r\nmore opaque payload"),
	}
	expected := len(request)
	for _, payload := range payloads {
		expected += 5 + len(payload)
	}

	ex, err := runExchange("upgrade-then-binary", expected, func(c *recordingConn) (any, error) {
		reader := bufio.NewReader(c)
		if err := readHeader(reader); err != nil {
			return nil, err
		}
		if err := writeAll(c, []byte("HTTP/1.1 101 Switching Protocols\r\nUpgrade: DERP\r\nConnection: Upgrade\r\n\r\n")); err != nil {
			return nil, err
		}
		_, err := io.Copy(io.Discard, reader)
		return nil, err
	}, func(c *recordingConn) error {
		if err := writeAll(c, request); err != nil {
			return err
		}
		if err := readHeader(bufio.NewReader(c)); err != nil {
			return err
		}
		for i, payload := range payloads {
			if err := sendFrame(c, byte(2+i), payload); err != nil {
				return err
			}
		}
		return c.CloseWrite()
	})
	if err != nil {
		return err
	}
	return byteDiff(ex.sent, ex.received)
}

func compareWithAllowedTraceparents(want, got []byte, allowedOffsets map[int]bool) error {
	wi, gi := 0, 0
	for wi < len(want) {
		if allowedOffsets[wi] && gi+traceparentSize <= len(got) && traceparentLine.Match(got[gi:gi+traceparentSize]) {
			gi += traceparentSize
		}
		if gi >= len(got) || want[wi] != got[gi] {
			return byteDiff(want, got)
		}
		wi++
		gi++
	}
	if allowedOffsets[wi] && gi+traceparentSize == len(got) && traceparentLine.Match(got[gi:]) {
		gi += traceparentSize
	}
	if gi != len(got) {
		return byteDiff(want, got)
	}
	return nil
}

func rawBinary() error {
	payloads := [][]byte{
		{0x00, 0xff, 0x7f},
		[]byte("GET /not-http\r\n"),
		[]byte("POST /h HTTP/1\r\n"),
		[]byte("GET / HTTP/1.1\r\n"),
	}
	var want bytes.Buffer
	allowed := map[int]bool{}
	for i, payload := range payloads {
		want.Write(frame(byte(4+i), payload))
		if i == len(payloads)-1 {
			// A byte-perfect request line at sk_msg offset zero is indistinguishable
			// from HTTP. Injection immediately after it is therefore allowed here.
			allowed[want.Len()] = true
		}
	}

	ex, err := runExchange("raw-binary", want.Len(), func(c *recordingConn) (any, error) {
		_, err := io.Copy(io.Discard, c)
		return nil, err
	}, func(c *recordingConn) error {
		for i, payload := range payloads {
			if err := sendFrame(c, byte(4+i), payload); err != nil {
				return err
			}
		}
		return c.CloseWrite()
	})
	if err != nil {
		return err
	}
	return compareWithAllowedTraceparents(ex.sent, ex.received, allowed)
}

type positiveResult struct {
	traceparents int
	bodies       [][]byte
}

func receiveRequests(c *recordingConn, count int) (positiveResult, error) {
	reader := bufio.NewReader(c)
	result := positiveResult{}
	for range count {
		line, err := reader.ReadString('\n')
		if err != nil {
			return result, err
		}
		if !strings.HasSuffix(line, " HTTP/1.1\r\n") {
			return result, fmt.Errorf("invalid request line %q", line)
		}
		contentLength := 0
		for {
			line, err = reader.ReadString('\n')
			if err != nil {
				return result, err
			}
			if line == "\r\n" {
				break
			}
			if strings.HasPrefix(line, "Traceparent: ") {
				if !traceparentLine.MatchString(line) {
					return result, fmt.Errorf("malformed traceparent %q", line)
				}
				result.traceparents++
			}
			if strings.HasPrefix(strings.ToLower(line), "content-length:") {
				contentLength, err = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(strings.ToLower(line), "content-length:")))
				if err != nil {
					return result, err
				}
			}
		}
		body := make([]byte, contentLength)
		if _, err := io.ReadFull(reader, body); err != nil {
			return result, err
		}
		result.bodies = append(result.bodies, body)
		if err := writeAll(c, []byte{0xac}); err != nil {
			return result, err
		}
	}
	return result, nil
}

func stripTraceparents(raw []byte) ([]byte, int, error) {
	var clean bytes.Buffer
	count := 0
	for len(raw) > 0 {
		newline := bytes.IndexByte(raw, '\n')
		if newline < 0 {
			clean.Write(raw)
			break
		}
		line := raw[:newline+1]
		raw = raw[newline+1:]
		if bytes.HasPrefix(line, []byte("Traceparent: ")) {
			if !traceparentLine.Match(line) {
				return nil, 0, fmt.Errorf("malformed traceparent %q", line)
			}
			count++
			continue
		}
		clean.Write(line)
	}
	return clean.Bytes(), count, nil
}

func positiveControl(selfcheck bool) error {
	requests := [][]byte{
		[]byte("GET /one HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"),
		[]byte("GET /two HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"),
		[]byte("POST /three HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nhello\x00world"),
	}
	expected := 0
	for _, request := range requests {
		expected += len(request)
	}

	ex, err := runExchange("positive-control", expected, func(c *recordingConn) (any, error) {
		return receiveRequests(c, len(requests))
	}, func(c *recordingConn) error {
		ack := []byte{0}
		for _, request := range requests {
			if err := writeAll(c, request); err != nil {
				return err
			}
			if _, err := io.ReadFull(c, ack); err != nil {
				return err
			}
			if ack[0] != 0xac {
				return fmt.Errorf("bad server acknowledgement %#x", ack[0])
			}
		}
		return c.CloseWrite()
	})
	if err != nil {
		return err
	}
	result, ok := ex.serverValue.(positiveResult)
	if !ok {
		return errors.New("missing positive-control server result")
	}
	clean, traceparents, err := stripTraceparents(ex.received)
	if err != nil {
		return err
	}
	if err := byteDiff(ex.sent, clean); err != nil {
		return fmt.Errorf("request/body mutation after removing Traceparent headers: %w", err)
	}
	wantTraceparents := len(requests)
	if selfcheck {
		wantTraceparents = 0
	}
	if traceparents != wantTraceparents || result.traceparents != wantTraceparents {
		return fmt.Errorf("Traceparent count: raw=%d parsed=%d, want=%d", traceparents, result.traceparents, wantTraceparents)
	}
	wantBodies := [][]byte{nil, nil, []byte("hello\x00world")}
	for i := range wantBodies {
		if !bytes.Equal(result.bodies[i], wantBodies[i]) {
			return fmt.Errorf("request %d body changed: %w", i+1, byteDiff(wantBodies[i], result.bodies[i]))
		}
	}
	return nil
}

func waitForStartFile(path string) error {
	if path == "" {
		return nil
	}
	deadline := time.Now().Add(90 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for OBI start gate %s", path)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func main() {
	selfcheck := flag.Bool("selfcheck", false, "verify the userspace harness without OBI")
	startFile := flag.String("start-file", "", "wait for this file before opening sockets")
	flag.Parse()

	if err := waitForStartFile(*startFile); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	progressScenario.Store("startup")
	watchdog := time.AfterFunc(watchdogTimeout, func() {
		fmt.Fprintf(os.Stderr, "watchdog timeout after %s: scenario=%s client-written=%d server-received=%d\n",
			watchdogTimeout, progressScenario.Load(), progressSent.Load(), progressReceived.Load())
		os.Exit(1)
	})
	defer watchdog.Stop()

	scenarios := []struct {
		name string
		run  func() error
	}{
		{"upgrade-then-binary", upgradeThenBinary},
		{"raw-binary", rawBinary},
		{"positive-control", func() error { return positiveControl(*selfcheck) }},
	}
	for _, scenario := range scenarios {
		progressScenario.Store(scenario.name)
		progressSent.Store(0)
		progressReceived.Store(0)
		if err := scenario.run(); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", scenario.name, err)
			os.Exit(1)
		}
		fmt.Printf("PASS %s\n", scenario.name)
	}
}
