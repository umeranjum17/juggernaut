#!/usr/bin/env bash
# The ports-and-adapters check: a change importing the Pi kit outside its adapter fails, inside it passes,
# a legacy importer passes, a bus client outside the bus adapter fails, and a plan must name port and adapter.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
check="$here/bin/jg-ports-check.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-ports.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
pass() { printf 'ok - %s\n' "$*"; }
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
g() { git -C "$tmp/r" -c user.email=fixture@example.invalid -c user.name=Fixture "$@"; }

git init -q "$tmp/r"
mkdir -p "$tmp/r/defaults" "$tmp/r/core/ports/pi-engine" "$tmp/r/core/bus/cmd/jg-bus" "$tmp/r/ext" "$tmp/r/tests"
cp "$here/defaults/ports-adapters" "$tmp/r/defaults/"
printf 'ext/old.ts message-bus\next/old.ts pi-engine-kit\n' >"$tmp/r/defaults/ports-adapters-legacy"
printf 'import { x } from "@earendil-works/pi-coding-agent";\n' >"$tmp/r/ext/old.ts"
printf 'export {};\n' >"$tmp/r/ext/clean.ts"
g add -A && g commit -q -m base && g branch -q -m main
reset_to_base() { g checkout -q main && g checkout -q -B cand; }
expect_refused() {  # <label> <path>
  if out=$(bash "$check" --root "$tmp/r" --base main 2>&1); then no "$1 was accepted"; fi
  case $out in *"$2 uses "*"outside its adapter"*) ;; *) no "$1: the refusal did not name $2: $out" ;; esac
}
expect_accepted() { bash "$check" --root "$tmp/r" --base main >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; no "$1 was refused"; }; }

reset_to_base
printf 'import { ExtensionAPI } from "@earendil-works/pi-coding-agent";\n' >"$tmp/r/ext/new.ts"
g add -A && g commit -qm 'pi kit outside the adapter'
expect_refused 'a Pi kit import outside the adapter' ext/new.ts
pass 'a change importing the Pi kit outside its adapter fails'

reset_to_base
printf 'export type { ExtensionAPI } from "@earendil-works/pi-coding-agent";\n' >"$tmp/r/core/ports/pi-engine/adapter.ts"
g add -A && g commit -qm 'pi kit inside the adapter'
expect_accepted 'a Pi kit import inside the adapter'
pass 'a change importing the Pi kit inside its adapter passes'

reset_to_base
printf '// import x from "@earendil-works/pi-ai"\nexport {};\n' >"$tmp/r/ext/comment.ts"
g add -A && g commit -qm 'comment only'
expect_accepted 'a comment that names the kit'
pass 'a comment naming the kit is not an import'

reset_to_base
printf 'import { y } from "@earendil-works/pi-tui";\n' >>"$tmp/r/ext/old.ts"
g commit -qam 'edit a legacy importer'
expect_accepted 'an edit to a legacy importer'
pass 'an old importer listed as legacy passes until it moves'

reset_to_base
printf 'import { y } from "@earendil-works/pi-tui";\n' >>"$tmp/r/ext/clean.ts"
printf 'ext/clean.ts pi-engine-kit\n' >>"$tmp/r/defaults/ports-adapters-legacy"
g commit -qam 'grandfather itself'
expect_refused 'a change that lists itself as legacy' ext/clean.ts
pass 'a change cannot add itself to the legacy list'

reset_to_base
printf 'nats-server -c conf\n' >"$tmp/r/ext/run.sh"
g add -A && g commit -qm 'bus client outside the adapter'
expect_refused 'a bus client outside the adapter' ext/run.sh
reset_to_base
printf 'nats-server -c conf\n' >"$tmp/r/core/bus/cmd/jg-bus/up.sh"
g add -A && g commit -qm 'bus client inside the adapter'
expect_accepted 'a bus client inside the adapter'
pass 'a bus client is refused outside core/bus/cmd/jg-bus/ and passes inside it'

printf 'Plan: add a widget with the Pi engine kit.\n' >"$tmp/plan.md"
if bash "$check" --root "$tmp/r" --plan "$tmp/plan.md" >"$tmp/out.log" 2>&1; then no 'a plan with no port was accepted'; fi
grep -q 'core/ports/pi-engine/PORT.md' "$tmp/out.log" || no 'the plan refusal did not name the port'
printf 'Plan: Pi engine kit, port core/ports/pi-engine/PORT.md, adapter core/ports/pi-engine/adapter.ts.\n' >"$tmp/plan.md"
bash "$check" --root "$tmp/r" --plan "$tmp/plan.md" >/dev/null 2>&1 || no 'a plan naming port and adapter was refused'
printf 'Plan: rename a variable.\n' >"$tmp/plan.md"
bash "$check" --root "$tmp/r" --plan "$tmp/plan.md" >/dev/null 2>&1 || no 'a plan without a dependency was refused'
pass 'a plan using a dependency must name its port module and adapter'

bash "$check" --root "$here" --all >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; no 'the real tree has an unlisted client use'; }
pass 'the real tree has no client use outside an adapter or the legacy list'

# The done-done journey journeys/ports-adapter-refusal.sh replays the same refusal against a real clone.
[ -x "$here/journeys/ports-adapter-refusal.sh" ] || no 'journeys/ports-adapter-refusal.sh is missing or not executable'
pass 'the ports-adapter-refusal journey is present'
