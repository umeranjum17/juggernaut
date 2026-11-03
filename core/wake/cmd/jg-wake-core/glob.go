package main

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// globMatch reports whether s matches the shell pattern p the way bash's `case` does with extglob
// off: `*` matches any string including `/` and `.`, `?` one character, `[...]` a bracket
// expression (`!` or `^` negates, ranges, [:class:] names), and `\` quotes the next character. A
// `[` that has no closing `]` is a literal. The rule file's key and payload fields are such
// patterns, and path.Match is the wrong tool: its `*` stops at `/`, and event keys are paths.
func globMatch(p, s string) bool {
	for len(p) > 0 {
		switch p[0] {
		case '*':
			for len(p) > 0 && p[0] == '*' {
				p = p[1:]
			}
			if len(p) == 0 {
				return true
			}
			for i := 0; i <= len(s); {
				if globMatch(p, s[i:]) {
					return true
				}
				if i == len(s) {
					break
				}
				_, w := utf8.DecodeRuneInString(s[i:])
				i += w
			}
			return false
		case '?':
			if len(s) == 0 {
				return false
			}
			_, w := utf8.DecodeRuneInString(s)
			p, s = p[1:], s[w:]
		case '[':
			if len(s) == 0 {
				return false
			}
			r, w := utf8.DecodeRuneInString(s)
			ok, rest, valid := matchBracket(p, r)
			if !valid {
				if s[0] != '[' {
					return false
				}
				p, s = p[1:], s[1:]
				continue
			}
			if !ok {
				return false
			}
			p, s = rest, s[w:]
		case '\\':
			if len(p) > 1 {
				p = p[1:]
			}
			fallthrough
		default:
			pr, pw := utf8.DecodeRuneInString(p)
			if len(s) == 0 {
				return false
			}
			sr, sw := utf8.DecodeRuneInString(s)
			if pr != sr {
				return false
			}
			p, s = p[pw:], s[sw:]
		}
	}
	return len(s) == 0
}

// matchBracket matches r against the bracket expression at the start of p. valid is false when p
// holds no closed expression, so the caller treats the `[` as a literal.
func matchBracket(p string, r rune) (matched bool, rest string, valid bool) {
	i := 1
	negate := false
	if i < len(p) && (p[i] == '!' || p[i] == '^') {
		negate = true
		i++
	}
	first := true
	for {
		if i >= len(p) {
			return false, "", false
		}
		if p[i] == ']' && !first {
			i++
			break
		}
		first = false
		if strings.HasPrefix(p[i:], "[:") {
			if end := strings.Index(p[i+2:], ":]"); end >= 0 {
				if classHas(p[i+2:i+2+end], r) {
					matched = true
				}
				i += 2 + end + 2
				continue
			}
		}
		lo, w := bracketRune(p[i:])
		i += w
		hi := lo
		if i+1 < len(p) && p[i] == '-' && p[i+1] != ']' {
			var w2 int
			hi, w2 = bracketRune(p[i+1:])
			i += 1 + w2
		}
		if r >= lo && r <= hi {
			matched = true
		}
	}
	return matched != negate, p[i:], true
}

func bracketRune(p string) (rune, int) {
	if p[0] == '\\' && len(p) > 1 {
		r, w := utf8.DecodeRuneInString(p[1:])
		return r, 1 + w
	}
	return utf8.DecodeRuneInString(p)
}

func classHas(name string, r rune) bool {
	switch name {
	case "alpha":
		return unicode.IsLetter(r)
	case "digit":
		return r >= '0' && r <= '9'
	case "alnum":
		return unicode.IsLetter(r) || unicode.IsDigit(r)
	case "upper":
		return unicode.IsUpper(r)
	case "lower":
		return unicode.IsLower(r)
	case "space":
		return unicode.IsSpace(r)
	case "blank":
		return r == ' ' || r == '\t'
	case "punct":
		return unicode.IsPunct(r) || unicode.IsSymbol(r)
	case "xdigit":
		return strings.ContainsRune("0123456789abcdefABCDEF", r)
	case "cntrl":
		return unicode.IsControl(r)
	case "print":
		return unicode.IsPrint(r)
	case "graph":
		return unicode.IsPrint(r) && !unicode.IsSpace(r)
	}
	return false
}
