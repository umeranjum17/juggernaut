#!/usr/bin/env bash
# Behavior tests for bin/jg-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/jg-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/jg-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/jg-brief.sh emitted unexpected output: $out"
  pass "jg-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/jg-brief.sh" \
    || fail "jg-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "jg-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/jg-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "jg-brief.sh --help omitted its header terminator"
  pass "jg-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. jg-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# jg-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "jg-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "{JUGGERNAUT_SPEC}" "$brief" "$id: brief missing the {JUGGERNAUT_SPEC} placeholder"
    assert_grep "## Captain's intent" "$brief" "$id: brief missing Captain's intent subsection"
    assert_grep "## Juggernaut spec" "$brief" "$id: brief missing Juggernaut spec subsection"
    assert_grep 'never a bare number such as "PR 108"' "$brief" "$id: brief missing the full-PR-URL rule"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_grep "stage or commit your work and run the light gate locally over the files you changed, fixing every finding" "$brief" \
      "$id: brief missing the light gate every PR opens behind"
    assert_grep "needs that pull request's checks green" "$brief" \
      "$id: brief missing the rule that a done line needs the PR's checks green"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "jg-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# --forge forgejo is the Forgejo value of the project's registered forge binding
# (bin/jg-project-mode.sh --forge), passed at intake exactly like --mode. It
# names tea instead of gh-axi in the ship brief's forge-CLI rule and in the
# direct-PR Definition of done's own open-a-PR line, and it marks the delivery
# contract line so bin/jg-spawn.sh can check it against the registry. A brief
# with no --forge renders the unchanged gh-axi wording. The forge is a ship
# input only, and the closed set refuses anything else.
test_forge_selection_renders_correct_cli() {
  local home brief out rc
  home="$TMP_ROOT/forge-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-forge-default some-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "a ship brief with no --forge should still scaffold"
  brief="$home/data/brief-forge-default/brief.md"
  assert_grep "3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations." "$brief" \
    "a brief with no --forge must render the exact pre-existing gh-axi Rule 3 line"
  # shellcheck disable=SC2016 # Backticks are literal generated brief text.
  assert_grep 'open a PR with `gh-axi`' "$brief" \
    "a direct-PR brief with no --forge must still tell the worker to open the PR with gh-axi"
  grep -qx "Delivery contract: mode=direct-PR" "$brief" \
    || fail "a brief with no --forge must keep the bare delivery contract line"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-forge-forgejo some-proj --mode direct-PR --forge forgejo >/dev/null 2>&1 \
    || fail "--forge forgejo should scaffold a direct-PR ship brief"
  brief="$home/data/brief-forge-forgejo/brief.md"
  assert_grep "3. Use tea for Forgejo operations and chrome-devtools-axi for browser operations." "$brief" \
    "--forge forgejo must render the tea Rule 3 line"
  # shellcheck disable=SC2016 # Backticks are literal generated brief text.
  assert_grep 'open a PR with `tea`' "$brief" \
    "--forge forgejo's direct-PR DOD must tell the worker to open the PR with tea"
  grep -qx "Delivery contract: mode=direct-PR forge=forgejo" "$brief" \
    || fail "--forge forgejo must mark the delivery contract line for the spawn's registry check"
  # shellcheck disable=SC2016 # Backticks and braces are literal generated brief text.
  assert_grep 'confirm it is not a draft (`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<number>` must show `draft` as false' "$brief" \
    "--forge forgejo's direct-PR DOD must read the draft state back with tea"
  # shellcheck disable=SC2016 # Backticks are literal generated brief text.
  assert_grep 'remove that prefix with `tea pulls edit <number>' "$brief" \
    "--forge forgejo's direct-PR DOD must clear a draft with tea"
  assert_no_grep 'gh-axi pr view' "$brief" \
    "--forge forgejo's direct-PR DOD must not send the worker to gh-axi for the draft read-back"
  assert_no_grep 'gh-axi pr ready' "$brief" \
    "--forge forgejo's direct-PR DOD must not send the worker to gh-axi to clear a draft"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-forge-nm some-proj --mode no-mistakes --forge forgejo >/dev/null 2>&1 \
    || fail "--forge forgejo should scaffold a no-mistakes ship brief"
  brief="$home/data/brief-forge-nm/brief.md"
  assert_grep "3. Use tea for Forgejo operations and chrome-devtools-axi for browser operations." "$brief" \
    "a no-mistakes --forge forgejo brief must render the tea Rule 3 line"
  grep -qx "Delivery contract: mode=no-mistakes forge=forgejo" "$brief" \
    || fail "a no-mistakes --forge forgejo brief must mark the delivery contract line"
  # shellcheck disable=SC2016 # Backticks and braces are literal generated brief text.
  assert_grep 'confirm it is not a draft (`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<number>` must show `draft` as false' "$brief" \
    "a no-mistakes --forge forgejo DOD must read the draft state back with tea"
  assert_no_grep 'gh-axi pr view' "$brief" \
    "a no-mistakes --forge forgejo DOD must not send the worker to gh-axi for the draft read-back"
  assert_no_grep 'gh-axi pr ready' "$brief" \
    "a no-mistakes --forge forgejo DOD must not send the worker to gh-axi to clear a draft"

  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086 # The row's arguments must split into words.
    out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-forge-bad some-proj $args 2>&1); rc=$?
    expect_code 1 "$rc" "$label must be refused"
    assert_contains "$out" "$expect" "$label was refused without its reason"
    [ ! -e "$home/data/brief-forge-bad/brief.md" ] || fail "$label left a brief behind"
  done <<'ROWS'
a value outside the closed set|--mode direct-PR --forge gitlab|expected none, gerrit, or forgejo
the removed github value|--mode direct-PR --forge github|expected none, gerrit, or forgejo
forgejo on local-only|--mode local-only --forge forgejo|cannot ship mode=local-only
a shape on forgejo|--mode direct-PR --forge forgejo --shape squash|--shape applies only with --forge gerrit
forgejo on a scout|--scout --forge forgejo|apply only to ship briefs
ROWS

  pass "jg-brief.sh: --forge forgejo names tea in Rule 3, the direct-PR DOD, and the draft read-back, marks the delivery contract, and the closed set refuses everything else"
}

# A ship task's delivery mode is juggernaut's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "jg-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  write_registry "$home"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Juggernaut will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "jg-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is juggernaut's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a squad_lead charter|brief-refused-b4 --squad-lead --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "jg-brief.sh: --yolo and scout/squad_lead --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  write_registry "$home"
  id="brief-direct-authority-a4"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; juggernaut relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then juggernaut merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Juggernaut then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "jg-brief.sh: faster paths use configured authority without stacked review"
}

