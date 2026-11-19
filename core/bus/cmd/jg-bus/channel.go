package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// event is one captain-facing event document. The record, the bus and a replay all
// build the event here, so what went out and what a replay rebuilds cannot drift
// apart. Field order is the record's own, so the bytes read the same way the shell
// wrote them.
type event struct {
	At      int64  `json:"at"`
	Kind    string `json:"kind"`
	Key     string `json:"key"`
	Subject string `json:"subject"`
	Text    string `json:"text"`
	Link    string `json:"link,omitempty"`
	// Media is set by the chat gateway's inbound event only; old events do not have it.
	Media []mediaFile `json:"media,omitempty"`
	// Options is set by a card the owner answers with a tap: one button each. Answer is set by a
	// card-close event for a card the board answered. Old events have neither.
	Options []cardOption `json:"options,omitempty"`
	Answer  string       `json:"answer,omitempty"`
	// Home is the publishing home, set by emitEvent. The chat gateway sends the owner only what a
	// real home published (realHome); an event without it is from before this field and is let through.
	Home string `json:"home,omitempty"`
}

// toJSON renders one value without HTML escaping, so a text with `&` or `<` keeps the
// bytes the shell's builder produced.
func toJSON(v any) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return `""`
	}
	return strings.TrimSuffix(buf.String(), "\n")
}

// eventJSON builds the one event document for a fact.
func (a *app) eventJSON(at int64, kind, key, text, link string, media ...mediaFile) string {
	return toJSON(event{At: at, Kind: kind, Key: key,
		Subject: a.cfgOr("subject-prefix", "") + "." + kind, Text: text, Link: link, Media: media})
}

// appendLine appends one line to a record and reports why when it cannot.
func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintf(f, "%s\n", line)
	return err
}

// appendQuiet appends where a failed write is not the caller's news.
func appendQuiet(path, line string) {
	_ = appendLine(path, line)
}

// detail is a transport failure as one clamped line, which is what the log and the
// undelivered record hold.
func detail(s string) string {
	s = strings.NewReplacer("\n", " ", "\r", " ").Replace(s)
	return clampChars(s, 300)
}

// clampChars keeps at most n characters, by rune as `cut -c` is.
func clampChars(s string, n int) string {
	if n <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// firstLine is the first line of a text, which is what a delivery title holds.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// noteFailure logs one transport failure, once, and never fails its caller.
func (a *app) noteFailure(what, why string) {
	appendQuiet(a.log, fmt.Sprintf("%s failed: %s", what, detail(why)))
}

// noteUndelivered names a delivery that did not arrive, with its error.
func (a *app) noteUndelivered(target, why, doc string) {
	appendQuiet(a.undelivered, fmt.Sprintf(`{"at":%d,"target":%s,"error":%s,"event":%s}`,
		time.Now().Unix(), toJSON(target), toJSON(detail(why)), doc))
}

// publish tees one captain-facing event. It never fails its emitter: both callers are
// the fleet's own delivery paths, so every transport failure is named and the command
// still exits 0.
func (a *app) publish(args []string) int {
	if len(args) < 3 {
		return die("publish needs <kind> <key> <text>")
	}
	kind, key, text := args[0], args[1], args[2]
	link, rest := "", args[3:]
	var options []cardOption
	answer := ""
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case "--option", "--answer":
			if i+1 >= len(rest) || rest[i+1] == "" {
				return die("publish %s needs a value (--option value=label) or the answer (--answer)", rest[i])
			}
			if rest[i] == "--answer" {
				answer = rest[i+1]
			} else {
				v, l, ok := strings.Cut(rest[i+1], "=")
				if !ok { // a bare option is its own label
					l = v
				}
				options = append(options, cardOption{v, l})
			}
			i++
		case "--link":
			if i+1 >= len(rest) {
				return die("publish --link needs a url")
			}
			link = rest[i+1]
			i++
		default:
			return die("publish: unknown flag %s", rest[i])
		}
	}
	return a.emitEvent(event{Kind: kind, Key: key, Text: text, Link: link, Options: options, Answer: answer})
}

// emit is publish for a caller that holds the event's parts, such as the chat gateway's inbound
// event with its stored files. When the bus refuses a card, outcome, alert or digest, the chat
// gateway's adapter sends it in-process, so the owner still hears it.
func (a *app) emit(kind, key, text, link string, media []mediaFile) int {
	return a.emitEvent(event{Kind: kind, Key: key, Text: text, Link: link, Media: media})
}

// emitEvent stamps the event and emits it; the document is the bytes eventJSON builds.
func (a *app) emitEvent(ev event) int {
	ev.At, ev.Subject, ev.Home = time.Now().Unix(), a.cfgOr("subject-prefix", "")+"."+ev.Kind, resolveHome(a.home)
	return a.emitDoc(ev.Kind, toJSON(ev), func() error { return a.sendToChat(ev) })
}

// emitDoc records one event document and delivers it. In `direct` mode, the one mode that delivers,
// fallback sends it through the chat in-process; an event that send did not take is named in the
// undelivered record.
func (a *app) emitDoc(kind, doc string, fallback func() error) int {
	if a.channelMode() == "off" {
		return 0
	}
	subject := a.cfgOr("subject-prefix", "") + "." + kind
	if err := os.MkdirAll(a.state, 0o755); err != nil {
		a.noteFailure("record", err.Error())
	} else if err := appendLine(a.record, doc); err != nil {
		a.noteFailure("record", err.Error())
	}
	if ferr := fallback(); ferr != nil && !isChatEvent(subject) {
		a.noteUndelivered("direct", ferr.Error(), doc)
	}
	return 0
}

