package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The supported set renders to Telegram's tags, and all other text - markup lookalikes, tags the
// model wrote, markers without a partner - leaves as escaped text that cannot break the message.
func TestTelegramHTMLRender(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"bold", "a **big** day", "a <b>big</b> day"},
		{"italic star", "a *quiet* day", "a <i>quiet</i> day"},
		{"italic underscore", "a _quiet_ day", "a <i>quiet</i> day"},
		{"nested", "**bold _and italic_ and `code`**", "<b>bold <i>and italic</i> and <code>code</code></b>"},
		{"code span is not parsed", "`**x** <b>`", "<code>**x** &lt;b&gt;</code>"},
		{"link", "see [the PR](https://example.com/a?x=1&y=2)", `see <a href="https://example.com/a?x=1&amp;y=2">the PR</a>`},
		{"link with parens", "[w](https://example.com/a_(b))", `<a href="https://example.com/a_(b)">w</a>`},
		{"fence with language", "```go\nif a < b && c {\n}\n```", "<pre><code class=\"language-go\">if a &lt; b &amp;&amp; c {\n}</code></pre>"},
		{"fence without language", "```\n**raw**\n```", "<pre>**raw**</pre>"},
		{"quote", "> one **two**\n> three\nafter", "<blockquote>one <b>two</b>\nthree</blockquote>\nafter"},
		{"escapes", "1 < 2 & 3 > 2 <script>x</script>", "1 &lt; 2 &amp; 3 &gt; 2 &lt;script&gt;x&lt;/script&gt;"},
		{"snake_case and globs stay text", "set task_id_x in *.go and *.md", "set task_id_x in *.go and *.md"},
		{"unpaired markers stay text", "a ** b, _c, [e](f), x*", "a ** b, _c, [e](f), x*"},
		{"unclosed fence stays text", "```go\nx < y", "```go\nx &lt; y"},
		{"unsafe link stays text", "[x](javascript:alert(1)) [y](https://a.b/\"onclick)", "[x](javascript:alert(1)) [y](https://a.b/\"onclick)"},
		{"links do not nest", "[a [b](https://x.y)](https://z.w)", `<a href="https://x.y">a [b</a>](https://z.w)`},
		{"odd language is dropped", "```go<b>\nx\n```", "<pre>x</pre>"},
		{"plain text passes", "Done. 3 files changed (all green).", "Done. 3 files changed (all green)."},
	} {
		if got := renderTelegramHTML(c.in); got != c.want {
			t.Errorf("%s: %q rendered %q, want %q", c.name, c.in, got, c.want)
		}
	}
	// Whatever the model writes, the only tags in the result are the ones the renderer makes, and
	// every one of them is closed in order.
	for _, in := range []string{"**a *b** c*", "*a **b* c**", "`a **b` c**", "> **a\n> b**", "[**a](https://x.y)**", "_a *b_ c*", "```\n</pre>\n```", "<b>**x**</b>"} {
		if bad := badNesting(renderTelegramHTML(in)); bad != "" {
			t.Errorf("%q rendered %q: %s", in, renderTelegramHTML(in), bad)
		}
	}
}

// badNesting checks the tags of out are the allowed ones and nest properly.
func badNesting(out string) string {
	var stack []string
	for i := 0; i < len(out); i++ {
		if out[i] != '<' {
			continue
		}
		end := strings.IndexByte(out[i:], '>')
		if end < 0 {
			return "tag never ends"
		}
		tag := out[i+1 : i+end]
		i += end
		if strings.HasPrefix(tag, "/") {
			if len(stack) == 0 || stack[len(stack)-1] != tag[1:] {
				return "closing </" + tag[1:] + "> out of order"
			}
			stack = stack[:len(stack)-1]
			continue
		}
		name := strings.Fields(tag)[0]
		switch name {
		case "b", "i", "code", "pre", "a", "blockquote":
			stack = append(stack, name)
		default:
			return "unexpected tag <" + tag + ">"
		}
	}
	if len(stack) > 0 {
		return "unclosed " + strings.Join(stack, ",")
	}
	return ""
}

