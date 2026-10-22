package main

// Scenario proving that the instrumentation's own cgroup stays out of the
// traces, at both ends of a connection.
//
// OBI runs in a container of its own, next to the probes a collector runs:
// metric exporters, health checks, the runtime inspectors OBI itself opens.
// None of that is the application's traffic, yet it used to be reported twice
// over: as client spans whenever a probe matched discovery (an exporter does
// listen on a port), and as root server spans of every instrumented service
// the probes talked to. Patch 016 identifies the cgroup OBI runs in, keeps
// its processes out of instrumentation whatever `instrument` selects, and
// records the connections they dial so the server side leaves them unparsed.
//
// run-under-obi.sh starts OBI in a child cgroup of this container's root,
// the way a container runtime isolates it, and names that cgroup in
// OBI_CGROUP_DIR. The subject here is this binary again, at a path discovery
// *does* match, which moves itself into that cgroup before dialling the
// instrumented server in this process. Its request has to arrive untouched
// and without a Traceparent (it is not instrumented), and OBI must print no
// server span for it, while the control request this process then sends
// itself gets both. The span checks live in run-under-obi.sh, which has OBI's
// output; this scenario produces the traffic and checks the bytes.
//
// As in deny-child, the subject announces its pid and dials only once its
// exclusion is visible in `denied_pids`: that is the userspace half of the
// patch reaching the kernel, and it makes the scenario wait on an observable
// rather than on a sleep.

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	// Set by run-under-obi.sh to the cgroup it starts OBI in; unset when the
	// payload runs alone for the selfcheck.
	obiCgroupDirEnv = "OBI_CGROUP_DIR"

	ownCgroupRequest        = "GET /own-cgroup HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
	ownCgroupControlRequest = "GET /own-cgroup-control HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
)

// ownCgroupClient is the subject: this binary, at the path discovery matches,
// in the instrumentation's cgroup from before it opens a socket.
func ownCgroupClient(port int) error {
	if os.Getenv(obiCgroupDirEnv) != "" {
		if err := joinOwnCgroup(); err != nil {
			return err
		}
	}
	// Announced only once in the cgroup, so discovery's first look at this
	// process already finds it there.
	if _, err := fmt.Printf("ready pid %d\n", os.Getpid()); err != nil {
		return err
	}
	if err := awaitDenyGate(); err != nil {
		return fmt.Errorf("waiting to dial: %w", err)
	}

	conn, err := rawDial(port)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := writeAll(conn, []byte(ownCgroupRequest)); err != nil {
		return err
	}
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	if line != "HTTP/1.1 204 No Content\r\n" {
		return fmt.Errorf("bad server status line %q", line)
	}
	if err := readHeader(reader); err != nil {
		return err
	}
	_, err = fmt.Println("sent")
	return err
}

//nolint:gocyclo
func ownCgroupScenario(selfcheck bool) error {
	// The BPF maps only exist on Linux; local darwin selfcheck runs the other
	// scenarios and CI's Linux selfcheck covers this one.
	if runtime.GOOS != "linux" {
		fmt.Println("own-cgroup: skipped (Linux-only)")
		return nil
	}
	if !selfcheck && os.Getenv(obiCgroupDirEnv) == "" {
		return fmt.Errorf("%s is not set: run-under-obi.sh starts OBI in a cgroup of its own and names it there", obiCgroupDirEnv)
	}

	ln, err := rawListen()
	if err != nil {
		return err
	}
	defer ln.Close()

	self, err := os.Executable()
	if err != nil {
		return err
	}

	gateR, gateW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer gateW.Close()
	reportR, reportW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer reportR.Close()

	subject := exec.Command(self, "-own-cgroup-client", strconv.Itoa(ln.port))
	subject.Stdin = gateR
	subject.Stdout = reportW
	subject.Stderr = os.Stderr
	err = subject.Start()
	_ = gateR.Close()
	_ = reportW.Close()
	if err != nil {
		return fmt.Errorf("starting the subject: %w", err)
	}
	defer func() {
		_ = subject.Process.Kill()
		_ = subject.Wait()
	}()

	subjectOut := bufio.NewReader(reportR)
	line, err := subjectOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading the subject's readiness: %w", err)
	}
	subjectPID := 0
	if _, err := fmt.Sscanf(line, "ready pid %d", &subjectPID); err != nil {
		return fmt.Errorf("bad readiness line %q: %w", line, err)
	}
	if subjectPID != subject.Process.Pid {
		return fmt.Errorf("subject reported pid %d, started %d", subjectPID, subject.Process.Pid)
	}

	// --- the exclusion reaching the kernel ----------------------------------
	// The subject matches the discovery criteria by path; only its cgroup
	// keeps it out, and that decision has to be published like any other.
	if !selfcheck {
		haveDenyMap, err := waitForDenial(subjectPID)
		if err != nil {
			return fmt.Errorf("process in the instrumentation's cgroup: %w", err)
		}
		if !haveDenyMap {
			fmt.Printf("own-cgroup: no %s map; waiting out the discovery window (%s)\n",
				deniedPidsMapName, denyPublishWindow)
			time.Sleep(denyPublishWindow)
		}
	}

	// --- the request from the instrumentation's cgroup ----------------------
	if _, err := gateW.Write([]byte("g")); err != nil {
		return err
	}
	server, err := ln.accept()
	if err != nil {
		return err
	}
	defer server.Close()
	recorder := &recordingConn{rawConn: server}

	var problems []error

	subjectTPs, err := readRequest(bufio.NewReader(recorder), recorder)
	if err != nil {
		return fmt.Errorf("server read of the subject's request: %w", err)
	}
	if subjectTPs != 0 {
		problems = append(problems, fmt.Errorf(
			"request from the instrumentation's cgroup carried %d Traceparents", subjectTPs))
	}
	if err := byteDiff([]byte(ownCgroupRequest), recorder.read.Bytes()); err != nil {
		problems = append(problems, fmt.Errorf("request from the instrumentation's cgroup mutated: %w", err))
	}

	done, err := subjectOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("waiting for the subject: %w", err)
	}
	if done != "sent\n" {
		return fmt.Errorf("unexpected subject output %q", done)
	}

	// --- control: the same request from this process, which is instrumented --
	control, err := rawDial(ln.port)
	if err != nil {
		return err
	}
	defer control.Close()
	controlServer, err := ln.accept()
	if err != nil {
		return err
	}
	defer controlServer.Close()
	controlRecorder := &recordingConn{rawConn: controlServer}

	if err := writeAll(control, []byte(ownCgroupControlRequest)); err != nil {
		return fmt.Errorf("control client write: %w", err)
	}
	controlTPs, err := readRequest(bufio.NewReader(controlRecorder), controlRecorder)
	if err != nil {
		return fmt.Errorf("server read of the control request: %w", err)
	}
	controlReader := bufio.NewReader(control)
	if _, err := controlReader.ReadString('\n'); err != nil {
		return err
	}
	if err := readHeader(controlReader); err != nil {
		return err
	}
	wantControlTPs := 1
	if selfcheck {
		wantControlTPs = 0
	}
	if controlTPs != wantControlTPs {
		problems = append(problems, fmt.Errorf(
			"control request: %d Traceparents, want %d", controlTPs, wantControlTPs))
	}

	return errors.Join(problems...)
}

