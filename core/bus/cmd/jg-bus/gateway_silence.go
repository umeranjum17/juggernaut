package main

import "strings"

// silencePhrases are the lines a speech model makes up from silence or near silence. A transcript
// that is nothing but these is not speech. To drop another one, add it here, in lower case.
var silencePhrases = []string{
	"thanks for watching",
	"thank you for watching",
	"please subscribe",
	"like and subscribe",
	"subscribe to my channel",
	"see you in the next video",
	"subtitles by the amara.org community",
	"you",
}

// repeatRuns is how many times a short phrase must repeat, with nothing else, to count as a loop.
const repeatRuns = 6

// silenceWords lower-cases the text and cuts it into bare words, so the case and the marks around
// a word never decide the match.
func silenceWords(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '\'' || r > 127)
	})
}

// isInventedSilence says whether a transcript is only made-up silence phrases, or one short phrase
// (up to four words) repeated many times. Speech that holds such a phrase among other words is not.
func isInventedSilence(text string) bool {
	words := silenceWords(text)
	if len(words) == 0 {
		return false
	}
	for i := 0; i < len(words); { // only known phrases, back to back
		n := 0
		for _, p := range silencePhrases {
			if pw := silenceWords(p); len(pw) > n && hasPrefixWords(words[i:], pw) {
				n = len(pw)
			}
		}
		if n == 0 {
			break
		}
		if i += n; i == len(words) {
			return true
		}
	}
	for size := 1; size <= 4; size++ { // one short phrase, over and over
		if len(words)%size != 0 || len(words)/size < repeatRuns {
			continue
		}
		same := true
		for i := size; i < len(words) && same; i++ {
			same = words[i] == words[i-size]
		}
		if same {
			return true
		}
	}
	return false
}

func hasPrefixWords(words, prefix []string) bool {
	if len(words) < len(prefix) {
		return false
	}
	for i, p := range prefix {
		if words[i] != p {
			return false
		}
	}
	return true
}
