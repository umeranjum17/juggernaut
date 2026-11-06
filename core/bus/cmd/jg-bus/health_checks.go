package main

// health_checks.go holds the health run's other tests (the memory budget, the wake engine and the
// watcher, the temporary disk) and the systemd units that run it every 60 seconds.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const (
	budgetWarnPercent = 80
	diskWarnPercent   = 85
)

// consumerFindings fails a service whose durable consumer does not exist on its stream: the engine or the
// watcher then reads nothing, and its unit can still be active.
func (a *app) consumerFindings() []finding {
	var failed []finding
	// The messages go to the owner's chat, which refuses internal words, so a member is named plainly.
	for _, name := range []string{"wake-engine", "wake-watcher"} {
		var p *part
		var err error
		plain := map[string]string{"wake-engine": "notification engine", "wake-watcher": "monitoring loop"}[name]
		if name == "wake-engine" {
			p, err = a.wakePart()
		} else {
			p, err = a.wakeWatcherPart()
		}
		if err != nil {
			failed = append(failed, finding{plain, "it cannot find its server address: " + detail(err.Error())})
			continue
		}
		if _, errText, err := p.nats("--timeout", "5s", "consumer", "info", p.stream, p.name, "--json"); err != nil {
			failed = append(failed, finding{plain, "its reader is missing or the server did not answer: " + detail(errText)})
		}
	}
	if _, err := os.Stat(filepath.Join(a.state, ".wake-watcher-degraded")); err == nil {
		failed = append(failed, finding{"monitoring loop", "the loop reports it runs with reduced function"})
	}
	return failed
}

// diskFindings fails when the temporary disk is past diskWarnPercent: writes fail there first.
func (a *app) diskFindings() []finding {
	var st syscall.Statfs_t
	if err := syscall.Statfs(os.TempDir(), &st); err != nil || st.Blocks == 0 {
		return nil
	}
	if pct := int((st.Blocks - st.Bavail) * 100 / st.Blocks); pct > diskWarnPercent {
		return []finding{{os.TempDir(), fmt.Sprintf("the temporary disk is %d%% full", pct)}}
	}
	return nil
}

// budgetFindings warns when the accounts' JetStream reservations pass budgetWarnPercent of the
// server's global caps: the next account that joins by reload can then fail with error 10028.
func (a *app) budgetFindings() []finding {
	dir := filepath.Dir(a.accountsFile())
	conf := withIncludes(readFileString(filepath.Join(dir, "bus.conf")), dir)
	var needMem, needFile int
	for _, m := range jsReservation.FindAllStringSubmatch(conf, -1) {
		mem, _ := parseMb(m[1])
		file, _ := parseMb(m[2])
		needMem, needFile = needMem+mem, needFile+file
	}
	haveMem, haveFile, err := globalCaps(conf)
	if err != nil || haveMem == 0 || haveFile == 0 {
		return []finding{{"caps", "cannot read the JetStream caps from " + filepath.Join(dir, "bus.conf")}}
	}
	if pct := max(needMem*100/haveMem, needFile*100/haveFile); pct > budgetWarnPercent {
		return []finding{{"reservations", fmt.Sprintf("the accounts reserve %d%% of the JetStream caps (%d of %d Mb memory, %d of %d Mb storage); a reload that adds an account can fail with error 10028", pct, needMem, haveMem, needFile, haveFile)}}
	}
	return nil
}

// healthUnit is the oneshot service that runs the check, or its 60 second timer.
func (a *app) healthUnit(timer bool) (string, error) {
	name := strings.TrimSuffix(stackUnit("health"), ".service")
	if timer {
		return "[Unit]\nDescription=Juggernaut bus health run, every 60 seconds\n\n[Timer]\nOnBootSec=60s\nOnUnitActiveSec=60s\nAccuracySec=1s\nUnit=" + name + ".service\n\n[Install]\nWantedBy=timers.target\n", nil
	}
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	q := func(v string) string {
		return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "%", "%%").Replace(v) + `"`
	}
	var b strings.Builder
	fmt.Fprintf(&b, "[Unit]\nDescription=Juggernaut bus health run (one JetStream test per account)\n\n[Service]\nType=oneshot\n")
	fmt.Fprintf(&b, "WorkingDirectory=%s\n", strings.ReplaceAll(a.runtime, "%", "%%"))
	for _, e := range []string{"JG_HOME=" + a.home, "JG_BUS_ROOT=" + a.root, "JG_STATE_OVERRIDE=" + a.state, "PATH=" + os.Getenv("PATH")} {
		fmt.Fprintf(&b, "Environment=%s\n", q(e))
	}
	fmt.Fprintf(&b, "ExecStart=%s health run\n", q(self))
	return b.String(), nil
}

// healthInstall writes both units and starts the timer. Run it only for the machine's bus owner.
func (a *app) healthInstall() int {
	for _, timer := range []bool{false, true} {
		text, err := a.healthUnit(timer)
		if err != nil {
			return die("%v", err)
		}
		name := stackUnit("health")
		if timer {
			name = strings.TrimSuffix(name, ".service") + ".timer"
		}
		path, ok := unitPath(name)
		if !ok {
			return die("no home directory for the systemd user unit")
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return die("%v", err)
		}
		if _, err := writeIfChanged(path, text); err != nil {
			return die("cannot write %s: %v", path, err)
		}
	}
	for _, args := range [][]string{{"daemon-reload"}, {"enable", "--now", strings.TrimSuffix(stackUnit("health"), ".service") + ".timer"}} {
		if out, err := exec.Command("systemctl", append([]string{"--user"}, args...)...).CombinedOutput(); err != nil {
			return die("systemctl %s: %v: %s", args[0], err, detail(string(out)))
		}
	}
	say("health: timer installed and started")
	return 0
}
