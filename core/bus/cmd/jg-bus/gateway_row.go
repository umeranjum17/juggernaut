package main

// gateway_row.go is the migration card's `chat` row: whether the captain's Telegram chat has been
// seen working both ways. The gateway records each leg it completes in roundtrip.tsv; the row reads
// that record, the service heartbeat and one getMe, and never sends a message.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// A leg is one thing the chat must be seen to do. Inbound legs come from the owner and were filed
// as notes; outbound legs were sent with `jg-inbox.sh reply` and accepted by the platform.
var rowIn, rowOut = []string{"text", "image", "file"}, []string{"text", "image", "file"}

const (
	rowWindow    = 7 * 24 * time.Hour
	rowHeartbeat = 2 * time.Minute // `serve` writes its heartbeat at least every 45 s
)

// recordLeg appends `<epoch> TAB <in|out>-<kind> TAB <id>` to roundtrip.tsv. The id is the note's
// (inbound) or the platform's message id (outbound), so a replay counts once.
func (a *app) recordLeg(leg, id string) {
	appendQuiet(filepath.Join(a.state, "captain-chat", "roundtrip.tsv"), fmt.Sprintf("%d\t%s\t%s", time.Now().Unix(), leg, id))
}

// beat tells `gateway status --row` the service is looping.
func (a *app) beat(ad Adapter) {
	_ = os.WriteFile(filepath.Join(a.state, "captain-chat", ad.Name()+".alive"), []byte(strconv.FormatInt(time.Now().Unix(), 10)+"\n"), 0o600)
}

// gatewayRow prints `state TAB detail` for the migration card and always exits 0.
func (a *app) gatewayRow() int {
	row := func(state, format string, args ...any) int {
		fmt.Printf("%s\t%s\n", state, fmt.Sprintf(format, args...))
		return 0
	}
	token, file, present, err := a.readTokenFile()
	if !present || a.channelMode() != "live" || !slices.Contains(strings.Fields(a.cfgOr("gateway-adapters", "telegram")), "telegram") {
		return row("absent", "off: no bot token on this machine; connect your own with jg-bus gateway setup")
	}
	if err != nil {
		return row("pending", "the token file cannot be used: %v", redact(err.Error(), token))
	}
	if info, serr := os.Stat(filepath.Join(a.state, "captain-chat", "telegram.alive")); serr != nil || time.Since(info.ModTime()) > rowHeartbeat {
		return row("pending", "the gateway service is not running (token file %s)", file)
	}
	if _, err := (&telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token}).Probe(context.Background()); err != nil {
		return row("pending", "the bot did not answer getMe: %v", err)
	}
	seen, notes, replies, last := map[string]bool{}, map[string]bool{}, map[string]bool{}, int64(0)
	raw, _ := os.ReadFile(filepath.Join(a.state, "captain-chat", "roundtrip.tsv"))
	for _, l := range strings.Split(string(raw), "\n") {
		f := strings.Split(l, "\t")
		at, perr := strconv.ParseInt(f[0], 10, 64)
		if len(f) != 3 || perr != nil || time.Since(time.Unix(at, 0)) > rowWindow {
			continue
		}
		seen[f[1]], last = true, max(last, at)
		if strings.HasPrefix(f[1], "in-") {
			notes[f[2]] = true
		} else {
			replies[f[2]] = true
		}
	}
	var have, miss [2][]string
	for i, dir := range []string{"in", "out"} {
		for _, kind := range rowIn {
			if seen[dir+"-"+kind] {
				have[i] = append(have[i], kind)
			} else {
				miss[i] = append(miss[i], kind)
			}
		}
	}
	if len(miss[0])+len(miss[1]) == 0 {
		return row("live", "6 of 6 legs, last %s, %d notes, %d replies", time.Unix(last, 0).UTC().Format("2006-01-02"), len(notes), len(replies))
	}
	list := func(s []string) string {
		if len(s) == 0 {
			return "none"
		}
		return strings.Join(s, " ")
	}
	var gaps []string
	for i, dir := range []string{"in", "out"} {
		if len(miss[i]) > 0 {
			gaps = append(gaps, dir+" "+strings.Join(miss[i], " "))
		}
	}
	return row("pending", "in: %s - out: %s - missing %s", list(have[0]), list(have[1]), strings.Join(gaps, ", "))
}
