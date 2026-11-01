package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// accounts prints the account block of the machine's one server: one account per
// home, each with its own user, its own credentials file and its own
// jg.<home>.> prefix. No home exports or imports anything, so an account can
// publish and read only its own subjects, and a home that is not listed here has
// no way onto the server at all. core/bus/accounts.conf documents the shape.
func (a *app) accounts(args []string) int {
	homes := args
	if len(homes) == 0 {
		homes = []string{a.home}
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
	for _, home := range homes {
		name := homeAccount(filepath.Base(home))
		cred := filepath.Join(a.runtime, name+".pass")
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
// config carries is one of these per account, because a server whose global cap is
// smaller than the sum of its account reservations refuses to start JetStream
// ("insufficient storage resources available", 10047).
const (
	accountMemStore  = 64
	accountFileStore = 512
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