# A PR-based ship must not report done on a draft, which cannot be merged; a
# lane that deliberately holds a draft declares a wait instead. local-only opens
# no PR, so it must not carry the requirement.
test_pr_based_dod_requires_non_draft() {
  local home mode id brief
  home="$TMP_ROOT/draft-dod-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="brief-draft-$mode"
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode: brief was not scaffolded"
    if [ "$mode" = local-only ]; then
      assert_no_grep "isDraft" "$brief" "$mode: a branch-only delivery must not require a non-draft PR"
      continue
    fi
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`' "$brief" \
      "$mode: done must require reading the PR back from the forge as non-draft"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'mark it ready with `gh-axi pr ready <number>`' "$brief" \
      "$mode: a draft must be marked ready before done"
    assert_grep "If you deliberately keep the PR a draft, append \`paused" "$brief" \
      "$mode: a deliberate draft must declare a wait instead of done"
  done
  pass "jg-brief.sh: PR-based done requires a non-draft PR; a deliberate draft declares a wait"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief spelling
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  for spelling in 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:" 'Captain,'; do
    assert_no_grep "$spelling" "$brief" "rendered intent contract still teaches operator-address labels"
  done
  assert_grep '[captain]' "$brief" "rendered intent contract must explain the neutral legacy provenance marker"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$brief" \
    "no-mistakes DOD must require --intent to be the Captain's intent subsection"
  assert_grep "plus any later words the captain actually said" "$brief" \
    "no-mistakes DOD must allow later captain words in --intent"
  assert_grep "Do not include \`## Juggernaut spec\`" "$brief" \
    "no-mistakes DOD must keep Juggernaut spec out of --intent"
  assert_grep "or your own decisions and tradeoffs" "$brief" \
    "no-mistakes DOD must keep worker tradeoffs out of --intent"
  assert_grep "This replaces the no-mistakes skill's advice to enrich \`--intent\`" "$brief" \
    "no-mistakes DOD must override the external skill's enrich-with-decisions guidance"
  # A bare reference cannot preserve the captain's ask, so the rendered DOD states
  # the self-sufficiency rule and requires referenced material to be resolved into
  # its substance.
  assert_grep "The \`--intent\` string you pass must be self-sufficient" "$brief" \
    "no-mistakes DOD must require a self-sufficient --intent string"
  assert_grep "write the substance of the referenced items into \`--intent\`" "$brief" \
    "no-mistakes DOD must tell the worker to resolve report, decision, and PR references into substance"

  # The --yes ban is a fleet-wide prohibition, not a preference, and it must not
  # claim an enforcement the tool does not provide: this is instruction only.
  assert_grep "NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide." "$brief" \
    "no-mistakes DOD must state the --yes ban as a prohibition"
  assert_grep "answering your own ask-user finding is a hard rule violation" "$brief" \
    "no-mistakes DOD must say why --yes is banned"
  assert_no_grep "Avoid \`--yes\`" "$brief" \
    "no-mistakes DOD still states the --yes ban as a preference"
  assert_no_grep "no-mistakes refuses" "$brief" \
    "no-mistakes DOD must not claim the tool itself refuses --yes"
  pass "jg-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright"
}

# The green-PR report must not depend on a status poll: `axi status` never
# reports `checks-passed` while the ci step monitors the PR for merge, so a
# worker told to wait on it for the next gate or outcome never learned its PR
# went green (2026-09-22, PR #5317). The rendered DOD must make the drive
# call's own return the green signal and reattach after a bounded return.
test_no_mistakes_dod_green_detection() {
  local home id brief
  home="$TMP_ROOT/green-detection-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id="brief-green-b1"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Only a drive call's return reports the green PR" "$brief" \
    "no-mistakes DOD must make the drive call's return the green signal"
  assert_grep "never reports \`checks-passed\` while the ci step is still monitoring the PR for merge" "$brief" \
    "no-mistakes DOD must say axi status cannot show a green PR in merge monitoring"
  assert_grep "never wait on a status poll for the next gate or outcome" "$brief" \
    "no-mistakes DOD must forbid waiting on a status poll"
  assert_grep "reattach at once by re-running \`no-mistakes axi run\` without flags" "$brief" \
    "no-mistakes DOD must reattach the drive call after a bounded return"
  assert_grep "once checks are green it returns \`checks-passed\` immediately" "$brief" \
    "no-mistakes DOD must say a reattach reports an already-green PR"
  assert_no_grep "poll \`no-mistakes axi status\` from a separate call" "$brief" \
    "no-mistakes DOD still makes a status poll the wait for the next gate or outcome"
  pass "jg-brief.sh: no-mistakes DOD detects a green PR from the drive call, not a status poll"
}

test_ask_user_escalation_format() {
  local home id brief mode other_id other_brief
  home="$TMP_ROOT/ask-user-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id="brief-ask-user-d1"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # A no-mistakes ask-user gate must escalate its ask-user findings as one status
  # event plus one verbatim findings snapshot file, using that same shape even
  # for a single finding, never paraphrased into the status line.
  assert_grep "escalate all ask-user findings as one event plus one snapshot file" "$brief" \
    "ship rule 6 lost the one-event-plus-snapshot-file ask-user contract"
  assert_grep "using that same shape even when the gate holds only a single ask-user finding" "$brief" \
    "ship rule 6 must require the same shape for a single finding"
  assert_grep "write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority)" "$brief" \
    "ship rule 6 must limit the verbatim axi slice to ask-user findings"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks and the key/findings/file tokens must stay literal
  assert_grep 'needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must render the exact needs-decision ask-user status line"
  assert_grep "$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must point the snapshot file under this task's own data directory"
  assert_grep "The status line only points at the file; it never restates or summarizes a finding's content." "$brief" \
    "ship rule 6 must forbid paraphrasing ask-user findings into the status line"

  # The DOD's own ask-user paragraph must point back at rule 6's format
  # (one-owner rule) rather than restating or bare-citing it.
  assert_grep "escalate to juggernaut using rule 6's ask-user format" "$brief" \
    "no-mistakes DOD ask-user paragraph must point at rule 6's format instead of a bare citation"
  assert_no_grep "escalate to juggernaut (rule 6) and stop." "$brief" \
    "no-mistakes DOD ask-user paragraph still uses the old bare rule-6 pointer"

  other_id="brief-no-ask-user-scout"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$other_id" some-proj --scout >/dev/null 2>&1
  other_brief="$home/data/$other_id/brief.md"
  assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
    "scout brief received a no-mistakes-only decision case"

  for mode in direct-PR local-only; do
    other_id="brief-no-ask-user-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$other_id" some-proj --mode "$mode" >/dev/null 2>&1
    other_brief="$home/data/$other_id/brief.md"
    assert_no_grep "nm-<run>-findings.txt" "$other_brief" \
      "$mode brief received a no-mistakes-only escalation format"
    assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
      "$mode brief received a no-mistakes-only decision case"
  done

  pass "jg-brief.sh: no-mistakes ask-user findings use one event plus a verbatim snapshot"
}

# The project-memory section bounds operator edits of a project's AGENTS.md or
# CLAUDE.md to corrections of factually wrong information - including wrong
# information the task itself introduced - and never invites additions of
# missing knowledge, because those files tax every agent session of the project.
test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "loaded into every agent session" "$brief" \
    "project-memory contract lost the per-session cost rationale"
  assert_grep "only to correct information that is factually wrong" "$brief" \
    "project-memory contract lost the corrections-only bound"
  assert_grep "including information your own change made wrong" "$brief" \
    "project-memory contract lost the self-inflicted correction case"
  assert_grep "never to add knowledge because it is missing" "$brief" \
    "project-memory contract still permits additions of missing knowledge"
  assert_no_grep "if this task produced durable project-intrinsic knowledge" "$brief" \
    "project-memory contract still invites additions for durable knowledge"
  assert_grep "A correction edits only the wrong text: do not run \`$ROOT/bin/jg-ensure-agents-md.sh\`" "$brief" \
    "project-memory contract no longer forbids the ensure helper on a correction"
  pass "jg-brief.sh: ship project-memory wording bounds edits to corrections of wrong information"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/jg-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Juggernaut helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required \`--session \"\$HERDR_LAB_SESSION\"\` as a Herdr option, before any \`--\` delimiter" "$brief" \
    "Herdr lab brief missing the per-call session option contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "jg-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_juggernaut_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  foreign_root="$TMP_ROOT/juggernaut helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/jg-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  JG_HOME="$home" JG_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/jg-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Juggernaut helper path"
  assert_no_grep "bin/jg-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "jg-brief.sh: --herdr-lab uses its quoted Juggernaut-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --scout >/dev/null 2>&1
    else
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "jg-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# Regression (issue #2575): the task-dispatch skill and this script's own help tell
# juggernaut to fill `{TASK}` and `{JUGGERNAUT_SPEC}`. The unguarded Herdr gate used
# to quote `{TASK}` in its own prose, so that documented global replace spliced
# the whole task body into the middle of the gate's sentence - silently
# destroying the one contract that exists precisely because the scaffold cannot
# see the task text. Each placeholder must exist only at its genuine fill site,
# so the documented fill leaves the gate intact and each body appears once.
test_documented_global_replace_leaves_the_herdr_gate_intact() {
  local home id brief kind count content filled body spec
  home="$TMP_ROOT/task-fill-site-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  body='Restart the herdr session, then profile it'
  spec='Use the isolated lab helper for every lifecycle call'
  for kind in ship scout; do
    id="brief-fill-site-$kind"
    if [ "$kind" = scout ]; then
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --scout >/dev/null 2>&1
    else
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind brief was not scaffolded"
    count=$(grep -c -F '{TASK}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {TASK} fill site, found $count"
    count=$(grep -c -F '{JUGGERNAUT_SPEC}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {JUGGERNAUT_SPEC} fill site, found $count"
    content=$(cat "$brief")
    filled=${content//'{TASK}'/$body}
    filled=${filled//'{JUGGERNAUT_SPEC}'/$spec}
    count=$(printf '%s\n' "$filled" | grep -c -F "$body")
    [ "$count" = 1 ] \
      || fail "$kind brief: the documented {TASK} replace duplicated the intent body $count times"
    count=$(printf '%s\n' "$filled" | grep -c -F "$spec")
    [ "$count" = 1 ] \
      || fail "$kind brief: the {JUGGERNAUT_SPEC} replace duplicated the spec body $count times"
    printf '%s\n' "$filled" | grep -qF 'this scaffold cannot inspect the task text' \
      || fail "$kind brief: the Herdr safety gate did not survive the documented fill"
  done
  pass "jg-brief.sh: the documented {TASK} and {JUGGERNAUT_SPEC} fills cannot corrupt the Herdr safety gate"
}

test_squad_lead_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the juggernaut repo itself (no clones needed).
  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER='juggernaut self-development' \
    JG_SQUAD_LEAD_SCOPE='juggernaut repo work' \
    "$ROOT/bin/jg-brief.sh" fdev --squad-lead --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects squad_lead brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep '# The captain and the parent channel' "$brief" \
    "squad_lead charter lost the parent-channel section"
  assert_grep 'Nobody reads this chat' "$brief" \
    "squad_lead charter no longer says the chat is unread"
  assert_grep 'in this home it IS the captain' "$brief" \
    "squad_lead charter no longer names the parent channel as the captain"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "squad_lead charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "squad_lead charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "squad_lead charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER='x' "$ROOT/bin/jg-brief.sh" oops --squad-lead >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "squad_lead brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure squad_lead brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER='x' "$ROOT/bin/jg-brief.sh" oops2 --squad-lead --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to squad_lead charters, never a ship/scout brief.
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "jg-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_squad_lead_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  JG_HOME="$home" JG_CLASSIFY_PAUSED_VERB=paused \
    JG_SQUAD_LEAD_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/jg-brief.sh" marked-request-reporting --squad-lead --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "squad_lead charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "squad_lead charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "squad_lead charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "squad_lead charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "squad_lead charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "squad_lead charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "squad_lead charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "squad_lead charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "squad_lead charter lost correlated parent results"
  assert_grep 'bin/jg-squad-lead-report.sh <verb> <corr_id> <note>' "$brief" \
    "squad_lead charter lost the mechanical helper invocation"
  assert_grep 'do not pass a status path' "$brief" \
    "squad_lead charter still tells the mate to pass a hand path to the helper"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "squad_lead charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "squad_lead charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "squad_lead charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, work ready for review, or work you landed' "$brief" \
    "squad_lead charter lost decisions, blockers, failures, ready outcomes, or landed work"
  # Under standing merge authority nothing is ever "ready for review", so the
  # landed merge is the trigger a charter without this line silently omits.
  assert_grep 'a merge you performed yourself under standing merge authority and one the captain merged on the forge' "$brief" \
    "squad_lead charter did not name a landed merge as a reporting trigger"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "squad_lead charter changed the preserved status vocabulary"
  pass "jg-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_squad_lead_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER=x \
    "$ROOT/bin/jg-brief.sh" relative-home --squad-lead --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" JG_HOME=home JG_SQUAD_LEAD_CHARTER=x \
      "$ROOT/bin/jg-brief.sh" relative-home --squad-lead --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative JG_HOME changed charter bytes compared with the same absolute home"
  assert_grep "--append '$home/state/relative-home.status'" "$brief" \
    "relative JG_HOME did not render an absolute squad_lead status path"

  brief="$home/data/relative-state/brief.md"
  JG_HOME="$home" JG_STATE_OVERRIDE="$state_override" JG_SQUAD_LEAD_CHARTER=x \
    "$ROOT/bin/jg-brief.sh" relative-state --squad-lead --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" JG_HOME="$home" JG_STATE_OVERRIDE=state-override JG_SQUAD_LEAD_CHARTER=x \
      "$ROOT/bin/jg-brief.sh" relative-state --squad-lead --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative JG_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep "--append '$state_override/relative-state.status'" "$brief" \
    "relative JG_STATE_OVERRIDE did not render an absolute squad_lead status path"

  brief="$data_override/relative-data/brief.md"
  JG_HOME="$home" JG_DATA_OVERRIDE="$data_override" JG_SQUAD_LEAD_CHARTER=x \
    "$ROOT/bin/jg-brief.sh" relative-data --squad-lead --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" JG_HOME="$home" JG_DATA_OVERRIDE=data-override JG_SQUAD_LEAD_CHARTER=x \
      "$ROOT/bin/jg-brief.sh" relative-data --squad-lead --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative JG_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep "--append '$home/state/relative-data.status'" "$brief" \
    "relative JG_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    JG_HOME=missing-home JG_SQUAD_LEAD_CHARTER=x \
      "$ROOT/bin/jg-brief.sh" unresolved-home --squad-lead --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative JG_HOME must fail"
  assert_grep "JG_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative JG_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    JG_HOME="$home" JG_STATE_OVERRIDE=missing-state JG_SQUAD_LEAD_CHARTER=x \
      "$ROOT/bin/jg-brief.sh" unresolved-state --squad-lead --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative JG_STATE_OVERRIDE must fail"
  assert_grep "JG_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative JG_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    JG_HOME="$home" JG_DATA_OVERRIDE=missing-data JG_SQUAD_LEAD_CHARTER=x \
      "$ROOT/bin/jg-brief.sh" unresolved-data --squad-lead --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative JG_DATA_OVERRIDE must fail"
  assert_grep "JG_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative JG_DATA_OVERRIDE did not fail loudly"

  pass "jg-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_squad_leads() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" herdr-scout juggernaut --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER=ops "$ROOT/bin/jg-brief.sh" herdr-squad-lead --squad-lead juggernaut --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "squad_lead --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-squad-lead/brief.md" \
    "rejected squad_lead --herdr-lab still wrote a brief"
  pass "jg-brief.sh: Herdr lab contract covers scouts and rejects squad_lead misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief append now epoch templates template line signals
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"

  for kind in ship:no-mistakes ship:direct-PR ship:local-only scout squad_lead; do
    id="brief-pause-verb-${kind//:/-}"
    case "$kind" in
      ship:*)
        JG_HOME="$home" JG_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/jg-brief.sh" "$id" juggernaut --mode "${kind#ship:}" >/dev/null 2>&1
        ;;
      scout)
        JG_HOME="$home" JG_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/jg-brief.sh" "$id" juggernaut --scout >/dev/null 2>&1
        ;;
      squad_lead)
        JG_HOME="$home" JG_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/jg-brief.sh" "$id" --squad-lead --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    # Fill the scaffold's generated status-append command the way a worker does
    # and run it. The stamp must be a value the worker supplies, so the command
    # may not carry an unevaluated substitution that a file-write tool would
    # copy through verbatim.
    # shellcheck disable=SC2016 # Match literal backticks in the generated interface.
    append=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$brief")
    now=$(date +%s)
    append=${append//\{state\}/done}
    append=${append//\{one short line\}/test event}
    append=${append//<epoch>/$now}
    case "$append" in
      *"\$("*) fail "$kind scaffold left an unevaluated command in its status-append line" ;;
    esac
    mkdir -p "$home/state"
    bash -c "$append" || fail "generated status command failed"
    epoch=$(bash -c '. "$1"; status_line_at_epoch "$(cat "$2")"' _ \
      "$ROOT/bin/jg-classify-lib.sh" "$home/state/$id.status")
    [ "$epoch" = "$now" ] || fail "$kind scaffold did not record the worker's event time"
    # Every status signal the brief instructs a worker to append is a template
    # the worker fills in and writes verbatim, with or without a shell, not only
    # rule 4's echo: substitute each one's named placeholders and read the stamp
    # back. Extracting by "append" as well as by the stamp means dropping a stamp
    # from any instruction fails here rather than shrinking the set.
    templates=$(grep -o -e "append \`[^\`]*: [^\`]*\`" \
      -e "\`[^\`]*\[at=<epoch>\][^\`]*\`" "$brief" \
      | sed 's/^append //' | tr -d '`' | sort -u)
    signals=0
    while IFS= read -r template; do
      [ -n "$template" ] || continue
      case "$template" in
        'echo "'*) template=${template#echo \"}; template=${template%%\" >>*} ;;
      esac
      case "$template" in
        *"\$("*) fail "$kind signal embeds an unevaluated command: $template" ;;
      esac
      now=$(date +%s)
      line=${template//\{state\}/done}
      line=${line//<epoch>/$now}
      line=$(printf '%s' "$line" \
        | sed -e 's/{[^}]*}/one short line/g' -e 's/<[^>]*>/slug/g')
      epoch=$(bash -c '. "$1"; status_line_at_epoch "$2"' _ \
        "$ROOT/bin/jg-classify-lib.sh" "$line")
      [ "$epoch" = "$now" ] || fail "$kind signal carries no worker-written stamp: $template"
      signals=$((signals + 1))
    done <<SIGNALS
$templates
SIGNALS
    [ "$signals" -ge 4 ] \
      || fail "$kind brief instructed only $signals stamped status signals"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "jg-brief.sh: custom pause verb renders in every scaffold"
}

test_ship_and_scout_teach_validation_round_pause() {
  local home kind id brief
  home="$TMP_ROOT/validation-round-pause-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data" "$home/config"
  : > "$home/config/wait-no-turns"

  for kind in ship scout; do
    id="brief-validation-round-pause-$kind"
    if [ "$kind" = scout ]; then
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --scout >/dev/null 2>&1
    else
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" juggernaut --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "your own validation round, which you declare once just before its blocking hold" "$brief" \
      "$kind brief did not teach workers to declare their validation-round wait before holding it"
    assert_grep "append \`paused:\` once just before its first blocking command, then stay in the command" "$brief" \
      "$kind brief's Waiting section does not declare the validation round once and then hold it"
    assert_no_grep "is not a \`paused:\` wait" "$brief" \
      "$kind brief still tells workers never to declare a wait they hold in a command"
    assert_grep "your own validation round" "$brief" \
      "$kind brief did not teach workers to declare their validation-round wait"
    assert_grep 'Before ending your turn with your own background shell or monitor still running' "$brief" \
      "$kind brief did not require declaring a background-work wait"
    assert_grep 'before waiting on your own pipeline run or a long foreground command' "$brief" \
      "$kind brief did not require declaring a pipeline or foreground wait"
    assert_grep 'Juggernaut may still raise one first-sight alert' "$brief" \
      "$kind brief incorrectly promised to suppress the first alert"
    assert_grep 'Do not declare active implementation or reasoning as a wait' "$brief" \
      "$kind brief did not limit the declaration to actual waits"
  done
  pass "jg-brief.sh: ship and scout scaffolds declare a validation-round pause once, then hold it"
}

test_scout_and_squad_lead_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/jg-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" JG_SQUAD_LEAD_CHARTER='sample reviews' \
    "$ROOT/bin/jg-brief.sh" sample-mate --squad-lead --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "squad_lead charter did not load the shared captain-call policy for detailed investigations"
  pass "jg-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# A scout brief sends a visual deliverable to a sign-off board report and never
# to a retired review surface.
test_scout_brief_names_sign_off_only() {
  local home="$TMP_ROOT/scout-signoff" fakebin brief
  mkdir -p "$home/data"
  fakebin=$(jg_fakebin "$TMP_ROOT/scout-signoff-bin")
  PATH="$fakebin:${JG_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" JG_HOME="$home" \
    "$ROOT/bin/jg-brief.sh" scout-signoff alpha --scout >/dev/null \
    || fail 'scout scaffold failed'
  brief="$home/data/scout-signoff/brief.md"
  assert_grep 'sign-off board report' "$brief" \
    'scout brief did not send a visual deliverable to a sign-off board report'
  assert_grep 'return the sign-off report link only' "$brief" \
    'scout brief did not ask for the sign-off report link only'
  assert_no_grep 'Lavish' "$brief" 'scout brief still named the retired review surface'
  assert_no_grep 'lavish-axi' "$brief" 'scout brief still named the retired tool'
  pass 'jg-brief.sh: a scout brief names the sign-off board and no retired review surface'
}

# Scout and squad_lead paths still scaffold well-formed briefs.
test_scout_and_squad_lead_scaffold() {
  local brief
  JG_HOME="$BRIEF_HOME" "$ROOT/bin/jg-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "jg-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "## Captain's intent" "$brief" "scout brief missing Captain's intent subsection"
  assert_grep "## Juggernaut spec" "$brief" "scout brief missing Juggernaut spec subsection"
  assert_grep "{JUGGERNAUT_SPEC}" "$brief" "scout brief missing the spec placeholder"

  JG_SQUAD_LEAD_CHARTER='Supervise the alpha domain.' \
    JG_HOME="$BRIEF_HOME" "$ROOT/bin/jg-brief.sh" brief-sm-q6 --squad-lead alpha >/dev/null 2>&1 \
    || fail "jg-brief.sh squad_lead scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "squad_lead charter was not scaffolded"
  assert_grep "persistent squad lead" "$brief" \
    "squad_lead charter must declare its role"
  assert_no_grep "## Captain's intent" "$brief" \
    "squad_lead charter must not grow ship/scout Task subsections"
  assert_no_grep "{JUGGERNAUT_SPEC}" "$brief" \
    "squad_lead charter must not carry the Juggernaut spec placeholder"
  pass "jg-brief: scout and squad_lead code paths still scaffold well-formed briefs"
}

# Contract: a waiting worker spends no turns. A decision wait ends the turn, an
# external wait sleeps in one bounded blocking shell command sized per harness,
# and a waiting worker neither polls its inbox nor polls a pipeline between holds.
test_workers_wait_without_spending_turns() {
  local home id brief
  home="$TMP_ROOT/wait-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data" "$home/config"
  : > "$home/config/wait-no-turns"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-wait-ship some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "jg-brief.sh ship scaffold exited non-zero"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-wait-scout some-proj --scout >/dev/null 2>&1 \
    || fail "jg-brief.sh scout scaffold exited non-zero"
  for id in brief-wait-ship brief-wait-scout; do
    brief="$home/data/$id/brief.md"
    assert_grep "end your turn at once" "$brief" "$id: a decision wait must end the turn"
    assert_grep "with ONE blocking shell command that returns when the state changes" "$brief" \
      "$id: an external wait must sleep in one blocking shell command"
    assert_grep "gh pr checks <pr> --watch" "$brief" "$id: the CI wait primitive is missing"
    assert_grep "a \`timeout\` of at most 2700 seconds" "$brief" "$id: the Pi ceiling is missing"
    assert_grep "its maximum \`timeout\` of 600000 ms" "$brief" "$id: the Claude Code ceiling is missing"
    assert_grep "empty \`write_stdin\` polls of up to 300000 ms" "$brief" "$id: the Codex ceiling is missing"
    assert_grep "is the sanctioned foreground wait" "$brief" \
      "$id: the wait a Claude Code worker may use is not named"
    assert_grep "reattach with \`no-mistakes axi run --wait\` instead, and never send the same \`respond\` again" "$brief" \
      "$id: a timed-out respond must reattach with axi run, never resend its answer"
    assert_grep "Do not poll or list the inbox while waiting; a waiting instruction rings." "$brief" \
      "$id: polling the inbox while waiting is not forbidden"
    assert_grep "natural checkpoint" "$brief" "$id: the flag dropped the natural-checkpoint inbox check"
  done
  brief="$home/data/brief-wait-ship/brief.md"
  assert_grep "issue the same foreground call again" "$brief" \
    "the no-mistakes DOD must reattach with the same foreground call"
  assert_no_grep "background the drive call" "$brief" "the no-mistakes DOD still backgrounds the drive call"

  JG_SQUAD_LEAD_CHARTER='Supervise the alpha domain.' \
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-wait-sm --squad-lead --no-projects >/dev/null 2>&1 \
    || fail "jg-brief.sh squad_lead scaffold exited non-zero"
  brief="$home/data/brief-wait-sm/brief.md"
  assert_grep "Do not poll or list the inbox while waiting; a waiting instruction rings." "$brief" \
    "squad_lead: polling the inbox while waiting is not forbidden"
  assert_grep "natural checkpoint" "$brief" "squad_lead: the flag dropped the natural-checkpoint inbox check"
  pass "jg-brief: workers end the turn on a decision, wait in one bounded shell command, and never poll"
}

# Without config/wait-no-turns the scaffold matches the pre-flag brief and drive text.
test_wait_no_turns_absent_keeps_the_previous_brief() {
  local home brief
  home="$TMP_ROOT/wait-off"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  [ ! -e "$home/config/wait-no-turns" ]
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-wait-off some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "jg-brief.sh ship scaffold exited non-zero"
  brief="$home/data/brief-wait-off/brief.md"
  assert_no_grep "end your turn at once" "$brief" "an absent flag still added the waiting section"
  assert_grep "natural checkpoint" "$brief" "an absent flag dropped the unprompted inbox check"
  assert_no_grep "Do not poll or list the inbox while waiting" "$brief" "an absent flag still added the no-poll inbox line"
  assert_grep "background the drive call" "$brief" "an absent flag replaced the backgrounded drive text"
  assert_no_grep "issue the same foreground call again" "$brief" \
    "an absent flag still asked for the foreground reattach"
  pass "jg-brief: without config/wait-no-turns the brief and drive text stay as they were"
}

test_worker_role_scope() {
  local kind home brief
  home="$TMP_ROOT/worker-role"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  for kind in no-mistakes direct-PR local-only scout; do
    if [ "$kind" = scout ]; then
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$kind" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
    else
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$kind" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
    fi
    brief="$home/data/$kind/brief.md"
    assert_no_grep '# Current worker role contract' "$brief" "$kind scaffolded a second owner of the role scope jg-spawn.sh delivers"
  done
  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER='Supervise assigned work.' \
    "$ROOT/bin/jg-brief.sh" supervisor --squad-lead --no-projects >/dev/null || fail "squad_lead scaffold failed"
  brief="$home/data/supervisor/brief.md"
  assert_no_grep '# Current worker role contract' "$brief" "squad_lead received the worker exception"
  assert_no_grep 'do not adopt the supervisor identity' "$brief" "squad_lead received the worker exception"
  assert_grep "The local \`AGENTS.md\` is your job description" "$brief" "squad_lead lost its supervisor contract"
  assert_grep 'That file is your parent channel' "$brief" "squad_lead lost its parent channel"
  pass "jg-brief: scaffolds leave the worker role scope to the launch boundary and keep the squad_lead contract"
}

# A home can carry standing worker instructions in its gitignored
# config/brief-include.md. The include must land last on ship and scout
# scaffolds, stay out of charters, change nothing when absent or blank, and stop
# the scaffold before anything is written when the path is unusable.
test_home_brief_include_is_appended_last() {
  local home config brief kind out rc last_heading task_count
  home="$TMP_ROOT/include-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  config="$home/config"
  mkdir -p "$config"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" include-absent some-proj --scout >/dev/null || fail "scout scaffold failed without an include"
  assert_no_grep '# Home brief additions' "$home/data/include-absent/brief.md" "an absent include still added a section"
  printf ' \n\n' > "$config/brief-include.md"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" include-blank some-proj --scout >/dev/null || fail "scout scaffold failed with a blank include"
  assert_no_grep '# Home brief additions' "$home/data/include-blank/brief.md" "a blank include still added a section"

  # shellcheck disable=SC2016 # The include is literal text and must never expand at scaffold time.
  printf '%s\n' '# Task' 'Run `house-tool $(id)` first.' > "$config/brief-include.md"
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "include-$kind" some-proj --scout >/dev/null || fail "scout scaffold failed with an include"
    else
      JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "include-$kind" some-proj --mode no-mistakes >/dev/null || fail "ship scaffold failed with an include"
    fi
    brief="$home/data/include-$kind/brief.md"
    # shellcheck disable=SC2016 # Literal include text.
    assert_grep 'Run `house-tool $(id)` first.' "$brief" "$kind brief did not carry the include verbatim"
    assert_grep 'every other section of this brief takes precedence' "$brief" "$kind include section lost its precedence line"
    last_heading=$(grep -n '^# ' "$brief" | grep -v -x '[0-9]*:# Task' | tail -n 1)
    [ "${last_heading#*:}" = '# Home brief additions' ] \
      || fail "$kind include was not the last generated section (got: $last_heading)"
    task_count=$(sed -n '/^# Home brief additions$/q;p' "$brief" | grep -c -x '# Task')
    [ "$task_count" = 1 ] || fail "$kind scaffold lost its own # Task section ahead of the include"
  done

  printf '%s\n' 'Delivery contract: mode=local-only' > "$config/brief-include.md"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" include-contract some-proj --scout 2>&1); rc=$?
  expect_code 1 "$rc" "an include carrying a delivery contract line must stop the scaffold"
  assert_contains "$out" "must not carry a 'Delivery contract: mode=' line" "delivery-contract refusal did not explain itself"
  assert_absent "$home/data/include-contract" "a refused include left a partial scaffold behind"
  printf '%s\n' 'Prefer small commits.' > "$config/brief-include.md"

  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER='Supervise assigned work.' \
    "$ROOT/bin/jg-brief.sh" include-mate --squad-lead --no-projects >/dev/null || fail "squad_lead scaffold failed with an include"
  assert_no_grep '# Home brief additions' "$home/data/include-mate/brief.md" "a squad_lead charter took the brief include"

  JG_HOME="$home" JG_CONFIG_OVERRIDE="$TMP_ROOT/include-empty-config" \
    "$ROOT/bin/jg-brief.sh" include-override some-proj --scout >/dev/null || fail "scout scaffold failed under JG_CONFIG_OVERRIDE"
  assert_no_grep '# Home brief additions' "$home/data/include-override/brief.md" "JG_CONFIG_OVERRIDE did not select the config directory"

  rm -f "$config/brief-include.md"
  mkdir "$config/brief-include.md"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" include-unusable some-proj --scout 2>&1); rc=$?
  expect_code 1 "$rc" "an unusable include path must stop the scaffold"
  assert_contains "$out" "brief-include.md must be a readable regular file" "unusable include refusal did not name the file"
  assert_absent "$home/data/include-unusable" "an unusable include left a partial scaffold behind"
  pass "jg-brief.sh: the home brief include lands last on ship and scout, verbatim, and fails closed"
}

# With the brief-inherit feature uninstalled, the scaffold still succeeds and the
# home-local include lands last.
test_brief_include_works_without_add_on() {
  local home addons brief last_heading
  home="$TMP_ROOT/no-add-on-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  addons="$TMP_ROOT/no-add-on-empty"
  mkdir -p "$home/config" "$addons"
  printf '%s\n' 'Prefer small commits.' > "$home/config/brief-include.md"
  JG_HOME="$home" JG_ADDONS_DIR="$addons" "$ROOT/bin/jg-brief.sh" no-add-on some-proj --scout >/dev/null \
    || fail "scout scaffold failed without the brief-inherit feature"
  brief="$home/data/no-add-on/brief.md"
  assert_grep 'Prefer small commits.' "$brief" "home-local include missing without the feature"
  last_heading=$(grep '^# ' "$brief" | tail -n 1)
  [ "$last_heading" = '# Home brief additions' ] \
    || fail "home-local include was not the last section without the feature (got: $last_heading)"
  pass "jg-brief.sh: with no brief-inherit feature, the home-local include still lands last"
}

# --base-branch names the branch a task starts from and a ship's PR targets. It is
# recorded as a Base branch line under # Setup, which jg-spawn reads back, and is
# refused where no pull request carries the work.
test_base_branch_is_rendered_and_bounded() {
  local home out rc brief base meta_base
  home="$TMP_ROOT/base-branch-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  # shellcheck source=bin/jg-dod-lib.sh
  . "$ROOT/bin/jg-dod-lib.sh"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-dp-b1 some-proj --mode direct-PR --base-branch feature/hub >/dev/null 2>&1 \
    || fail "direct-PR --base-branch should scaffold"
  brief="$home/data/brief-base-dp-b1/brief.md"
  base=$(jg_brief_base_branches "$brief")
  [ "$base" = feature/hub ] || fail "the direct-PR brief recorded base '$base', not feature/hub"
  # shellcheck disable=SC2016  # literal backticks in rendered prose must stay unexpanded
  assert_grep 'open a PR with `gh-axi` that is ready for review, not a draft, against the base branch `feature/hub` (`--base feature/hub`)' "$brief" \
    "the direct-PR definition of done does not target the base branch"
  # shellcheck disable=SC2016
  assert_grep 'Never push to the base branch `feature/hub` or the default branch' "$brief" \
    "the direct-PR safety rule does not protect the base branch"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-nm-b2 some-proj --mode no-mistakes --base-branch release/1.2 >/dev/null 2>&1 \
    || fail "no-mistakes --base-branch should scaffold"
  brief="$home/data/brief-base-nm-b2/brief.md"
  # shellcheck disable=SC2016
  assert_grep 'pass `--base-branch release/1.2` on every `no-mistakes axi run`' "$brief" \
    "the no-mistakes definition of done does not pass the base branch to the pipeline"

  # A base git accepts but the shell would expand is quoted in worker commands.
  # shellcheck disable=SC2016  # the literal $HOTFIX is the point
  meta_base='release/$HOTFIX'
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-meta-b8 some-proj --mode no-mistakes --base-branch "$meta_base" >/dev/null 2>&1 \
    || fail "no-mistakes --base-branch with a shell metacharacter should scaffold"
  brief="$home/data/brief-base-meta-b8/brief.md"
  base=$(jg_brief_base_branches "$brief")
  [ "$base" = "$meta_base" ] || fail "the brief recorded base '$base', not $meta_base"
  # shellcheck disable=SC2016
  assert_grep 'pass `--base-branch release/\$HOTFIX` on every' "$brief" \
    "the no-mistakes command did not shell-quote the base branch"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-meta-b9 some-proj --mode direct-PR --base-branch "$meta_base" >/dev/null 2>&1 \
    || fail "direct-PR --base-branch with a shell metacharacter should scaffold"
  # shellcheck disable=SC2016
  assert_grep '(`--base release/\$HOTFIX`)' "$home/data/brief-base-meta-b9/brief.md" \
    "the direct-PR command did not shell-quote the base branch"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-scout-b3 some-proj --scout --base-branch feature/hub >/dev/null 2>&1 \
    || fail "scout --base-branch should scaffold"
  base=$(jg_brief_base_branches "$home/data/brief-base-scout-b3/brief.md")
  [ "$base" = feature/hub ] || fail "the scout brief recorded base '$base', not feature/hub"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-none-b4 some-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/brief-base-none-b4/brief.md"
  ! jg_brief_base_branches "$brief" >/dev/null || fail "a brief without --base-branch recorded a base"
  assert_grep 'at a detached HEAD on a clean default branch.' "$brief" \
    "a brief without --base-branch changed its default-branch setup line"

  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-lo-b5 some-proj --mode local-only --base-branch feature/hub 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "local-only --base-branch should be refused"
  assert_contains "$out" "mode=local-only" "the local-only refusal did not explain itself"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-bad-b6 some-proj --mode direct-PR --base-branch 'bad..name' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid base branch name should be refused"
  out=$(JG_HOME="$home" JG_SQUAD_LEAD_CHARTER=charter "$ROOT/bin/jg-brief.sh" brief-base-sm-b7 --squad-lead --no-projects --base-branch feature/hub 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a squad_lead charter should refuse --base-branch"
  for id in brief-base-lo-b5 brief-base-bad-b6 brief-base-sm-b7; do
    [ ! -e "$home/data/$id/brief.md" ] || fail "a refused --base-branch scaffold wrote $id"
  done
  pass "jg-brief.sh: --base-branch records the base, targets the PR at it, and is refused where no PR carries it"
}

# (a) An unregistered/default project - no --branch-prefix passed at all - must
# keep every generated ship mode's branch on the legacy "fm/<task-id>" name, byte
# for byte, so every existing juggernaut installation is unaffected.
test_ship_branch_prefix_defaults_to_legacy_fm() {
  local home id mode brief
  home="$TMP_ROOT/branch-prefix-default-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  for id_mode in "brief-branch-nm-e1:no-mistakes" "brief-branch-dp-e2:direct-PR" "brief-branch-lo-e3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    # shellcheck disable=SC2016  # literal backticks around the branch name must stay unexpanded
    assert_grep "\`git checkout -b fm/$id --\`" "$brief" \
      "$mode: omitting --branch-prefix must still create the legacy fm/<task-id> branch"
  done
  pass "jg-brief.sh: --branch-prefix omitted defaults every ship mode to fm/<task-id>"
}

# A project that carries a version branch (release/c-<N>) is where new work
# belongs, so a ship brief scaffolded with that project records the branch as its
# base with no --base-branch flag, and the Definition of done targets it.
# A project without one keeps the default-branch setup sentence, a mode that
# publishes nothing keeps no base, and an explicit flag still wins.
# bin/jg-version-branch-lib.sh owns which branch that is; bin/jg-spawn.sh
# resolves the same default and refuses a brief that disagrees.
test_base_branch_defaults_to_the_project_version_branch() {
  local home proj brief
  home="$TMP_ROOT/base-default-home"
  mkdir -p "$home/config" "$home/data" && : > "$home/config/delivery-risk-loose"
  proj="$TMP_ROOT/base-default-proj"
  jg_git_init_commit "$proj"
  git -C "$proj" branch -q release/c-3

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-default-v1 some-proj \
    --mode direct-PR --project "$proj" >/dev/null 2>&1 \
    || fail "a project with a version branch should scaffold"
  brief="$home/data/brief-base-default-v1/brief.md"
  # shellcheck source=bin/jg-dod-lib.sh
  . "$ROOT/bin/jg-dod-lib.sh"
  [ "$(jg_brief_base_branches "$brief")" = release/c-3 ] \
    || fail "the brief did not default its base to the project's version branch"
  # shellcheck disable=SC2016  # literal backticks in rendered prose must stay unexpanded
  assert_grep 'against the base branch `release/c-3` (`--base release/c-3`)' "$brief" \
    "the Definition of done did not target the version branch"

  # An explicit base still wins over the project's version branch.
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-default-v2 some-proj \
    --mode direct-PR --project "$proj" --base-branch feature/hub >/dev/null 2>&1 \
    || fail "an explicit --base-branch should scaffold"
  brief="$home/data/brief-base-default-v2/brief.md"
  [ "$(jg_brief_base_branches "$brief")" = feature/hub ] \
    || fail "an explicit --base-branch was overridden by the project's version branch"

  # A mode that publishes nothing carries no base, on the same project.
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-default-v3 some-proj \
    --mode local-only --project "$proj" >/dev/null 2>&1 \
    || fail "local-only with a project directory should scaffold"
  brief="$home/data/brief-base-default-v3/brief.md"
  ! jg_brief_base_branches "$brief" >/dev/null \
    || fail "a local-only brief recorded a base it cannot land"

  # A project without a version branch keeps the default-branch setup.
  proj="$TMP_ROOT/base-default-plain"
  jg_git_init_commit "$proj"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-base-default-v4 some-proj \
    --mode direct-PR --project "$proj" >/dev/null 2>&1 \
    || fail "a project without a version branch should scaffold"
  brief="$home/data/brief-base-default-v4/brief.md"
  ! jg_brief_base_branches "$brief" >/dev/null \
    || fail "a project without a version branch recorded a base"
  assert_grep 'at a detached HEAD on a clean default branch.' "$brief" \
    "a project without a version branch changed its default-branch setup line"
  pass "jg-brief.sh: a project's version branch is the default base"
}

# (b) + (c) A configured override must replace "fm/" everywhere the branch name is
# rendered - the branch-creation command, the never-push rule text, the
# definition-of-done text, and the status-message text - never partially.
test_ship_branch_prefix_override_is_consistent_across_modes() {
  local home id brief
  home="$TMP_ROOT/branch-prefix-override-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"

  id="brief-branch-override-nm-e4"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode no-mistakes --branch-prefix 'contrib/' >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016
  assert_grep "\`git checkout -b contrib/$id --\`" "$brief" \
    "no-mistakes: branch-creation command did not use the configured override"
  assert_no_grep "fm/$id" "$brief" \
    "no-mistakes: brief mixed the legacy fm/ prefix in with the configured override"

  id="brief-branch-override-dp-e5"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode direct-PR --branch-prefix 'contrib/' >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016
  assert_grep "\`git checkout -b contrib/$id --\`" "$brief" \
    "direct-PR: branch-creation command did not use the configured override"
  # shellcheck disable=SC2016
  assert_grep "push only your \`contrib/$id\` branch" "$brief" \
    "direct-PR: never-push rule text did not use the configured override"
  assert_no_grep "fm/$id" "$brief" \
    "direct-PR: brief mixed the legacy fm/ prefix in with the configured override"

  id="brief-branch-override-lo-e6"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode local-only --branch-prefix 'contrib/' >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016
  assert_grep "\`git checkout -b contrib/$id --\`" "$brief" \
    "local-only: branch-creation command did not use the configured override"
  # shellcheck disable=SC2016
  assert_grep "Work only on your \`contrib/$id\` branch" "$brief" \
    "local-only: never-push rule text did not use the configured override"
  # shellcheck disable=SC2016
  assert_grep "committed on your branch \`contrib/$id\`" "$brief" \
    "local-only: definition-of-done text did not use the configured override"
  # shellcheck disable=SC2016
  assert_grep "\`done [at=<epoch>]: ready in branch contrib/$id\`" "$brief" \
    "local-only: status-message text did not use the configured override"
  assert_no_grep "fm/$id" "$brief" \
    "local-only: brief mixed the legacy fm/ prefix in with the configured override"
  pass "jg-brief.sh: a --branch-prefix override renders identically across every generated section"
}

# An empty override must still resolve to a valid, sensible branch name: the bare
# task id, never a leading slash and never an empty branch name.
test_ship_branch_prefix_empty_override_yields_bare_task_id() {
  local home id brief
  home="$TMP_ROOT/branch-prefix-bare-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  id="brief-branch-bare-e7"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode local-only --branch-prefix '' >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016
  assert_grep "\`git checkout -b $id --\`" "$brief" \
    "an empty --branch-prefix must yield a bare <task-id> branch"
  assert_no_grep "checkout -b /$id" "$brief" \
    "an empty --branch-prefix produced a leading-slash branch name"
  assert_no_grep "fm/$id" "$brief" \
    "an empty --branch-prefix left the legacy fm/ prefix in place"
  pass "jg-brief.sh: an empty --branch-prefix override resolves to a bare <task-id> branch"
}

test_branch_prefix_is_refused_where_it_does_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/branch-prefix-refused-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
    assert_absent "$home/data/${args%% *}/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
branch-prefix on a scout brief|brief-branchref-f1 some-proj --scout --branch-prefix fix/|--branch-prefix applies only to ship briefs
branch-prefix on a squad_lead charter|brief-branchref-f2 --squad-lead --no-projects --branch-prefix fix/|--branch-prefix applies only to ship briefs
ROWS
  pass "jg-brief.sh: --branch-prefix is refused on scout and squad_lead scaffolds"
}

# The UI change flag (nav-check yes/no) is ship-only: yes adds the no-silent-removal
# rule and the Nav lines, no records the call, anything else is refused.
test_ui_change_field() {
  local home brief out status
  home="$TMP_ROOT/ui-change-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-ui-yes some-proj --mode direct-PR --ui-change yes >/dev/null \
    || fail "ui-change yes scaffold failed"
  brief=$(cat "$home/data/brief-ui-yes/brief.md")
  assert_contains "$brief" "UI change (nav-check): yes" "yes line missing"
  assert_contains "$brief" "never removes or renames an existing menu, tab or screen" "rule missing"
  assert_contains "$brief" "Nav before:" "Nav before instruction missing"
  assert_contains "$brief" "Nav after:" "Nav after instruction missing"
  assert_contains "$brief" "must name each removed screen" "design-option rule missing"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-ui-no some-proj --mode direct-PR --ui-change no >/dev/null \
    || fail "ui-change no scaffold failed"
  brief=$(cat "$home/data/brief-ui-no/brief.md")
  assert_contains "$brief" "UI change (nav-check): no" "no line missing"
  assert_not_contains "$brief" "Nav before:" "no must not carry the Nav rule"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-ui-none some-proj --mode direct-PR >/dev/null \
    || fail "scaffold without ui-change failed"
  assert_not_contains "$(cat "$home/data/brief-ui-none/brief.md")" "UI change (nav-check)" "omitted flag wrote a line"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-ui-bad some-proj --mode direct-PR --ui-change maybe 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "expected a refusal for --ui-change maybe"
  assert_absent "$home/data/brief-ui-bad/brief.md" "refused scaffold wrote a brief"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-ui-scout some-proj --scout --ui-change yes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "scout accepted --ui-change"
  assert_contains "$out" "applies only to ship briefs" "scout refusal did not explain why"
  pass "jg-brief.sh: --ui-change records yes/no, carries the nav rule, and refuses misuse"
}

# The design call (first-draft yes/no plus a reason) is a ship-only pair: yes adds
# the receipt instruction, no records the call, and any half-set or misplaced
# pair is refused before a brief is written.
test_design_call_field() {
  local home brief out status
  home="$TMP_ROOT/design-call-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-design-yes some-proj --mode direct-PR \
    --design-call yes --design-reason "new landing page" >/dev/null || fail "design-call yes scaffold failed"
  brief=$(cat "$home/data/brief-design-yes/brief.md")
  assert_contains "$brief" "Design call (first-draft): yes - new landing page" "yes call line missing"
  assert_contains "$brief" "first-draft receipt: <the run record file>" "yes call must ask for the receipt line"
  assert_contains "$brief" "never hand-write option HTML" "yes call must forbid hand-authored option HTML"
  assert_contains "$brief" "judge-only record" "yes call must refuse a judge-only receipt"
  assert_contains "$brief" "jg-design-gate.sh board" "yes call must name the board-post check"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-design-no some-proj --mode direct-PR \
    --design-call no --design-reason "one-line copy fix" >/dev/null || fail "design-call no scaffold failed"
  brief=$(cat "$home/data/brief-design-no/brief.md")
  assert_contains "$brief" "Design call (first-draft): no - one-line copy fix" "no call line missing"
  assert_not_contains "$brief" "never hand-write option HTML" "no call must not carry the yes instruction"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-design-none some-proj --mode direct-PR >/dev/null \
    || fail "scaffold without a design call failed"
  assert_not_contains "$(cat "$home/data/brief-design-none/brief.md")" "Design call (first-draft)" "omitted flag wrote a call"
  for args in "--design-call yes" "--design-reason why" "--design-call maybe --design-reason why"; do
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-design-bad some-proj --mode direct-PR $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "expected a refusal for: $args"
    assert_absent "$home/data/brief-design-bad/brief.md" "refused scaffold wrote a brief ($args)"
  done
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-design-scout some-proj --scout --design-call no --design-reason why 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "scout accepted a design call"
  assert_contains "$out" "apply only to ship briefs" "scout refusal did not explain why"
  pass "jg-brief.sh: --design-call records yes/no with a reason and refuses misuse"
}

# The TakeOne demo-video call is a ship-only pair like the design call, and takes
# effect only while the home has config/takeone-demo: off, the pair is validated and
# the brief carries no demo line; on, yes adds the receipt instruction.
test_demo_call_field() {
  local home brief out status args
  home="$TMP_ROOT/demo-call-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data" "$home/config"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-demo-off some-proj --mode direct-PR \
    --demo-call yes --demo-reason "launch video" >/dev/null || fail "demo-call scaffold with the switch off failed"
  assert_not_contains "$(cat "$home/data/brief-demo-off/brief.md")" "Demo-video call" "switch off must not write a demo line"
  : > "$home/config/takeone-demo"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-demo-yes some-proj --mode direct-PR \
    --demo-call yes --demo-reason "launch video" >/dev/null || fail "demo-call yes scaffold failed"
  brief=$(cat "$home/data/brief-demo-yes/brief.md")
  assert_contains "$brief" "Demo-video call (TakeOne): yes - launch video" "yes call line missing"
  assert_contains "$brief" "takeone receipt: <reference>" "yes call must ask for the receipt line"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-demo-no some-proj --mode direct-PR \
    --demo-call no --demo-reason "no video in this task" >/dev/null || fail "demo-call no scaffold failed"
  brief=$(cat "$home/data/brief-demo-no/brief.md")
  assert_contains "$brief" "Demo-video call (TakeOne): no - no video in this task" "no call line missing"
  assert_not_contains "$brief" "takeone receipt: <reference>" "no call must not ask for a receipt"
  for args in "--demo-call yes" "--demo-reason why" "--demo-call maybe --demo-reason why"; do
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-demo-bad some-proj --mode direct-PR $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "expected a refusal for: $args"
    assert_absent "$home/data/brief-demo-bad/brief.md" "refused scaffold wrote a brief ($args)"
  done
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-demo-scout some-proj --scout --demo-call no --demo-reason why 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "scout accepted a demo-video call"
  assert_contains "$out" "apply only to ship briefs" "scout refusal did not explain why"
  pass "jg-brief.sh: --demo-call records yes/no with a reason behind config/takeone-demo and refuses misuse"
}

# A branch prefix is embedded verbatim into a `git checkout -b` command in the
# generated brief, so a space or a leading dash could corrupt or hijack that
# command; both must be rejected loudly rather than silently accepted.
test_branch_prefix_value_is_validated() {
  local home out status
  home="$TMP_ROOT/branch-prefix-validated-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"

  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-branchval-g1 some-proj --mode no-mistakes --branch-prefix 'bad prefix/' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a space-containing --branch-prefix should be refused"
  assert_contains "$out" "must not contain a space" "space-containing --branch-prefix did not explain why"
  assert_absent "$home/data/brief-branchval-g1/brief.md" "refused space-containing --branch-prefix still wrote a brief"

  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-branchval-g2 some-proj --mode no-mistakes --branch-prefix=-oops 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a dash-leading --branch-prefix should be refused"
  assert_contains "$out" "must not start with '-'" "dash-leading --branch-prefix did not explain why"
  assert_absent "$home/data/brief-branchval-g2/brief.md" "refused dash-leading --branch-prefix still wrote a brief"

  pass "jg-brief.sh: --branch-prefix value is validated against embedded spaces and a leading dash"
}

test_branch_prefix_command_is_shell_safe() {
  local home id prefix marker brief command repo branch
  home="$TMP_ROOT/branch-prefix-shell-safe-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  marker="$TMP_ROOT/branch-prefix-shell-safe-marker"
  id='brief-branch-safe-g3'
  prefix="\$(touch\${IFS}$marker)"
  mkdir -p "$home/data"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" some-proj --mode local-only --branch-prefix "$prefix" >/dev/null 2>&1 \
    || fail "a ref-format-valid metacharacter prefix should scaffold safely"
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # The sed expression intentionally contains literal backticks.
  command=$(sed -n 's/^1\. First action: create your branch: `\(.*\)`$/\1/p' "$brief")
  [ -n "$command" ] || fail "generated brief exposed no branch-creation command"
  repo="$TMP_ROOT/branch-prefix-shell-safe-repo"
  git init -q "$repo" || fail "could not initialize shell-safety fixture repository"
  ( cd "$repo" && eval "$command" ) || fail "generated branch-creation command did not run"
  assert_absent "$marker" "generated branch command executed the prefix's command substitution"
  branch=$(git -C "$repo" branch --show-current)
  [ "$branch" = "$prefix$id" ] \
    || fail "generated branch command did not create the literal configured branch (got '$branch')"
  pass "jg-brief.sh: ref-format-valid shell metacharacters stay literal in generated branch commands"
}

# config/preferred-stack.json and config/architecture.json are advice, never a
# gate. A new project's brief carries the home's stack for its medium, an
# existing project keeps the stack and layout it already has, and a malformed
# file warns once and still lets the brief build.
test_preferred_stack_is_advice_never_a_gate() {
  local home brief out status newproj existing
  home="$TMP_ROOT/stack-home"
  newproj="$TMP_ROOT/stack-new"
  existing="$TMP_ROOT/stack-existing"
  mkdir -p "$home/data" "$home/config" "$newproj" "$existing"
  cat > "$home/config/preferred-stack.json" <<'EOF'
{
  "rules": [
    { "when": "A phone app.", "use": { "medium": "mobile", "stack": "React Native" }, "why": "One codebase, two stores." }
  ],
  "default": { "stack": "", "why": "Pick what fits this project." }
}
EOF
  cp "$ROOT/docs/examples/architecture.json" "$home/config/architecture.json"
  echo '{"dependencies":{"react-native":"0.79"}}' > "$existing/package.json"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-stack-new-a1 some-proj --mode direct-PR \
    --medium mobile --project "$newproj" >/dev/null 2>&1 || fail "new mobile brief failed to scaffold"
  brief="$home/data/brief-stack-new-a1/brief.md"
  # shellcheck disable=SC2016 # The expected brief text contains a literal backtick.
  assert_grep 'Stack for `mobile`: **React Native**' "$brief" "new mobile brief did not name the configured stack"
  assert_grep "never a gate" "$brief" "brief did not mark the stack advice as a recommendation"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-stack-existing-a2 some-proj --mode direct-PR \
    --medium mobile --project "$existing" >/dev/null 2>&1 || fail "existing-project brief failed to scaffold"
  brief="$home/data/brief-stack-existing-a2/brief.md"
  assert_grep "already uses React Native" "$brief" "existing project's own stack was not kept"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_no_grep 'Stack for `mobile`' "$brief" "existing project was told to change to the home's stack"

  printf '{oops' > "$home/config/preferred-stack.json"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-stack-bad-a3 some-proj --mode direct-PR \
    --medium mobile --project "$newproj" 2>&1); status=$?
  expect_code 0 "$status" "a malformed preferred-stack.json must never fail a brief"
  assert_contains "$out" "PREFERRED_STACK: invalid config/preferred-stack.json - malformed JSON" \
    "a malformed preferred-stack.json did not warn"
  assert_present "$home/data/brief-stack-bad-a3/brief.md" "a malformed preferred-stack.json blocked the brief"
  pass "jg-brief.sh: preferred stack is advice, an existing project wins, a malformed file warns"
}

