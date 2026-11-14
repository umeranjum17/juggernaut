#!/usr/bin/env bash
# A done-done judge on a Fable or Opus model is refused by merge-card before any model call, naming the cheap model;
# a cheap judge goes on to run done-done. Stub done-done records each call, so "no model call" is observable.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mc=$here/../merge-card
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/jh/data/t1" "$work/dd" "$work/wt"
cat > "$work/bin/done-done" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case ${1:-} in
  --version) echo "done-done 0.6.18" ;;
  check) [ "${2:-}" != --help ] || echo "--citation-base"; [ "${2:-}" = --help ] || echo '{"verdict":"pass"}' ;;
esac
STUB
chmod +x "$work/bin/done-done"
printf 'screen: none\noutcome: x\n' > "$work/jh/data/t1/checks.md"
run() { # <judge model in config> [extra merge-card args]
  printf 'judge:\n  model: "%s"\n  route: answerer:pi\n' "$1" > "$work/dd/config.yaml"; shift
  : > "$work/log"
  (cd "$work" && PATH=$work/bin:$PATH STUB_LOG=$work/log JG_HOME=$work/jh DONE_DONE_HOME=$work/dd \
    bash "$mc" check "$@" t1 "$work/wt" abc123 - 2>&1) || true
}
model_calls() { grep -c '^check --from' "$work/log" || true; }
out=$(run claude-fable-5-2)
case $out in *claude-fable-5-2*refused*claude-haiku-5-5*) ;; *) echo "not ok - fable not refused with the cheap model named: $out"; exit 1 ;; esac
[ "$(model_calls)" = 0 ] || { echo "not ok - a model call ran for fable"; exit 1; }
echo "ok - claude-fable-5-2 in judge.model is refused before any model call"
out=$(run claude-opus-5-5)
case $out in *claude-opus-5-5*refused*) ;; *) echo "not ok - opus not refused: $out"; exit 1 ;; esac
echo "ok - claude-opus-5-5 is refused"
out=$(run claude-haiku-5-5 --judge claude-fable-5-2)
case $out in *"--judge"*refused*) ;; *) echo "not ok - --judge fable not refused: $out"; exit 1 ;; esac
[ "$(model_calls)" = 0 ] || { echo "not ok - a model call ran for --judge fable"; exit 1; }
echo "ok - --judge with a fable model is refused"
out=$(run claude-haiku-5-5)
case $out in *refused*) echo "not ok - haiku refused: $out"; exit 1 ;; esac
[ "$(model_calls)" -ge 1 ] || { echo "not ok - haiku judge did not run done-done: $out"; exit 1; }
echo "ok - claude-haiku-5-5 runs"
printf 'judge:\n  model: "claude-fable-5-2"\n' > "$work/dd/config.yaml"
out=$(DONE_DONE_HOME=$work/dd JG_ROOT_OVERRIDE=$here/../../.. PATH=$work/bin:$PATH bash "$here/../bin/jg-judge-model-guard.sh" --config "$work/dd/config.yaml" 2>&1) && { echo "not ok - guard passed fable"; exit 1; }
case $out in *claude-haiku-5-5*) echo "ok - the guard the bootstrap check calls names the cheap model" ;; *) echo "not ok - $out"; exit 1 ;; esac