// emitReply publishes the owner's answer to a card, in the shape the router reads. When the bus
// refuses it, the board's own route takes it now, which is what the router would have done.
func (a *app) emitReply(card, answer, label string) int {
	reply := map[string]string{"at": time.Now().UTC().Format("2006-01-02T15:04:05Z"), "kind": "reply",
		"key": card, "subject": a.cfgOr("subject-prefix", "") + ".reply", "answer": answer}
	if label != "" {
		reply["label"] = label
	}
	doc := toJSON(reply)
	return a.emitDoc("reply", doc, func() error {
		if code := a.routeReply([]byte(doc)); code != 0 {
			return fmt.Errorf("the board route exited %d", code)
		}
		return nil
	})
}

// reply routes one captain reply event by the rule in force: the board's own route.
func (a *app) reply(args []string) int {
	src := "-"
	if len(args) > 0 {
		src = args[0]
	}
	var data []byte
	var err error
	if src == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		if _, err := os.Stat(src); err != nil {
			return die("no such reply event file: %s", src)
		}
		data, err = os.ReadFile(src)
	}
	if err != nil {
		return die("no reply event: %v", err)
	}
	if strings.TrimSpace(string(data)) == "" {
		return die("no reply event on stdin")
	}
	return a.routeReply(data)
}

// routeReply routes one reply event's JSON; the CLI and the router service both end here.
func (a *app) routeReply(data []byte) int {
	var ev struct {
		Key    string `json:"key"`
		At     string `json:"at"`
		Answer string `json:"answer"`
		Label  string `json:"label"`
	}
	if err := json.Unmarshal(data, &ev); err != nil {
		return die("the reply event is not JSON")
	}
	if ev.Key == "" || ev.Answer == "" {
		return die("a reply event needs a card key and the answer")
	}
	at := ev.At
	if at == "" {
		at = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	cmd := exec.Command(filepath.Join(a.root, "bin", "jg-board-answers.sh"),
		"route-answer", ev.Key, at, ev.Answer, ev.Label)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "JG_HOME="+a.home, "JG_STATE_OVERRIDE="+a.state)
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			return exit.ExitCode()
		}
		return die("the reply could not be routed: %v", err)
	}
	return 0
}

// config prints one key in force, or every key the shipped file carries.
func (a *app) config(args []string) int {
	if len(args) > 0 && args[0] != "" {
		key := args[0]
		v, ok := a.cfg(key)
		if !ok {
			return die("no '%s' in the channel config", key)
		}
		fmt.Printf("%s\n", v)
		return 0
	}
	fmt.Printf("channel config in force:\n")
	f, err := os.Open(filepath.Join(a.root, "defaults", "captain-channel"))
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 || fields[0] != "set" {
			continue
		}
		fmt.Printf("  %-18s %s\n", fields[1], a.cfgOr(fields[1], ""))
	}
	return 0
}

// status reports the mode, the delivery target and what the records hold.
func (a *app) status() int {
	target := "none"
	if a.channelMode() == "direct" {
		target = "chat"
	}
	fmt.Printf("mode %s, delivery %s\n", a.channelMode(), target)
	fmt.Printf("record %s: %d event(s), %d undelivered\n", a.record, countLines(a.record), countLines(a.undelivered))
	return 0
}

// unit prints the systemd user service for the chat gateway, which a home installs once so it is
// up after every boot and restart without anyone typing a command.
func (a *app) unit(args []string) int {
	if len(args) > 0 && args[0] != "gateway" {
		return die("unit: unknown part %q (gateway)", args[0])
	}
	self, err := os.Executable()
	if err != nil {
		return die("cannot find the jg-bus binary: %v", err)
	}
	quote := func(value string) string {
		value = strings.ReplaceAll(value, `\`, `\\`)
		value = strings.ReplaceAll(value, `"`, `\"`)
		value = strings.ReplaceAll(value, "%", "%%")
		return `"` + value + `"`
	}
	percent := func(value string) string { return strings.ReplaceAll(value, "%", "%%") }
	var b strings.Builder
	fmt.Fprintf(&b, "[Unit]\nDescription=Juggernaut captain chat gateway (Telegram text in and out)\nAfter=network.target\n\n")
	fmt.Fprintf(&b, "[Service]\nType=simple\n")
	fmt.Fprintf(&b, "WorkingDirectory=%s\n", percent(a.runtime))
	fmt.Fprintf(&b, "Environment=%s\n", quote("JG_HOME="+a.home))
	fmt.Fprintf(&b, "Environment=%s\n", quote("PATH="+os.Getenv("PATH")))
	fmt.Fprintf(&b, "ExecStart=%s %s %s\n", quote(self), quote("gateway"), quote("serve"))
	fmt.Fprintf(&b, "Environment=%s\n", quote("JG_BUS_ROOT="+a.root))
	fmt.Fprintf(&b, "Environment=%s\n", quote("JG_STATE_OVERRIDE="+a.state))
	fmt.Fprintf(&b, "Restart=always\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n")
	fmt.Print(b.String())
	return 0
}