// The owner's message goes out with parse_mode HTML and its buttons; when Telegram cannot parse
// the markup the same text goes once more as plain text; any other refusal is not retried; an
// edit follows the same rules.
func TestTelegramHTMLSend(t *testing.T) {
	var calls []map[string]any
	var paths []string
	refuse := ""
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		json.NewDecoder(r.Body).Decode(&m)
		calls, paths = append(calls, m), append(paths, r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:])
		if _, html := m["parse_mode"]; html && refuse != "" {
			w.WriteHeader(400)
			fmt.Fprintf(w, `{"ok":false,"error_code":400,"description":%q}`, refuse)
			return
		}
		fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 700+len(calls))
	}))
	defer bot.Close()
	ad := &telegram{base: bot.URL, token: tok, sleep: func(time.Duration) {}}
	ctx := context.Background()
	text := "**Ready** <3 files> & `go test`\n> quoted"
	buttons := []Button{{"Merge", "o:s1:0"}, {"Wait", "o:s1:1"}}

	// Formatted, with buttons and the thread kept.
	if _, err := ad.Send(ctx, Outbound{Chat: "42", ReplyTo: "9", Text: text, Buttons: buttons}); err != nil {
		t.Fatal(err)
	}
	m := calls[0]
	if m["parse_mode"] != "HTML" || m["text"] != "<b>Ready</b> &lt;3 files&gt; &amp; <code>go test</code>\n<blockquote>quoted</blockquote>" {
		t.Fatalf("sendMessage body %v: want parse_mode HTML and the rendered text", m)
	}
	if kb, _ := json.Marshal(m["reply_markup"]); string(kb) != `{"inline_keyboard":[[{"callback_data":"o:s1:0","text":"Merge"}],[{"callback_data":"o:s1:1","text":"Wait"}]]}` || m["reply_parameters"] == nil {
		t.Fatalf("buttons or thread lost: %v", m)
	}

	// A parse error: one plain resend of the same text, still with its buttons.
	calls, paths, refuse = nil, nil, "Bad Request: can't parse entities: Can't find end tag corresponding to start tag \"b\""
	id, err := ad.Send(ctx, Outbound{Chat: "42", Text: text, Buttons: buttons})
	if err != nil || id != "702" {
		t.Fatalf("send after a parse error: id %q, err %v", id, err)
	}
	if len(calls) != 2 || calls[1]["text"] != text || calls[1]["parse_mode"] != nil || calls[1]["reply_markup"] == nil {
		t.Fatalf("calls %v: want the HTML call, then the same text as plain text with its buttons", calls)
	}

	// Another refusal is returned at once, with no second call.
	calls, refuse = nil, "Bad Request: chat not found"
	if _, err := ad.Send(ctx, Outbound{Chat: "42", Text: text}); err == nil || !strings.Contains(err.Error(), "chat not found") || len(calls) != 1 {
		t.Fatalf("err %v after %d calls: want the refusal after one call", err, len(calls))
	}

	// An edit (the mark on a tapped choice) is formatted and falls back the same way.
	calls, paths, refuse = nil, nil, ""
	if err := ad.Edit(ctx, "42", "88", "Pick *one*\n\nPicked: Merge", nil); err != nil {
		t.Fatal(err)
	}
	if paths[0] != "editMessageText" || calls[0]["parse_mode"] != "HTML" || calls[0]["text"] != "Pick <i>one</i>\n\nPicked: Merge" {
		t.Fatalf("edit %s %v", paths[0], calls[0])
	}
	calls, refuse = nil, "Bad Request: can't parse entities: Unsupported start tag"
	if err := ad.Edit(ctx, "42", "88", "Pick *one*", nil); err != nil || len(calls) != 2 || calls[1]["text"] != "Pick *one*" || calls[1]["parse_mode"] != nil {
		t.Fatalf("edit after a parse error: err %v, calls %v", err, calls)
	}
}
