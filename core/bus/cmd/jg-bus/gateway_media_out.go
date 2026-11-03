package main

// Outbound media: the files of a reply are checked, then streamed from disk to the chat.

import (
	"context"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"
)

// LocalFile is a vetted file to send. Photo says it goes as a picture, not as a file.
type LocalFile struct {
	Path, Name string
	Photo      bool
}

// OutLimits: the largest file, the largest picture and the longest caption (UTF-16 units).
type OutLimits struct {
	File, Photo int64
	Caption     int
}

func (t *telegram) Out() OutLimits {
	return OutLimits{File: 50 << 20, Photo: 10 << 20, Caption: 1024}
}

func utf16Len(s string) int { return len(utf16.Encode([]rune(s))) }

// within says whether p is root or lies under it.
func within(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// secretPath says whether a file may hold a secret and is never sent: anything under this home's
// config/, its bus state or ~/.ssh, a .env file, or a name ending .token, .pass, .key or .pem.
func (a *app) secretPath(p string) bool {
	low := strings.ToLower(filepath.Base(p))
	for _, end := range []string{".token", ".pass", ".key", ".pem"} {
		if strings.HasSuffix(low, end) {
			return true
		}
	}
	if low == ".env" || strings.HasPrefix(low, ".env.") {
		return true
	}
	user, _ := os.UserHomeDir()
	for _, root := range []string{filepath.Join(a.home, "config"), filepath.Join(a.state, "bus"), filepath.Join(user, ".ssh")} {
		real, err := filepath.EvalSymlinks(root)
		if within(root, p) || (err == nil && within(real, p)) {
			return true
		}
	}
	return false
}

// vetAttachment returns the file to send, or the line telling the owner why it was not sent. The
// path is checked as written and after symlinks, so a link to a secret does not get through.
func (a *app) vetAttachment(lim OutLimits, p string) (LocalFile, string) {
	name := filepath.Base(p)
	no := func(why string) (LocalFile, string) { return LocalFile{}, "I did not send " + name + ": " + why }
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		return no("the file is not there.")
	}
	if a.secretPath(filepath.Clean(p)) || a.secretPath(real) {
		return no("it can hold a secret, and I never send those.")
	}
	info, err := os.Stat(real)
	if err != nil || !info.Mode().IsRegular() {
		return no("it is not a regular file.")
	}
	if info.Size() > lim.File {
		return no(fmt.Sprintf("it is %s and the limit is %d MB. It stays at %s.", humanSize(info.Size()), lim.File>>20, p))
	}
	f, err := os.Open(real)
	if err != nil {
		return no("I cannot read it.")
	}
	defer f.Close()
	head := make([]byte, 512)
	n, _ := io.ReadFull(f, head)
	kind := http.DetectContentType(head[:n])
	photo := info.Size() <= lim.Photo && (kind == "image/jpeg" || kind == "image/png" || kind == "image/webp")
	return LocalFile{Path: real, Name: name, Photo: photo}, ""
}

// upload is a multipart body built as it is read, so a file is never held in memory.
func upload(fields map[string]string, files map[string]LocalFile) func() (io.Reader, string) {
	return func() (io.Reader, string) {
		pr, pw := io.Pipe()
		mw := multipart.NewWriter(pw)
		go func() {
			var err error
			for k, v := range fields {
				if err = mw.WriteField(k, v); err != nil {
					break
				}
			}
			for k, f := range files {
				if err != nil {
					break
				}
				var w io.Writer
				if w, err = mw.CreateFormFile(k, f.Name); err == nil {
					var src *os.File
					if src, err = os.Open(f.Path); err == nil {
						_, err = io.Copy(w, src)
						src.Close()
					}
				}
			}
			if err == nil {
				err = mw.Close()
			}
			pw.CloseWithError(err)
		}()
		return pr, mw.FormDataContentType()
	}
}

// sendFiles is sendPhoto or sendDocument; a picture Telegram refuses (400) is sent as a file.
func (t *telegram) sendFiles(ctx context.Context, out Outbound, reply string) (string, error) {
	for photo := out.Files[0].Photo; ; photo = false {
		kind, method := "document", "sendDocument"
		if photo {
			kind, method = "photo", "sendPhoto"
		}
		fields := map[string]string{"chat_id": out.Chat, "reply_parameters": reply}
		if out.Text != "" {
			fields["caption"] = out.Text
		}
		id, err := t.call(ctx, method, 10*time.Minute, upload(fields, map[string]LocalFile{kind: out.Files[0]}))
		if se, ok := err.(*sendError); photo && ok && se.code == 400 {
			continue
		}
		return id, err
	}
}
