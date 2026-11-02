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

// natsCommand builds one client call against <url>. This home's own account
// credentials go in the environment, never on the argument list, because the machine
// runs one account per home and a client that connects as the empty user is refused
// with an authorization violation.
func (a *app) natsCommand(url string, rest ...string) *exec.Cmd {
	cmd := exec.Command("nats", append([]string{"-s", url}, rest...)...)
	if user, pass, ok := a.credentials(); ok {
		cmd.Env = append(os.Environ(), "NATS_USER="+user, "NATS_PASSWORD="+pass)
	}
	return cmd
}

// credentials: this home's account name and the password the machine's accounts file
// carries for it, from the one resolver the server's block also uses (myAccount).
func (a *app) credentials() (string, string, bool) {
	name, cred, err := a.myAccount()
	if err != nil {
		return "", "", false
	}
	data, err := os.ReadFile(cred)
	if err != nil {
		return "", "", false
	}
	pass := strings.TrimSpace(string(data))
	if pass == "" {
		return "", "", false
	}
	return name, pass, true
}

// machineConfig renders the machine's one server config: the base config in force
// with a JetStream budget sized for the accounts the accounts file actually carries,
// plus the accounts file. It is a single file with no includes, which is what `unit`
// runs. It refuses, with the shortfall named, to return a config whose global caps
// sit below what its accounts reserve: that server would never start JetStream.
func (a *app) machineConfig() (string, error) {
	base := readFileString(a.busFile("nats.conf"))
	if strings.TrimSpace(base) == "" {
		return "", fmt.Errorf("no server config at %s", a.busFile("nats.conf"))
	}
	accounts := readFileString(filepath.Join(a.runtime, "accounts.conf"))
	if strings.TrimSpace(accounts) == "" {
		return "", fmt.Errorf("no accounts at %s", filepath.Join(a.runtime, "accounts.conf"))
	}
	header := "# Written by bin/jg-bus.sh unit: the server config in force plus this machine's\n" +
		"# accounts, in one file. Regenerated on every run; edit the sources, not this.\n"
	config := header + withStoreCaps(base, countReservations(accounts)) + "\n" + accounts
	if err := checkLimits(config); err != nil {
		return "", err
	}
	return config, nil
}

// jetstreamLimits is the machine-wide JetStream budget, in Mb, for <accounts> accounts
// that each reserve accountMemStore and accountFileStore: one reservation per account
// plus limitsHeadroom more.
func jetstreamLimits(accounts int) (memMb, fileMb int) {
	if accounts < 0 {
		accounts = 0
	}
	n := accounts + limitsHeadroom
	return accountMemStore * n, accountFileStore * n
}

// jsReservation matches one account's JetStream reservation in the accounts block.
var jsReservation = regexp.MustCompile(`jetstream:\s*\{\s*max_mem:\s*(\d+\s*\w+)\s*,\s*max_file:\s*(\d+\s*\w+)\s*\}`)

// countReservations is the number of accounts in an accounts file that reserve
// JetStream, which is what the machine budget is sized from: the file the server will
// load, not a count taken somewhere else.
func countReservations(accounts string) int {
	return len(jsReservation.FindAllString(accounts, -1))
}

// parseMb reads a NATS size such as 64Mb, 1Gb or 512MB into Mb.
func parseMb(raw string) (int, bool) {
	m := regexp.MustCompile(`^(\d+)\s*([KkMmGgTt])[Bb]?$`).FindStringSubmatch(strings.TrimSpace(raw))
	if m == nil {
		return 0, false
	}
	var n int
	if _, err := fmt.Sscanf(m[1], "%d", &n); err != nil {
		return 0, false
	}
	switch strings.ToUpper(m[2]) {
	case "K":
		return n / 1024, true
	case "M":
		return n, true
	case "G":
		return n * 1024, true
	}
	return n * 1024 * 1024, true
}

