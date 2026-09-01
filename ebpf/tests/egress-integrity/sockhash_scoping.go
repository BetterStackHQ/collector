package main

// Scenario proving that OBI's sockhash membership is scoped to discovery.
//
// Membership in `sock_dir` is what swaps a socket's protocol ops for tcp_bpf,
// whose sendmsg/recvmsg stalls are the reason this patch series exists.
// Upstream enrolls every outgoing socket in the cgroup, because the sockops
// callback that enrolls (ACTIVE_ESTABLISHED_CB) fires while the SYN-ACK is
// processed and cannot see the owning process. Patch 012 moves the discovery
// check to BPF_SOCK_OPS_TCP_CONNECT_CB, which does run in the connecting task,
// and enrolls only the sockets it marked.
//
// The check here is a real experiment with a control, not a bare absence
// assertion. A second copy of this binary, at a path discovery does not match,
// connects and reports its socket cookie *before* sending anything; this
// process's own socket, opened seconds earlier on the same loopback in the same
// cgroup, is sampled at the same moment. The allowed socket must be in
// `sock_dir` — if it were not, nothing would be enrolled at all and every
// byte-integrity scenario in this harness would pass vacuously — and the
// bystander's must not be, both before and after its one HTTP/1.1 request. That
// request must also arrive byte-for-byte, without a Traceparent, while the
// allowed process's identical request gets one.

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	// linux/asm-generic/socket.h; generic across the architectures OBI supports
	soCookie = 57

	// linux/bpf.h
	bpfMapGetNextKey  = 4
	bpfMapGetNextID   = 12
	bpfMapGetFDByID   = 14
	bpfObjGetInfoByFD = 15
	bpfMapTypeSockash = 18

	// bpf_map_info: type at 0, name at 24 (BPF_OBJ_NAME_LEN = 16)
	mapInfoSize     = 128
	mapInfoNameAt   = 24
	mapInfoNameLen  = 16
	sockDirMapName  = "sock_dir"
	bystanderExe    = "/tmp/bystander-client"
	bystanderReqFmt = "GET /bystander HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
	scopingReqFmt   = "GET /scoping HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
)

func socketCookie(fd int) (uint64, error) {
	var cookie uint64
	size := uint32(unsafe.Sizeof(cookie))
	_, _, errno := syscall.Syscall6(syscall.SYS_GETSOCKOPT,
		uintptr(fd), uintptr(syscall.SOL_SOCKET), soCookie,
		uintptr(unsafe.Pointer(&cookie)), uintptr(unsafe.Pointer(&size)), 0)
	if errno != 0 {
		return 0, fmt.Errorf("getsockopt(SO_COOKIE): %w", errno)
	}
	return cookie, nil
}

// The standard library's syscall package has no SYS_BPF on linux/amd64, so the
// number comes from the kernel's syscall tables directly. Wrong-arch builds
// fail loudly at the first call rather than issuing some unrelated syscall.
var sysBPF = map[string]uintptr{"amd64": 321, "arm64": 280}[runtime.GOARCH]

func bpfCall(cmd int, attr unsafe.Pointer, size uintptr) (uintptr, syscall.Errno) {
	if sysBPF == 0 {
		panic("no bpf(2) syscall number for GOARCH=" + runtime.GOARCH)
	}
	ret, _, errno := syscall.Syscall(sysBPF, uintptr(cmd), uintptr(attr), size)
	return ret, errno
}

type bpfAttrID struct {
	id        uint32
	nextID    uint32
	openFlags uint32
	_         uint32
}

type bpfAttrInfo struct {
	bpfFD   uint32
	infoLen uint32
	info    uint64
}

type bpfAttrElem struct {
	mapFD   uint32
	_       uint32
	key     uint64
	nextKey uint64
	flags   uint64
}

