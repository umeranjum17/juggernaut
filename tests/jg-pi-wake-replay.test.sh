#!/usr/bin/env bash
# Behavior tests for the Pi watcher extension's wake delivery identity
# (docs/watcher-continuity.md "Actionable wake ordering").
#
# The extension is driven in a hermetic lab: the real extension source is copied
# into a temp repo with stand-ins for the three Pi packages, and a lab
# bin/jg-watch-arm.sh stands in for one watcher cycle. Each lab cycle reports
# readiness and then the same already-delivered reason a re-derived row
# produces, so the extension's own close -> claim -> restore -> deliver ->
# consume -> finish path runs exactly as it does in a live session.
#
# Two contracts are pinned:
#   REPLAY      - a reason this process already delivered and the model consumed
#                 is not delivered again, across at least two turn boundaries.
#   REPLACEMENT - a row delivered but never consumed still rides the replacement
#                 handoff, and a genuinely later process replays it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-pi-wake-replay)
LAB="$TMP_ROOT/lab"
STATE="$LAB/state"
REASON='stale: default:wX:p1 (pane vanished, state pruned: no task record owns it and the backend confirms it is gone)'

command -v node >/dev/null 2>&1 || {
  printf 'skip: live: node absent\n'
  exit 0
}

make_lab() {
  mkdir -p "$LAB/.pi/extensions/lib" "$LAB/bin" "$STATE" \
    "$LAB/node_modules/typebox" \
    "$LAB/node_modules/@earendil-works/pi-tui" \
    "$LAB/node_modules/@earendil-works/pi-coding-agent" || return 1
  cp "$ROOT/.pi/extensions/jg-primary-pi-watch.ts" "$LAB/.pi/extensions/" || return 1
  cp "$ROOT"/.pi/extensions/lib/*.ts "$LAB/.pi/extensions/lib/" || return 1

  # The extension resolves its package imports against its own location, so
  # these stand-ins satisfy them without any loader hook.
  printf '%s\n' '{"name":"typebox","version":"0.0.0-test","type":"module","exports":{".":"./index.mjs"}}' \
    > "$LAB/node_modules/typebox/package.json" || return 1
  cat > "$LAB/node_modules/typebox/index.mjs" <<'EOF'
const builder = new Proxy(function () {}, { get: () => builder, apply: () => builder });
export const Type = builder;
export default { Type };
EOF
  printf '%s\n' '{"name":"@earendil-works/pi-tui","version":"0.0.0-test","type":"module","exports":{".":"./index.mjs"}}' \
    > "$LAB/node_modules/@earendil-works/pi-tui/package.json" || return 1
  cat > "$LAB/node_modules/@earendil-works/pi-tui/index.mjs" <<'EOF'
export class Box { constructor() { this.children = []; } addChild(c) { this.children.push(c); } clear() {} setBgFn() {} }
export class Container { constructor() { this.children = []; } addChild(c) { this.children.push(c); } }
export class Text { constructor(text) { this.text = text; } }
EOF
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","version":"0.0.0-test","type":"module","exports":{".":"./index.mjs"}}' \
    > "$LAB/node_modules/@earendil-works/pi-coding-agent/package.json" || return 1
  cat > "$LAB/node_modules/@earendil-works/pi-coding-agent/index.mjs" <<'EOF'
export const getMarkdownTheme = () => ({});
export class UserMessageComponent { constructor() {} }
EOF
}

# One watcher cycle. It reports readiness first, then (while WAKE_CYCLES allows)
# the same reason again, which is what a producer re-deriving a row it still
# tracks does cycle after cycle.
make_arm() {
  cat > "$LAB/bin/jg-watch-arm.sh" <<'EOF'
#!/usr/bin/env bash
set -u
lab=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  --handling-delivered) exit "${HANDLING_STATUS:-0}" ;;
esac
n=$(cat "$lab/state/cycles" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$lab/state/cycles"
printf 'watcher: started pid=%s recovery-generation=gen%s\n' "$$" "$n"
if [ "$n" -le "${WAKE_CYCLES:-4}" ]; then
  sleep 0.05
  printf '%s\n' "${WAKE_REASON:?WAKE_REASON must be set}"
  exit 0
fi
sleep 5
exit 0
EOF
  chmod +x "$LAB/bin/jg-watch-arm.sh" || return 1
  printf 'jg_watcher_confirmation_budget() { printf 1; }\n' > "$LAB/bin/jg-wake-lib.sh"
}

# The harness: a fake Pi runtime that records every accepted user message, plus
# the turn boundaries that carry one back to the model.
make_driver() {
  cat > "$LAB/driver.mjs" <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const lab = process.env.LAB;
const state = `${lab}/state`;
const scenario = process.argv[2] ?? "replay";
const wakeCycles = Number(process.env.WAKE_CYCLES ?? 4);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

writeFileSync(`${state}/.lock`, `${process.pid}\n`);

const deliveries = [];
const handlers = new Map();
const bus = new Map();
const on = (name, fn) => {
  const list = handlers.get(name) ?? [];
  list.push(fn);
  handlers.set(name, list);
};
const fire = async (name, event) => {
  for (const fn of handlers.get(name) ?? []) await fn(event, {});
};
const pi = {
  events: {
    on(name, fn) {
      const list = bus.get(name) ?? [];
      list.push(fn);
      bus.set(name, list);
    },
    emit(name, data) {
      for (const fn of bus.get(name) ?? []) fn(data);
    },
  },
  on,
  async sendUserMessage(content, options) {
    deliveries.push({ content, options });
  },
  registerCommand() {},
  registerTool() {},
};

const extension = await import(pathToFileURL(`${lab}/.pi/extensions/jg-primary-pi-watch.ts`).href);
extension.default(pi);

const turnBoundary = (text) =>
  fire("message_start", { message: { role: "user", content: [{ type: "text", text }] } });
const cycles = () => Number(readFileSync(`${state}/cycles`, "utf8").trim() || 0);
const handoff = `${state}/extensions/pi-primary-watch/session-replacement-actionable.json`;

async function waitForDeliveries(count, deadlineMs = 20000) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    if (deliveries.length >= count) return true;
    await sleep(20);
  }
  return false;
}

// Every delivery is consumed at its own turn boundary, which is what finishes a
// pending record. Runs until the lab arm has spent all its wake cycles and no
// further delivery arrives.
async function drainWithTurnBoundaries(deadlineMs = 20000) {
  const deadline = Date.now() + deadlineMs;
  let consumed = 0;
  let quiet = 0;
  while (Date.now() < deadline) {
    if (deliveries.length > consumed) {
      await turnBoundary(deliveries[consumed].content);
      consumed = deliveries.length;
      quiet = 0;
      continue;
    }
    await sleep(20);
    quiet += 20;
    if (quiet >= 600 && cycles() > wakeCycles) return;
  }
}

if (scenario === "replay") {
  await fire("session_start", { reason: "startup" });
  await drainWithTurnBoundaries();
  console.log(`delivered=${deliveries.length}`);
  process.exit(deliveries.length === 1 ? 0 : 1);
}

if (scenario === "confirm") {
  await fire("session_start", { reason: "startup" });
  if (!(await waitForDeliveries(1))) {
    console.log("delivered=0 (no wake was delivered)");
    process.exit(1);
  }
  const failed = deliveries.some((d) => d.content.includes("handling delivery confirmation was rejected"));
  console.log(`delivered=${deliveries.length}`);
  console.log(`failed=${failed ? "yes" : "no"}`);
  process.exit(0);
}

if (scenario === "leave-unfinished") {
  await fire("session_start", { reason: "startup" });
  if (!(await waitForDeliveries(1))) {
    console.log("delivered=0 (no wake was delivered)");
    process.exit(1);
  }
  await fire("session_shutdown", { reason: "reload" });
  const persisted = existsSync(handoff) ? readFileSync(handoff, "utf8") : "";
  console.log(`persisted=${persisted.includes("default:wX:p1") ? "yes" : "no"}`);
  process.exit(persisted.includes("default:wX:p1") ? 0 : 1);
}

if (scenario === "replacement") {
  await fire("session_start", { reason: "startup" });
  if (!(await waitForDeliveries(1))) {
    console.log("delivered=0 (the replacement did not replay the unfinished row)");
    process.exit(1);
  }
  console.log(`delivered=${deliveries.length}`);
  console.log(`replayed=${deliveries[0].content.includes("default:wX:p1") ? "yes" : "no"}`);
  process.exit(deliveries.length === 1 && deliveries[0].content.includes("default:wX:p1") ? 0 : 1);
}

console.log(`unknown scenario ${scenario}`);
process.exit(2);
EOF
}

run_scenario() {  # <scenario> <wake-cycles>
  ( cd "$LAB" && env -u JG_STATE_OVERRIDE -u JG_HOME \
    LAB="$LAB" \
    JG_HOME="$LAB" \
    JG_ROOT_OVERRIDE="$LAB" \
    JG_STATE_OVERRIDE="$STATE" \
    JG_CONFIG_OVERRIDE="$LAB/config" \
    JG_PI_ARM_READY_TIMEOUT_MS=3000 \
    JG_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/jg-operational-input.sh" \
    WAKE_CYCLES="$2" \
    WAKE_REASON="$REASON" \
    HANDLING_STATUS="${HANDLING_STATUS:-0}" \
    NODE_NO_WARNINGS=1 \
    timeout 90 node "$LAB/driver.mjs" "$1" 2>&1 )
}

make_lab || fail "could not build the extension lab"
make_arm || fail "could not write the lab arm"
make_driver || fail "could not write the lab driver"

test_replay_delivers_one_copy_across_turn_boundaries() {
  printf '0\n' > "$STATE/cycles"
  local out status
  out=$(run_scenario replay 4)
  status=$?
  printf '%s\n' "$out"
  expect_code 0 "$status" "one already-settled wake row must reach the model exactly once"
  assert_contains "$out" 'delivered=1' "the same delivered reason must not be re-emitted across turn boundaries"
  pass "extension: one settled wake row is delivered once across four watcher cycles and turn boundaries"
}

test_replacement_replays_a_row_left_unfinished() {
  printf '0\n' > "$STATE/cycles"
  local out status
  out=$(run_scenario leave-unfinished 1)
  status=$?
  printf '%s\n' "$out"
  expect_code 0 "$status" "a delivered but unconsumed wake must ride the replacement handoff"
  assert_contains "$out" 'persisted=yes' "the unfinished row was not persisted for the replacement"

  # A later process: fresh extension state, same durable handoff. Its own
  # delivered-identity record starts empty, so the row must replay.
  out=$(run_scenario replacement 1)
  status=$?
  printf '%s\n' "$out"
  expect_code 0 "$status" "a replacement process must still replay a row delivered but never finished"
  assert_contains "$out" 'replayed=yes' "the replacement did not replay the unfinished row"
  pass "extension: a later process still replays a row delivered but never consumed"
}

# bin/jg-watch-arm.sh --handling-delivered answers 3 for an episode the drain
# already acknowledged (tests/jg-watch-arm-handling-delivered.test.sh): the
# extension must treat that as complete, and any other refusal as FAILED.
test_acknowledged_generation_is_not_reported_failed() {
  local out status
  printf '0\n' > "$STATE/cycles"
  out=$(HANDLING_STATUS=3 run_scenario confirm 1)
  status=$?
  printf '%s\n' "$out"
  expect_code 0 "$status" "a superseded confirmation must still deliver the wake"
  assert_contains "$out" 'delivered=1' "the wake was not delivered"
  assert_contains "$out" 'failed=no' "an already-acknowledged generation must not report FAILED"
  pass "extension: status 3 (acknowledged generation) delivers the wake with no FAILED message"
}

test_genuine_refusal_is_still_reported_failed() {
  local out status code
  for code in 1 2; do
    printf '0\n' > "$STATE/cycles"
    out=$(HANDLING_STATUS=$code run_scenario confirm 1)
    status=$?
    printf '%s\n' "$out"
    expect_code 0 "$status" "a refused confirmation must still deliver the wake"
    assert_contains "$out" 'failed=yes' "refusal status $code must still be reported as FAILED"
  done
  pass "extension: any other non-zero confirmation status is still reported FAILED"
}

test_replay_delivers_one_copy_across_turn_boundaries
test_replacement_replays_a_row_left_unfinished
test_acknowledged_generation_is_not_reported_failed
test_genuine_refusal_is_still_reported_failed

printf 'ok - %s\n' "Pi watcher wake delivery identity"
