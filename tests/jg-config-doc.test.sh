#!/usr/bin/env bash
# bin/jg-config-doc.sh over a fixture repository: it lists the settings that have a default in bin/ or core/
# and no entry in docs/configuration.md, reports a new one above the stored count, asks for a lower stored
# count once settings are documented, reads an older commit with --rev, and refuses a missing input.
# The fixture files hold literal ${JG_...:-} text, so single quotes are meant.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
script="$here/bin/jg-config-doc.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-config-doc.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
pass() { printf 'ok - %s\n' "$*"; }
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
r="$tmp/r"
g() { git -C "$r" -c user.email=fixture@example.invalid -c user.name=Fixture "$@"; }
run() {  # <args...>: sets out, err and rc
  rc=0
  bash "$script" --root "$r" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  out=$(cat "$tmp/out") err=$(cat "$tmp/err")
}
refused() {  # <text> <label>: the last run exited 2 and said <text> on stderr
  [ "$rc" -eq 2 ] || no "$2 exited $rc: $err"
  case $err in *"$1"*) ;; *) no "$2 did not say '$1': $err" ;; esac
}

git init -q "$r"
mkdir -p "$r/bin" "$r/core/feature/bin" "$r/docs" "$r/defaults" "$r/tests"
cat >"$r/bin/jg-one.sh" <<'EOF'
#!/usr/bin/env bash
a=${JG_DOCUMENTED:-1}
b=${JG_UNDOC_ONE:-x}
c=${JG_NO_DEFAULT}
d=${JG_DASH_ONLY-x}
e=${JG_UNDOC_ONE:-again}
EOF
printf '#!/usr/bin/env bash\nf=${JG_UNDOC_TWO:-}\n' >"$r/core/feature/bin/two.sh"
printf '#!/usr/bin/env bash\ng=${JG_ONLY_IN_TESTS:-1}\n' >"$r/tests/t.test.sh"
printf '# Configuration\n\nSet `JG_DOCUMENTED` to change the thing.\n' >"$r/docs/configuration.md"
printf '# stored count\n2\n' >"$r/defaults/config-doc-count"
g add -A && g commit -q -m base

run
[ "$rc" -eq 0 ] || no "the fixture at its stored count exited $rc: $err"
[ "$out" = "$(printf 'JG_UNDOC_ONE\nJG_UNDOC_TWO')" ] || no "the list was not the two undocumented settings: $out"
case $err in *"2 settings have a default and no entry in docs/configuration.md, at the stored count"*) ;; *) no "the summary did not say at the stored count: $err" ;; esac
pass 'each setting with a default in bin/ or core/ and no entry is listed once; no default, a dash-only default and tests/ are not settings'

run --count
[ "$rc" -eq 0 ] && [ "$out" = 2 ] || no "--count printed '$out' (exit $rc)"
pass '--count prints the number alone'

printf 'h=${JG_UNTRACKED:-1}\n' >"$r/bin/untracked.sh"
run --count
[ "$out" = 2 ] || no "an untracked file was counted: $out"
rm -f -- "$r/bin/untracked.sh"
pass 'an untracked file is not read'

printf 'i=${JG_BRAND_NEW:-on}\n' >>"$r/bin/jg-one.sh"
run
[ "$rc" -eq 1 ] || no "a new undocumented setting above the stored count exited $rc"
case $out in *JG_BRAND_NEW*) ;; *) no "the new setting was not listed: $out" ;; esac
case $err in *"3 settings have a default and no entry in docs/configuration.md, above the stored count 2 in defaults/config-doc-count"*) ;;
  *) no "the refusal did not name the count, the stored count and the file: $err" ;; esac
pass 'a new setting with no entry is reported and exits 1, naming the count and the stored count'

g commit -q -am 'add a setting'
run --rev HEAD~1 --count
[ "$out" = 2 ] || no "--rev HEAD~1 did not read the older tree: $out"
run --rev HEAD --count
[ "$out" = 3 ] || no "--rev HEAD did not read the commit: $out"
run --rev no-such-commit
refused 'unknown commit no-such-commit' 'an unknown commit'
pass '--rev reads the code and the reference at that commit and refuses an unknown commit'

printf 'The `JG_BRAND_NEW` and `JG_UNDOC_TWO` settings are named in prose.\n' >>"$r/docs/configuration.md"
run
[ "$rc" -eq 0 ] || no "documenting settings below the stored count exited $rc: $err"
[ "$out" = JG_UNDOC_ONE ] || no "the documented settings were still listed: $out"
case $err in *"1 settings have a default and no entry"*"below the stored count 2: lower defaults/config-doc-count to 1"*) ;;
  *) no "the summary did not ask for the lower stored count: $err" ;; esac
pass 'a name anywhere in the reference is an entry, and a count below the stored count asks to lower it'

run --limit "$here/defaults/config-doc-count"
[ "$rc" -eq 0 ] || no "the shipped stored count could not be read: $err"
printf 'not a number\n' >"$tmp/bad-limit"
run --limit "$tmp/bad-limit"
refused 'is not a number' 'a stored count that is not a number'
pass 'the shipped stored count file reads as a number and a bad one is refused'

rm -f -- "$r/defaults/config-doc-count"
run
refused 'no stored count defaults/config-doc-count' 'a missing stored count'
run --count
[ "$rc" -eq 0 ] && [ "$out" = 1 ] || no "--count needed the stored count: $out (exit $rc)"
rm -f -- "$r/docs/configuration.md"
run --count
refused 'no docs/configuration.md' 'a missing reference'
pass 'a missing stored count or reference is refused with exit 2, and --count needs no stored count'
