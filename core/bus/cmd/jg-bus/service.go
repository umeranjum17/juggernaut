package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// startOne starts one service from its file, logs it beside its pid, and says so. A
// service that is already running is left alone.
func (a *app) startOne(quiet bool, name string, argv ...string) {
	if _, running := a.runningPid(name); running {
		if !quiet {
			say("%s: already running", name)
		}
		return
	}
	logPath := filepath.Join(a.runtime, name+".log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		say("%s: cannot write %s", name, logPath)
		return
	}
	defer logFile.Close()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = a.runtime
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		say("%s: did not start: %v", name, err)
		return
	}
	pid := cmd.Process.Pid
	_ = cmd.Process.Release()
	_ = os.WriteFile(filepath.Join(a.runtime, name+".pid"), []byte(fmt.Sprintf("%d\n", pid)), 0o644)
	if !quiet {
		say("%s: started (%d), log %s", name, pid, logPath)
	}
}

// daprArgv and ntfyArgv are the one argv each service starts with, shared by `serve`
// and the unit, so a detached start and a supervised one run the same command.
func (a *app) daprArgv(path string) []string {
	return []string{path,
		"--app-id", a.cfgOr("dapr-app-id", ""),
		"--dapr-http-port", a.cfgOr("dapr-http-port", ""),
		"--dapr-grpc-port", a.cfgOr("dapr-grpc-port", ""),
		"--enable-metrics=false",
		"--resources-path", a.daprResources()}
}

// daprResources is the component directory the sidecar loads. The server refuses an empty
// user once accounts exist, so when this home has credentials the component is copied into
// the runtime directory with them in its address; otherwise the shipped directory is used.
func (a *app) daprResources() string {
	shipped := filepath.Dir(a.busFile("dapr/components/pubsub.yaml"))
	auth := a.natsAuth()
	if auth == nil {
		return shipped
	}
	dir := filepath.Join(a.runtime, "dapr")
	text := readFileString(filepath.Join(shipped, "pubsub.yaml"))
	bare := strings.TrimPrefix(a.cfgOr("nats-url", ""), "nats://")
	text = regexp.MustCompile(`(?m)^(\s*value:\s*)"nats://[^"]*"`).ReplaceAllString(text,
		`${1}"nats://`+auth[1]+`:`+auth[3]+`@`+bare+`"`)
	if os.MkdirAll(dir, 0o700) != nil || os.WriteFile(filepath.Join(dir, "pubsub.yaml"), []byte(text), 0o600) != nil {
		return shipped
	}
	return dir
}

func (a *app) ntfyArgv(path string) []string {
	return []string{path, "serve", "-c", a.busFile("ntfy.yml")}
}

// streamName is the JetStream stream the shipped config file names.
func (a *app) streamName() string {
	m := regexp.MustCompile(`"name"[ \t]*:[ \t]*"([^"]*)"`).FindStringSubmatch(readFileString(a.root + "/core/bus/stream.json"))
	if m == nil {
		return ""
	}
	return m[1]
}

func readFileString(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}

// ensureStream creates the stream from its file when it is not there. It needs the
// nats client; without it the event record still holds every event, so this is a
// reported skip, not a stop.
func (a *app) ensureStream() error {
	if _, err := exec.LookPath("nats"); err != nil {
		return err
	}
	url := a.cfgOr("nats-url", "")
	name := a.streamName()
	auth := a.natsAuth()
	if err := exec.Command("nats", append(auth, "-s", url, "stream", "info", name)...).Run(); err == nil {
		return nil
	}
	logFile, err := os.Create(filepath.Join(a.runtime, "stream.log"))
	if err != nil {
		return err
	}
	defer logFile.Close()
	cmd := exec.Command("nats", append(auth, "-s", url, "stream", "add", "--config",
		filepath.Join(a.root, "core", "bus", "stream.json"))...)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	return cmd.Run()
}

// natsAuth is the client login for this home's account when the machine's accounts file
// exists (the unit's server refuses an empty user), and nothing for a bare server.
func (a *app) natsAuth() []string {
	name := homeAccount(filepath.Base(a.home))
	pass := strings.TrimSpace(readFileString(filepath.Join(a.runtime, name+".pass")))
	if pass == "" {
		return nil
	}
	return []string{"--user", name, "--password", pass}
}

// streamExists is the read-only check: 0 when the stream is on the server, else 1.
func (a *app) streamExists() int {
	args := append(a.natsAuth(), "-s", a.cfgOr("nats-url", ""), "stream", "info", a.streamName())
	if exec.Command("nats", args...).Run() != nil {
		return 1
	}
	return 0
}

