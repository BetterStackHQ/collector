package main

// Scenario proving that a discovery exclusion beats the pid filter's parent
// fallback.
//
// valid_pid() (bpf/pid/pid.h) checks the allow-list for the calling process
// and, on a miss, retries with its parent. That fallback is how OBI follows an
// instrumented process into its workers, and the sockhash-scoping scenario
// relies on it being intact. But it also let a process the user *excluded*
// through on an ancestor's ticket: userspace only ever declined to add such a
// process to the allow-list, and never told the kernel it was excluded. With
// `open_ports` discovery pid 1 is routinely instrumented and everything
// descends from pid 1, so `exclude_instrument` meant nothing in the kernel.
// Patch 013 publishes the exclusions into `denied_pids` and consults them
// first.
//
// The subject here is therefore a *direct* child of the instrumented harness —
// no reparenting, unlike the sockhash-scoping bystander — running a copy of
// this binary at a path the CI config excludes. Its parent is allowed, it is
// not, and the two must not be confused.
//
// The child announces its pid and waits before it opens any socket. That
// ordering is the point: valid_pid() is consulted in obi_kprobe_tcp_connect at
// connect() time, so a socket dialled before discovery published the exclusion
// would have been enrolled into the sockhash for the rest of its life. The
// harness releases the child only once the exclusion is visible in
// `denied_pids`, which also makes the scenario wait on an observable rather
// than on a sleep. Against a build without the map (008..012) it falls back to
// waiting out the discovery window, and then fails on the assertions, which is
// what makes it a negative control rather than a tautology.

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	// linux/bpf.h
	bpfMapTypeHash = 1

	deniedPidsMapName = "denied_pids"

	// A path the harness's own discovery criterion (*egress-integrity*) does
	// not match and run-under-obi.sh excludes explicitly.
	denyChildExe = "/tmp/deny-child"

	// Written by run-under-obi.sh for the process it starts before OBI, at a
	// path the same exclusion matches.
	denyChildEarlyPIDFile = "/tmp/deny-child-early.pid"

	denyChildRequest  = "GET /deny-child HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
	denyParentRequest = "GET /deny-parent HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"

	// Discovery has to notice the child first: the watcher polls every
	// discovery.poll_interval (5s by default) and skips processes younger than
	// discovery.min_process_age (5s), so ~10s is expected. The cap is the
	// margin over that, kept under the harness watchdog.
	denyPublishTimeout = 45 * time.Second
	denyPublishPoll    = 250 * time.Millisecond

	// Used only when `denied_pids` does not exist, i.e. against a pre-013 OBI:
	// long enough that the child is certainly discovered and excluded in
	// userspace, so the failure that follows is about the kernel honouring it.
	denyPublishWindow = 25 * time.Second
)

