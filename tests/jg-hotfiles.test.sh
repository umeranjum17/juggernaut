#!/usr/bin/env bash
# Integration: run the real hotfiles.sh over a fixture repo and a stub board, and check that a file
# changed by 3 lanes in the window is named and posted once, while 2-lane, out-of-window and
# repeat-lane files are not.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/core/fleet-stats/hotfiles.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
fail() { echo "hotfiles test: $1" >&2; exit 1; }

r=$d/repo
git init -q "$r"
git -C "$r" config user.email t@example.invalid
git -C "$r" config user.name t
commit() { # <date> <subject> <ticket> <file>...
  local when=$1 subj=$2 tk=$3; shift 3
  for f in "$@"; do mkdir -p "$r/$(dirname "$f")"; echo "$when$subj" >>"$r/$f"; git -C "$r" add "$f"; done
  GIT_AUTHOR_DATE=$when GIT_COMMITTER_DATE=$when git -C "$r" commit -q -m "$subj" -m "Ticket: $tk"
}
commit 2026-11-12T10:00:00Z "t1: a" t1 bin/jg-trunk.sh .done-done.yaml
commit 2026-11-12T11:00:00Z "t2: b" t2 bin/jg-trunk.sh .done-done.yaml
commit 2026-11-12T12:00:00Z "t3: c" t3 bin/jg-trunk.sh other.sh
commit 2026-11-12T13:00:00Z "t3: d" t3 other.sh
commit 2026-11-01T10:00:00Z "old: e" t9 other.sh
now=$(date -u -d 2026-11-13T00:00:00Z +%s)

out=$("$CLI" --repo "$r" --now "$now")
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "only bin/jg-trunk.sh has 3 lanes: $out"
printf '%s' "$out" | cut -f1-3 | grep -qx $'bin/jg-trunk.sh\t3\tt1,t2,t3' || fail "file, lane count, lane ids: $out"
printf '%s' "$out" | cut -f4 | grep -q 'split' || fail "split proposal"
[ "$("$CLI" --repo "$r" --now "$now" --min-lanes 2 | wc -l)" = 2 ] || fail "--min-lanes 2 adds .done-done.yaml only (other.sh has one lane in the window)"

# --post files one board card per hot file, and a second run files nothing new.
cat >"$d/board" <<'STUB'
#!/usr/bin/env bash
case $1 in
  list) cat "$BOARD_DIR/cards" 2>/dev/null || true ;;
  add) echo "$2" >>"$BOARD_DIR/cards" ;;
esac
STUB
chmod +x "$d/board"
export BOARD_DIR=$d JG_BACKLOG=$d/board
"$CLI" --repo "$r" --now "$now" --post >/dev/null
[ "$(wc -l <"$d/cards")" = 1 ] || fail "one card for the one hot file"
grep -q '^\[feature\] hot file bin/jg-trunk.sh' "$d/cards" || fail "card title"
"$CLI" --repo "$r" --now "$now" --post >/dev/null
[ "$(wc -l <"$d/cards")" = 1 ] || fail "second run must not repeat the card"

"$CLI" --repo "$d/none" --now "$now" 2>/dev/null && fail "unreadable repo must refuse"
"$CLI" --now "$now" 2>/dev/null && fail "missing --repo must refuse"
echo "hotfiles test: ok"
