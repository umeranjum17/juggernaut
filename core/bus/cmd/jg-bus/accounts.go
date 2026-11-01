package main

import (
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
	account := func(name, cred string) {
		fmt.Fprintf(&b, "  %s {\n", name)
		fmt.Fprintf(&b, "    jetstream: { max_mem: 64Mb, max_file: 512Mb }\n")
		fmt.Fprintf(&b, "    users: [ { user: %s, password_file: %s } ]\n", name, cred)
		fmt.Fprintf(&b, "  }\n")
	}
	fmt.Fprintf(&b, "system_account: SYS\n\naccounts {\n")
	account("SYS", sysCred)
	for _, home := range homes {
		name := homeAccount(filepath.Base(home))
		cred := filepath.Join(a.runtime, name+".pass")
		if err := writeCredential(cred); err != nil {
			return die("cannot write %s: %v", cred, err)
		}
		account(name, cred)
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