// checkLimits refuses a server config whose global JetStream caps are below the sum of
// its accounts' reservations, or that has no caps or no accounts to size against. It
// reads the finished text, so it also catches a base config the cap rewrite did not
// reach. `jg-bus check-limits <config>` runs it on any file.
func checkLimits(config string) error {
	var needMem, needFile, accounts int
	for _, m := range jsReservation.FindAllStringSubmatch(config, -1) {
		mem, okM := parseMb(m[1])
		file, okF := parseMb(m[2])
		if !okM || !okF {
			return fmt.Errorf("bus: refusing the server config: an account reserves %q / %q, which is not a size", m[1], m[2])
		}
		needMem, needFile, accounts = needMem+mem, needFile+file, accounts+1
	}
	if accounts == 0 {
		return fmt.Errorf("bus: refusing the server config: it has no account that reserves JetStream")
	}
	haveMem, haveFile, err := globalCaps(config)
	if err != nil {
		return err
	}
	if haveMem < needMem || haveFile < needFile {
		return fmt.Errorf("bus: refusing the server config: %d accounts reserve %dMb memory and %dMb storage, but the server caps are %dMb and %dMb; the server would not start JetStream (insufficient resources, 10028/10047)",
			accounts, needMem, needFile, haveMem, haveFile)
	}
	return nil
}

// globalCaps reads max_mem_store and max_file_store of the config's jetstream block.
func globalCaps(config string) (memMb, fileMb int, err error) {
	loc := jetstreamBlock.FindStringIndex(config)
	if loc == nil {
		return 0, 0, fmt.Errorf("bus: refusing the server config: it has no jetstream block")
	}
	block := config[loc[0]:loc[1]]
	read := func(key string) (int, error) {
		m := regexp.MustCompile(`(?m)^[ \t]*` + key + `[ \t]*[:=]?[ \t]*(\S+)`).FindStringSubmatch(block)
		if m == nil {
			return 0, fmt.Errorf("bus: refusing the server config: its jetstream block has no %s", key)
		}
		mb, ok := parseMb(m[1])
		if !ok {
			return 0, fmt.Errorf("bus: refusing the server config: %s %q is not a size", key, m[1])
		}
		return mb, nil
	}
	if memMb, err = read("max_mem_store"); err != nil {
		return 0, 0, err
	}
	fileMb, err = read("max_file_store")
	return memMb, fileMb, err
}

// checkLimitsCommand: `check-limits <config>` exits 1 naming the shortfall.
func (a *app) checkLimitsCommand(args []string) int {
	if len(args) != 1 {
		return die("usage: jg-bus check-limits <server-config>")
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return die("cannot read %s: %v", args[0], err)
	}
	if err := checkLimits(string(raw)); err != nil {
		return die("%v", err)
	}
	say("limits: ok, the caps in %s cover every account", args[0])
	return 0
}

// jetstreamBlock is the JetStream stanza of a server config.
var jetstreamBlock = regexp.MustCompile(`(?s)jetstream[ \t]*[:=]?[ \t]*\{.*?\}`)

// withStoreCaps sets the config's machine-wide JetStream budget for <accounts>
// accounts (jetstreamLimits), keeping every other key the base wrote (store_dir above
// all).
func withStoreCaps(base string, accounts int) string {
	memMb, fileMb := jetstreamLimits(accounts)
	mem := fmt.Sprintf("max_mem_store: %dMb", memMb)
	file := fmt.Sprintf("max_file_store: %dMb", fileMb)
	loc := jetstreamBlock.FindStringIndex(base)
	if loc == nil {
		return base + fmt.Sprintf("\njetstream {\n  store_dir: \"./jetstream\"\n  %s\n  %s\n}\n", mem, file)
	}
	block := base[loc[0]:loc[1]]
	for _, caps := range []struct {
		re   *regexp.Regexp
		line string
	}{
		{regexp.MustCompile(`(?m)^[ \t]*max_mem_store:.*$`), mem},
		{regexp.MustCompile(`(?m)^[ \t]*max_file_store:.*$`), file},
	} {
		if caps.re.MatchString(block) {
			block = caps.re.ReplaceAllLiteralString(block, "  "+caps.line)
			continue
		}
		open := strings.Index(block, "{")
		if open < 0 {
			continue
		}
		block = block[:open+1] + "\n  " + caps.line + block[open+1:]
	}
	return base[:loc[0]] + block + base[loc[1]:]
}

