package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// accounts prints the account block of the machine's one server: one account per
// home, each with its own user, its own credentials file and its own
// jg.<home>.> prefix. No home exports or imports anything, so an account can
// publish and read only its own subjects, and a home that is not listed here has
// no way onto the server at all. core/bus/accounts.conf documents the shape.
//
// The account is named after the home's unique id and never after its folder:
// every Squad Lead home folder can share one basename, so a basename names no
// home. Main and every other home take home-<12 hex of the sha256 of the home's
// resolved absolute path>; a registered Squad Lead takes its registry id. The set
// is the homes named on the command line (this home when none) plus Main and every
// entry in data/squad_leads.md. Two homes that land on one account name are
// refused with one line naming both.
func (a *app) accounts(args []string) int {
	named, code := a.accountNames(args)
	if code != 0 {
		return code
	}
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	sysCred := filepath.Join(a.runtime, "sys.pass")
	if err := writeCredential(sysCred); err != nil {
		return die("cannot write %s: %v", sysCred, err)
	}
	var b strings.Builder
	account := func(name, cred string, withStream bool) bool {
		password, err := os.ReadFile(cred)
		if err != nil {
			die("cannot read %s: %v", cred, err)
			return false
		}
		fmt.Fprintf(&b, "  %s {\n", name)
		if withStream {
			fmt.Fprintf(&b, "    jetstream: { max_mem: %dMb, max_file: %dMb }\n", accountMemStore, accountFileStore)
		}
		fmt.Fprintf(&b, "    users: [ { user: %s, password: %q } ]\n", name, strings.TrimSpace(string(password)))
		fmt.Fprintf(&b, "  }\n")
		return true
	}
	fmt.Fprintf(&b, "system_account: SYS\n\naccounts {\n")
	if !account("SYS", sysCred, false) {
		return 1
	}
	for _, h := range named {
		name := h.name
		cred := a.credentialPath(h)
		if err := os.MkdirAll(filepath.Dir(cred), 0o755); err != nil {
			return die("cannot create %s", filepath.Dir(cred))
		}
		migrateBasenameCredential(filepath.Dir(cred), name, h.path, named)
		if err := writeCredential(cred); err != nil {
			return die("cannot write %s: %v", cred, err)
		}
		if !account(name, cred, true) {
			return 1
		}
	}
	fmt.Fprintf(&b, "}\n")
	fmt.Print(b.String())
	return 0
}

// busHome is one home on the server: its resolved path and its account name.
type busHome struct{ path, name string }

// registryHomeRe anchors on the structured suffix of a data/squad_leads.md line,
// the same one bin/jg-squad-lead-registry-lib.sh parses.
var registryHomeRe = regexp.MustCompile(`^- ([A-Za-z0-9._-]+) - .+ \((?:host:[^;)]*;\s*root:[^;)]*;\s*)?home:\s*([^;)]*);\s*scope:.*;\s*projects:[^;)]*;\s*added\s+\d{4}-\d{2}-\d{2}\)\s*$`)

// resolveHome makes a home path absolute and symlink-free, so one home has one
// name however it was spelled.
func resolveHome(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		path = abs
	}
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	return filepath.Clean(path)
}

// registeredHomes reads Main's Squad Lead registry: resolved home path -> id.
func (a *app) registeredHomes() map[string]string {
	data := os.Getenv("JG_DATA_OVERRIDE")
	if data == "" {
		data = filepath.Join(a.home, "data")
	}
	raw, err := os.ReadFile(filepath.Join(data, "squad_leads.md"))
	if err != nil {
		raw, _ = os.ReadFile(filepath.Join(data, "secondmates.md"))
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		if m := registryHomeRe.FindStringSubmatch(line); m != nil && strings.TrimSpace(m[2]) != "" {
			out[resolveHome(strings.TrimSpace(m[2]))] = m[1]
		}
	}
	return out
}

// homeID is a home's unique id: its registered Squad Lead id, else a stable hash
// of its resolved absolute path.
func homeID(path string, registered map[string]string) string {
	if id, ok := registered[path]; ok {
		return id
	}
	sum := sha256.Sum256([]byte(path))
	return "home-" + hex.EncodeToString(sum[:])[:12]
}

// accountNames lists every home that gets an account, sorted by account name, and
// refuses a name two homes share.
func (a *app) accountNames(args []string) ([]busHome, int) {
	registered := a.registeredHomes()
	paths := map[string]bool{}
	for _, p := range append(append([]string{}, args...), a.home) {
		paths[resolveHome(p)] = true
	}
	for p := range registered {
		paths[p] = true
	}
	var out []busHome
	byName := map[string]string{"SYS": "the system account"}
	for p := range paths {
		out = append(out, busHome{p, homeAccount(homeID(p, registered))})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].path < out[j].path })
	for _, h := range out {
		if other, ok := byName[h.name]; ok {
			return nil, die("homes %s and %s both map to bus account %q; rename one Squad Lead id", other, h.path, h.name)
		}
		byName[h.name] = h.path
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out, 0
}

