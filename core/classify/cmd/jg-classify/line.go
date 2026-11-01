package main

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// The status-line grammar: how one status line splits into a verb, a stamp, a key and a
// note. Every function here is a pure read of the line and mirrors, byte for byte, the
// shell reader it replaced (the case-glob and parameter-expansion rules of bash in a UTF-8
// locale), so a line classifies the same on either side of the port.

// isSpace is the shell's [[:space:]] in a UTF-8 locale: the ASCII blanks plus the Unicode
// separators glibc counts (no-break spaces are deliberately not among them).
func isSpace(r rune) bool {
	switch r {
	case ' ', '\t', '\n', '\v', '\f', '\r',
		0x1680, 0x2028, 0x2029, 0x205f, 0x3000:
		return true
	}
	return r >= 0x2000 && r <= 0x200a && r != 0x2007
}

func trimLeftSpace(s string) string { return strings.TrimLeftFunc(s, isSpace) }

func trimSpace(s string) string { return strings.TrimFunc(s, isSpace) }

func startsWithSpace(s string) bool {
	r, n := utf8.DecodeRuneInString(s)
	return n > 0 && r != utf8.RuneError && isSpace(r)
}

// firstWord splits s at its first blank: the word, and what follows it with leading blanks gone.
func firstWord(s string) (word, rest string) {
	i := strings.IndexFunc(s, isSpace)
	if i < 0 {
		return s, ""
	}
	return s[:i], trimLeftSpace(s[i:])
}

// hasTag is the glob *\[<name>=*\]* : a "[name=" with a closing bracket somewhere after it.
func hasTag(s, open string) bool {
	i := strings.Index(s, open)
	return i >= 0 && strings.Contains(s[i+len(open):], "]")
}

// isCorrToken: the whole word is the unbracketed token the fleet writes, corr= and 16 hex digits.
func isCorrToken(w string) bool {
	if len(w) != 5+16 || w[:5] != "corr=" {
		return false
	}
	for _, c := range []byte(w[5:]) {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

// lineVerb is the leading verb word: the text before the first colon, cut at the first tag,
// trimmed, with whole-word correlation tokens dropped after the first word.
func lineVerb(line string) string {
	v := line
	if i := strings.IndexByte(v, ':'); i >= 0 {
		v = v[:i]
	}
	if i := strings.IndexByte(v, '['); i >= 0 {
		v = v[:i]
	}
	v = trimSpace(v)
	if !strings.Contains(v, "corr=") {
		return v
	}
	words := strings.FieldsFunc(v, isSpace)
	out := words[0]
	for _, w := range words[1:] {
		if !isCorrToken(w) {
			out += " " + w
		}
	}
	return out
}

// unstamped removes the time-tag-shaped runs a worker wrote as the stamp: a run counts only
// while nothing before it holds a colon. The copy is for matching; the caller's bytes stay.
func unstamped(line string) string {
	rest, keep := line, ""
	for hasTag(rest, "[at=") {
		i := strings.Index(rest, "[at=")
		before := rest[:i]
		if strings.IndexByte(before, ':') >= 0 {
			break
		}
		keep += strings.TrimSuffix(before, " ")
		rest = rest[i+4:]
		rest = rest[strings.IndexByte(rest, ']')+1:]
	}
	return keep + rest
}

func slugOK(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// decisionKey is the stated "[key=<slug>]" of a line: before the colon, or else at the head of
// the note. A line with no token yields keyless. ok is false for a stated slug that is not well-formed.
func decisionKey(line, keyless string) (key string, ok bool) {
	u := unstamped(line)
	head := u
	if i := strings.IndexByte(u, ':'); i >= 0 {
		head = u[:i]
	}
	var k string
	switch {
	case hasTag(head, "[key="):
		k = head[strings.Index(head, "[key=")+5:]
		k = k[:strings.IndexByte(k, ']')]
	default:
		i := strings.IndexByte(u, ':')
		if i < 0 {
			return keyless, true
		}
		rest := trimLeftSpace(u[i+1:])
		if !strings.HasPrefix(rest, "[key=") || !strings.Contains(rest, "]") {
			return keyless, true
		}
		k = rest[5:]
		k = k[:strings.IndexByte(k, ']')]
	}
	if !slugOK(k) {
		return "", false
	}
	return k, true
}

func isLowerRune(r rune) bool { return r != utf8.RuneError && unicode.IsLower(r) }
