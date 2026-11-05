package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func pngBytes(seed uint8) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{seed, 0, 0, 255})
	var b bytes.Buffer
	png.Encode(&b, img)
	return b.Bytes()
}

// strip is a w by h picture whose every pixel tells where it is, so a cut can be checked pixel by pixel.
func strip(w, h int) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetNRGBA(x, y, color.NRGBA{uint8(x / 4), uint8(y / 28), uint8(x + y), 255})
		}
	}
	return img
}

func pngOf(img image.Image) []byte {
	var b bytes.Buffer
	png.Encode(&b, img)
	return b.Bytes()
}

// call is one request the fake Bot API got: its method, its form fields (or JSON keys) and the
// files it carried, by form field.
type call struct {
	method   string
	fields   map[string]string
	filename map[string]string
	data     map[string][]byte
	streamed bool
}

// The owner's notes are answered with files: a picture, a picture and a file, an album, a picture
// Telegram refuses, a file Telegram refuses, and files that must never go (a token, a link to it,
// .env, a file over 50 MB, a file that is gone). A picture taller than 3:1 (780x6872) goes as three
// slices in one album, in order, with the same pixels and the caption on the first; one exactly 3:1
// stays one picture. Against a fake Bot API.
func TestGatewayOutboundMedia(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home := t.TempDir()
	const secret = "SECRET-FILE-BYTES"
	var calls []call
	var batch string
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		if !strings.HasPrefix(r.URL.Path, "/bot"+tok+"/") {
			http.Error(w, `{"ok":false}`, 404)
			return
		}
		if method == "getUpdates" {
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
			return
		}
		c := call{method: method, fields: map[string]string{}, filename: map[string]string{}, data: map[string][]byte{}, streamed: r.ContentLength == -1}
		if mr, err := r.MultipartReader(); err == nil {
			for p, err := mr.NextPart(); err == nil; p, err = mr.NextPart() {
				b, _ := io.ReadAll(p)
				if p.FileName() != "" {
					c.filename[p.FormName()], c.data[p.FormName()] = p.FileName(), b
				} else {
					c.fields[p.FormName()] = string(b)
				}
			}
		} else {
			var m map[string]any
			json.NewDecoder(r.Body).Decode(&m)
			rp, _ := json.Marshal(m["reply_parameters"])
			c.fields["text"], c.fields["reply_parameters"] = fmt.Sprint(m["text"]), string(rp)
		}
		calls = append(calls, c)
		for _, f := range c.filename { // Telegram refuses a thin picture and a file it dislikes
			if (method == "sendPhoto" && f == "thin.png") || (method == "sendDocument" && f == "bad.pdf") {
				fmt.Fprint(w, `{"ok":false,"error_code":400,"description":"Bad Request: PHOTO_INVALID_DIMENSIONS"}`)
				return
			}
		}
		if method == "sendMediaGroup" {
			fmt.Fprint(w, `{"ok":true,"result":[{"message_id":501},{"message_id":502}]}`)
			return
		}
		fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 600+len(calls))
	}))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer dapr.Close()
	tokenFile, conf, state, data := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state"), filepath.Join(home, "data")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	a := &app{root: root, home: home, state: state, data: data, configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	once := func() {
		if code := a.gateway([]string{"--once"}); code != 0 {
			t.Fatalf("gateway --once exited %d", code)
		}
	}
	os.MkdirAll(filepath.Join(home, "config"), 0o700)
	os.MkdirAll(data, 0o700)
	write := func(rel string, b []byte) string {
		p := filepath.Join(home, rel)
		os.WriteFile(p, b, 0o600)
		return p
	}
	shot, report, thin, bad := write("data/shot.png", pngBytes(1)), write("data/report.pdf", []byte("%PDF- the report")), write("data/thin.png", pngBytes(9)), write("data/bad.pdf", []byte("%PDF- bad"))
	tokenPath, env, gone := write("config/x.token", []byte(secret)), write(".env", []byte(secret)), write("data/gone.txt", []byte("x"))
	link, huge := filepath.Join(data, "innocent.png"), write("data/huge.bin", nil)
	os.Symlink(tokenPath, link)
	os.Truncate(huge, 51<<20) // a sparse file: it costs no disk
	albums := []string{write("data/a1.png", pngBytes(2)), write("data/a2.png", pngBytes(3)), write("data/a3.png", pngBytes(4))}
	tallImg, edgeImg := strip(780, 6872), strip(780, 2340) // the owner's phone could not read 780x6872; 3:1 exactly is still readable
	tall, edge := write("data/tall.png", pngOf(tallImg)), write("data/edge.png", pngOf(edgeImg))
	sliverImg := strip(300, 1860) // two full slices of 900 and a last 60 rows high, under a third of the width: joined to the second
	sliver := write("data/sliver.png", pngOf(sliverImg))

	// Ten notes from the owner (messages 100 to 190); each is answered below.
	var ups []string
	for i := 10; i < 20; i++ {
		ups = append(ups, upd(i, "private", 42, 42, false, fmt.Sprintf("note %d", i)))
	}
	batch = strings.Join(ups, ",")
	once()
	batch = ""
	ids := map[string]string{} // message id -> note id
	readLines(state+"/captain-chat/inbound.jsonl", func(v map[string]string) { ids[v["message"]] = v["note"] })
	if len(ids) != 10 {
		t.Fatalf("filed %d of 10 notes", len(ids))
	}
	calls = nil
	reply := func(i int, text string, files ...string) {
		args := []string{"reply", ids[fmt.Sprint(100+10*i)]}
		for _, f := range files {
			args = append(args, "--attach", f)
		}
		if text != "" {
			args = append(args, "--", text)
		}
		if out, err := a.inbox("", args...); err != nil {
			t.Fatalf("reply %d: %v %s", i, err, out)
		}
	}
	reply(0, "here is the screenshot", shot)
	reply(1, "the report and the shot", report, shot)
	reply(2, "three pictures", albums...)
	reply(3, "a thin picture", thin)
	reply(4, "a bad file", bad)
	reply(5, "files you should not get", tokenPath, link, env, huge, gone)
	os.Remove(gone)    // recorded, then gone before the gateway looks
	reply(6, "", shot) // a picture alone: no text at all
	reply(7, "a long strip", tall)
	reply(8, "", edge)
	reply(9, "", sliver)
	once()

	mustCall := func(i int, method string) call {
		if i >= len(calls) || calls[i].method != method {
			t.Fatalf("call %d: want %s, calls are %v", i, method, methods(calls))
		}
		return calls[i]
	}
	// 0: one picture, threaded on the owner's message, caption is the text, bytes are the file's.
	c := mustCall(0, "sendPhoto")
	if c.fields["chat_id"] != "42" || c.fields["caption"] != "here is the screenshot" || !strings.Contains(c.fields["reply_parameters"], `"message_id":100`) ||
		!bytes.Equal(c.data["photo"], pngBytes(1)) || c.filename["photo"] != "shot.png" || !c.streamed {
		t.Errorf("sendPhoto = %+v: want chat 42, the caption, message 100, the file's bytes, streamed", c)
	}
	// 1, 2: a picture goes first with the caption, the PDF follows as a document.
	if c = mustCall(1, "sendPhoto"); c.fields["caption"] != "the report and the shot" || !strings.Contains(c.fields["reply_parameters"], `"message_id":110`) {
		t.Errorf("album 1 = %+v", c)
	}
	if c = mustCall(2, "sendDocument"); !bytes.Equal(c.data["document"], []byte("%PDF- the report")) || c.filename["document"] != "report.pdf" || c.fields["caption"] != "" {
		t.Errorf("sendDocument = %+v", c)
	}
	// 3: three pictures are one album: media names the parts, the caption sits on the first.
	c = mustCall(3, "sendMediaGroup")
	var media []map[string]string
	json.Unmarshal([]byte(c.fields["media"]), &media)
	if len(media) != 3 || media[0]["type"] != "photo" || media[0]["media"] != "attach://f0" || media[0]["caption"] != "three pictures" || media[1]["caption"] != "" ||
		!bytes.Equal(c.data["f0"], pngBytes(2)) || !bytes.Equal(c.data["f2"], pngBytes(4)) || len(c.data) != 3 {
		t.Errorf("sendMediaGroup = %+v media %v", c, media)
	}
	// 4, 5: Telegram refused the thin picture (400), so the same file went again as a document.
	mustCall(4, "sendPhoto")
	if c = mustCall(5, "sendDocument"); c.filename["document"] != "thin.png" || c.fields["caption"] != "a thin picture" {
		t.Errorf("fallback = %+v", c)
	}
	// 6, 7: a file Telegram refuses outright: the chat is told, with the caption it carried.
	mustCall(6, "sendDocument")
	if c = mustCall(7, "sendMessage"); !strings.Contains(c.fields["text"], "a bad file") || !strings.Contains(c.fields["text"], "I could not send bad.pdf") {
		t.Errorf("failed file text = %q", c.fields["text"])
	}
	// 8: the secret token, the link to it, .env, the 51 MB file and the vanished file are each
	// refused in one text; nothing of them was sent.
	c = mustCall(8, "sendMessage")
	for _, want := range []string{"files you should not get", "I did not send x.token: it can hold a secret", "I did not send innocent.png: it can hold a secret",
		"I did not send .env: it can hold a secret", "I did not send huge.bin: it is 51.0 MB and the limit is 50 MB. It stays at " + huge, "I did not send gone.txt: the file is not there"} {
		if !strings.Contains(c.fields["text"], want) {
			t.Errorf("refusal text lacks %q:\n%s", want, c.fields["text"])
		}
	}
	// 9: a picture alone has no caption.
	if c = mustCall(9, "sendPhoto"); c.fields["caption"] != "" {
		t.Errorf("picture alone = %+v", c)
	}
	// 10: the 780x6872 strip is one album of three slices, in order: 780x2340, 780x2340, 780x2192, each
	// at most 3:1, the caption on the first only, and put together they are the strip, pixel for pixel.
	c = mustCall(10, "sendMediaGroup")
	media = nil
	json.Unmarshal([]byte(c.fields["media"]), &media)
	if len(media) != 3 || media[0]["caption"] != "a long strip" || media[1]["caption"] != "" || media[2]["caption"] != "" || len(c.data) != 3 {
		t.Errorf("tall strip = %+v media %v", c, media)
	}
	row := 0
	for i, wantH := range []int{2340, 2340, 2192} {
		name := fmt.Sprintf("f%d", i)
		if media[i]["type"] != "photo" || media[i]["media"] != "attach://"+name || c.filename[name] != fmt.Sprintf("tall-%d.png", i+1) {
			t.Errorf("slice %d = %v file %q", i, media[i], c.filename[name])
		}
		slice, err := png.Decode(bytes.NewReader(c.data[name]))
		if err != nil {
			t.Fatalf("slice %d is not a PNG: %v", i, err)
		}
		if b := slice.Bounds(); b.Dx() != 780 || b.Dy() != wantH || b.Dy() > 3*b.Dx() {
			t.Errorf("slice %d is %v, want 780x%d and at most 3:1", i, b, wantH)
		}
		for y := 0; y < wantH; y++ {
			for x := 0; x < 780; x++ {
				if got, want := color.NRGBAModel.Convert(slice.At(x, y)), tallImg.At(x, row+y); got != want {
					t.Fatalf("slice %d pixel (%d,%d) = %v, want %v", i, x, y, got, want)
				}
			}
		}
		t.Logf("tall strip 780x6872 -> slice %d of 3: %s %v caption %q, pixels equal to rows %d-%d of the strip", i+1, c.filename[name], slice.Bounds().Size(), media[i]["caption"], row, row+wantH-1)
		row += wantH
	}
	// 11: a picture exactly 3:1 is not cut: one picture, the file's own bytes.
	if c = mustCall(11, "sendPhoto"); c.filename["photo"] != "edge.png" || !bytes.Equal(c.data["photo"], pngOf(edgeImg)) || c.fields["caption"] != "" || len(calls) != 13 {
		t.Errorf("3:1 picture = %+v, %d calls", c, len(calls))
	}
	t.Logf("3:1 picture 780x2340 -> one sendPhoto %s, %d bytes, the file's own", c.filename["photo"], len(c.data["photo"]))
	// 12: the 60-row sliver is not sent alone: two slices, 300x900 and 300x960.
	c = mustCall(12, "sendMediaGroup")
	for i, wantH := range []int{900, 960} {
		if slice, err := png.Decode(bytes.NewReader(c.data[fmt.Sprintf("f%d", i)])); err != nil || slice.Bounds().Dx() != 300 || slice.Bounds().Dy() != wantH || len(c.data) != 2 {
			t.Errorf("sliver slice %d: %v, %d files, err %v; want 300x%d", i, slice.Bounds(), len(c.data), err, wantH)
		} else {
			t.Logf("strip 300x1860 with a 60-row end -> slice %d of 2: %v (the end is joined to the last slice)", i+1, slice.Bounds().Size())
		}
	}
	if left, _ := os.ReadDir(filepath.Join(state, "captain-chat", "slices")); len(left) != 0 {
		t.Errorf("slices left behind after the reply was sent: %v", left)
	}
	for _, c := range calls {
		for _, b := range c.data {
			if strings.Contains(string(b), secret) {
				t.Errorf("a %s call carried the secret", c.method)
			}
		}
	}
	// The receipts show the files a reply carries; a restart sends nothing twice.
	if out, _ := a.inbox("", "receipts", "--all-replies"); !strings.Contains(string(out), `"attachments":["`+shot+`"]`) {
		t.Errorf("receipts do not show the attachment: %s", out)
	}
	os.Remove(state + "/captain-chat/telegram.reply-cursor")
	once()
	if len(calls) != 13 {
		t.Errorf("restart sent %d more calls", len(calls)-13)
	}
	// A note that was already answered takes more messages: `followup` sends a later picture and a
	// later text on the same note, threaded on the owner's message, each once.
	for _, args := range [][]string{
		{"followup", ids["100"], "--attach", albums[0], "--", "the landed screen"},
		{"followup", ids["100"], "--", "and the release"},
	} {
		if out, err := a.inbox("", args...); err != nil {
			t.Fatalf("%v: %v %s", args, err, out)
		}
	}
	once()
	once()
	if len(calls) != 15 {
		t.Fatalf("followups sent %d calls, want 2 more: %v", len(calls)-13, methods(calls))
	}
	if c = mustCall(13, "sendPhoto"); c.fields["caption"] != "the landed screen" || !bytes.Equal(c.data["photo"], pngBytes(2)) ||
		!strings.Contains(c.fields["reply_parameters"], `"message_id":100`) || c.fields["chat_id"] != "42" {
		t.Errorf("followup picture = %+v", c)
	}
	if c = mustCall(14, "sendMessage"); c.fields["text"] != "and the release" || !strings.Contains(c.fields["reply_parameters"], `"message_id":100`) {
		t.Errorf("followup text = %+v", c)
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && !i.IsDir() && i.Size() < 1<<20 && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
	t.Logf("calls: %v; token, link, .env, 51 MB and vanished file refused in text, never sent; picture refused by Telegram resent as a document", methods(calls))
}

func mustRead(p string) []byte { b, _ := os.ReadFile(p); return b }

func methods(cs []call) (out []string) {
	for _, c := range cs {
		out = append(out, c.method)
	}
	return out
}