test_worker_role_scope

# Rule 2 governs file edits rather than pool administration, so every operator
# scaffold must prohibit the administrative act itself. The rule is emitted from
# one shared string so the ship and scout copies cannot drift apart.
test_operator_scaffolds_forbid_pool_administration() {
  local home id brief mode ship_rule scout_rule
  home="$TMP_ROOT/pool-admin-home"
  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="brief-pool-$mode"
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" alpha --mode "$mode" >/dev/null 2>&1 \
      || fail "jg-brief.sh --mode $mode exited non-zero"
    brief="$home/data/$id/brief.md"
    assert_grep "Never use git stash: all worktrees of a repo share one stash; commit work in progress on your own branch instead." "$brief" \
      "$mode ship brief did not forbid the shared stash and name the safe alternative"
    assert_grep "worktree pool" "$brief" \
      "$mode ship brief did not name the shared worktree pool"
    assert_grep "create, remove, return, prune, move, or reassign" "$brief" \
      "$mode ship brief did not state the prohibition around the act"
    # shellcheck disable=SC2016 # Literal command text must remain unexpanded.
    assert_grep 'git worktree add|remove|move|prune' "$brief" \
      "$mode ship brief did not name the concrete git worktree commands"
    assert_grep "treehouse" "$brief" \
      "$mode ship brief did not name the treehouse mutation commands"
    assert_grep "any other worktree provider" "$brief" \
      "$mode ship brief pinned one provider instead of covering every provider"
    assert_grep "sibling slot" "$brief" \
      "$mode ship brief did not forbid writing into a sibling slot"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'blocked [at=<epoch>]: {what you need}' "$brief" \
      "$mode ship brief gave the prohibition no exit for a genuine second-checkout need"
  done

  assert_grep "no verify skill" "$home/data/brief-pool-no-mistakes/brief.md" \
    "ship brief did not require the proof line to say no verify skill"
  assert_grep "Commit nothing afterward" "$home/data/brief-pool-no-mistakes/brief.md" \
    "ship brief did not forbid commits after the final-head done-done run"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-pool-scout alpha --scout >/dev/null 2>&1 \
    || fail "jg-brief.sh --scout exited non-zero"
  brief="$home/data/brief-pool-scout/brief.md"
  assert_grep "Never use git stash: all worktrees of a repo share one stash; commit work in progress on your own branch instead." "$brief" \
    "scout brief did not forbid the shared stash and name the safe alternative"
  assert_grep "worktree pool" "$brief" "scout brief did not name the shared worktree pool"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'blocked [at=<epoch>]: {what you need}' "$brief" "scout brief gave the prohibition no exit"

  # One shared string, not two copies: the emitted rule must be byte-identical
  # across the ship and scout scaffolds so a later edit cannot fix one and miss
  # the other.
  ship_rule=$(awk '/^7\. Never administer/,/^$/' "$home/data/brief-pool-no-mistakes/brief.md")
  scout_rule=$(awk '/^7\. Never administer/,/^$/' "$brief")
  [ -n "$ship_rule" ] || fail "ship brief emitted no shared-infrastructure rule to compare"
  [ "$ship_rule" = "$scout_rule" ] \
    || fail "ship and scout shared-infrastructure rules have drifted apart"

  # The daemon half of the rule survived the fold.
  assert_grep "no-mistakes" "$brief" "scout brief lost the shared no-mistakes daemon rule"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'blocked [at=<epoch>]: {the daemon error}' "$brief" \
    "scout brief lost the daemon-error reporting instruction"

  # A squad_lead runs its own home and legitimately allocates and returns slots
  # for its own operators, so the operator prohibition must NOT reach its charter.
  JG_SQUAD_LEAD_CHARTER='Supervise the alpha domain.' \
    JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-pool-mate --squad-lead alpha >/dev/null 2>&1 \
    || fail "jg-brief.sh --squad-lead exited non-zero"
  assert_no_grep "create, remove, return, prune, move, or reassign" \
    "$home/data/brief-pool-mate/brief.md" \
    "squad_lead charter must not inherit the operator pool-administration prohibition"

  pass "jg-brief.sh: every operator scaffold forbids administering the shared worktree pool"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_forge_selection_renders_correct_cli
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_dod_green_detection
test_pr_based_dod_requires_non_draft
test_ask_user_escalation_format
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_juggernaut_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts_but_not_squad_leads
test_squad_lead_no_projects_charter
test_squad_lead_marked_request_reporting_contract
test_squad_lead_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_ship_and_scout_teach_validation_round_pause
test_scout_and_squad_lead_load_decision_hold_policy
test_scout_and_squad_lead_scaffold
test_scout_brief_names_sign_off_only
test_workers_wait_without_spending_turns
test_wait_no_turns_absent_keeps_the_previous_brief
test_home_brief_include_is_appended_last
test_brief_include_works_without_add_on

test_base_branch_is_rendered_and_bounded
test_base_branch_defaults_to_the_project_version_branch
test_ship_branch_prefix_defaults_to_legacy_fm
test_ship_branch_prefix_override_is_consistent_across_modes
test_ship_branch_prefix_empty_override_yields_bare_task_id
test_branch_prefix_is_refused_where_it_does_not_apply
test_branch_prefix_value_is_validated
test_branch_prefix_command_is_shell_safe
test_operator_scaffolds_forbid_pool_administration
test_design_call_field
test_demo_call_field
test_ui_change_field

# No-mistakes is for real risk: the brief states which risk, and the local
# presence flag config/delivery-risk-loose is the only way to skip the question.
test_delivery_risk_reason() {
  local home brief out status
  home="$TMP_ROOT/delivery-risk-home"
  mkdir -p "$home/data"
  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-risk-missing some-proj --mode no-mistakes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a no-mistakes brief with no --risk should be refused"
  assert_contains "$out" "states its risk with --risk" "the refusal did not name the flag"
  assert_contains "$out" "direct-PR" "the refusal did not offer the direct-PR route"
  assert_absent "$home/data/brief-risk-missing/brief.md" "refused no-mistakes scaffold wrote a brief"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-risk-yes some-proj --mode no-mistakes --risk security >/dev/null 2>&1 \
    || fail "a no-mistakes brief with --risk security should scaffold"
  brief=$(cat "$home/data/brief-risk-yes/brief.md")
  assert_contains "$brief" "Delivery risk (no-mistakes): security" "the brief did not record the risk reason"

  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-risk-direct some-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "a direct-PR brief needs no risk reason"
  assert_not_contains "$(cat "$home/data/brief-risk-direct/brief.md")" "Delivery risk" "a direct-PR brief carried a risk line"

  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-risk-bad some-proj --mode no-mistakes --risk because 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unlisted --risk value should be refused"
  assert_contains "$out" "must be one of" "an unlisted --risk value did not explain the list"
  assert_absent "$home/data/brief-risk-bad/brief.md" "refused unknown-risk scaffold wrote a brief"

  out=$(JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-risk-scout some-proj --scout --risk security 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "scout accepted --risk"
  assert_contains "$out" "applies only to ship briefs" "scout refusal did not explain why"

  mkdir -p "$home/config" && : > "$home/config/delivery-risk-loose"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" brief-risk-loose some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "config/delivery-risk-loose should turn the risk question off"
  assert_not_contains "$(cat "$home/data/brief-risk-loose/brief.md")" "Delivery risk" "loose mode wrote a risk line"
  pass "jg-brief.sh: --risk states the no-mistakes risk, is refused elsewhere, and config/delivery-risk-loose turns it off"
}
test_delivery_risk_reason
test_preferred_stack_is_advice_never_a_gate