// denyChild is the excluded subject: a copy of this binary at an excluded path,
// started as a plain child of the instrumented harness and left there.
func denyChild(port int) error {
	// Announced before any socket exists, so the harness can wait for the
	// exclusion to reach BPF before this process dials.
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

	cookie, err := socketCookie(conn.fd)
	if err != nil {
		return err
	}
	if _, err := fmt.Printf("cookie %d\n", cookie); err != nil {
		return err
	}
	if err := awaitDenyGate(); err != nil {
		return fmt.Errorf("waiting to send: %w", err)
	}

	if err := writeAll(conn, []byte(denyChildRequest)); err != nil {
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
	if _, err := fmt.Println("sent"); err != nil {
		return err
	}

	// Hold the socket open so the harness can sample sock_dir again; it closes
	// our stdin when it is done.
	_, _ = io.Copy(io.Discard, os.Stdin)
	return nil
}

func awaitDenyGate() error {
	gate := make([]byte, 1)
	_, err := io.ReadFull(os.Stdin, gate)
	return err
}

// denyKeyFor builds the denied_pids key OBI publishes for a pid: pid_data_t
// {u32 nspid; u32 ns}, which on the little-endian architectures OBI supports
// is the namespaced pid in the low half of the 8-byte key and the pid
// namespace inode in the high half.
//
// The harness shares this container's pid namespace with OBI and with the
// child, so the pid it knows is the namespaced one, and /proc/<pid>/ns/pid is
// the same link OBI reads (procs.FindNamespace). Comparing the whole key keeps
// the check exact: a match cannot be some other denied process's entry.
func denyKeyFor(pid int) (uint64, error) {
	link, err := os.Readlink(fmt.Sprintf("/proc/%d/ns/pid", pid))
	if err != nil {
		return 0, err
	}
	openIdx, closeIdx := strings.LastIndex(link, "["), strings.LastIndex(link, "]")
	if openIdx < 0 || closeIdx < openIdx {
		return 0, fmt.Errorf("unexpected pid namespace link %q", link)
	}
	ns, err := strconv.ParseUint(link[openIdx+1:closeIdx], 10, 32)
	if err != nil {
		return 0, fmt.Errorf("unexpected pid namespace link %q: %w", link, err)
	}

	return uint64(ns)<<32 | uint64(uint32(pid)), nil
}

// deniedPIDs reports the published exclusions, and whether the map exists at
// all: it does not on an OBI built without patch 013.
func deniedPIDs() (keys map[uint64]struct{}, haveMap bool, err error) {
	return bpfMapKeys(deniedPidsMapName, bpfMapTypeHash)
}

// waitForDenial blocks until pid's exclusion is in denied_pids, reporting how
// long that took and how many entries the map holds, because "it was already
// there" and "it arrived" are different facts and only the run can tell them
// apart.
func waitForDenial(pid int) (haveMap bool, err error) {
	want, err := denyKeyFor(pid)
	if err != nil {
		return false, err
	}

	start := time.Now()
	for {
		keys, haveMap, err := deniedPIDs()
		if err != nil {
			return false, fmt.Errorf("reading %s: %w", deniedPidsMapName, err)
		}
		if !haveMap {
			return false, nil
		}
		if _, ok := keys[want]; ok {
			fmt.Printf("deny-child: exclusion for pid %d published after %s (%d entries in %s)\n",
				pid, time.Since(start).Round(10*time.Millisecond), len(keys), deniedPidsMapName)
			return true, nil
		}
		if time.Since(start) > denyPublishTimeout {
			return true, fmt.Errorf("OBI did not exclude pid %d within %s (%d entries in %s)",
				pid, denyPublishTimeout, len(keys), deniedPidsMapName)
		}
		time.Sleep(denyPublishPoll)
	}
}

// requireEarlyDenial checks the exclusion of the process run-under-obi.sh
// starts before OBI. Its denial is recorded during the first discovery poll,
// which runs before any BPF collection exists, so it is the one that has to
// survive being published later — and it is the shape the bug had in
// production: an excluded daemon already running when the agent starts.
func requireEarlyDenial() error {
	raw, err := os.ReadFile(denyChildEarlyPIDFile)
	if errors.Is(err, os.ErrNotExist) {
		// payload run without the runner
		return nil
	}
	if err != nil {
		return err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return fmt.Errorf("bad %s: %w", denyChildEarlyPIDFile, err)
	}

	haveMap, err := waitForDenial(pid)
	if err != nil {
		return fmt.Errorf("process started before OBI: %w", err)
	}
	if !haveMap {
		fmt.Printf("deny-child: no %s map; skipping the pre-OBI exclusion check\n", deniedPidsMapName)
	}

	return nil
}

//nolint:gocyclo
func denyChildScenario(selfcheck bool) error {
	// SO_COOKIE and the BPF maps only exist on Linux; local darwin selfcheck
	// runs the other scenarios and CI's Linux selfcheck covers this one.
	if runtime.GOOS != "linux" {
		fmt.Println("deny-child: skipped (Linux-only)")
		return nil
	}

	ln, err := rawListen()
	if err != nil {
		return err
	}
	defer ln.Close()

	// --- allowed control: this process is the child's parent, and allowed ----
	allowed, err := rawDial(ln.port)
	if err != nil {
		return err
	}
	defer allowed.Close()
	allowedCookie, err := socketCookie(allowed.fd)
	if err != nil {
		return err
	}
	allowedServer, err := ln.accept()
	if err != nil {
		return err
	}
	defer allowedServer.Close()

	allowedRecorder := &recordingConn{rawConn: allowedServer}
	if err := writeAll(allowed, []byte(denyParentRequest)); err != nil {
		return fmt.Errorf("parent client write: %w", err)
	}
	parentTPs, err := readRequest(bufio.NewReader(allowedRecorder), allowedRecorder)
	if err != nil {
		return fmt.Errorf("parent server read: %w", err)
	}
	allowedReader := bufio.NewReader(allowed)
	if _, err := allowedReader.ReadString('\n'); err != nil {
		return err
	}
	if err := readHeader(allowedReader); err != nil {
		return err
	}

	wantParentTPs := 1
	if selfcheck {
		wantParentTPs = 0
	}
	if parentTPs != wantParentTPs {
		return fmt.Errorf("parent process: %d Traceparents on its request, want %d", parentTPs, wantParentTPs)
	}

	// --- an excluded process that predates OBI ------------------------------
	if !selfcheck {
		if err := requireEarlyDenial(); err != nil {
			return err
		}
	}

	// --- the excluded direct child ------------------------------------------
	if err := copySelfTo(denyChildExe); err != nil {
		return fmt.Errorf("staging deny-child: %w", err)
	}
	defer os.Remove(denyChildExe)

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

	// Started and deliberately not waited for: this process has to remain its
	// parent, because an allowed parent is exactly what the scenario is about.
	child := exec.Command(denyChildExe, "-deny-child", strconv.Itoa(ln.port))
	child.Stdin = gateR
	child.Stdout = reportW
	child.Stderr = os.Stderr
	err = child.Start()
	_ = gateR.Close()
	_ = reportW.Close()
	if err != nil {
		return fmt.Errorf("starting deny-child: %w", err)
	}
	defer func() {
		_ = child.Process.Kill()
		_ = child.Wait()
	}()

	childOut := bufio.NewReader(reportR)
	line, err := childOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading deny-child readiness: %w", err)
	}
	childPID := 0
	if _, err := fmt.Sscanf(line, "ready pid %d", &childPID); err != nil {
		return fmt.Errorf("bad deny-child readiness line %q: %w", line, err)
	}
	if childPID != child.Process.Pid {
		return fmt.Errorf("deny-child reported pid %d, started %d", childPID, child.Process.Pid)
	}

	// --- wait for the exclusion to reach the kernel -------------------------
	haveDenyMap := false
	if !selfcheck {
		haveDenyMap, err = waitForDenial(childPID)
		if err != nil {
			return err
		}
		if !haveDenyMap {
			// No denied_pids map: an OBI without patch 013. Give discovery the
			// same chance to see the child, then let the assertions below say
			// what that build does with it.
			fmt.Printf("deny-child: no %s map; waiting out the discovery window (%s)\n",
				deniedPidsMapName, denyPublishWindow)
			time.Sleep(denyPublishWindow)
		}
	}

	// --- release the dial ---------------------------------------------------
	if _, err := gateW.Write([]byte("g")); err != nil {
		return err
	}
	line, err = childOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading deny-child cookie: %w", err)
	}
	var childCookie uint64
	if _, err := fmt.Sscanf(line, "cookie %d", &childCookie); err != nil {
		return fmt.Errorf("bad deny-child cookie line %q: %w", line, err)
	}
	if childCookie == allowedCookie {
		return errors.New("socket cookies collided; the membership check would be meaningless")
	}

	childServer, err := ln.accept()
	if err != nil {
		return err
	}
	defer childServer.Close()
	childRecorder := &recordingConn{rawConn: childServer}

	// Failures from here on are collected rather than returned one at a time.
	// Against an OBI that does not honour the exclusion every consequence is
	// worth seeing from a single run: the socket enrolled into the sockhash,
	// the Traceparent spliced in, and the bytes that changed because of it.
	var problems []error

	// --- at establishment: the parent's socket is enrolled, the child's is not
	before, haveSockDir, err := sockDirCookies()
	if err != nil {
		return fmt.Errorf("reading sock_dir: %w", err)
	}
	if !haveSockDir && !selfcheck {
		return errors.New("no sock_dir SOCKHASH found; tpinjector is not enrolling anything")
	}
	if haveSockDir {
		problems = append(problems,
			requireMembership("at establishment", before, allowedCookie, true),
			requireMembership("at establishment", before, childCookie, false))
	}

	// --- release the child's one request ------------------------------------
	if _, err := gateW.Write([]byte("g")); err != nil {
		return err
	}
	childTPs, err := readRequest(bufio.NewReader(childRecorder), childRecorder)
	if err != nil {
		return fmt.Errorf("deny-child server read: %w", err)
	}
	if childTPs != 0 {
		problems = append(problems, fmt.Errorf(
			"excluded child's request carried %d Traceparents on its allowed parent's ticket", childTPs))
	}
	if err := byteDiff([]byte(denyChildRequest), childRecorder.read.Bytes()); err != nil {
		problems = append(problems, fmt.Errorf("excluded child's request mutated: %w", err))
	}

	done, err := childOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("waiting for deny-child: %w", err)
	}
	if done != "sent\n" {
		return fmt.Errorf("unexpected deny-child output %q", done)
	}

	// --- after egress: still only the parent's socket -----------------------
	if haveSockDir {
		after, _, err := sockDirCookies()
		if err != nil {
			return fmt.Errorf("re-reading sock_dir: %w", err)
		}
		problems = append(problems,
			requireMembership("after child egress", after, childCookie, false),
			requireMembership("after child egress", after, allowedCookie, true))
	}

	// Proven, not assumed: the child was denied by name, and its parent stayed
	// allowed throughout. Without the second half the scenario would also pass
	// on a build that simply stopped instrumenting anything.
	if haveDenyMap {
		keys, _, err := deniedPIDs()
		if err != nil {
			return err
		}
		self, err := denyKeyFor(os.Getpid())
		if err != nil {
			return err
		}
		if _, denied := keys[self]; denied {
			problems = append(problems, fmt.Errorf(
				"the instrumented parent (pid %d) is in %s", os.Getpid(), deniedPidsMapName))
		}
	}

	return errors.Join(problems...)
}
