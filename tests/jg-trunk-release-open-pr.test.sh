#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh release: the release keeps one pull-request URL and takes an open release
# pull request as success (report fable-why-no-landing, row 24, slice S14). Before the fix the release stored the whole
# answer of the create call as the URL, so the next run did not see the open pull request, called create again after
# the push and ended with "the release PR was not opened".
#
# T1 The ledger holds this home's nine lines of 10:15:05Z as they are and pull request 813 is open: the release makes no
#    create call, prints one URL, moves the released mark and writes a row of one line.
# T2 No pull request is open and the create call fails: the error of today stays and nothing is recorded.
# T3 The create call fails and one pull request from the trunk into the default branch is open: that one is the release.
# T4 The create call answers in full (number, url, help): the row holds the one URL.
# T5 Two open pull requests go from the trunk into the default branch: the release stops and prints both.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/umeranjum17/juggernaut/pull
LEDGER=; MARK=

# A world whose project is named juggernaut, so the ledger holds the home's row byte for byte, and a gh-axi stand-in:
# a pull request's state is the file state-<n> (closed when absent), the open list is the file open-prs, and the create
# call fails unless create-ok exists, when it answers as gh-axi does.
release_world() {
  world rel
  PROJ="$HOME_D/projects/juggernaut"; LEDGER="$HOME_D/data/trunk-releases.tsv"; MARK="$HOME_D/state/trunk-released-juggernaut"
  printf -- '- juggernaut [local-trunk] - fixture named like the real project (added 2026-11-10)\n' >> "$HOME_D/data/projects.md"
  jg_git_init_commit "$PROJ"; jg_git_add_origin "$PROJ" "$W/origin-j.git"
  trunk init "$PROJ" >/dev/null || fail "trunk init must work"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'pull_request:\n  number: %s\n  state: %s\n' "\$3" "\$(cat "$W/state-\$3" 2>/dev/null || echo closed)" ;;
  list) cat "$W/open-prs" 2>/dev/null || printf 'count: 0\npull_requests: []\n' ;;
  create) [ -e "$W/create-ok" ] || { echo 'error: a pull request for branch "trunk" into branch "main" already exists'; exit 1; }
    printf 'created:\n  number: 815\n  url: "%s/815"\n  base: main\n  head: trunk\nhelp[2]:\n  Run \`gh-axi pr view 815 -R umeranjum17/juggernaut\` to see the full PR\n' "$U" ;;
esac
SH
  { printf 'juggernaut\ttrunk\tb96c903b\t1\t1794110341\t%s/810\n' "$U"
    printf 'juggernaut\ttrunk-v3\t9e050a451a9cfb8511735d603a15c3f722853c07\t59\t1794219305\tcreated:\n'
    cat <<ROW
  number: 813
  url: "$U/813"
  base: main
  head: trunk-v3
help[2]:
  Run \`gh-axi pr view 813 -R umeranjum17/juggernaut\` to see the full PR
  Run \`gh-axi pr checks 813 -R umeranjum17/juggernaut\` to monitor CI
ROW
  } > "$LEDGER"
  [ "$(wc -l < "$LEDGER")" = 9 ] || fail "fixture: the ledger must hold the nine lines"
}

batch() {  # <id>: one landed, fully green commit on the trunk and the captain's word to release it
  lane "$1" "$1"; trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "$1 must verify"
  trunk word release "$PROJ" "ship $1" >/dev/null 2>&1 || fail "the captain's word must record"
}
open_prs() {  # <n>...: the open pull requests from the trunk into main, as gh-axi lists them
  printf 'count: %s\npull_requests[%s]{number,title,state,author,draft,review,url}:\n' "$#" "$#"
  for n; do printf '  %s,"Release: 1 tickets from the local trunk",open,umeranjum17,no,none,"%s/%s"\n' "$n" "$U" "$n"; done
}
creates() { grep -c 'pr create' "$W/gh-calls" 2>/dev/null || true; }
one_url_row() {  # <url> <what>: the ledger grew by exactly one line, a row of six fields whose URL is <url>
  [ "$(wc -l < "$LEDGER")" = "$((rows + 1))" ] || fail "$2 must write a row of one line"
  [ "$(tail -1 "$LEDGER" | awk -F'\t' '{ print NF "|" $1 "|" $3 "|" $6 }')" = "6|juggernaut|$(tip)|$1" ] || fail "$2 must write a row of six fields with the one URL: $(tail -1 "$LEDGER")"
}

test_a_release_keeps_one_url_and_takes_the_open_release_pr_as_success() {
  local out rows
  release_world
  batch j1; echo open > "$W/state-813"; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) || fail "T1: the open release PR 813 must be success: $out"
  [ "$(creates)" = 0 ] || fail "T1: a release while 813 is open must make no create call"
  [ "$(grep -o 'https://' <<<"$out" | wc -l)" = 1 ] || fail "T1: the release must print one URL: $out"
  assert_contains "$out" "$U/813" "T1: the URL must be that of 813"
  [ "$(cat "$MARK")" = "$(tip)" ] || fail "T1: the released mark must move to the tip"
  one_url_row "$U/813" T1
  pass 'T1 with this home'"'"'s nine ledger lines and 813 open, the release exits 0 with no create call, one URL, a moved mark and a one-line row'

  echo closed > "$W/state-813"; batch j2; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) && fail "T2: no open PR and a failed create call must fail: $out"
  assert_contains "$out" 'the release PR was not opened; run release again' "T2: the error of today must stay"
  assert_contains "$out" 'already exists' "T2: the create call's own answer must show"
  [ "$(cat "$MARK")" != "$(tip)" ] && [ "$(wc -l < "$LEDGER")" = "$rows" ] || fail "T2: a failed release must record nothing"
  pass 'T2 with no open PR and a failed create call, the error of today stays and nothing is recorded'

  open_prs 814 > "$W/open-prs"
  out=$(trunk release "$PROJ" 2>&1) || fail "T3: the one open PR from the trunk must be success: $out"
  assert_contains "$(cat "$W/gh-calls")" 'pr list --state open --head trunk --base main' "T3: the look-up must ask for the trunk into main"
  [ "$(cat "$MARK")" = "$(tip)" ] || fail "T3: the released mark must move"
  one_url_row "$U/814" T3
  pass 'T3 a failed create call takes the one open PR from the trunk into main as the release'

  rm "$W/open-prs"; : > "$W/create-ok"; batch j3; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) || fail "T4: a create call that answers must release: $out"
  [ "$(grep -o 'https://' <<<"$out" | wc -l)" = 1 ] || fail "T4: the release must print one URL: $out"
  one_url_row "$U/815" T4
  pass 'T4 a create call that answers in full stores only its one URL in a one-line row'

  rm "$W/create-ok"; open_prs 816 817 > "$W/open-prs"; batch j4; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) && fail "T5: two open PRs from the trunk must stop the release: $out"
  assert_contains "$out" "$U/816" "T5: the release must print the first open PR"
  assert_contains "$out" "$U/817" "T5: the release must print the second open PR"
  [ "$(cat "$MARK")" != "$(tip)" ] && [ "$(wc -l < "$LEDGER")" = "$rows" ] || fail "T5: a stopped release must record nothing"
  pass 'T5 two open PRs from the trunk into main stop the release, both printed, nothing recorded'
}

test_a_release_keeps_one_url_and_takes_the_open_release_pr_as_success
printf 'jg-trunk-release-open-pr: ok\n'