// unitPath is where this home's systemd user service lives.
func unitPath(name string) (string, bool) {
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", false
		}
		config = filepath.Join(home, ".config")
	}
	return filepath.Join(config, "systemd", "user", name), true
}

// unitName is the unit this home installs. It is one per machine, so a test or a lab
// home names its own rather than replacing the machine's live bus.
func unitName() string {
	if name := os.Getenv("JG_BUS_UNIT"); name != "" {
		return name
	}
	return "jg-bus.service"
}

// haveUserManager: 0 when systemctl can reach a user manager, which is what makes a
// unit the right owner of the server.
func haveUserManager() bool {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return false
	}
	return exec.Command("systemctl", "--user", "show-environment").Run() == nil
}

// installService makes this home's bus a running service, once: the unit is written
// when it is missing or names another home, systemd is reloaded, and the unit is
// enabled now, so the server comes back after a reboot instead of waiting for someone
// to start it by hand. Without a user manager it falls back to `ensure`, which starts
// the same server detached from the home's state directory. It says exactly one line
// and never fails its caller: a home whose bus cannot start still has to come up.
func (a *app) installService() int {
	if _, err := exec.LookPath("nats-server"); err != nil {
		say("bus: cannot start, no nats-server on PATH (install: bin/jg-bootstrap.sh install nats-server nats)")
		return 0
	}
	if !haveUserManager() {
		return a.ensure()
	}
	name := unitName()
	// The server loads its accounts once, so a config that gained or lost an account
	// needs a restart to take effect; an unchanged one never restarts the shared bus.
	confBefore := readFileString(filepath.Join(a.runtime, "bus.conf"))
	text, err := a.buildUnit("nats")
	if err != nil {
		say("bus: cannot start, %v", err)
		return 0
	}
	confChanged := readFileString(filepath.Join(a.runtime, "bus.conf")) != confBefore
	path, ok := unitPath(name)
	if !ok {
		say("bus: cannot start, no home directory for the systemd user unit")
		return 0
	}
	installed := false
	if current, err := os.ReadFile(path); err != nil || string(current) != text {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			say("bus: cannot start, %v", err)
			return 0
		}
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			say("bus: cannot start, %v", err)
			return 0
		}
		if out, err := exec.Command("systemctl", "--user", "daemon-reload").CombinedOutput(); err != nil {
			say("bus: cannot start, systemctl --user daemon-reload failed: %s", detail(string(out)))
			return 0
		}
		installed = true
	}
	wasActive := exec.Command("systemctl", "--user", "is-active", "--quiet", name).Run() == nil
	if out, err := exec.Command("systemctl", "--user", "enable", "--now", name).CombinedOutput(); err != nil {
		say("bus: cannot start %s: %s", name, detail(string(out)))
		return 0
	}
	if wasActive && confChanged {
		if out, err := exec.Command("systemctl", "--user", "restart", name).CombinedOutput(); err != nil {
			say("bus: cannot restart %s for its new accounts: %s", name, detail(string(out)))
			return 0
		}
	}
	if exec.Command("systemctl", "--user", "is-active", "--quiet", name).Run() != nil {
		say("bus: %s did not stay active; see: systemctl --user status %s", name, name)
		return 0
	}
	if installed {
		say("bus: installed and started, systemd user service %s for %s (%s)", name, a.home, a.cfgOr("nats-url", ""))
		return 0
	}
	say("bus: up, systemd user service %s for %s (%s)", name, a.home, a.cfgOr("nats-url", ""))
	return 0
}

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
	if a.natsCommand(url, "stream", "info", name).Run() == nil {
		return nil
	}
	logFile, err := os.Create(filepath.Join(a.runtime, "stream.log"))
	if err != nil {
		return err
	}
	defer logFile.Close()
	cmd := a.natsCommand(url, "stream", "add", "--config",
		filepath.Join(a.root, "core", "bus", "stream.json"))
	cmd.Stdout, cmd.Stderr = logFile, logFile
	return cmd.Run()
}

// natsAuth is the client login for this home's account when its credentials exist (the
// unit's server refuses an empty user), and nothing for a bare server.
func (a *app) natsAuth() []string {
	name, pass, ok := a.credentials()
	if !ok {
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