// ---- connections older than OBI ----------------------------------------------
//
// The connect kprobe cannot have seen a connection that existed before OBI
// loaded; those are the socket iterator's job, and the iterator reads the
// cgroup a socket was *created* in, which an accepted socket inherits from its
// listener. run-under-obi.sh therefore starts this process before OBI, at the
// path discovery matches. It listens, and three children open connections
// that then sit idle until the harness has run its other scenarios: one child
// joins OBI's cgroup and dials this process, one stays in the root cgroup and
// dials it too, and the third joins OBI's cgroup and listens, with this
// process dialling it. When the gate opens, each connection carries one
// request. OBI's output must then show a server span for the root child's
// request and none for the request from OBI's cgroup, and a client span for
// this process's request to the listener in OBI's cgroup: a connection
// accepted into OBI's cgroup is not one it dialled.

const (
	ownCgroupEarlyRequest         = "GET /own-cgroup-early HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
	ownCgroupEarlyControlRequest  = "GET /own-cgroup-early-control HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
	ownCgroupEarlyAcceptedRequest = "GET /own-cgroup-early-accepted HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"

	// the other scenarios run in between, so this is generous
	earlyGateTimeout = 10 * time.Minute
)

// joinOwnCgroup moves this process into the cgroup run-under-obi.sh started
// OBI in.
func joinOwnCgroup() error {
	dir := os.Getenv(obiCgroupDirEnv)
	if dir == "" {
		return fmt.Errorf("%s is not set", obiCgroupDirEnv)
	}
	pid := []byte(strconv.Itoa(os.Getpid()))
	if err := os.WriteFile(filepath.Join(dir, "cgroup.procs"), pid, 0o644); err != nil {
		return fmt.Errorf("joining %s: %w", dir, err)
	}
	return nil
}

func waitForGate(path string) error {
	deadline := time.Now().Add(earlyGateTimeout)
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for the gate %s", path)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func expectNoContent(r *bufio.Reader) error {
	line, err := r.ReadString('\n')
	if err != nil {
		return err
	}
	if line != "HTTP/1.1 204 No Content\r\n" {
		return fmt.Errorf("bad server status line %q", line)
	}
	return readHeader(r)
}

