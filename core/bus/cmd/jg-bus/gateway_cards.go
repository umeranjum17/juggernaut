package main

// gateway_cards.go keeps a captain decision card in step between the board and the owner's chat.
// A card event with options is sent with one inline button per option. A tap answers the card the
// way a text reply does (a reply event the router takes to the board) and the message is edited to
// show the answer. An answer on the board (a `card-close` event with an answer), a text reply, or a
// withdrawn card edits the same message and removes the buttons. A changed card (the same key
// published again with other text or options) edits it in place. state/captain-chat/cards.jsonl
// maps each card to its chat message; the last line of a card wins, so a restart loses nothing.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
)

// cardOption is one answer a card offers: the value the board stores and the label on the button.
type cardOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// cardMsg is one card's message. State is open, answered or withdrawn. Rev counts the changes the
// message should show and Shown the last one the chat took, so a failed edit is found and tried again.
type cardMsg struct {
	Card, Hash, Chat, Message, Text, Note, State string
	Options                                      []cardOption
	At                                           int64 // the event that last set Text and Options
	Rev, Shown                                   int
}

// cardFooter tells the owner how to answer; the buttons go with it, so an answered card drops both.
const cardFooter = "\n\nTap an option to answer, or reply to this message."

func (a *app) cardsFile() string { return filepath.Join(a.state, "captain-chat", "cards.jsonl") }

// cards is the latest line of every card; a card is named by its key, and a tap by a short hash of it
// so the button's data stays far under Telegram's 64 bytes.
func (a *app) cards() map[string]cardMsg {
	all := map[string]cardMsg{}
	readLines(a.cardsFile(), func(c cardMsg) { all[c.Card] = c })
	return all
}

func (a *app) saveCard(c cardMsg) error { return appendLine(a.cardsFile(), toJSON(c)) }

func cardHash(card string) string {
	sum := sha256.Sum256([]byte(card))
	return hex.EncodeToString(sum[:])[:12]
}

// view is what the chat should show for the card now.
func (c cardMsg) view() (string, []Button) {
	text := c.Text
	if c.Note != "" {
		text += "\n\n" + c.Note
	}
	if c.State != "open" {
		return text, nil
	}
	var buttons []Button
	for i, o := range c.Options {
		buttons = append(buttons, Button{o.Label, fmt.Sprintf("c:%s:%d", c.Hash, i)})
	}
	return text + cardFooter, buttons
}

// showCard puts the card's current view in its message and records that it did. A message Telegram
// cannot edit any more (400, 403) is given up on, since trying again cannot change that.
func (a *app) showCard(ad Adapter, c cardMsg) error {
	text, buttons := c.view()
	err := ad.Edit(context.Background(), c.Chat, c.Message, text, buttons)
	var se *sendError
	switch {
	case err == nil || errors.As(err, &se) && se.code == 400 && strings.Contains(se.msg, "not modified"):
	case errors.As(err, &se) && (se.code == 400 || se.code == 403):
		a.noteFailure("gateway card edit", err.Error())
	default:
		return err
	}
	c.Shown = c.Rev
	return a.saveCard(c)
}

// syncCards tries again every edit that did not go through.
func (a *app) syncCards(ad Adapter) {
	for _, c := range a.cards() {
		if c.Shown < c.Rev {
			if err := a.showCard(ad, c); err != nil {
				a.noteFailure("gateway card edit", err.Error())
			}
		}
	}
}

