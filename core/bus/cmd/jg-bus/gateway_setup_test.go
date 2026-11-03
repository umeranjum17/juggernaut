//go:build linux

package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
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

// Setup end to end against a fake Bot API: the token is pasted on a terminal that does not echo it,
// getMe names the bot, the token file is mode 600, and the first private message with the code makes
// that person the owner. Enter alone keeps the stored token; a malformed or refused token is saved
// nowhere. Fake ids only.
func TestGatewaySetup(t *testing.T) {
	if _, err := exec.LookPath("stty"); err != nil {
		t.Skip("needs stty")
	}
	home, state, getMe := t.TempDir(), t.TempDir(), 0
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, upd(30, "private", 91, 91, false, "654321"))
		case r.URL.Path == "/bot"+tok+"/getMe":
			getMe++
			fmt.Fprint(w, `{"ok":true,"result":{"username":"fake_bot"}}`)
		case strings.HasSuffix(r.URL.Path, "/getMe"):
			w.WriteHeader(401)
			fmt.Fprint(w, `{"ok":false}`)
		default:
			io.Copy(io.Discard, r.Body)
			fmt.Fprint(w, `{"ok":true,"result":{"message_id":9}}`)
		}
	}))
	defer bot.Close()
	conf, tokenPath := filepath.Join(home, "config", "captain-channel"), filepath.Join(home, "config", "captain-chat", "telegram.token")
	os.MkdirAll(filepath.Dir(conf), 0o700)
	os.WriteFile(conf, []byte("set telegram-api-url "+bot.URL+"\nset mode live\n"), 0o600)
	a := &app{root: ".", home: home, state: state, data: home, configFiles: []string{conf}}
	pairCode = func() string { return "654321" }

	// Everything the command says goes to stderr: collect it to prove the token is not in it.
	oldErr := os.Stderr
	er, ew, _ := os.Pipe()
	os.Stderr = ew
	var said bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); io.Copy(&said, er) }()
	defer func() { os.Stderr = oldErr }()

	master, slave := openPty(t)
	defer master.Close()
	defer slave.Close()
	var echoed bytes.Buffer
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
	code := make(chan int, 1)
	go func() { code <- a.setup(slave) }()
	for i := 0; echoOf(slave); i++ { // the user types only once echo is off
		if i > 300 {
			t.Fatal("setup never turned terminal echo off")
		}
		time.Sleep(10 * time.Millisecond)
	}
	master.Write([]byte(tok + "\n"))
	select {
	case rc := <-code:
		if rc != 0 {
			t.Fatalf("setup exited %d: %s", rc, said.String())
		}
	case <-time.After(20 * time.Second):
		t.Fatal("setup did not finish")
	}
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	shown := echoed.String()
	mu.Unlock()
	info, err := os.Stat(tokenPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("token file %v, %v: want mode 600", info, err)
	}
	if got, _ := os.ReadFile(tokenPath); string(got) != tok+"\n" || strings.Contains(shown, "SECRET") || !echoOf(slave) {
		t.Fatalf("token file %q, terminal showed %q, echo restored %v", got, shown, echoOf(slave))
	}
	if got := fileGet(conf, "telegram-allow-user"); got != "91" || fileGet(conf, "mode") != "live" {
		t.Fatalf("allow-user %q: want 91 with other keys kept", got)
	}

	// Enter alone keeps the stored token (and pairs again); a malformed token and one Telegram refuses
	// are refused and the stored token is not touched.
	for in, want := range map[string]bool{"\n": true, "not-a-token\n": false, "111:wrong-token\n": false} {
		pr, pw, _ := os.Pipe()
		pw.WriteString(in)
		pw.Close()
		if rc := a.setup(pr); (rc == 0) != want {
			t.Fatalf("setup with %q exited %d, want success=%v", in, rc, want)
		}
	}
	if got, _ := os.ReadFile(tokenPath); string(got) != tok+"\n" || getMe != 2 {
		t.Fatalf("token file %q, getMe calls %d: want the token kept and 2 calls", got, getMe)
	}
	os.Stderr = oldErr
	ew.Close()
	wg.Wait()
	for _, want := range []string{"@BotFather", "@fake_bot", "https://t.me/fake_bot", "mode 600", "bin/jg-stack.sh up"} {
		if !strings.Contains(said.String(), want) {
			t.Errorf("setup said nothing like %q", want)
		}
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenPath && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
	if strings.Contains(said.String(), tok) {
		t.Error("the bot token was printed")
	}
	t.Logf("setup: token typed on a no-echo terminal (terminal showed %q), getMe named @fake_bot, token file mode %v, owner 91 recorded, echo restored", shown, info.Mode().Perm())
}
