package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"strings"
)

// The reads below answer what the shell adapter used to ask jq. They keep jq's rules where a
// herdr answer can reach them: an absent key reads null, null and false fall to a default
// (`// empty`), a non-object cannot be indexed (an error, exit 5), and a stream of several
// documents answers once per document. Values keep their raw bytes, so a key order or a number
// the client wrote is the one printed.

type raw = json.RawMessage

// jqError is a failure jq would have reported with exit 5 (a parse error or an index of the
// wrong type). Output printed before it stays printed.
type jqError struct{ msg string }

func (e *jqError) Error() string { return e.msg }

func errf(format string, a ...any) error { return &jqError{fmt.Sprintf(format, a...)} }

// documents decodes every JSON document in r. fn runs on each in order; the first error from
// either the decoder or fn ends the stream and is returned, after the earlier documents ran.
func documents(r io.Reader, fn func(doc raw) error) error {
	dec := json.NewDecoder(r)
	for {
		var doc raw
		if err := dec.Decode(&doc); err == io.EOF {
			return nil
		} else if err != nil {
			return errf("parse error: %v", err)
		}
		if err := fn(doc); err != nil {
			return err
		}
	}
}

func kind(v raw) byte {
	v = bytes.TrimSpace(v)
	if len(v) == 0 {
		return 'n'
	}
	switch c := v[0]; {
	case c == '{', c == '[', c == '"', c == 't', c == 'f', c == 'n':
		return c
	default:
		return '0'
	}
}

func isNull(v raw) bool { return kind(v) == 'n' }

// truthy is jq's test: everything but null and false.
func truthy(v raw) bool {
	k := kind(v)
	return k != 'n' && !(k == 'f')
}

func kindName(v raw) string {
	switch kind(v) {
	case '{':
		return "object"
	case '[':
		return "array"
	case '"':
		return "string"
	case 't', 'f':
		return "boolean"
	case 'n':
		return "null"
	}
	return "number"
}

type member struct {
	key string
	val raw
}

// members lists an object's members in document order. A repeated key keeps its last value at
// the position of its first, the way jq builds the object.
func members(v raw) ([]member, error) {
	dec := json.NewDecoder(bytes.NewReader(v))
	if _, err := dec.Token(); err != nil {
		return nil, errf("parse error: %v", err)
	}
	var out []member
	at := map[string]int{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, errf("parse error: %v", err)
		}
		key, _ := tok.(string)
		var val raw
		if err := dec.Decode(&val); err != nil {
			return nil, errf("parse error: %v", err)
		}
		if i, ok := at[key]; ok {
			out[i].val = val
			continue
		}
		at[key] = len(out)
		out = append(out, member{key, val})
	}
	return out, nil
}

// index is jq's `.key`: null indexes to null, an object to the member (null when absent), and
// anything else is an error.
func index(v raw, key string) (raw, error) {
	switch kind(v) {
	case 'n':
		return raw("null"), nil
	case '{':
		ms, err := members(v)
		if err != nil {
			return nil, err
		}
		for _, m := range ms {
			if m.key == key {
				return m.val, nil
			}
		}
		return raw("null"), nil
	}
	return nil, errf("Cannot index %s with string (%q)", kindName(v), key)
}

// walk is `.a.b.c`.
func walk(v raw, path []string) (raw, error) {
	for _, key := range path {
		var err error
		if v, err = index(v, key); err != nil {
			return nil, err
		}
	}
	return v, nil
}

// iterate is `.[]`: an array's elements or an object's values.
func iterate(v raw) ([]raw, error) {
	switch kind(v) {
	case '[':
		var els []raw
		if err := json.Unmarshal(v, &els); err != nil {
			return nil, errf("parse error: %v", err)
		}
		return els, nil
	case '{':
		ms, err := members(v)
		if err != nil {
			return nil, err
		}
		out := make([]raw, len(ms))
		for i, m := range ms {
			out[i] = m.val
		}
		return out, nil
	}
	return nil, errf("Cannot iterate over %s", kindName(v))
}

// elements is `.a.b[]?`: the path is read as usual, so a path that cannot be indexed is an
// error, and only the `?` on the iteration swallows a value that is not an array or object.
func elements(doc raw, path []string) ([]raw, error) {
	v, err := walk(doc, path)
	if err != nil {
		return nil, err
	}
	els, err := iterate(v)
	if err != nil {
		return nil, nil
	}
	return els, nil
}

// text is `jq -r` on one value: a string unquoted, null as "null", a scalar as its literal,
// and an array or object pretty-printed.
func text(v raw) string {
	switch kind(v) {
	case '"':
		var s string
		if json.Unmarshal(v, &s) == nil {
			return s
		}
	case '{', '[':
		var b bytes.Buffer
		if json.Indent(&b, v, "", "  ") == nil {
			return b.String()
		}
	}
	return string(bytes.TrimSpace(v))
}

// tostring is jq's `tostring`: a string as itself, anything else as compact JSON.
func tostring(v raw) string {
	if kind(v) == '"' {
		return text(v)
	}
	var b bytes.Buffer
	if json.Compact(&b, v) == nil {
		return b.String()
	}
	return string(bytes.TrimSpace(v))
}

// equal is jq's `==` on two values.
func equal(a, b raw) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	return reflect.DeepEqual(x, y)
}

// isString reports v is the JSON string s.
func isString(v raw, s string) bool {
	if kind(v) != '"' {
		return false
	}
	var got string
	return json.Unmarshal(v, &got) == nil && got == s
}

// lines joins output lines the way a command substitution reads them: each ends in a newline
// and the trailing newlines of the whole are dropped.
func substitution(lines []string) string {
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}
