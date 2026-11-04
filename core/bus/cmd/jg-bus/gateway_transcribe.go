package main

// Voice notes: an audio or video note the owner sends is turned into words on this machine and the
// words go in the filed note as a "transcript:" line. No audio leaves the machine. The engine is
// optional; with none installed the gateway does exactly what it did before (bin/jg-chat-transcribe.sh).

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const wavBytesPerSecond = 32000 // 16 kHz, mono, 16 bit

// engine is the program that turns a wav into words on stdout. chat-transcribe-cmd names one; else
// the engine that `bin/jg-chat-transcribe.sh setup` installed. ok is false when neither exists.
func (a *app) engine() (argv []string, ok bool) {
	if c := a.cfgOr("chat-transcribe-cmd", ""); c != "" {
		return []string{c}, true
	}
	if _, err := os.Stat(filepath.Join(a.state, "captain-chat", "stt", "hex")); err == nil {
		return []string{filepath.Join(a.root, "bin", "jg-chat-transcribe.sh"), "run"}, true
	}
	return nil, false
}

func (a *app) seconds(key string, def int) int {
	if n, err := strconv.Atoi(a.cfgOr(key, "")); err == nil && n > 0 {
		return n
	}
	return def
}

// transcript returns the words in one stored audio or video file as the note's line, and the words
// alone (empty when there are none). It never fails the message: a missing engine, a timeout or a
// bad file is a line that says so. Only fixed reasons reach the log, never the words.
func (a *app) transcript(f mediaFile, argv []string) (line, text string) {
	limit, maxSec := time.Duration(a.seconds("chat-transcribe-timeout", 120))*time.Second, a.seconds("chat-transcribe-max-seconds", 300)
	fail := func(why string) (string, string) {
		a.noteFailure("gateway transcript", why)
		return "transcript: unavailable (" + why + ")", ""
	}
	dir, err := os.MkdirTemp(filepath.Join(a.state, "captain-chat"), ".stt-")
	if err != nil {
		return fail("no scratch space")
	}
	defer os.RemoveAll(dir)
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	wav := filepath.Join(dir, "in.wav")
	if _, err := runTool(ctx, nil, "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", f.Path, "-vn", "-t", strconv.Itoa(maxSec),
		"-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav); err != nil {
		return fail(reason(ctx, err, "ffmpeg", "the audio could not be read", limit))
	}
	out, err := runTool(ctx, a.homeEnv(), argv[0], append(argv[1:], wav)...)
	if err != nil {
		return fail(reason(ctx, err, "the engine", "the engine failed", limit))
	}
	if text = strings.Join(strings.Fields(string(out)), " "); text == "" { // one line: no word can add a line to the note
		return fail("no speech found")
	}
	text = clampChars(text, 8000)
	if info, err := os.Stat(wav); err == nil && info.Size() >= int64(maxSec)*wavBytesPerSecond {
		return fmt.Sprintf("transcript (first %d s only, the limit): %s", maxSec, text), text
	}
	return "transcript: " + text, text
}

// homeEnv names this home to the installed engine, which keeps its files in the home's state.
func (a *app) homeEnv() []string {
	return []string{"JG_HOME=" + a.home, "JG_STATE_OVERRIDE=" + a.state}
}

// reason is the fixed sentence for a failure: it never carries what the program printed.
func reason(ctx context.Context, err error, who, other string, limit time.Duration) string {
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return fmt.Sprintf("timed out after %d s", int(limit.Seconds()))
	case errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist):
		return who + " is not installed"
	}
	return other
}

// runTool starts one program in its own process group, so a timeout stops its children too.
func runTool(ctx context.Context, env []string, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if env != nil {
		cmd.Env = append(os.Environ(), env...)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	return cmd.Output()
}
