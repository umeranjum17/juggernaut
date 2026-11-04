package main

// gateway_voice.go runs every outgoing Telegram text through the captain voice file. The rules
// live in markdown that bin/jg-voice.py reads at run time, so this file holds no word lists.
// The check steps aside: a missing checker, a failed run or a slow one sends the text as written,
// because a style layer must never stop a message to the captain.

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// voiceText returns text as the voice file says it should go out (channel "telegram").
func voiceText(text string) string {
	root := os.Getenv("JG_BUS_ROOT")
	if root == "" {
		root = os.Getenv("JG_ROOT_OVERRIDE")
	}
	if root == "" || strings.TrimSpace(text) == "" {
		return text
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "python3", filepath.Join(root, "bin", "jg-voice.py"), "apply", "--channel", "telegram")
	cmd.Stdin = strings.NewReader(text)
	out, err := cmd.Output()
	if err != nil || len(out) == 0 {
		return text
	}
	return string(out)
}
