//go:build linux

package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// openPty returns a pseudo-terminal pair: what the user types goes into master, the program reads slave.
func openPty(t *testing.T) (master, slave *os.File) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Skipf("no pseudo-terminal: %v", err)
	}
	var n, unlock uint32
	for _, c := range []struct {
		req uintptr
		arg *uint32
	}{{syscall.TIOCSPTLCK, &unlock}, {syscall.TIOCGPTN, &n}} {
		if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), c.req, uintptr(unsafe.Pointer(c.arg))); e != 0 {
			t.Fatalf("pty ioctl: %v", e)
		}
	}
	slave, err = os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	return master, slave
}

// echoOf runs `stty -a` on the terminal and reports whether echo is on.
func echoOf(tty *os.File) bool {
	c := exec.Command("stty", "-a")
	c.Stdin = tty
	out, _ := c.Output()
	return strings.Contains(string(out), " echo ")
}

// The token is read on a terminal that does not echo it and is put back afterwards, a pipe is read
// as it is, and a stored token file is mode 600 and replaces a looser old one. Fake token only.
func TestGatewaySecret(t *testing.T) {
	if _, err := exec.LookPath("stty"); err != nil {
		t.Skip("needs stty")
	}
	master, slave := openPty(t)
	defer master.Close()
	defer slave.Close()
	var echoed bytes.Buffer // what the terminal printed back to the user
	var mu sync.Mutex
	go func() {
		b := make([]byte, 256)
		for {
			n, err := master.Read(b)
			mu.Lock()
			echoed.Write(b[:n])
			mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	shown := func() string { mu.Lock(); defer mu.Unlock(); return echoed.String() }
	got := make(chan string, 1)
	go func() { s, _ := readSecret(slave); got <- s }()
	for i := 0; echoOf(slave); i++ { // the user types only once echo is off
		if i > 300 {
			t.Fatal("readSecret never turned terminal echo off")
		}
		time.Sleep(10 * time.Millisecond)
	}
	master.Write([]byte(tok + "\n"))
	select {
	case s := <-got:
		if s != tok {
			t.Fatalf("read %q, want the typed token", s)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("readSecret did not return")
	}
	time.Sleep(100 * time.Millisecond)
	typedShown := shown()
	master.Write([]byte("visible\n")) // control: with echo back on this terminal shows what is typed
	time.Sleep(100 * time.Millisecond)
	if strings.Contains(typedShown, "SECRET") || !echoOf(slave) || !strings.Contains(shown(), "visible") {
		t.Fatalf("token echoed (%q), or echo not restored, or control failed (%q)", typedShown, shown())
	}
	pr, pw, _ := os.Pipe()
	pw.WriteString(tok + "\n")
	pw.Close()
	if s, err := readSecret(pr); err != nil || s != tok {
		t.Fatalf("pipe read %q, %v", s, err)
	}

	path := filepath.Join(t.TempDir(), "config", "captain-chat", "telegram.token")
	if err := writeToken(path, "old"); err != nil || os.Chmod(path, 0o644) != nil {
		t.Fatal("cannot prepare an old, loose token file", err)
	}
	if err := writeToken(path, tok); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	body, _ := os.ReadFile(path)
	left, _ := filepath.Glob(path + "*")
	if info.Mode().Perm() != 0o600 || string(body) != tok+"\n" || len(left) != 1 {
		t.Fatalf("token file mode %v body %q files %v: want 600, the token, no leftovers", info.Mode().Perm(), body, left)
	}
	t.Logf("token read with echo off (terminal showed %q), echo restored, control echoed %q; token file mode %v", typedShown, strings.TrimSpace(shown()), info.Mode().Perm())
}
