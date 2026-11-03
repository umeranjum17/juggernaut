package main

// gateway_setup.go owns `jg-bus gateway setup`, the guided bring-your-own-bot path. Every user makes
// their own bot, so nothing here names a bot or a person. It runs only when the user types it:
// install and session start never call it.

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// tokenShape is what BotFather hands out: digits, a colon, then letters, digits, "_" and "-".
var tokenShape = regexp.MustCompile(`^[0-9]+:[A-Za-z0-9_-]+$`)

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

// setup walks the user from "no bot" to "bot paired to me": BotFather steps, a hidden token paste,
// a getMe check, the token file, then slice 3's pairing by first private message.
func (a *app) setup(in *os.File) int {
	say(`Connect your own Telegram bot (about 2 minutes). Nothing is shared: the bot is yours.
  1. In Telegram, open @BotFather and send /newbot.
  2. Choose a name, then a username that ends in "bot".
  3. BotFather answers with a token. Copy it.
If this home's gateway service is running, stop it first.`)
	old, file, present, oldErr := a.readTokenFile()
	keep := present && oldErr == nil
	if keep {
		say("A token is already stored at %s. Press Enter alone to keep it, or paste a new one to replace it.", file)
	}
	fmt.Fprint(os.Stderr, "Paste the token (nothing shows as you type): ")
	token, err := readSecret(in)
	if err != nil {
		return die("gateway setup: %v", err)
	}
	switch {
	case token == "" && keep:
		token = old
	case token == "":
		return die("gateway setup: no token was entered")
	case !tokenShape.MatchString(token):
		return die("gateway setup: that is not a bot token (digits, a colon, then letters and digits); copy it again from BotFather")
	}
	ad := &telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token, wait: 30 * time.Second, sleep: time.Sleep}
	who, err := ad.Probe(context.Background())
	if err != nil {
		return die("gateway setup: Telegram did not accept the token (%v); nothing was saved", err)
	}
	if token != old {
		if err := writeToken(a.tokenPath(), token); err != nil {
			return die("gateway setup: cannot store the token: %v", redact(err.Error(), token))
		}
	}
	if _, _, _, err := a.readTokenFile(); err != nil {
		return die("gateway setup: %v", err)
	}
	say("bot: %s answered getMe; token stored at %s (mode 600)", who, file)
	say("Now open https://t.me/%s and press Start. This step records you as the owner.", strings.TrimPrefix(who, "@"))
	if rc := a.pair(ad); rc != 0 {
		return rc
	}
	if m := a.channelMode(); m != "live" {
		say("note: channel mode is %q; the gateway stays off until it is live", m)
	}
	say("Next: run bin/jg-stack.sh up to start the gateway service.")
	return 0
}