// sockDirFDs returns a file descriptor for every SOCKHASH named sock_dir that
// this process can see. Walking the id space rather than a bpffs pin keeps the
// harness independent of OBI's pinning configuration, and it is what
// `bpftool map dump name sock_dir` does — bpftool is not installable in the
// --network=none container the scenarios run in.
func sockDirFDs() ([]int, error) {
	var fds []int
	id := uint32(0)
	for {
		attr := bpfAttrID{id: id}
		if _, errno := bpfCall(bpfMapGetNextID, unsafe.Pointer(&attr), unsafe.Sizeof(attr)); errno != 0 {
			// ENOENT ends the walk. EPERM/EACCES means this process may not
			// enumerate maps at all, which is the selfcheck run on a plain
			// runner: report "no map" and let the caller decide.
			if errno == syscall.ENOENT || errno == syscall.EPERM || errno == syscall.EACCES {
				return fds, nil
			}
			for _, fd := range fds {
				_ = syscall.Close(fd)
			}
			return nil, fmt.Errorf("BPF_MAP_GET_NEXT_ID: %w", errno)
		}
		id = attr.nextID

		get := bpfAttrID{id: id}
		ret, errno := bpfCall(bpfMapGetFDByID, unsafe.Pointer(&get), unsafe.Sizeof(get))
		if errno != 0 {
			// a map can disappear between the two calls
			continue
		}
		fd := int(ret)

		var info [mapInfoSize]byte
		query := bpfAttrInfo{
			bpfFD:   uint32(fd),
			infoLen: mapInfoSize,
			info:    uint64(uintptr(unsafe.Pointer(&info[0]))),
		}
		_, errno = bpfCall(bpfObjGetInfoByFD, unsafe.Pointer(&query), unsafe.Sizeof(query))
		runtime.KeepAlive(info)
		if errno != 0 {
			_ = syscall.Close(fd)
			continue
		}

		name := string(bytes.TrimRight(info[mapInfoNameAt:mapInfoNameAt+mapInfoNameLen], "\x00"))
		if name != sockDirMapName || binary.NativeEndian.Uint32(info[0:4]) != bpfMapTypeSockash {
			_ = syscall.Close(fd)
			continue
		}
		fds = append(fds, fd)
	}
}

// sockDirCookies returns the set of socket cookies currently enrolled in
// sock_dir, or ok=false when no such map exists (selfcheck runs, where OBI
// never loaded).
func sockDirCookies() (cookies map[uint64]struct{}, ok bool, err error) {
	fds, err := sockDirFDs()
	if err != nil {
		return nil, false, err
	}
	if len(fds) == 0 {
		return nil, false, nil
	}
	defer func() {
		for _, fd := range fds {
			_ = syscall.Close(fd)
		}
	}()

	cookies = map[uint64]struct{}{}
	for _, fd := range fds {
		var key, next uint64
		haveKey := false
		// sock_dir holds at most 65535 entries; the bound only guards against a
		// map being mutated underneath the walk.
		for range 1 << 17 {
			attr := bpfAttrElem{
				mapFD:   uint32(fd),
				nextKey: uint64(uintptr(unsafe.Pointer(&next))),
			}
			if haveKey {
				attr.key = uint64(uintptr(unsafe.Pointer(&key)))
			}
			_, errno := bpfCall(bpfMapGetNextKey, unsafe.Pointer(&attr), unsafe.Sizeof(attr))
			runtime.KeepAlive(&key)
			runtime.KeepAlive(&next)
			if errno == syscall.ENOENT {
				break
			}
			if errno != 0 {
				return nil, false, fmt.Errorf("BPF_MAP_GET_NEXT_KEY: %w", errno)
			}
			cookies[next] = struct{}{}
			key = next
			haveKey = true
		}
	}
	return cookies, true, nil
}

// respawnBystander re-executes the bystander with its pipes and exits, so the
// process that actually opens a socket is orphaned onto pid 1.
//
// The indirection is not ceremony. OBI's discovery filter is inherited:
// valid_pid() in bpf/pid/pid.h falls back to the namespaced parent pid, so a
// direct child of the instrumented harness passes the filter — deliberately,
// that is how OBI follows a process tree into its workers. A bystander forked
// straight from this process would be enrolled, and rightly so. Reparenting
// produces a process that is genuinely outside discovery: an exe path
// discovery does not match, under a parent it does not match either.
func respawnBystander(port int) error {
	inner := exec.Command(bystanderExe,
		"-bystander", strconv.Itoa(port),
		"-bystander-spawner", strconv.Itoa(os.Getpid()))
	inner.Stdin = os.Stdin
	inner.Stdout = os.Stdout
	inner.Stderr = os.Stderr
	// deliberately not waited for: exiting here is what orphans it
	return inner.Start()
}

