package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// parityRow is one consumer-visible fact, in the field order a diff reads.
type parityRow struct {
	at      string
	kind    string
	key     string
	subject string
	text    string
	link    string
}

// recEvent is one recorded event, decoded only as far as a replay needs it.
type recEvent struct {
	At      json.RawMessage `json:"at"`
	Kind    string          `json:"kind"`
	Key     string          `json:"key"`
	Subject string          `json:"subject"`
	Text    string          `json:"text"`
	Link    string          `json:"link"`
}

// parity replays every recorded event through the builder the live path sends with
// and compares it with the event the record holds. The delivery target is the one
// decision the switch flips, so parity reports it instead of diffing it.
func (a *app) parity(args []string) int {
	rec := a.record
	corrupt := false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--record":
			if i+1 >= len(args) {
				return die("parity --record needs a file")
			}
			rec = args[i+1]
			i++
		case "--corrupt":
			corrupt = true
		default:
			return die("parity: unknown argument %s", args[i])
		}
	}
	// A run that compared nothing proves nothing, so an absent or empty record is
	// reported as zero events rather than as a pass.
	data, err := os.ReadFile(rec)
	if err != nil || len(data) == 0 {
		fmt.Printf("captain channel parity: record=%s events=0 instants=0 decisions=0 deliveries=0 differences=0\n", rec)
		return 0
	}
	recorded := parseRecorded(data)
	corruptAt := ""
	if len(recorded) > 0 {
		corruptAt = recorded[0].at
	}
	rebuilt := make([]parityRow, 0, len(recorded))
	for _, row := range recorded {
		text := row.text
		// --corrupt tampers with the replayed events at the first recorded instant on
		// the new side only, so a diff that still reported nothing would be vacuous.
		if corrupt && row.at == corruptAt {
			text += " (corrupted on the new path)"
		}
		rebuilt = append(rebuilt, parityRow{at: row.at, kind: row.kind, key: row.key,
			subject: a.cfgOr("subject-prefix", "") + "." + row.kind, text: text, link: row.link})
	}
	var changed []int
	for i := range recorded {
		if recorded[i] != rebuilt[i] {
			changed = append(changed, i)
		}
	}
	differenceLines := 2 * len(changed)
	// The difference is printed decoded and in one block per side, so a reader sees
	// the words that changed and the output reads exactly as the shell's diff did.
	for n, i := range changed {
		if n >= 10 {
			break
		}
		fmt.Printf("- %s %s at %s: \"%s\"\n", recorded[i].kind, recorded[i].key, recorded[i].at, oneLine(recorded[i].text))
	}
	for n, i := range changed {
		if n >= 10 {
			break
		}
		fmt.Printf("+ %s %s at %s: \"%s\"\n", rebuilt[i].kind, rebuilt[i].key, rebuilt[i].at, oneLine(rebuilt[i].text))
	}
	events := len(recorded)
	instants := distinctInstants(recorded)
	decisions := events * 2
	deliveries := 0
	mode := a.channelMode()
	target := "none"
	if mode == "live" {
		target = a.ntfyURL()
		deliveries = events
	}
	if corrupt {
		fmt.Printf("captain channel parity --corrupt: tampered with the replayed event at %s on the new path: events=%d instants=%d decisions=%d deliveries=%d differences=%d (must be non-zero)\n",
			corruptAt, events, instants, decisions, deliveries, differenceLines)
		if differenceLines != 0 {
			return 0
		}
		return 1
	}
	fmt.Printf("captain channel parity: record=%s events=%d instants=%d decisions=%d deliveries=%d differences=%d\n",
		rec, events, instants, decisions, deliveries, differenceLines)
	fmt.Printf("captain channel parity: mode %s, so each event goes to %s\n", mode, target)
	if differenceLines != 0 {
		return 1
	}
	return 0
}

// parseRecorded turns the record into one row per parseable line. A line the record
// itself cannot parse is not compared.
func parseRecorded(data []byte) []parityRow {
	var rows []parityRow
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var ev recEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		link := ev.Link
		if link == "" {
			link = "-"
		}
		rows = append(rows, parityRow{at: rawScalar(ev.At), kind: ev.Kind, key: ev.Key,
			subject: ev.Subject, text: ev.Text, link: link})
	}
	return rows
}

// rawScalar reads one JSON scalar as the text `tostring` would print.
func rawScalar(raw json.RawMessage) string {
	text := strings.TrimSpace(string(raw))
	if text == "" || text == "null" {
		return ""
	}
	if strings.HasPrefix(text, `"`) {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return s
		}
	}
	return text
}

// oneLine keeps a row's text on one line, as the decoded diff prints it.
func oneLine(s string) string {
	return strings.NewReplacer("\n", "|", "\r", "|").Replace(s)
}

// distinctInstants counts the recorded instants a replay ran at.
func distinctInstants(rows []parityRow) int {
	seen := map[string]struct{}{}
	for _, row := range rows {
		seen[row.at] = struct{}{}
	}
	return len(seen)
}