// migrateBasenameCredential moves an install made before accounts were named by
// home id: its <folder>.pass becomes the new account's credentials, once, and only
// when no other home shares that folder name (a shared name never named one home,
// so its password is not any home's to inherit).
func migrateBasenameCredential(runtime, name, path string, all []busHome) {
	newCred := filepath.Join(runtime, name+".pass")
	if _, err := os.Stat(newCred); err == nil {
		return
	}
	base := homeAccount(filepath.Base(path))
	oldCred := filepath.Join(runtime, base+".pass")
	if base == name {
		return
	}
	for _, h := range all {
		if h.path != path && homeAccount(filepath.Base(h.path)) == base {
			return
		}
	}
	raw, err := os.ReadFile(oldCred)
	if err != nil || os.WriteFile(newCred, raw, 0o600) != nil {
		return
	}
	_ = os.Remove(oldCred)
	fmt.Fprintf(os.Stderr, "jg-bus: bus account %q migrated to %q for %s (re-run `jg-bus.sh unit` and restart jg-bus.service)\n", base, name, path)
}

// homeAccount: the account name for a home, which is also its subject prefix
// (jg.<name>.>): only characters a NATS subject can carry.
func homeAccount(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	if b.Len() == 0 {
		return "home"
	}
	return b.String()
}

// writeCredential creates a home's credentials file once and never rewrites it,
// so a running server and its client keep agreeing on the password.
func writeCredential(path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(base64.RawURLEncoding.EncodeToString(raw)+"\n"), 0o600)
}

// Reservation one home's account may use, in Mb. The machine-wide budget the merged
// config carries covers one of these per account in the accounts file plus headroom
// for the next home, because a server whose global cap is smaller than the sum of its
// account reservations refuses to start JetStream ("insufficient memory resources",
// 10028, or "insufficient storage resources available", 10047). See jetstreamLimits.
const (
	accountMemStore  = 64
	accountFileStore = 512
	// limitsHeadroom is the number of accounts' worth of budget kept above what the
	// accounts file reserves, so adding one home does not need a server restart to fit.
	limitsHeadroom = 1
)

// machineHomes: this home plus every sibling home that has a state directory, which
// is the set one machine-wide server carries an account for.
func (a *app) machineHomes() []string {
	homes := []string{a.home}
	entries, err := os.ReadDir(filepath.Dir(a.home))
	if err != nil {
		return homes
	}
	for _, entry := range entries {
		sibling := filepath.Join(filepath.Dir(a.home), entry.Name())
		if sibling == a.home {
			continue
		}
		if st, err := os.Stat(filepath.Join(sibling, "state")); err == nil && st.IsDir() {
			homes = append(homes, sibling)
		}
	}
	return homes
}

// unitAccounts writes the machine's accounts file, which the unit's server config
// carries. It covers every home that has a state directory beside this one, so one
// unit serves the whole machine.
func (a *app) unitAccounts(path string, homes []string) error {
	out := captureStdout(func() int { return a.accounts(homes) })
	if out == "" {
		return fmt.Errorf("no accounts were produced")
	}
	return os.WriteFile(path, []byte(out), 0o600)
}

// captureStdout runs one command with stdout captured, so its text can be written
// to a file instead of a terminal.
func captureStdout(run func() int) string {
	old := os.Stdout
	read, write, err := os.Pipe()
	if err != nil {
		return ""
	}
	os.Stdout = write
	done := make(chan string)
	go func() {
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(read)
		done <- buf.String()
	}()
	code := run()
	os.Stdout = old
	_ = write.Close()
	text := <-done
	if code != 0 {
		return ""
	}
	return text
}

// myAccount is the ONE place a client learns who it is on the server: this home's
// account name and the credentials file the accounts block was written from. The
// server's block (accounts), `account`, the stream client, the sidecar login and the
// shell key-value library (bin/jg-kv-lib.sh asks `account`) all come through here, so a
// rename of the account scheme cannot reach the server and miss a client again (the
// 415 rename did exactly that: the server was named by home id, the clients by folder).
func (a *app) myAccount() (name, cred string, err error) {
	named, code := a.accountNames(nil)
	if code != 0 {
		return "", "", fmt.Errorf("account names are ambiguous")
	}
	me := resolveHome(a.home)
	for _, h := range named {
		if h.path == me {
			return h.name, a.credentialPath(h), nil
		}
	}
	return "", "", fmt.Errorf("no account for %s", me)
}

// credentialPath is where one home's password lives: in that home's own state
// directory, so the home's client and the machine's one accounts file read the same
// file whichever home generated the server config. This home uses its resolved
// runtime directory; a sibling home with a state directory uses its own; a home with
// none here (a registered Squad Lead elsewhere) falls back to this home's.
func (a *app) credentialPath(h busHome) string {
	file := h.name + ".pass"
	if h.path == resolveHome(a.home) {
		return filepath.Join(a.runtime, file)
	}
	if st, err := os.Stat(filepath.Join(h.path, "state")); err == nil && st.IsDir() {
		return filepath.Join(h.path, "state", "bus", file)
	}
	return filepath.Join(a.runtime, file)
}

// account prints this home's account name, which is also its user and the middle of
// its jg.<name>.> prefix, then its credentials file, so a client connects as itself.
func (a *app) account() int {
	name, cred, err := a.myAccount()
	if err != nil {
		return die("%v", err)
	}
	fmt.Printf("%s\t%s\n", name, cred)
	return 0
}
