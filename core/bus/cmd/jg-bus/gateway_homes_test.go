package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A throwaway test home publishes into the machine's one shared bus, so the owner's chat must not
// believe it. The gateway sends the owner only what a real home published: its own home or a member of
// the machine registry that is not a throw-away location. A test home never joins that registry, so the
// "Keep the unlanded work?" card a test suite raises is refused here, and so is its card-close for a
// real card's key. Cards are published through the real publish path and delivered through the real
// consumer, against a fake Bot API.
func TestGatewayRefusesCardsFromTestHomes(t *testing.T) {
	l := newChatLab(t, true)
	throwaway, machine := t.TempDir(), t.TempDir()
	old := tempRoots
	tempRoots = func() []string { return []string{throwaway} }
	t.Cleanup(func() { tempRoots = old })

	realHome, polluted := filepath.Join(machine, "real-home"), filepath.Join(machine, "polluted-home")
	os.MkdirAll(l.a.state, 0o755)
	l.a.runtime = filepath.Join(machine, "gateway-state", "bus")
	os.MkdirAll(l.a.runtime, 0o755)
	registry := realHome + "\t" + filepath.Join(realHome, "state") + "\n" + // a home that joined
		polluted + "\t" + filepath.Join(throwaway, "state") + "\n" // a line a test left in the list before test homes were refused
	os.WriteFile(filepath.Join(l.a.runtime, "homes"), []byte(registry), 0o600)

	ad, owner, err := l.a.chatTarget()
	if ad == nil || err != nil {
		t.Fatalf("chat target %v, %v", ad, err)
	}
	ad.sleep = func(time.Duration) {}
	p := l.a.gatewayPart(ad, owner)

	// publishAt is a home running `jg-bus publish`; what it records is what the bus carries.
	publishAt := func(home string, args ...string) []byte {
		t.Helper()
		pub := *l.a
		pub.home, pub.state = home, filepath.Join(home, "state")
		pub.record = filepath.Join(pub.state, "captain-channel.jsonl")
		if code := pub.publish(args); code != 0 {
			t.Fatalf("publish %v exited %d", args, code)
		}
		lines := strings.Split(strings.TrimSpace(readFileString(pub.record)), "\n")
		return []byte(lines[len(lines)-1])
	}
	deliver := func(body []byte) {
		t.Helper()
		if err := p.handle(body); err != nil {
			t.Fatal(err)
		}
	}
	card := func(home, key string) []byte {
		return publishAt(home, "card", key, "Keep the unlanded work?", "--option", "yes=Yes", "--option", "no=No")
	}
	testHome := filepath.Join(throwaway, "case", "home")

	// A test home's card, its outcome and its alert reach nobody; the refusal is named in the log.
	deliver(card(testHome, "jg-1a2b3c4d-nm-live"))
	deliver(publishAt(testHome, "outcome", "o-1", "The fix is merged: [full https:// URL]"))
	deliver(publishAt(testHome, "alert", "a-1", "A test alert."))
	if len(l.sends) != 0 || len(l.a.cards()) != 0 {
		t.Fatalf("sends %v, cards %v: want nothing from a test home to reach the owner", l.sends, l.a.cards())
	}
	log := readFileString(l.a.log)
	if !strings.Contains(log, "jg-1a2b3c4d-nm-live") || !strings.Contains(log, "not a registered home") {
		t.Fatalf("log %q: want the refused card named", log)
	}

	// A registered real home and the gateway's own home are heard, and the card is open with its buttons.
	deliver(card(realHome, "real-ask"))
	deliver(card(l.a.home, "own-ask"))
	if len(l.sends) != 2 || l.a.cards()["real-ask"].State != "open" || l.a.cards()["own-ask"].State != "open" {
		t.Fatalf("sends %d, cards %v: want both real cards open in the chat", len(l.sends), l.a.cards())
	}

	// A test home cannot close or change a real card by publishing the same key.
	deliver(publishAt(testHome, "card-close", "real-ask", "withdrawn", "--answer", "No"))
	deliver(publishAt(testHome, "card", "real-ask", "Something else?", "--option", "a=A"))
	if c := l.a.cards()["real-ask"]; c.State != "open" || c.Text != "Keep the unlanded work?" || len(l.sends) != 2 {
		t.Fatalf("card %+v, sends %d: want a test home to leave a real card alone", c, len(l.sends))
	}

	// A registry line left by a test (its state is a throw-away place) is not a real home either.
	deliver(card(polluted, "polluted-ask"))
	if len(l.sends) != 2 || l.a.cards()["polluted-ask"].Card != "" {
		t.Fatalf("sends %d: want a leftover registry line to be refused", len(l.sends))
	}

	// An event from a publisher older than the home field carries no home and is still heard.
	deliver([]byte(`{"at":1000,"kind":"outcome","key":"old-1","subject":"jg.captain.outcome","text":"An older build says hello."}`))
	if len(l.sends) != 3 || l.sends[2]["text"] != "An older build says hello." {
		t.Fatalf("sends %v: want the event with no home sent", l.sends)
	}
}
