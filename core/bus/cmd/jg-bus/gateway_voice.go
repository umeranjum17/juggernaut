package main

// gateway_voice.go runs every outgoing Telegram text through the captain voice file. The rules
// live in markdown that bin/jg-voice.py reads at run time, so this file holds no word lists.
// The checker rewrites a message that holds a banned term, or refuses it (exit 1) with a re-draft
// instruction; a refused message is never sent, so the send fails with a 400 that the callers
// already treat as a call that cannot work and record as undelivered. A missing checker or a
// crashed run steps aside and sends the text as written, because a style layer must never stop a
// message to the captain.

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// voiceText returns text as the voice file says it should go out (channel "telegram"). The error
// is a *sendError when the checker refused the text.
func voiceText(text string) (string, error) {
	root := os.Getenv("JG_BUS_ROOT")
	if root == "" {
		root = os.Getenv("JG_ROOT_OVERRIDE")
	}
	if root == "" || strings.TrimSpace(text) == "" {
		return text, nil
	}
	// The checker's own model-rewrite timeout (45s) ends first, so a slow model refuses instead of timing out here.
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "python3", filepath.Join(root, "bin", "jg-voice.py"), "apply", "--channel", "telegram")
	cmd.Stdin = strings.NewReader(text)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return "", &sendError{"voice", 400, strings.TrimSpace(stderr.String())}
	}
	if err != nil || len(out) == 0 {
		return text, nil
	}
	return string(out), nil
}

// boardLinkText gives every bare board link in text the board access token (bin/jg-board-link.sh
// owns the rule). It runs after voiceText, so the token never reaches a model rewrite. A message
// with a bare link and no token to add is refused with a 400, like a voice refusal, and is never
// sent; a missing script or a crashed run sends the text as written, as voiceText does.
func boardLinkText(text string) (string, error) {
	root := os.Getenv("JG_BUS_ROOT")
	if root == "" {
		root = os.Getenv("JG_ROOT_OVERRIDE")
	}
	if root == "" || !strings.Contains(text, "#") {
		return text, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", filepath.Join(root, "bin", "jg-board-link.sh"), "fix")
	cmd.Stdin = strings.NewReader(text)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return "", &sendError{"board-link", 400, strings.TrimSpace(stderr.String())}
	}
	if err != nil {
		return text, nil
	}
	return string(out), nil
}
