// Objective journeys of the help desk bot. Run from the project root: node journeys/run.ts <journey id>
// Exit 0: passed. Exit 1 and `assert: <name>`: an assertion failed. Exit 77: a prerequisite is missing (setup error).
// Each journey drives the public CLI exactly as a user's client would, on a fresh store.
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DAY = 24 * 3600 * 1000;
const T0 = 1_800_000_000_000;
type Step = [at: number, args: string[], expect: string, assert: string];

// A step runs `cli.ts <store> --now <at> <args>` and its first output line must start with `expect`.
const J: Record<string, Step[]> = {
  "first-question-gets-answer": [
    [T0, ["start", "c1", "umer", "How do I reset my password?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Use the reset link.", "--source", "help/reset"], "ok answered", "answer cites a source"],
  ],
  "follow-up-question": [
    [T0, ["start", "c1", "umer", "How do I reset my password?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Use the reset link.", "--source", "help/reset"], "ok answered", "first answer"],
    [T0 + 2, ["receive", "c1", "The link expired."], "ok awaiting_answer", "follow-up accepted"],
  ],
  "answer-without-source-refused": [
    [T0, ["start", "c1", "umer", "Is there a phone line?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Yes."], "refused: an answer cites at least one answer source", "uncited answer refused"],
    [T0 + 2, ["show", "c1"], '{"state":"awaiting_answer"', "state unchanged after refusal"],
  ],
  "bot-hands-off-unknown": [
    [T0, ["start", "c1", "umer", "My invoice is wrong"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["handoff", "c1", "billing question"], "ok handed_off", "handed off with a reason"],
    [T0 + 2, ["show", "c1"], '{"state":"handed_off","handoff":"waiting"', "handoff waiting for a person"],
  ],
  "handoff-without-reason-refused": [
    [T0, ["start", "c1", "umer", "My invoice is wrong"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["handoff", "c1", ""], "refused: a handoff needs a reason", "handoff without reason refused"],
    [T0 + 2, ["show", "c1"], '{"state":"awaiting_answer","handoff":null', "state unchanged after refusal"],
  ],
  "agent-closes-handoff": [
    [T0, ["start", "c1", "umer", "My invoice is wrong"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["handoff", "c1", "billing question"], "ok handed_off", "handed off"],
    [T0 + 2, ["accept", "c1", "sara"], "ok handed_off", "a person accepted"],
    [T0 + 3, ["close-handoff", "c1", "refund sent"], "ok handed_off", "the person closed it"],
    [T0 + 4, ["resolve", "c1", "agent"], "ok resolved", "resolved after the handoff closed"],
  ],
  "closed-handoff-cannot-be-accepted": [
    [T0, ["start", "c1", "umer", "My invoice is wrong"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["handoff", "c1", "billing question"], "ok handed_off", "handed off"],
    [T0 + 2, ["accept", "c1", "sara"], "ok handed_off", "accepted"],
    [T0 + 3, ["close-handoff", "c1", "refund sent"], "ok handed_off", "closed"],
    [T0 + 4, ["accept", "c1", "omar"], "refused: a closed handoff cannot be accepted", "closed handoff not accepted again"],
    [T0 + 5, ["show", "c1"], '{"state":"handed_off","handoff":"closed"', "handoff still closed"],
  ],
  "second-handoff-refused": [
    [T0, ["start", "c1", "umer", "My invoice is wrong"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["handoff", "c1", "billing question"], "ok handed_off", "first handoff"],
    [T0 + 2, ["handoff", "c1", "still waiting"], "refused: a conversation has at most one open handoff", "second open handoff refused"],
  ],
  "user-confirms-resolved": [
    [T0, ["start", "c1", "umer", "How do I reset my password?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Use the reset link.", "--source", "help/reset"], "ok answered", "answered"],
    [T0 + 2, ["resolve", "c1", "user"], "ok resolved", "user confirmed"],
  ],
  "answer-after-resolve-refused": [
    [T0, ["start", "c1", "umer", "How do I reset my password?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Use the reset link.", "--source", "help/reset"], "ok answered", "answered"],
    [T0 + 2, ["resolve", "c1", "user"], "ok resolved", "resolved"],
    [T0 + 3, ["answer", "c1", "One more thing.", "--source", "help/reset"], "refused: a resolved conversation takes no answer", "no answer after resolve"],
    [T0 + 4, ["show", "c1"], '{"state":"resolved"', "still resolved"],
  ],
  "reopen-within-a-week": [
    [T0, ["start", "c1", "umer", "How do I reset my password?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Use the reset link.", "--source", "help/reset"], "ok answered", "answered"],
    [T0 + 2, ["resolve", "c1", "user"], "ok resolved", "resolved"],
    [T0 + 6 * DAY, ["reopen", "c1"], "ok awaiting_answer", "reopened on day 6"],
  ],
  "reopen-after-a-week-refused": [
    [T0, ["start", "c1", "umer", "How do I reset my password?"], "ok awaiting_answer", "conversation started"],
    [T0 + 1, ["answer", "c1", "Use the reset link.", "--source", "help/reset"], "ok answered", "answered"],
    [T0 + 2, ["resolve", "c1", "user"], "ok resolved", "resolved"],
    [T0 + 8 * DAY, ["reopen", "c1"], "refused: a conversation reopens only within 7 days of resolve", "no reopen on day 8"],
    [T0 + 8 * DAY + 1, ["show", "c1"], '{"state":"resolved"', "still resolved"],
  ],
};

const id = process.argv[2];
const steps = id ? J[id] : undefined;
if (!steps) {
  process.stdout.write(`unknown journey ${id ?? ""}; known: ${Object.keys(J).join(" ")}\n`);
  process.exit(2);
}
if (!existsSync("src/cli.ts")) {
  process.stdout.write("setup: src/cli.ts is missing (run from the project root)\n");
  process.exit(77);
}
const dir = mkdtempSync(join(tmpdir(), "helpdesk-journey-"));
let code = 0;
try {
  for (const [at, args, expect, assert] of steps) {
    const r = spawnSync(process.execPath, ["src/cli.ts", join(dir, "store.json"), "--now", String(at), ...args], { encoding: "utf8" });
    const line = (r.stdout ?? "").split("\n")[0];
    if (!line.startsWith(expect)) {
      process.stdout.write(`assert: ${assert}\n  ran: cli ${args.join(" ")}\n  want: ${expect}\n  got: ${line}\n`);
      code = 1;
      break;
    }
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
if (code === 0) process.stdout.write(`ok ${id}\n`);
process.exit(code);
