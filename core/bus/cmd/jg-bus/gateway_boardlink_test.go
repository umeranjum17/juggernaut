package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Every Telegram send gives a bare board link its access token, or refuses the message. A link
// that already has the token is left alone. The token never reaches the test output.
func TestGatewayBoardLink(t *testing.T) {
	root, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("JG_BUS_ROOT", root)
	t.Setenv("JG_VOICE_FILE", "")
	t.Setenv("JG_VOICE_REWRITE_CMD", "")
	const secret = "tg-board-secret-7"
	board := "http://100.64.0.1:4420/"
	urlFile := filepath.Join(t.TempDir(), "board.url")
	t.Setenv("JG_SIGNOFF_URL_FILE", urlFile)
	l := newChatLab(t, true)
	ad, _, err := l.a.chatTarget()
	if ad == nil || err != nil {
		t.Fatalf("chat target %v, %v", ad, err)
	}
	ad.sleep = func(time.Duration) {}
	send := func(text string) error {
		_, err := ad.Send(context.Background(), Outbound{Chat: "1", Text: text})
		return err
	}
	last := func() string { return l.sends[len(l.sends)-1]["text"].(string) }

	if err := os.WriteFile(urlFile, []byte(board+"?token="+secret+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := send("The report is ready: " + board + "#reports/card-1 Please read it."); err != nil {
		t.Fatal(err)
	}
	if want := "The report is ready: " + board + "?token=" + secret + "#reports/card-1 Please read it."; last() != want {
		t.Fatal("a bare board link did not get the token")
	}
	t.Log("Telegram send: a bare board link went out with the access token added")
	tokened := "The report is ready: " + board + "?token=" + secret + "#reports/card-1 Please read it."
	if err := send(tokened); err != nil || last() != tokened {
		t.Fatalf("a tokened link must go out unchanged (err %v)", err)
	}
	t.Log("Telegram send: a link that already had the token went out unchanged")

	// No token to add: the send is refused with a plain reason and nothing goes out.
	if err := os.WriteFile(urlFile, []byte(board+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	before := len(l.sends)
	err = send("The report is ready: " + board + "#reports/card-1")
	if err == nil || !strings.Contains(err.Error(), "access token") {
		t.Fatalf("a bare link with no token must be refused with a reason, got %v", err)
	}
	if strings.Contains(err.Error(), secret) || len(l.sends) != before {
		t.Fatal("a refused message must not leak or send anything")
	}
	t.Log("Telegram send: a bare link with no token available was refused and nothing was sent")
}
