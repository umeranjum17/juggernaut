#!/usr/bin/env node
// Shadow comparison for the fleet delete guard: replay every recorded decision through the shell guard and the
// OPA policy side by side and append one line per record to <home>/state/opa-shadow.log. Nothing is enforced
// from OPA: this file asks guard.mjs's pure decider and the policy the same question about the same recorded
// command, and it never calls guard(), so no block is logged and no wake is queued.
//
// Usage: node opa-shadow.mjs <jg-home> [--opa <path>] [--expect <known-gaps-file>]. OPA comes from --opa, then
// $OPA, then PATH. --expect is the per-rule replay eval: it exits 1 when a scored decision differs from a record
// the file does not name, so the rule cannot switch on a new disagreement. A record the logger cut is never
// scored - it is not the input the guard saw - so it is reported as `unscored`, never as a mismatch.
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { blockedDelete } from "./guard.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const POLICY = join(HERE, "policies", "recursive-delete.rego");
const QUERY = "data.juggernaut.guards.delete.decision";

const [home, ...rest] = process.argv.slice(2);
if (!home) {
	console.error("usage: opa-shadow.mjs <jg-home> [--opa <path>]");
	process.exit(2);
}
const at = rest.indexOf("--opa");
const opa = at >= 0 ? rest[at + 1] : process.env.OPA || "opa";

const TRUNCATED = / …\[\d+ chars total; around the delete: /;

const log = join(home, "state", "delete-guard.log");
const out = join(home, "state", "opa-shadow.log");
if (!existsSync(log)) {
	console.error(`opa-shadow: no recorded decisions at ${log}`);
	process.exit(1);
}

// The policy is fed the same home folders the guard reads, so an absolute target is judged the same way.
const tmp = mkdtempSync(join(tmpdir(), "opa-shadow-"));
process.on("exit", () => rmSync(tmp, { recursive: true, force: true }));
const homes = join(tmp, "homes.json");
writeFileSync(homes, JSON.stringify({ homes: [...new Set([userInfo().homedir, homedir()].map((h) => h.replace(/\/+$/, "")))] }));

function opaDecision(command) {
	const input = join(tmp, "input.json");
	writeFileSync(input, JSON.stringify({ command }));
	const r = spawnSync(opa, ["eval", "--format", "raw", "--data", POLICY, "--data", homes, "--input", input, QUERY], {
		encoding: "utf8",
	});
	if (r.status !== 0) throw new Error(`opa eval failed: ${(r.stderr || "").trim()}`);
	return r.stdout.trim();
}

const rows = readFileSync(log, "utf8").split("\n").filter((l) => l.trim() !== "");
let agree = 0;
let differ = 0;
let unscored = 0;
let nanos = 0;
const diffs = [];
const gaps = [];
rows.forEach((line, i) => {
	let row = {};
	try {
		row = JSON.parse(line) ?? {};
	} catch {
		// An unreadable record is still one record: both deciders see an empty command and agree on it.
	}
	const command = String(row.command ?? "");
	const shell = blockedDelete(command) === null ? "allow" : "block";
	const t0 = process.hrtime.bigint();
	const policy = opaDecision(command);
	nanos += Number(process.hrtime.bigint() - t0);
	const cut = TRUNCATED.test(command);
	const verdict = cut ? "unscored" : policy === shell ? "agree" : "differ";
	if (verdict === "agree") agree++;
	else if (verdict === "unscored") unscored++;
	else {
		differ++;
		gaps.push(String(row.at ?? i + 1));
		if (diffs.length < 3) diffs.push({ line: i + 1, shell, policy, command });
	}
	appendFileSync(out, `${i + 1} ${shell} ${policy} ${verdict}\n`);
});

const total = rows.length;
console.log(`records replayed: ${total}`);
console.log(`agree: ${agree}`);
console.log(`differ: ${differ}`);
console.log(`unscored (the logger cut the record, so it is not a decision): ${unscored}`);
console.log(`mean wall-clock per OPA decision: ${(nanos / 1e6 / (total || 1)).toFixed(1)} ms`);
for (const d of diffs) console.log(`differ line ${d.line}: shell=${d.shell} opa=${d.policy} command=${JSON.stringify(d.command)}`);
const expectAt = rest.indexOf("--expect");
if (expectAt >= 0) {
	const known = readFileSync(rest[expectAt + 1], "utf8")
		.split("\n")
		.map((l) => l.trim())
		.filter((l) => l !== "" && !l.startsWith("#"));
	const grew = gaps.filter((at) => !known.includes(at));
	if (grew.length > 0) {
		console.error(`opa-shadow: this rule may not switch to OPA: ${grew.length} disagreement(s) are not known gaps: ${grew.join(", ")}`);
		process.exit(1);
	}
}