func sameOptions(a, b []cardOption) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// sendCard sends a card with options, or edits the message it already has. A redelivery of the same
// event sends nothing; a card that is no longer open is not opened again.
func (a *app) sendCard(ad Adapter, owner string, ev event) error {
	text := strings.TrimSpace(ev.Text + "\n" + ev.Link)
	if parts := chunks(text, ad.Limit()-len(cardFooter)-200); len(parts) > 0 { // one message, so it can be edited
		text = parts[0]
	}
	if old, ok := a.cards()[ev.Key]; ok {
		switch {
		case old.At == ev.At || old.State != "open" || old.Text == text && sameOptions(old.Options, ev.Options):
			if old.Shown < old.Rev {
				return a.showCard(ad, old)
			}
			return nil
		}
		old.Text, old.Options, old.At, old.Rev = text, ev.Options, ev.At, old.Rev+1
		if err := a.saveCard(old); err != nil {
			return err
		}
		return a.showCard(ad, old)
	}
	c := cardMsg{Card: ev.Key, Hash: cardHash(ev.Key), Chat: owner, Text: text, State: "open", Options: ev.Options, At: ev.At, Rev: 1, Shown: 1}
	body, buttons := c.view()
	id, err := ad.Send(context.Background(), Outbound{Chat: owner, Text: body, Buttons: buttons})
	if err != nil {
		return err
	}
	c.Message = id
	if err := a.saveCard(c); err != nil {
		return err
	}
	// sent.jsonl is how a text reply finds its card.
	return appendLine(filepath.Join(a.state, "captain-chat", "sent.jsonl"), toJSON(map[string]string{
		"key": fmt.Sprintf("ev:card:%s:%d#0", ev.Key, ev.At), "chat": owner, "message": id, "card": ev.Key}))
}

// closeCard handles a card-close event: the board answered the card (ev.Answer) or withdrew it.
func (a *app) closeCard(ad Adapter, ev event) error {
	c, ok := a.cards()[ev.Key]
	switch {
	case !ok:
		return nil
	case c.State == "open" && ev.Answer != "":
		c.State, c.Note = "answered", "Answered on the board: "+ev.Answer
	case c.State == "open":
		c.State, c.Note = "withdrawn", strings.TrimSpace(ev.Text)
		if c.Note == "" {
			c.Note = "This card was withdrawn."
		}
	case c.Shown < c.Rev:
		return a.showCard(ad, c)
	default:
		return nil
	}
	c.Rev++
	if err := a.saveCard(c); err != nil {
		return err
	}
	return a.showCard(ad, c)
}

// closeAnswered marks a card the owner answered by text reply; a failed edit is tried again later.
func (a *app) closeAnswered(ad Adapter, card, words string) {
	c, ok := a.cards()[card]
	if !ok || c.State != "open" {
		return
	}
	if r := []rune(words); len(r) > 200 {
		words = string(r[:200]) + "…"
	}
	c.State, c.Note, c.Rev = "answered", "Answered: "+words, c.Rev+1
	if err := a.saveCard(c); err == nil {
		if err = a.showCard(ad, c); err != nil {
			a.noteFailure("gateway card edit", err.Error())
		}
	}
}

// tapCard handles the owner's tap on a card's button. The reply event goes out before the card is
// marked, so a crash between the two answers the card twice at worst and never loses the answer.
func (a *app) tapCard(ad Adapter, in Inbound) error {
	f := strings.Split(in.Data, ":")
	var c cardMsg
	n := -1
	if len(f) == 3 {
		n, _ = strconv.Atoi(f[2])
		for _, v := range a.cards() {
			if v.Hash == f[1] {
				c = v
			}
		}
	}
	switch {
	case c.Card == "" || c.Chat != in.Chat || c.Message != in.Message || n < 0 || n >= len(c.Options) || c.State == "withdrawn":
		a.answerTap(ad, in, "This card is closed.")
		return nil
	case c.State == "answered":
		a.answerTap(ad, in, "Already answered.")
		return nil
	}
	o := c.Options[n]
	a.emitReply(c.Card, o.Value, o.Label)
	c.State, c.Note, c.Rev = "answered", "Answered: "+o.Label, c.Rev+1
	if err := a.saveCard(c); err != nil {
		return err
	}
	a.answerTap(ad, in, "Answered: "+o.Label)
	if err := a.showCard(ad, c); err != nil { // the answer is out; syncCards tries the edit again
		a.noteFailure("gateway card edit", err.Error())
	}
	return nil
}
