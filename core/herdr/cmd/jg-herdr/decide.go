package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// versionAtLeast compares a dotted release to a floor, numerically, component by component:
// 0 candidate >= floor, 1 candidate < floor, 2 the candidate is unparseable. A prerelease or
// build suffix is stripped first, so 0.8.0-preview compares as 0.8.0. A floor component that
// is not a number cannot decide, the way the shell's failed numeric test could not.
func versionAtLeast(candidate, floor string) int {
	if i := strings.IndexAny(candidate, "-+"); i >= 0 {
		candidate = candidate[:i]
	}
	if candidate == "" || strings.Trim(candidate, "0123456789.") != "" {
		return 2
	}
	for floor != "" {
		c, f := head(candidate), head(floor)
		if c == "" {
			c = "0"
		}
		cn, cerr := strconv.ParseInt(c, 10, 64)
		fn, ferr := strconv.ParseInt(f, 10, 64)
		if cerr == nil && ferr == nil {
			if cn > fn {
				return 0
			}
			if cn < fn {
				return 1
			}
		}
		candidate, floor = tail(candidate), tail(floor)
	}
	return 0
}

func head(s string) string {
	if i := strings.IndexByte(s, '.'); i >= 0 {
		return s[:i]
	}
	return s
}

func tail(s string) string {
	if i := strings.IndexByte(s, '.'); i >= 0 {
		return s[i+1:]
	}
	return ""
}

// releaseFloorVerdict classifies a release against the presentation floor from two independent
// signals, the protocol number and the version: 0 at or above the floor, 1 provably below it,
// 2 indeterminate. Either signal can carry a positive verdict; a readable protocol below the
// floor, or a readable version below it, is decisive; only losing both is indeterminate.
func releaseFloorVerdict(protocol, version, minProtocol, minVersion string) int {
	known := false
	if protocol != "" && strings.Trim(protocol, "0123456789") == "" {
		known = true
		p, perr := strconv.ParseInt(protocol, 10, 64)
		m, merr := strconv.ParseInt(minProtocol, 10, 64)
		if perr == nil && merr == nil && p >= m {
			return 0
		}
	}
	status := versionAtLeast(version, minVersion)
	if status == 0 {
		return 0
	}
	if known || status == 1 {
		return 1
	}
	return 2
}

// presentationPreference reads the opt-out file: off, on (a deliberate opt-in, and the
// historical empty-file form) or default. The value is the file with all whitespace removed
// and ASCII folded to lower case; anything else warns and falls back to the default.
func presentationPreference(file string) string {
	if file == "" {
		return "default"
	}
	if st, err := os.Stat(file); err != nil || !st.Mode().IsRegular() {
		return "default"
	}
	data, _ := os.ReadFile(file)
	value := asciiOnly(stripSpace(string(data)))
	switch value {
	case "off":
		return "off"
	case "", "on":
		return "on"
	}
	fmt.Fprintf(os.Stderr, "warning: %s: unrecognized value \"%s\"; herdr presentation spaces fall back to the default (write \"off\" to opt out, \"on\" to force the projection on)\n", file, value)
	return "default"
}

// agentNameFor maps a task id into herdr's agent-name shape: 1-32 characters starting with a
// lowercase letter, then lowercase letters, digits, - or _. A valid short id is itself; a
// longer one keeps its first 27 characters and gains a checksum so ids that share a prefix
// stay distinct. The caller refuses an empty id.
func agentNameFor(id string) string {
	b := []byte(asciiOnly(id))
	for i, c := range b {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_', c == '-', c == '\n':
		default:
			b[i] = '-'
		}
	}
	name := strings.TrimRight(string(b), "\n")
	if name == "" || name[0] < 'a' || name[0] > 'z' {
		name = "t-" + name
	}
	if len(name) > 32 {
		name = agentNameVariant(name, id)
	}
	return name
}

// stripSpace is `tr -d '[:space:]'`: it drops the six ASCII whitespace bytes.
func stripSpace(s string) string {
	return strings.Map(func(r rune) rune {
		if r == ' ' || r >= '\t' && r <= '\r' {
			return -1
		}
		return r
	}, s)
}

// asciiOnly lower-cases ASCII letters only, as the shell's byte-wise tr does, and leaves every
// other byte alone.
func asciiOnly(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// agentNameVariant cuts a name to 27 characters, drops trailing - and _, and appends the
// first four hex digits of a POSIX checksum of salt, so it stays within the 32-character limit.
func agentNameVariant(name, salt string) string {
	if utf8.RuneCountInString(name) > 27 {
		name = string([]rune(name)[:27])
	}
	name = strings.TrimRight(name, "-_")
	return fmt.Sprintf("%s-%04x", name, cksum([]byte(salt))%65536)
}

var cksumTable = func() (t [256]uint32) {
	for i := range t {
		c := uint32(i) << 24
		for range 8 {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		t[i] = c
	}
	return
}()

// cksum is POSIX cksum(1): the CRC of the bytes followed by their length, complemented.
func cksum(data []byte) uint32 {
	var crc uint32
	for _, b := range data {
		crc = crc<<8 ^ cksumTable[byte(crc>>24)^b]
	}
	for n := len(data); n != 0; n >>= 8 {
		crc = crc<<8 ^ cksumTable[byte(crc>>24)^byte(n)]
	}
	return ^crc
}

var awkNumber = regexp.MustCompile(`^[ \t\n]*[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?`)

// awkNum is awk's string-to-number: the longest leading decimal, else zero.
func awkNum(s string) float64 {
	m := awkNumber.FindString(s)
	if m == "" {
		return 0
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(m), 64)
	if err != nil {
		return 0
	}
	return f
}

// submitConfirmBudget is a caller's confirmation budget in seconds, never below the minimum
// sleep and never negative, to four decimals.
func submitConfirmBudget(budget, minimum string) string {
	b, m := awkNum(budget)+0, awkNum(minimum)+0 // awk's `+= 0` turns -0 into 0
	if b < 0 {
		b = 0
	}
	if m < 0 {
		m = 0
	}
	if m > b {
		b = m
	}
	return fmt.Sprintf("%.4f", b)
}
