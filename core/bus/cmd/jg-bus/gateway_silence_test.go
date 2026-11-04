package main

import "testing"

// A transcript that is only made-up silence phrases, or one short phrase looped, is dropped; real
// speech stays, including speech that holds such a phrase among other words.
func TestInventedSilence(t *testing.T) {
	for _, c := range []struct {
		text string
		drop bool
	}{
		{"Thanks for watching!", true},
		{"Thank you for watching. Please subscribe.", true},
		{"Subtitles by the Amara.org community", true},
		{"you", true},
		{"the the the the the the", true},
		{"Okay. Okay. Okay. Okay. Okay. Okay. Okay.", true},
		{"so so so so so so so so so so so so so so so so", true},
		{"no way no way no way no way no way no way", true},
		{"", false},
		{"Please move the meeting to Thursday and thanks for watching the kids.", false},
		{"Thanks for watching my talk, here is the feedback I promised.", false},
		{"I told you so", false},
		{"no no no, that is wrong", false},
		{"yes yes yes yes", false},
		{"Hello from the fake engine", false},
	} {
		if got := isInventedSilence(c.text); got != c.drop {
			t.Errorf("isInventedSilence(%q) = %v, want %v", c.text, got, c.drop)
		}
	}
}
