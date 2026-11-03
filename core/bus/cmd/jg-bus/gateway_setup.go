package main

// gateway_setup.go holds what the guided bring-your-own-bot setup needs to handle a bot token: a
// hidden read and a private write. Every user makes their own bot, so nothing here names a bot or a
// person.

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

// readSecret reads one line from in. On a terminal the line is not echoed, and the terminal is put
// back as it was, also when the user interrupts. If echo cannot be turned off it refuses rather than
// show a secret. A pipe has nothing to hide and is read as it is. The secret goes through no argv.
func readSecret(in *os.File) (string, error) {
	stty := func(args ...string) ([]byte, error) {
		c := exec.Command("stty", args...)
		c.Stdin = in
		return c.Output()
	}
	if saved, err := stty("-g"); err == nil {
		if _, err := stty("-echo"); err != nil {
			return "", fmt.Errorf("cannot turn off terminal echo: %v", err)
		}
		restore := func() { _, _ = stty(strings.TrimSpace(string(saved))) }
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		done := make(chan struct{})
		go func() {
			select {
			case <-sig:
				restore()
				fmt.Fprintln(os.Stderr)
				os.Exit(130)
			case <-done:
			}
		}()
		defer func() { signal.Stop(sig); close(done); restore(); fmt.Fprintln(os.Stderr) }()
	}
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && line == "" {
		return "", fmt.Errorf("no token was entered")
	}
	return strings.TrimSpace(line), nil
}

// writeToken stores the token in a new mode-600 file and renames it over the old one, so the token
// is never in a file others can read, not even for a moment.
func writeToken(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".new"
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.WriteString(token + "\n"); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err = f.Close(); err == nil {
		err = os.Rename(tmp, path)
	}
	return err
}
