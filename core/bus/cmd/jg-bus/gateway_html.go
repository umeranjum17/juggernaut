package main

// gateway_html.go sends the owner's Telegram text with HTML formatting. Overwatch writes a
// markdown subset - **bold**, *italic* or _italic_, `code`, ``` fences, [text](url) and > quotes -
// and renderTelegramHTML turns it into the tags Telegram's HTML parse mode takes. Every other
// character, and every marker without a partner, goes out as text with &, < and > escaped, so
// model text can never break the markup. Rich-only blocks (tables, details) stay off. When
// Telegram still refuses the markup ("can't parse entities"), textCall resends the same text once
// as plain text, so a formatting slip never costs the owner a message.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"time"
)

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")
var attrEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")

// renderTelegramHTML renders text for parse_mode=HTML. The result always nests its tags properly:
// each tag pair comes from one matched span whose inside is rendered the same way.
func renderTelegramHTML(text string) string {
	lines := strings.Split(text, "\n")
	var out []string
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if lang, ok := fenceOpen(line); ok {
			end := -1
			for j := i + 1; j < len(lines); j++ {
				if strings.HasPrefix(strings.TrimSpace(lines[j]), "```") {
					end = j
					break
				}
			}
			if end > 0 { // an unclosed fence stays plain text
				open := "<pre>"
				if lang != "" {
					open = `<pre><code class="language-` + lang + `">`
				}
				closing := "</pre>"
				if lang != "" {
					closing = "</code></pre>"
				}
				out = append(out, open+htmlEscaper.Replace(strings.Join(lines[i+1:end], "\n"))+closing)
				i = end
				continue
			}
		}
		if isQuote(line) {
			var quoted []string
			for ; i < len(lines) && isQuote(lines[i]); i++ {
				quoted = append(quoted, renderInline(strings.TrimPrefix(strings.TrimPrefix(strings.TrimLeft(lines[i], " "), ">"), " "), false))
			}
			i--
			out = append(out, "<blockquote>"+strings.Join(quoted, "\n")+"</blockquote>")
			continue
		}
		out = append(out, renderInline(line, false))
	}
	return strings.Join(out, "\n")
}

// fenceOpen reports a line that opens a code fence and its language, kept only when it is a plain word.
func fenceOpen(line string) (lang string, ok bool) {
	t := strings.TrimSpace(line)
	if !strings.HasPrefix(t, "```") {
		return "", false
	}
	lang = strings.TrimSpace(t[3:])
	if strings.Contains(lang, "`") {
		return "", false
	}
	for _, r := range lang {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '+' || r == '-') {
			lang = ""
			break
		}
	}
	return lang, true
}

func isQuote(line string) bool { return strings.HasPrefix(strings.TrimLeft(line, " "), ">") }

func isWord(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b >= 0x80
}

// renderInline renders one line. The markers are ASCII, so it walks bytes; a multi-byte rune
// never holds a marker byte. inLink stops a link inside link text, which Telegram refuses.
func renderInline(s string, inLink bool) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '`':
			if j := strings.IndexByte(s[i+1:], '`'); j > 0 {
				b.WriteString("<code>" + htmlEscaper.Replace(s[i+1:i+1+j]) + "</code>")
				i += j + 2
				continue
			}
		case strings.HasPrefix(s[i:], "**"):
			if j := closeAt(s, i+2, "**"); j > 0 {
				b.WriteString("<b>" + renderInline(s[i+2:j], inLink) + "</b>")
				i = j + 2
				continue
			}
		case c == '*' || c == '_':
			if j := closeItalic(s, i); j > 0 {
				b.WriteString("<i>" + renderInline(s[i+1:j], inLink) + "</i>")
				i = j + 1
				continue
			}
		case c == '[' && !inLink:
			if label, url, n := linkAt(s[i:]); n > 0 {
				b.WriteString(`<a href="` + attrEscaper.Replace(url) + `">` + renderInline(label, true) + "</a>")
				i += n
				continue
			}
		}
		switch c {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		default:
			b.WriteByte(c)
		}
		i++
	}
	return b.String()
}

// closeAt finds the marker that closes a span whose text starts at from: the text is not empty
// and does not start or end with a space.
func closeAt(s string, from int, marker string) int {
	if from >= len(s) || s[from] == ' ' {
		return -1
	}
	for j := from + 1; j+len(marker) <= len(s); j++ {
		if s[j-1] != ' ' && strings.HasPrefix(s[j:], marker) {
			return j
		}
	}
	return -1
}

// closeItalic finds the end of an italic span that opens at i. The opener follows a space, an
// edge or punctuation and the closer precedes one, so snake_case names and a glob such as *.go
// stay text. A doubled marker belongs to bold and is skipped.
func closeItalic(s string, i int) int {
	d := s[i]
	if i > 0 && isWord(s[i-1]) || i+1 >= len(s) || s[i+1] == ' ' || s[i+1] == d {
		return -1
	}
	for j := i + 2; j < len(s); j++ {
		if s[j] != d || s[j-1] == ' ' || s[j-1] == d {
			continue
		}
		if j+1 < len(s) && (s[j+1] == d || isWord(s[j+1])) {
			continue
		}
		return j
	}
	return -1
}

// linkAt parses [label](url) at the start of s: a web, mail or Telegram address with no space or
// angle bracket. It returns the label, the address and the bytes used.
func linkAt(s string) (label, url string, n int) {
	end := strings.Index(s, "](")
	if end < 2 {
		return "", "", 0
	}
	depth := 0
	for j := end + 2; j < len(s); j++ {
		switch s[j] {
		case '(':
			depth++
		case ')':
			if depth > 0 {
				depth--
				continue
			}
			label, url = s[1:end], s[end+2:j]
			for _, p := range []string{"https://", "http://", "tg://", "mailto:"} {
				if strings.HasPrefix(url, p) && len(url) > len(p) && !strings.ContainsAny(url, " \t<>\"") && !strings.Contains(label, "]") {
					return label, url, j + 1
				}
			}
			return "", "", 0
		case ' ', '\t':
			return "", "", 0
		}
	}
	return "", "", 0
}

// isParseError tells Telegram's refusal of the markup from every other failure.
func isParseError(err error) bool {
	e, ok := err.(*sendError)
	return ok && e.code == 400 && strings.Contains(strings.ToLower(e.msg), "can't parse entities")
}

// textCall posts a text method (sendMessage, editMessageText) with the text rendered as HTML. A
// parse error from Telegram means nothing was made or changed, so the same text goes out once more
// as plain text.
func (t *telegram) textCall(ctx context.Context, method string, wait time.Duration, fields map[string]any, text string) (string, error) {
	post := func(m map[string]any) (string, error) {
		body, _ := json.Marshal(m)
		return t.call(ctx, method, wait, func() (io.Reader, string) { return bytes.NewReader(body), "application/json" })
	}
	fields["text"], fields["parse_mode"] = renderTelegramHTML(text), "HTML"
	id, err := post(fields)
	if isParseError(err) {
		fields["text"] = text
		delete(fields, "parse_mode")
		id, err = post(fields)
	}
	return id, err
}
