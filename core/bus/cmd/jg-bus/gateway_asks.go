package main

// Ask outcomes are reconciled from durable sources, not wake acknowledgments.
// `gateway asks` is the read-only JSON projection. The gateway reconciles it without Main.
// Receipt transitions (one owner, deliverAsk): pending -> sending -> sent; an API refusal
// becomes failed and can retry; a lost response or restart during sending becomes ambiguous
// and is never blindly resent. A new source digest is a new outcome, never an old receipt.
// Sources are this home and its local Squad Lead homes (gateway_ask_homes.go); every receipt
// and origin note stays in this home. Missing origins, primary chat (which has no outbound
// adapter), unreadable homes and unsafe/missing reports remain explicit in the projection.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"time"
)

type askOutcome struct {
	Ticket, Note, Key, Text, Report, Digest, Problem, SourceError string
	Home                                                          string `json:",omitempty"`
	Delivery                                                      string
	Parts                                                         map[string]string
	src                                                           askHome
}

var askNote = regexp.MustCompile(`(?:owner-words:|approved-by-captain:)\s*note:([A-Za-z0-9._-]+)`)
var askChat = regexp.MustCompile(`^\[chat ([a-z-]+) ([^]:]+):([^]]+)\]`)

func (a *app) askPath(key string) string {
	return filepath.Join(a.state, "captain-chat", "ask-outcomes", key+".json")
}

func (a *app) homeAsks(h askHome) ([]askOutcome, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(a.root, "bin", "jg-fleet-snapshot.sh"), "--contribution-input")
	cmd.Env = h.env()
	var diagnostic bytes.Buffer
	cmd.Stderr = &diagnostic
	raw, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ask source read: %w: %s", err, strings.TrimSpace(diagnostic.String()))
	}
	var snap struct {
		Backlog struct {
			Present bool
			Records []struct {
				ID, Ask, State, Title string
				BodyLines             []string `json:"body_lines"`
				ReportPath            string   `json:"report_path"`
			}
		}
	}
	if err := json.Unmarshal(raw, &snap); err != nil {
		return nil, err
	}
	if !snap.Backlog.Present {
		return nil, errors.New("ask backlog is unavailable")
	}
	var out []askOutcome
	for _, row := range snap.Backlog.Records {
		if row.Ask != "ask" {
			continue
		}
		o := askOutcome{Ticket: row.ID, Home: h.ID, Delivery: "pending", Parts: map[string]string{}, src: h}
		body := strings.Join(row.BodyLines, "\n")
		if m := askNote.FindStringSubmatch(body); m != nil {
			o.Note = m[1]
		}
		if strings.HasPrefix(row.ID, "captain-ask-") {
			o.Note = strings.TrimPrefix(row.ID, "captain-ask-")
		}
		// Task metadata binds aliases; after teardown the canonical task id remains readable.
		task := strings.ReplaceAll(row.ID, ".", "-")
		metas, _ := filepath.Glob(filepath.Join(h.state, "*.meta"))
		for _, p := range metas {
			b, _ := os.ReadFile(p)
			if strings.Contains("\n"+string(b), "\nticket="+row.ID+"\n") {
				task = strings.TrimSuffix(filepath.Base(p), ".meta")
				break
			}
		}
		status, _ := os.ReadFile(filepath.Join(h.state, task+".status"))
		lines := strings.Split(strings.TrimSpace(string(status)), "\n")
		last := lines[len(lines)-1]
		o.Text = "Recorded result (release state unverified):\n" + last
		terminal := row.State == "done" || strings.HasPrefix(last, "failed ") || strings.HasPrefix(last, "failed:")
		report := filepath.Join(h.data, task, "report.md")
		if row.ReportPath != "" {
			report = filepath.Join(h.home, row.ReportPath)
		}
		draft, readErr := os.ReadFile(report)
		hash := fmt.Sprintf("%x", sha256.Sum256(draft))
		ready, _ := os.ReadFile(filepath.Join(h.state, "recon-ready", task))
		handoff, _ := os.ReadFile(filepath.Join(h.data, task, "handoff.tsv"))
		accepted := strings.Fields(strings.TrimSpace(string(handoff)))
		valid := len(accepted) >= 6 && accepted[len(accepted)-4] == "accepted" && accepted[len(accepted)-3] == hash
		if readErr == nil && len(draft) > 0 && (valid || len(accepted) == 0 && strings.TrimSpace(string(ready)) == hash) {
			o.Report = report
			o.Text = "Your report is ready: " + row.Title + ". The report is attached."
			terminal = true
		} else if (row.ReportPath != "" || readErr == nil) && terminal {
			o.SourceError = "the current report has no matching acceptance"
		}
		if !terminal {
			continue
		}
		if strings.TrimSpace(last) == "" && o.Report == "" {
			o.Text = "Your ask was closed: " + row.Title + ". No final result is recorded."
		}
		if row.State == "done" {
			closures, _ := os.ReadFile(filepath.Join(h.data, "captain-closures.md"))
			for _, line := range strings.Split(string(closures), "\n") {
				if f := strings.SplitN(line, "\t", 3); len(f) == 3 && f[1] == row.ID {
					o.Text, o.Report = "Your ask was closed: "+row.Title+".\n"+f[2], ""
				}
			}
		}
		o.Digest = hash
		o.Key = fmt.Sprintf("%x", sha256.Sum256([]byte(h.keyTag()+row.ID+"\x00"+o.Note+"\x00"+o.Text+"\x00"+hash)))
		if b, err := os.ReadFile(a.askPath(o.Key)); err == nil {
			var saved askOutcome
			if json.Unmarshal(b, &saved) != nil || saved.Parts == nil || saved.Key != o.Key {
				return nil, fmt.Errorf("invalid ask receipt %s", o.Key)
			}
			o.Delivery, o.Parts, o.Problem = saved.Delivery, saved.Parts, saved.Problem
		}
		out = append(out, o)
	}
	return out, nil
}

