package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// The captain's ntfy topic is reachable over the tailnet, so the shipped ntfy.yml denies
// every anonymous request. Two logins exist, made once by the bus owner (`ntfy-provision`,
// run by bin/jg-stack.sh up after ntfy starts), each with the one right on the one topic:
//
//	juggernaut  write-only  what `deliver` posts with
//	captain     read-only   what his iPad subscribes with
//
// Their passwords live in the owner's state/bus as ntfy-<user>.pass (0600), generated here,
// never in a tracked file. A server config with no auth-file is an open local server, as
// before: nothing is provisioned and the delivery sends no login.
const (
	ntfyPublisher = "juggernaut"
	ntfyReader    = "captain"
)

func (a *app) ntfyPassFile(user string) string {
	return filepath.Join(a.runtime, "ntfy-"+user+".pass")
}

// ntfyAuthHeader is the value of the publisher's Authorization header, or "" when no login was provisioned.
func (a *app) ntfyAuthHeader() string {
	pass := strings.TrimSpace(readFileString(a.ntfyPassFile(ntfyPublisher)))
	if pass == "" {
		return ""
	}
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(ntfyPublisher+":"+pass))
}

// ntfyHasAuth is true when the server config in force names an auth-file.
func (a *app) ntfyHasAuth() bool {
	return regexp.MustCompile(`(?m)^auth-file:`).MatchString(readFileString(a.busFile("ntfy.yml")))
}

// ntfyCLI runs one `ntfy` server command against the config in force, from the runtime
// directory so the config's relative auth-file is the one the server reads.
func (a *app) ntfyCLI(password string, args ...string) (string, error) {
	cmd := exec.Command("ntfy", args...)
	cmd.Dir = a.runtime
	cmd.Env = append(os.Environ(), "NTFY_CONFIG_FILE="+a.busFile("ntfy.yml"), "NTFY_PASSWORD="+password)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// provisionUser makes one login with one right on the topic, once. It keeps the password
// already on disk, so a second run changes nothing; a login the database lost is made again.
func (a *app) provisionUser(user, right string) error {
	topic := a.cfgOr("ntfy-topic", "")
	file := a.ntfyPassFile(user)
	pass := strings.TrimSpace(readFileString(file))
	listed, _ := a.ntfyCLI("", "user", "list")
	known := regexp.MustCompile(`(?m)^user ` + regexp.QuoteMeta(user) + ` `).MatchString(listed)
	if known && pass != "" {
		return nil
	}
	if pass == "" {
		raw := make([]byte, 18)
		if _, err := rand.Read(raw); err != nil {
			return err
		}
		pass = hex.EncodeToString(raw)
		if err := os.WriteFile(file, []byte(pass+"\n"), 0o600); err != nil {
			return err
		}
	}
	verb := "add"
	if known {
		verb = "change-pass"
	}
	if out, err := a.ntfyCLI(pass, "user", verb, user); err != nil {
		return fmt.Errorf("ntfy user %s %s: %s", verb, user, detail(out))
	}
	if out, err := a.ntfyCLI("", "access", user, topic, right); err != nil {
		return fmt.Errorf("ntfy access %s %s: %s", user, topic, detail(out))
	}
	return nil
}

// ntfyProvision is `jg-bus ntfy-provision`: the owner's one-time login setup. It says one
// line naming what the captain's iPad needs: the server, the topic, the login and the file
// holding its password.
func (a *app) ntfyProvision() int {
	if _, err := exec.LookPath("ntfy"); err != nil {
		return die("ntfy-provision needs ntfy on PATH")
	}
	if !a.ntfyHasAuth() {
		say("ntfy: the config in force has no auth-file, so the server is open and no login is made")
		return 0
	}
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	for _, l := range [][2]string{{ntfyPublisher, "write-only"}, {ntfyReader, "read-only"}} {
		if err := a.provisionUser(l[0], l[1]); err != nil {
			return die("%v", err)
		}
	}
	say("ntfy: logins ready for topic %s at %s: publisher %s, captain %s (password in %s)",
		a.cfgOr("ntfy-topic", ""), a.cfgOr("ntfy-server", ""), ntfyPublisher, ntfyReader, a.ntfyPassFile(ntfyReader))
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