// waitForReparent blocks until this process has been handed over to init, so
// the connect() below cannot race the exit of the process that spawned us and
// be attributed to the instrumented parent after all. Comparing against the
// spawner's pid rather than a sampled getppid() keeps it correct when the
// spawner is already gone by the time we look.
func waitForReparent(spawner int) error {
	deadline := time.Now().Add(10 * time.Second)
	for os.Getppid() == spawner {
		if time.Now().After(deadline) {
			return fmt.Errorf("bystander is still a child of %d", spawner)
		}
		time.Sleep(2 * time.Millisecond)
	}
	return nil
}

// bystander is the detached client: a copy of this binary at a path discovery
// does not match, reparented away from the instrumented harness. It hands its
// socket cookie and pid to the harness before sending anything, so the harness
// can sample sock_dir at the moment upstream OBI would have enrolled it.
func bystander(port, spawner int) error {
	if err := waitForReparent(spawner); err != nil {
		return err
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
	if _, err := fmt.Printf("cookie %d pid %d\n", cookie, os.Getpid()); err != nil {
		return err
	}

	// Block until the parent has sampled sock_dir. The connection is
	// established, which is the moment upstream OBI would have enrolled it, and
	// nothing has been sent yet.
	gate := make([]byte, 1)
	if _, err := io.ReadFull(os.Stdin, gate); err != nil {
		return fmt.Errorf("waiting for parent: %w", err)
	}

	if err := writeAll(conn, []byte(bystanderReqFmt)); err != nil {
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

	// Hold the socket open so the parent can sample sock_dir again; the parent
	// closes our stdin when it is done.
	_, _ = io.Copy(io.Discard, os.Stdin)
	return nil
}

func copySelfTo(path string) error {
	self, err := os.Open("/proc/self/exe")
	if err != nil {
		return err
	}
	defer self.Close()

	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	dst, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(dst, self); err != nil {
		_ = dst.Close()
		return err
	}
	return dst.Close()
}

// readRequest consumes one bodyless HTTP/1.1 request, answers 204, and reports
// how many Traceparent headers it carried.
func readRequest(r *bufio.Reader, c *recordingConn) (int, error) {
	traceparents := 0
	line, err := r.ReadString('\n')
	if err != nil {
		return 0, err
	}
	if !strings.HasSuffix(line, " HTTP/1.1\r\n") {
		return 0, fmt.Errorf("invalid request line %q", line)
	}
	for {
		line, err = r.ReadString('\n')
		if err != nil {
			return 0, err
		}
		if line == "\r\n" {
			break
		}
		if strings.HasPrefix(line, "Traceparent: ") {
			if !traceparentLine.MatchString(line) {
				return 0, fmt.Errorf("malformed traceparent %q", line)
			}
			traceparents++
		}
	}

	return traceparents, writeAll(c, []byte(httpNoContentResponse))
}

func requireMembership(where string, cookies map[uint64]struct{}, cookie uint64, want bool) error {
	_, got := cookies[cookie]
	if got == want {
		return nil
	}
	state := map[bool]string{true: "present", false: "absent"}
	return fmt.Errorf("%s: socket cookie %d is %s in sock_dir, want %s (%d entries)",
		where, cookie, state[got], state[want], len(cookies))
}

func sockhashScoping(selfcheck bool) error {
	// SO_COOKIE and sock_dir only exist on Linux; local darwin selfcheck runs
	// the other scenarios and CI's Linux selfcheck covers this one.
	if runtime.GOOS != "linux" {
		fmt.Println("sockhash-scoping: skipped (Linux-only)")
		return nil
	}
	ln, err := rawListen()
	if err != nil {
		return err
	}
	defer ln.Close()

	// --- allowed control: a socket owned by this (discovered) process --------
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

	allowedClient := &recordingConn{rawConn: allowed, clientSide: true}
	allowedRecorder := &recordingConn{rawConn: allowedServer}
	if err := writeAll(allowedClient, []byte(scopingReqFmt)); err != nil {
		return fmt.Errorf("allowed client write: %w", err)
	}
	allowedTPs, err := readRequest(bufio.NewReader(allowedRecorder), allowedRecorder)
	if err != nil {
		return fmt.Errorf("allowed server read: %w", err)
	}
	allowedReader := bufio.NewReader(allowedClient)
	if _, err := allowedReader.ReadString('\n'); err != nil {
		return err
	}
	if err := readHeader(allowedReader); err != nil {
		return err
	}

	wantAllowedTPs := 1
	if selfcheck {
		wantAllowedTPs = 0
	}
	if allowedTPs != wantAllowedTPs {
		return fmt.Errorf("allowed process: %d Traceparents on its request, want %d",
			allowedTPs, wantAllowedTPs)
	}

	// --- bystander: same code, an exe path discovery does not match ----------
	if err := copySelfTo(bystanderExe); err != nil {
		return fmt.Errorf("staging bystander: %w", err)
	}
	defer os.Remove(bystanderExe)

	// os.Pipe rather than Cmd.StdinPipe/StdoutPipe: Cmd.Wait closes the pipes it
	// created, and the process we wait for is only the spawner. These ends have
	// to outlive it and stay wired to the detached client behind it.
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

	spawner := exec.Command(bystanderExe, "-bystander", strconv.Itoa(ln.port))
	spawner.Stdin = gateR
	spawner.Stdout = reportW
	spawner.Stderr = os.Stderr
	err = spawner.Start()
	_ = gateR.Close()
	_ = reportW.Close()
	if err != nil {
		return fmt.Errorf("starting bystander: %w", err)
	}
	if err := spawner.Wait(); err != nil {
		return fmt.Errorf("bystander spawner: %w", err)
	}

	bystanderPID := 0
	defer func() {
		if bystanderPID != 0 {
			_ = syscall.Kill(bystanderPID, syscall.SIGKILL)
		}
	}()

	bystanderServer, err := ln.accept()
	if err != nil {
		return err
	}
	defer bystanderServer.Close()
	bystanderRecorder := &recordingConn{rawConn: bystanderServer}

	childOut := bufio.NewReader(reportR)
	line, err := childOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading bystander cookie: %w", err)
	}
	var bystanderCookie uint64
	if _, err := fmt.Sscanf(line, "cookie %d pid %d", &bystanderCookie, &bystanderPID); err != nil {
		return fmt.Errorf("bad bystander report line %q: %w", line, err)
	}
	if bystanderCookie == allowedCookie {
		return errors.New("socket cookies collided; the membership check would be meaningless")
	}

	// --- at establishment: only the allowed socket is enrolled ---------------
	before, haveMap, err := sockDirCookies()
	if err != nil {
		return fmt.Errorf("reading sock_dir: %w", err)
	}
	if !haveMap && !selfcheck {
		return errors.New("no sock_dir SOCKHASH found; tpinjector is not enrolling anything")
	}
	if haveMap {
		if err := requireMembership("at establishment", before, allowedCookie, true); err != nil {
			return err
		}
		if err := requireMembership("at establishment", before, bystanderCookie, false); err != nil {
			return err
		}
	}

	// --- release the bystander's one request ---------------------------------
	if _, err := gateW.Write([]byte("g")); err != nil {
		return err
	}
	bystanderTPs, err := readRequest(bufio.NewReader(bystanderRecorder), bystanderRecorder)
	if err != nil {
		return fmt.Errorf("bystander server read: %w", err)
	}
	if bystanderTPs != 0 {
		return fmt.Errorf("bystander request carried %d Traceparents; discovery excluded it", bystanderTPs)
	}
	if err := byteDiff([]byte(bystanderReqFmt), bystanderRecorder.read.Bytes()); err != nil {
		return fmt.Errorf("bystander request mutated: %w", err)
	}

	done, err := childOut.ReadString('\n')
	if err != nil {
		return fmt.Errorf("waiting for bystander: %w", err)
	}
	if strings.TrimSpace(done) != "sent" {
		return fmt.Errorf("unexpected bystander output %q", done)
	}

	// --- after egress: still only the allowed socket -------------------------
	if haveMap {
		after, _, err := sockDirCookies()
		if err != nil {
			return fmt.Errorf("re-reading sock_dir: %w", err)
		}
		if err := requireMembership("after bystander egress", after, bystanderCookie, false); err != nil {
			return err
		}
		if err := requireMembership("after bystander egress", after, allowedCookie, true); err != nil {
			return err
		}
	}

	return nil
}
