package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A gateway whose polls keep failing must not look healthy. The real `gateway serve` loop runs in a
// child process against a Bot API that answers getUpdates with 502 (the same shape as an outage, or
// a batch that cannot be filed): the status row has to turn pending and name the failing polls,
// and the poll record has to carry the last good poll and the failures in a row. When the API
// recovers the row goes back to live-ready (the service is running and polling) and the failures reset.
func TestGatewayPollHealth(t *testing.T) {
	if os.Getenv("JG_TEST_SERVE_HOME") != "" { // the child: run the real serve loop until killed
		home := os.Getenv("JG_TEST_SERVE_HOME")
		a := &app{root: ".", home: home, state: filepath.Join(home, "state"), data: filepath.Join(home, "data"),
			configFiles: []string{filepath.Join(home, "conf")}, log: filepath.Join(home, "state", "log"), record: filepath.Join(home, "state", "rec")}
		os.Exit(a.gateway([]string{"serve"}))
	}
	home := t.TempDir()
	down := true
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch p := r.URL.Path; {
		case strings.HasSuffix(p, "/getMe"):
			fmt.Fprint(w, `{"ok":true,"result":{"username":"pollbot"}}`)
		case strings.HasSuffix(p, "/getUpdates") && down:
			http.Error(w, `{"ok":false}`, 502)
		case strings.HasSuffix(p, "/getUpdates"):
			fmt.Fprint(w, `{"ok":true,"result":[]}`)
		default:
			http.Error(w, `{"ok":false}`, 404)
		}
	}))
	defer bot.Close()
	tokenFile, conf, state := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-api-url %s\n", tokenFile, bot.URL)), 0o600)
	os.MkdirAll(state, 0o700)
	a := &app{root: ".", home: home, state: state, data: home, configFiles: []string{conf}}
	row := func() string {
		old := os.Stdout
		rd, wr, _ := os.Pipe()
		os.Stdout = wr
		a.gateway([]string{"status", "--row"})
		wr.Close()
		os.Stdout = old
		b := make([]byte, 4096)
		n, _ := rd.Read(b)
		return strings.TrimSpace(string(b[:n]))
	}

	child := exec.Command(os.Args[0], "-test.run=^TestGatewayPollHealth$", "-test.count=1")
	child.Env = append(os.Environ(), "JG_TEST_SERVE_HOME="+home)
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { child.Process.Kill(); child.Wait() }()

	// Three failed polls in a row (a failed poll waits 5 s before the next) turn the row pending.
	deadline := time.Now().Add(25 * time.Second)
	var got string
	for time.Now().Before(deadline) {
		if got = row(); strings.Contains(got, "polls failed") {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !strings.HasPrefix(got, "pending\t") || !strings.Contains(got, "polls failed") {
		t.Fatalf("with every poll failing the row is %q, want pending naming the failed polls", got)
	}
	rec, _ := os.ReadFile(filepath.Join(state, "captain-chat", "telegram.poll"))
	if f := strings.Split(strings.TrimSpace(string(rec)), "\t"); len(f) < 4 || f[1] == "0" || strings.Contains(string(rec), tok) {
		t.Fatalf("poll record %q: want last-ok, failures in a row (>0), last attempt and the redacted error", rec)
	}

	t.Logf("every poll failing (getUpdates answers 502): the status row reads %q and telegram.poll holds %q", got, strings.TrimSpace(string(rec)))

	// The API recovers: the next poll succeeds, the failures reset and the row stops naming them.
	down = false
	deadline = time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if got = row(); !strings.Contains(got, "polls failed") {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if strings.Contains(got, "polls failed") || !strings.HasPrefix(got, "pending\tin: none") {
		t.Fatalf("after recovery the row is %q, want the ordinary no-legs-yet row", got)
	}
	rec, _ = os.ReadFile(filepath.Join(state, "captain-chat", "telegram.poll"))
	if f := strings.Split(strings.TrimSpace(string(rec)), "\t"); len(f) < 3 || f[1] != "0" {
		t.Fatalf("poll record %q after recovery: want 0 failures in a row", rec)
	}
	t.Logf("after the API recovered: the status row reads %q and telegram.poll holds %q (0 failures in a row)", got, strings.TrimSpace(string(rec)))
}
