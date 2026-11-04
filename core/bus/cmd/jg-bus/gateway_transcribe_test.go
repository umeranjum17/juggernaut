package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The owner sends voice notes, an audio longer than the limit and a round video note against a fake
// Bot API, a real ffmpeg and engines that are small scripts: the words reach the filed note and the
// event, the reaction does not wait for the engine, and a timeout, a missing engine, a failing engine
// an unreadable file and a silent note (the engine's made-up words are dropped) each leave the note filed with a line that says why and prints no words.
func TestGatewayTranscript(t *testing.T) {
	for _, tool := range []string{"python3", "ffmpeg"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip(tool + " is needed")
		}
	}
	root, _ := filepath.Abs("../../../..")
	home := t.TempDir()
	tone := func(secs string) string {
		out := filepath.Join(home, "tone-"+secs+".wav")
		if b, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration="+secs, "-y", out).CombinedOutput(); err != nil {
			t.Fatalf("ffmpeg: %v %s", err, b)
		}
		raw, _ := os.ReadFile(out)
		return string(raw)
	}
	silent := filepath.Join(home, "silence.wav")
	if b, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "1", "-y", silent).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %v %s", err, b)
	}
	silentRaw, _ := os.ReadFile(silent)
	content := map[string]string{"silent": string(silentRaw), "short": tone("1"), "long": tone("5"), "junk": "not audio at all"}
	engineDone := filepath.Join(home, "engine-done")
	script := func(name, body string) string {
		p := filepath.Join(home, name)
		os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0o700)
		return p
	}
	// It checks that it was given a real 16 kHz wav, and finishes only after a moment.
	good := script("good", `head -c 4 "$1" | grep -q RIFF || exit 3
sleep 1
touch `+engineDone+`
printf 'Hello   from\nthe fake engine\n'`)
	slow := script("slow", "sleep 30")
	// What a speech model makes up from silence.
	invented := script("invented", `printf 'Thanks for watching!\n'`)
	broken := script("broken", "echo SECRETWORDS; echo SECRETWORDS >&2; exit 1")

	var reactedBeforeEngine, reacted int
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		base := "/bot" + tok + "/"
		switch p := r.URL.Path; {
		case p == base+"getUpdates":
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, current)
		case p == base+"getFile":
			fmt.Fprintf(w, `{"ok":true,"result":{"file_path":"files/%s"}}`, r.URL.Query().Get("file_id"))
		case strings.HasPrefix(p, "/file/bot"+tok+"/files/"):
			fmt.Fprint(w, content[strings.TrimPrefix(p, "/file/bot"+tok+"/files/")])
		case p == base+"setMessageReaction":
			reacted++
			if _, err := os.Stat(engineDone); err != nil {
				reactedBeforeEngine++
			}
			fmt.Fprint(w, `{"ok":true,"result":true}`)
		default:
			fmt.Fprint(w, `{"ok":true,"result":{"message_id":9}}`)
		}
	}))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer dapr.Close()
	tokenFile, conf, state := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	a := &app{root: root, home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	// pass sets the config, serves one update and returns the note it filed.
	n := 0
	pass := func(extra, fields string) (note string) {
		n++
		current = media(100+n, 42, fields)
		os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n%s", tokenFile, bot.URL, dapr.URL, extra)), 0o600)
		if code := a.gateway([]string{"--once"}); code != 0 {
			t.Fatalf("gateway --once exited %d", code)
		}
		files, _ := filepath.Glob(state + "/inbox/*.note")
		for _, f := range files {
			raw, _ := os.ReadFile(f)
			if strings.Contains(string(raw), fmt.Sprintf("[chat telegram 42:%d]", (100+n)*10)) {
				note = string(raw)
			}
		}
		if note == "" {
			lg, _ := os.ReadFile(a.log)
			t.Fatalf("pass %d filed no note; log: %s", n, lg)
		}
		return note
	}
	voice := func(id string) string { return fmt.Sprintf(`"voice":{"file_id":%q,"mime_type":"audio/ogg"}`, id) }

	// No engine installed: the note is what it was, with no transcript line, and no reaction waits.
	if note := pass("", voice("short")); strings.Contains(note, "transcript") {
		t.Errorf("no engine, yet the note says something about a transcript:\n%s", note)
	}
	// An engine, and a voice note: the reaction comes first, the words follow the file line.
	reacted, reactedBeforeEngine = 0, 0
	note := pass("set chat-transcribe-cmd "+good+"\n", voice("short"))
	if !strings.Contains(note, "audio/ogg]\ntranscript: Hello from the fake engine\n") {
		t.Errorf("the note lacks the transcript line under the file line:\n%s", note)
	}
	if reacted != 1 || reactedBeforeEngine != 1 {
		t.Errorf("%d reactions, %d before the engine finished: want one, sent before", reacted, reactedBeforeEngine)
	}
	rec, _ := os.ReadFile(state + "/rec")
	if !strings.Contains(string(rec), `"transcript":"Hello from the fake engine"`) {
		t.Errorf("the inbound event does not carry the transcript:\n%s", rec)
	}
	// A round video note is read like a voice note.
	if note := pass("set chat-transcribe-cmd "+good+"\n", `"video_note":{"file_id":"short"}`); !strings.Contains(note, "[file video ") || !strings.Contains(note, "\ntranscript: Hello from the fake engine\n") {
		t.Errorf("the video note was not transcribed:\n%s", note)
	}
	// Audio past the limit is cut, and the line says so.
	if note := pass("set chat-transcribe-cmd "+good+"\nset chat-transcribe-max-seconds 2\n", voice("long")); !strings.Contains(note, "\ntranscript (first 2 s only, the limit): Hello from the fake engine\n") {
		t.Errorf("the long audio was not marked as cut:\n%s", note)
	}
	// Each failure files the note with one fixed line and no words.
	for _, c := range []struct{ name, extra, file, line string }{
		{"timeout", "set chat-transcribe-cmd " + slow + "\nset chat-transcribe-timeout 1\n", "short", "transcript: unavailable (timed out after 1 s)"},
		{"missing engine", "set chat-transcribe-cmd " + filepath.Join(home, "nowhere") + "\n", "short", "transcript: unavailable (the engine is not installed)"},
		{"failing engine", "set chat-transcribe-cmd " + broken + "\n", "short", "transcript: unavailable (the engine failed)"},
		{"silent note", "set chat-transcribe-cmd " + invented + "\n", "silent", "transcript: unavailable (no speech found)"},
		{"unreadable audio", "set chat-transcribe-cmd " + good + "\n", "junk", "transcript: unavailable (the audio could not be read)"},
	} {
		note := pass(c.extra, voice(c.file))
		if !strings.Contains(note, "[file audio ") || !strings.Contains(note, "\n"+c.line+"\n") || strings.Contains(note, "SECRETWORDS") {
			t.Errorf("%s: want the file line and %q:\n%s", c.name, c.line, note)
		}
	}
	// A live pass with the installed engine, when asked: JG_TEST_STT_HOME is a home where `bin/jg-chat-transcribe.sh
	// setup` ran and JG_TEST_STT_WAV is a recording of speech. Only the word count is logged.
	if h, speech := os.Getenv("JG_TEST_STT_HOME"), os.Getenv("JG_TEST_STT_WAV"); h != "" && speech != "" {
		raw, err := os.ReadFile(speech)
		if err != nil {
			t.Fatal(err)
		}
		content["live"] = string(raw)
		if err := os.Symlink(filepath.Join(h, "state", "captain-chat", "stt"), filepath.Join(state, "captain-chat", "stt")); err != nil {
			t.Fatal(err)
		}
		note := pass("", voice("live"))
		i := strings.Index(note, "\ntranscript: ")
		if i < 0 || strings.Contains(note, "unavailable") {
			t.Fatalf("the installed engine did not transcribe the recording")
		}
		t.Logf("live pass: the installed engine transcribed the recording through the gateway path into the filed note, %d words", len(strings.Fields(note[i+len("\ntranscript: "):])))
	}
	filepath.Walk(state, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); strings.Contains(string(b), "SECRETWORDS") || strings.Contains(string(b), tok) ||
			(p == a.log && strings.Contains(string(b), "Hello")) {
			t.Errorf("%s holds engine output, a transcript or the bot token", p)
		}
		return nil
	})
	if left, _ := filepath.Glob(state + "/captain-chat/.stt-*"); len(left) > 0 {
		t.Errorf("scratch audio left behind: %v", left)
	}
	log, _ := os.ReadFile(a.log)
	t.Logf("round trip against a fake Bot API: words in the note under the file line, in the event, reaction sent before the engine finished; the log holds only fixed reasons:\n%s", log)
}

// current is the one update the fake Bot API serves; each pass sets the next one.
var current string