func (a *app) saveAsk(o *askOutcome) error {
	b, err := json.Marshal(o)
	if err != nil {
		return err
	}
	p := a.askPath(o.Key)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(p+".tmp", b, 0o600); err != nil {
		return err
	}
	return os.Rename(p+".tmp", p)
}

func (a *app) deliverAsk(ad Adapter, o *askOutcome) error {
	if o.Delivery == "sent" || o.Delivery == "ambiguous" || o.Delivery == "unreadable" {
		return nil
	}
	if o.Delivery == "sending" {
		o.Delivery, o.Problem = "ambiguous", "the process stopped during a send; check the chat before retrying"
		return a.saveAsk(o)
	}
	fail := func(why string) error { o.Delivery, o.Problem = "failed", why; return a.saveAsk(o) }
	if o.SourceError != "" {
		return fail(o.SourceError)
	}
	var note []byte
	for _, dir := range []string{"inbox", "inbox/handled"} {
		if o.Note != "" {
			note, _ = os.ReadFile(filepath.Join(a.state, dir, o.Note+".note"))
		}
		if len(note) > 0 {
			break
		}
	}
	_, body, _ := strings.Cut(string(note), "\n--\n")
	origin := askChat.FindStringSubmatch(body)
	if origin == nil {
		return fail("no captain chat origin is recorded")
	}
	if origin[1] != ad.Name() {
		return fail("no outbound adapter for the " + origin[1] + " origin")
	}
	allowed := strings.FieldsFunc(a.cfgOr("telegram-allow-user", ""), func(r rune) bool { return r == ',' || r == ' ' })
	if !slices.Contains(allowed, origin[2]) {
		return fail("the origin is no longer an allowed owner chat")
	}
	w := where{origin[2], origin[3]}
	var attachments []string
	if o.Report != "" {
		for _, v := range a.attachmentVetters(o.src) {
			if _, why := v.vetAttachment(ad.Out(), o.Report); why != "" {
				return fail(why)
			}
		}
		b, err := os.ReadFile(o.Report)
		if err != nil || fmt.Sprintf("%x", sha256.Sum256(b)) != o.Digest {
			return fail("the report changed or cannot be read; this acceptance cannot deliver it")
		}
		frozen := filepath.Join(filepath.Dir(a.askPath(o.Key)), o.Key, "report.md")
		if err := os.MkdirAll(filepath.Dir(frozen), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(frozen, b, 0o600); err != nil {
			return err
		}
		attachments = []string{frozen}
	}
	parts := a.replyParts(ad, w, "ask:"+o.Key, o.Text, attachments, false)
	for _, p := range parts {
		if o.Parts[p.key] != "" {
			continue
		}
		o.Delivery, o.Problem = "sending", ""
		if err := a.saveAsk(o); err != nil {
			return err
		}
		id, err := ad.Send(context.Background(), p.out)
		if err != nil {
			var se *sendError
			o.Delivery, o.Problem = "ambiguous", err.Error()
			if errors.As(err, &se) {
				o.Delivery = "failed"
			}
			return a.saveAsk(o)
		}
		if id == "" || id == "0" {
			o.Delivery, o.Problem = "ambiguous", "the platform returned no message id"
			return a.saveAsk(o)
		}
		o.Parts[p.key], o.Delivery = id, "pending"
		if err := a.saveAsk(o); err != nil {
			return err
		}
	}
	o.Delivery, o.Problem = "sent", ""
	return a.saveAsk(o)
}

func (a *app) followAskOutcomes(ad Adapter) error {
	// The kernel releases the per-home send lock on a crash, including --once races.
	dir := filepath.Join(a.state, "captain-chat")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "ask-send.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	rows, err := a.askSources()
	if err != nil {
		return err
	}
	for i := range rows {
		if err := a.deliverAsk(ad, &rows[i]); err != nil {
			return err
		}
	}
	return nil
}

func (a *app) gatewayAsks() int {
	rows, err := a.askSources()
	if err != nil {
		return die("asks: %v", err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(rows); err != nil {
		return die("asks: %v", err)
	}
	return 0
}
