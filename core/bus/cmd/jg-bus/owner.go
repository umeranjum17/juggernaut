package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The machine runs ONE bus unit and one server config, and exactly one home owns them:
// the home the installed unit names in its JG_HOME. Every other home on the machine only
// registers its own account in the shared accounts file and asks the running server to
// reload it. It never installs, rewrites or restarts the unit and never rewrites the
// server config. Before this rule every home's session start ran `jg-stack.sh up` and
// every update ran `install-service`, so each one pointed the machine's unit at its own
// config and locked every other home out (authentication error, user empty).

// unitOwner is the home the installed unit belongs to and where its config lives.
type unitOwner struct{ home, runtime string }

// installedOwner reads the machine unit and returns the home it names. ok is false when
// no unit is installed or the unit names no home that still exists, in which case the
// calling home may install it and become the owner.
func (a *app) installedOwner() (unitOwner, bool) {
	path, ok := unitPath(unitName())
	if !ok {
		return unitOwner{}, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return unitOwner{}, false
	}
	var o unitOwner
	for _, line := range strings.Split(string(raw), "\n") {
		switch {
		case strings.HasPrefix(line, "WorkingDirectory="):
			o.runtime = strings.ReplaceAll(strings.TrimPrefix(line, "WorkingDirectory="), "%%", "%")
		case strings.HasPrefix(line, `Environment="JG_HOME=`):
			v := strings.TrimSuffix(strings.TrimPrefix(line, `Environment="JG_HOME=`), `"`)
			v = strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(v, `\"`, `"`), `\\`, `\`), "%%", "%")
			o.home = v
		}
	}
	if o.home == "" || o.runtime == "" {
		return unitOwner{}, false
	}
	if st, err := os.Stat(o.home); err != nil || !st.IsDir() {
		return unitOwner{}, false
	}
	return o, true
}

// foreignOwner is THE decision: the owner of the machine unit when it is another home,
// and false when this home owns it (or may take it, because none is installed). A
// deliberate move of the machine bus to this home sets JG_BUS_TAKE_OWNERSHIP=1.
func (a *app) foreignOwner() (unitOwner, bool) {
	if os.Getenv("JG_BUS_TAKE_OWNERSHIP") == "1" {
		return unitOwner{}, false
	}
	o, ok := a.installedOwner()
	if !ok || resolveHome(o.home) == resolveHome(a.home) {
		return unitOwner{}, false
	}
	return o, true
}

// ownerApp is the owner's view of the machine: its paths and its config overrides.
func (a *app) ownerApp(o unitOwner) *app {
	state := filepath.Dir(o.runtime)
	b := *a
	b.home, b.state, b.runtime = o.home, state, o.runtime
	b.data = filepath.Join(o.home, "data") // the owner's registry, not the joining home's
	b.configFiles = configFilesFor(o.home, a.root)
	return &b
}

// registryFile is the machine's list of member homes: one "<resolved home>\t<state
// directory>" line per home that joined. JG_BUS_HOMES names another file, which is how a
// test or a lab keeps its registrations out of a real machine's list.
func registryFile(runtime string) string {
	if file := os.Getenv("JG_BUS_HOMES"); file != "" {
		return file
	}
	return filepath.Join(runtime, "homes")
}

// labHome is THE decision on whether a home may enter a machine's real registry: a
// throw-away home - one under a system temp root, or inside the checkout running this
// command - is a test fixture, never a member. It names the root that matched.
func labHome(home, root string) (string, bool) {
	for _, temp := range []string{os.TempDir(), "/tmp", "/var/tmp", "/dev/shm"} {
		if temp != "" && withinHome(home, temp) {
			return resolveHome(temp), true
		}
	}
	if root != "" && withinHome(home, root) {
		return resolveHome(root), true
	}
	return "", false
}

// withinHome reports whether path is root itself or below it, both resolved first.
func withinHome(path, root string) bool {
	p, r := resolveHome(path), resolveHome(root)
	return p == r || strings.HasPrefix(p, r+string(filepath.Separator))
}

// registerHome records this home and its state directory in the owner's list of
// machine homes, once, so the owner's accounts file carries it from then on. A lab home
// with no JG_BUS_HOMES is refused: 452 temp and worktree fixture homes had reached a real
// machine's list, because every suite's join landed in the owner's own registry.
func (a *app) registerHome(owner *app) error {
	home := resolveHome(a.home)
	if os.Getenv("JG_BUS_HOMES") == "" {
		if root, lab := labHome(home, a.root); lab {
			return fmt.Errorf("%s is a temporary or test home under %s, so it is never added to the machine registry owned by %s; set JG_BUS_HOMES to a file of its own to register it there", home, root, owner.home)
		}
	}
	file := registryFile(owner.runtime)
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	line := home + "\t" + a.state
	for _, l := range strings.Split(readFileString(file), "\n") {
		if l == line {
			return nil
		}
	}
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintln(f, line)
	return err
}

// registeredStates reads the machine's list of registered homes: resolved home -> state.
func (a *app) registeredStates() map[string]string {
	out := map[string]string{}
	for _, l := range strings.Split(readFileString(registryFile(a.runtime)), "\n") {
		if home, state, ok := strings.Cut(l, "\t"); ok && home != "" && state != "" {
			out[home] = state
		}
	}
	return out
}

// joinMachine is everything a non-owner home does about the machine bus: register its
// account in the owner's shared accounts file and ask the running server to reload it.
// The unit and the server config stay byte for byte as the owner left them. It refuses,
// naming the owner, when the owner's JetStream caps would not cover the new account.
// say receives its one line.
func (a *app) joinMachine(o unitOwner, say func(string, ...any)) int {
	owner := a.ownerApp(o)
	if err := a.registerHome(owner); err != nil {
		say("bus: cannot register this home with the bus owned by %s: %v", o.home, err)
		return 0
	}
	accountsPath := filepath.Join(owner.runtime, "accounts.conf")
	before := readFileString(accountsPath)
	changed, err := owner.writeAccounts(owner.machineHomes())
	if err != nil {
		say("bus: cannot add this home's account to the bus owned by %s: %v", o.home, err)
		return 0
	}
	if changed {
		conf := readFileString(filepath.Join(owner.runtime, "bus.conf"))
		if err := checkLimits(conf, owner.runtime); err != nil {
			_ = os.WriteFile(accountsPath, []byte(before), 0o600)
			say("%v; the bus is owned by %s: run `bin/jg-bus.sh install-service` there to raise the caps, then run this again", err, o.home)
			return 0
		}
		name := unitName()
		if exec.Command("systemctl", "--user", "is-active", "--quiet", name).Run() == nil {
			if out, err := exec.Command("systemctl", "--user", "kill", "--kill-whom=main", "--signal=HUP", name).CombinedOutput(); err != nil {
				say("bus: added this home's account but could not reload %s: %s", name, detail(string(out)))
				return 0
			}
		}
	}
	state := "already in"
	if changed {
		state = "added to"
	}
	say("bus: this home's account is %s the shared accounts of the bus owned by %s; this home does not own or change %s (to move the bus here, set JG_BUS_TAKE_OWNERSHIP=1 once)", state, o.home, unitName())
	return 0
}

// owner is `jg-bus owner`: exit 0 and "self" when this home owns the machine's bus unit (or
// may take it, because none is installed), exit 3 and the owner's home when another does.
// bin/jg-stack.sh asks it before it installs or starts any part that is one per machine.
func (a *app) owner() int {
	if o, foreign := a.foreignOwner(); foreign {
		fmt.Println(o.home)
		return 3
	}
	fmt.Println("self")
	return 0
}