// busListening reports whether anything answers on the configured address, which is
// the `> /dev/tcp/host/port` probe this path has always used.
func busListening(raw string) bool {
	address, ok := hostPort(raw)
	if !ok {
		return false
	}
	conn, err := net.DialTimeout("tcp", address, 300*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// hostPort reads the dial address out of a configured bus URL, so a value that is not
// one never turns into a dial attempt on something else.
func hostPort(raw string) (string, bool) {
	rest := raw
	if i := strings.Index(rest, "://"); i >= 0 {
		rest = rest[i+3:]
	}
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		rest = rest[:i]
	}
	if rest == "" {
		return "", false
	}
	if _, _, err := net.SplitHostPort(rest); err == nil {
		return rest, true
	}
	return net.JoinHostPort(rest, "4222"), true
}

// waitPort is the same probe in a bounded loop, which is how `serve` waits for the
// server it just started.
func waitPort(url string) bool {
	for i := 0; i < 100; i++ {
		if busListening(url) {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

// bootstrap creates the stream when it is missing and says one line either way.
func (a *app) bootstrap() int {
	name := a.streamName()
	// The unit runs this right after it forks the server, so wait for the port first.
	if !waitPort(a.cfgOr("nats-url", "")) {
		say("stream: %s not created, the server is not listening on %s", name, a.cfgOr("nats-url", ""))
		return 1
	}
	if _, err := exec.LookPath("nats"); err != nil {
		say("stream: not created, no nats client on PATH (the event record still holds every event)")
		return 0
	}
	if err := a.ensureStream(); err == nil {
		say("stream: %s ready", name)
	} else {
		say("stream: %s not created, see %s", name, filepath.Join(a.runtime, "stream.log"))
	}
	return 0
}

// ensure starts the server when it is not listening and creates the stream, then says
// one line. It is idempotent, and it starts nothing but the server: the sidecar and
// ntfy stay opt-in.
func (a *app) ensure() int {
	natsURL := a.cfgOr("nats-url", "")
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	if _, err := exec.LookPath("nats-server"); err != nil {
		say("bus: down, no nats-server on PATH")
		return 0
	}
	if !busListening(natsURL) {
		a.startOne(true, "nats", "nats-server", "-c", a.busFile("nats.conf"))
		if !waitPort(natsURL) {
			say("bus: down, the server did not listen on %s; see %s", natsURL,
				filepath.Join(a.runtime, "nats.log"))
			return 0
		}
	}
	if err := a.ensureStream(); err == nil {
		say("bus: up %s stream %s", natsURL, a.streamName())
	} else {
		say("bus: up %s, stream %s missing (no nats client, or the server refused; see %s)",
			natsURL, a.streamName(), filepath.Join(a.runtime, "stream.log"))
	}
	return 0
}

// serve starts the three services from their files. A service whose binary is missing
// is named and not started; the others still run, because the record never depends on
// them.
func (a *app) serve() int {
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	natsURL := a.cfgOr("nats-url", "")
	if _, err := exec.LookPath("nats-server"); err == nil {
		a.startOne(false, "nats", "nats-server", "-c", a.busFile("nats.conf"))
		if waitPort(natsURL) {
			say("nats: listening on %s", natsURL)
			a.bootstrap()
		} else {
			say("nats: did not start; see %s", filepath.Join(a.runtime, "nats.log"))
		}
	} else {
		say("nats: not started, no nats-server on PATH")
	}
	if path, err := exec.LookPath("daprd"); err == nil {
		a.startOne(false, "dapr", a.daprArgv(path)...)
	} else {
		say("dapr: not started, no daprd on PATH")
	}
	if path, err := exec.LookPath("ntfy"); err == nil {
		a.startOne(false, "ntfy", a.ntfyArgv(path)...)
	} else {
		say("ntfy: not started, no ntfy on PATH")
	}
	if self, err := os.Executable(); err == nil {
		a.startOne(false, "deliver", self, "deliver")
	}
	return 0
}

// stop stops the services this home started from their recorded pids.
func (a *app) stop() int {
	for _, name := range []string{"nats", "dapr", "ntfy", "deliver"} {
		pidPath := filepath.Join(a.runtime, name+".pid")
		data, err := os.ReadFile(pidPath)
		if err != nil {
			continue
		}
		var pid int
		if _, err := fmt.Sscanf(strings.TrimSpace(string(data)), "%d", &pid); err == nil {
			if err := syscall.Kill(pid, syscall.SIGTERM); err == nil {
				say("%s: stopped", name)
			}
		}
		_ = os.Remove(pidPath)
	}
	return 0
}
