package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// The four facts a ship brief records, read the way the shell read them: the first line that
// matches wins, and forge= and upstream-consent= are the LAST such token on the contract line.
var (
	reBranch  = regexp.MustCompile(`^Ship branch: (?s:(.*))$`)
	reMode    = regexp.MustCompile(`^Delivery contract: mode=([^ ]*)(?s:.*)$`)
	reForge   = regexp.MustCompile(`^Delivery contract: mode=[^ ]*(?s:.*)[[:space:]]forge=([^ ]*)(?s:.*)$`)
	reConsent = regexp.MustCompile(`^Delivery contract: mode=[^ ]*(?s:.*)[[:space:]]upstream-consent=([^ ]*)(?s:.*)$`)
)

type briefFacts struct{ branch, mode, forge, consent string }

// readBrief scans a brief once. A fact absent from the brief is empty, and so is one whose
// token is empty, which is how the shell's `sed -n ... | head -n 1` could not tell them apart.
func readBrief(path string) (briefFacts, error) {
	var f briefFacts
	data, err := os.ReadFile(path)
	if err != nil {
		return f, err
	}
	first := map[*regexp.Regexp]*string{reBranch: &f.branch, reMode: &f.mode, reForge: &f.forge, reConsent: &f.consent}
	seen := map[*regexp.Regexp]bool{}
	r := bufio.NewReader(bytes.NewReader(data))
	for {
		line, err := r.ReadString('\n')
		if len(line) > 0 {
			line = strings.TrimSuffix(line, "\n")
			for re, dst := range first {
				if seen[re] {
					continue
				}
				if m := re.FindStringSubmatch(line); m != nil {
					*dst, seen[re] = m[1], true
				}
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return f, err
		}
	}
	return f, nil
}

func orNone(v string) string {
	if v == "" {
		return "none"
	}
	return v
}

func deliveryAgreeCmd(args []string) int {
	fs := flag.NewFlagSet("delivery-agree", flag.ContinueOnError)
	var id, mode, yolo, branch, consent, brief, source, proj, forge string
	var relaunch bool
	fs.StringVar(&id, "id", "", "")
	fs.StringVar(&mode, "mode", "", "")
	fs.StringVar(&yolo, "yolo", "", "")
	fs.StringVar(&branch, "branch", "", "")
	fs.BoolVar(&relaunch, "relaunch", false, "")
	fs.StringVar(&consent, "upstream-consent", "", "")
	fs.StringVar(&brief, "brief", "", "")
	fs.StringVar(&source, "source-brief", "", "")
	fs.StringVar(&proj, "project", "", "")
	fs.StringVar(&forge, "standing-forge", "", "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || id == "" || brief == "" {
		return usage()
	}
	facts, err := readBrief(brief)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot read %s: %v\n", brief, err)
		return 1
	}
	if facts.forge == "" {
		facts.forge = "none"
	}
	stderr := os.Stderr
	if facts.branch != "" {
		if facts.branch != branch {
			fmt.Fprintf(stderr, "error: branch mismatch for %s: the brief says branch=%s but this spawn selected branch=%s\n", id, facts.branch, branch)
			return 1
		}
	} else if branch != "fm/"+id {
		// A relaunch's branch comes from the task record, so a promoted scout whose brief never
		// carried a Ship branch line relaunches on that recorded branch rather than being refused.
		if relaunch {
			fmt.Fprintf(stderr, "warning: %s records no ship branch; relaunching on the task's recorded branch %s\n", brief, branch)
		} else {
			fmt.Fprintf(stderr, "error: %s records no ship branch; regenerate it with --branch-prefix before spawning %s\n", brief, branch)
			return 1
		}
	} else {
		fmt.Fprintf(stderr, "warning: %s records no ship branch; defaulting to legacy branch %s\n", brief, branch)
	}
	if facts.mode == "" {
		fmt.Fprintf(stderr, "warning: %s records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode %s - confirm its definition of done matches\n", brief, mode)
	} else if facts.mode != mode {
		fmt.Fprintf(stderr, "error: delivery mismatch for %s: the brief says mode=%s but this spawn passed --mode %s; correct the flag or re-scaffold the brief so the worker's instructions and the task record agree\n", id, facts.mode, mode)
		return 1
	}
	if facts.consent != consent {
		fmt.Fprintf(stderr, "error: upstream-consent mismatch for %s: %s records upstream-consent=%s but this spawn passed %s; correct the flag or re-scaffold the brief so the worker's contract and the task record agree\n", id, brief, orNone(facts.consent), orNone(consent))
		return 1
	}
	if facts.forge != forge {
		risk := ""
		if mode == "no-mistakes" {
			risk = " --risk <release|security|migration|large-change|shared-protocol|fork-repo>"
		}
		scaffold := fmt.Sprintf("jg-brief.sh %s %s --mode %s%s", id, proj, mode, risk)
		if forge != "none" {
			scaffold = fmt.Sprintf("jg-brief.sh %s %s --mode %s --forge %s%s", id, proj, mode, forge, risk)
		}
		fmt.Fprintf(stderr, "error: forge mismatch for %s: %s is registered forge=%s but %s records forge=%s; keep the filled ## Captain's intent and ## Juggernaut spec bodies, remove %s, re-scaffold it with %s, then re-fill those two subsections, so the worker's publication matches the project's forge\n", id, proj, forge, source, facts.forge, source, scaffold)
		return 1
	}
	if forge == "gerrit" && yolo == "on" {
		fmt.Fprintf(stderr, "error: --yolo on is refused for %s: %s is registered forge=gerrit, where yolo is inactive because a Code-Review+2 is a positive attributed claim that a named human approved and juggernaut must not manufacture one (captain's decision 2026-09-15); spawn with --yolo off\n", id, proj)
		return 1
	}
	return 0
}

func deliveryNoticesCmd(args []string) int {
	fs := flag.NewFlagSet("delivery-notices", flag.ContinueOnError)
	var id, mode, branch, proj, standingMode, standingBranch string
	fs.StringVar(&id, "id", "", "")
	fs.StringVar(&mode, "mode", "", "")
	fs.StringVar(&branch, "branch", "", "")
	fs.StringVar(&proj, "project", "", "")
	fs.StringVar(&standingMode, "standing-mode", "", "")
	fs.StringVar(&standingBranch, "standing-branch", "", "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || id == "" {
		return usage()
	}
	// The registry holds the captain's standing posture, so dropping below it is allowed but never
	// silent. A conditional policy is excluded: both of its legs are legitimate classifications.
	if standingMode != "" && standingMode != "no-mistakes-prod-only" && rigorRank(mode) < rigorRank(standingMode) {
		fmt.Fprintf(os.Stderr, "notice: %s ships mode=%s while the standing posture for %s is %s - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state\n", id, mode, proj, standingMode)
	}
	if branch != standingBranch+id {
		fmt.Fprintf(os.Stderr, "notice: %s ships branch=%s while %s registers the ship-branch prefix '%s' (branch %s%s) - the task's branch and PR will read as juggernaut-authored; proceed only on a current explicit captain instruction or an intake judgment you can state\n", id, branch, proj, standingBranch, standingBranch, id)
	}
	return 0
}