// ownCgroupEarly is the parent of the early pair: started by run-under-obi.sh
// before OBI, instrumented once OBI discovers it.
//
//nolint:gocyclo
func ownCgroupEarly(gate string) error {
	if os.Getenv(obiCgroupDirEnv) == "" {
		return fmt.Errorf("%s is not set", obiCgroupDirEnv)
	}
	ln, err := rawListen()
	if err != nil {
		return err
	}
	defer ln.Close()

	self, err := os.Executable()
	if err != nil {
		return err
	}
	start := func(role string, port int) (*exec.Cmd, *bufio.Reader, error) {
		cmd := exec.Command(self, "-own-cgroup-early-role", role, "-early-gate", gate, "-early-port", strconv.Itoa(port))
		cmd.Stderr = os.Stderr
		out, err := cmd.StdoutPipe()
		if err != nil {
			return nil, nil, err
		}
		if err := cmd.Start(); err != nil {
			return nil, nil, fmt.Errorf("starting %s: %w", role, err)
		}
		return cmd, bufio.NewReader(out), nil
	}
	finish := func(cmd *exec.Cmd) {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}

	// --- a listener in OBI's cgroup, which this process dials ----------------
	listener, listenerOut, err := start("own-listener", 0)
	if err != nil {
		return err
	}
	defer finish(listener)
	line, err := listenerOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading the listener's port: %w", err)
	}
	listenerPort := 0
	if _, err := fmt.Sscanf(line, "listening %d", &listenerPort); err != nil {
		return fmt.Errorf("bad listener line %q: %w", line, err)
	}
	accepted, err := rawDial(listenerPort)
	if err != nil {
		return err
	}
	defer accepted.Close()

	// --- two clients of this process, one in OBI's cgroup --------------------
	ownClient, ownOut, err := start("own-client", ln.port)
	if err != nil {
		return err
	}
	defer finish(ownClient)
	rootClient, rootOut, err := start("root-client", ln.port)
	if err != nil {
		return err
	}
	defer finish(rootClient)

	first, err := ln.accept()
	if err != nil {
		return err
	}
	defer first.Close()
	second, err := ln.accept()
	if err != nil {
		return err
	}
	defer second.Close()

	// run-under-obi.sh waits for this line before it starts OBI
	if _, err := fmt.Println("early: connections established, waiting for the gate"); err != nil {
		return err
	}
	if err := waitForGate(gate); err != nil {
		return err
	}

	// --- one request per connection ------------------------------------------
	var problems []error
	seen := map[string]bool{}
	for _, conn := range []*rawConn{first, second} {
		recorder := &recordingConn{rawConn: conn}
		tps, err := readRequest(bufio.NewReader(recorder), recorder)
		if err != nil {
			return fmt.Errorf("server read: %w", err)
		}
		request := recorder.read.String()
		switch {
		case request == ownCgroupEarlyRequest:
			seen["own"] = true
			if tps != 0 {
				problems = append(problems, fmt.Errorf(
					"the request from OBI's cgroup carried %d Traceparents", tps))
			}
		case strings.HasPrefix(request, "GET /own-cgroup-early-control "):
			// its sender is a child of an instrumented process; a Traceparent
			// on this one is the injector doing its job
			seen["control"] = true
		default:
			problems = append(problems, fmt.Errorf("unexpected request %q", request))
		}
	}
	if !seen["own"] || !seen["control"] {
		problems = append(problems, fmt.Errorf("saw requests %v, want both the one from OBI's cgroup and the control", seen))
	}

	if err := writeAll(accepted, []byte(ownCgroupEarlyAcceptedRequest)); err != nil {
		return fmt.Errorf("writing to the listener in OBI's cgroup: %w", err)
	}
	if err := expectNoContent(bufio.NewReader(accepted)); err != nil {
		return fmt.Errorf("listener in OBI's cgroup: %w", err)
	}

	for role, out := range map[string]*bufio.Reader{"own-client": ownOut, "root-client": rootOut, "own-listener": listenerOut} {
		line, err := out.ReadString('\n')
		if err != nil {
			return fmt.Errorf("waiting for %s: %w", role, err)
		}
		if line != "done\n" {
			return fmt.Errorf("unexpected %s output %q", role, line)
		}
	}

	if _, err := fmt.Println("early: done"); err != nil {
		return err
	}
	return errors.Join(problems...)
}

// ownCgroupEarlyClient dials the early parent before OBI exists and sends one
// request once the gate opens.
func ownCgroupEarlyClient(role string, port int, gate string) error {
	request := ownCgroupEarlyControlRequest
	if role == "own-client" {
		if err := joinOwnCgroup(); err != nil {
			return err
		}
		request = ownCgroupEarlyRequest
	}
	conn, err := rawDial(port)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := waitForGate(gate); err != nil {
		return err
	}
	if err := writeAll(conn, []byte(request)); err != nil {
		return err
	}
	if err := expectNoContent(bufio.NewReader(conn)); err != nil {
		return err
	}
	_, err = fmt.Println("done")
	return err
}

// ownCgroupEarlyListener accepts, from OBI's cgroup, one connection the early
// parent opens before OBI exists, and answers its request once the gate opens.
func ownCgroupEarlyListener(gate string) error {
	if err := joinOwnCgroup(); err != nil {
		return err
	}
	ln, err := rawListen()
	if err != nil {
		return err
	}
	defer ln.Close()
	if _, err := fmt.Printf("listening %d\n", ln.port); err != nil {
		return err
	}
	conn, err := ln.accept()
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := waitForGate(gate); err != nil {
		return err
	}
	recorder := &recordingConn{rawConn: conn}
	if _, err := readRequest(bufio.NewReader(recorder), recorder); err != nil {
		return fmt.Errorf("reading the early parent's request: %w", err)
	}
	_, err = fmt.Println("done")
	return err
}
