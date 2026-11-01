// Fleet delete guard adapter: the decision is made by the Go guard host, and this file is
// only the JavaScript entry the pi extension and the OpenCode plugin import, because those
// hosts load a module rather than running a command. It adds no rule: it hands the command
// to `jg-guard-host delete`, which owns the decision and records the block.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const BIN = process.env.JG_GUARD_HOST_BIN || join(dirname(SELF), "jg-guard-host");

// ask runs one decision through the host. It returns the block reason, or null to allow.
function ask(command, cwd, runtime) {
	const r = spawnSync(BIN, ["delete", "--runtime", runtime], {
		input: JSON.stringify({ tool_name: "Bash", tool_input: { command: String(command ?? "") }, cwd }),
		encoding: "utf8",
	});
	if (r.error) {
		return (
			`BLOCKED by the fleet delete guard: the guard host at ${BIN} could not run (${r.error.message}). ` +
			`This block is final; fix the guard host and report it as blocked.`
		);
	}
	if (r.status === 2) return (r.stderr || "").trim();
	return null;
}

// guard returns the block message, or null to allow. Logging and waking happen in the host.
export function guard(command, { cwd = process.cwd(), runtime = "unknown" } = {}) {
	return ask(command, cwd, runtime);
}

// Hook CLI for Claude Code: PreToolUse JSON on stdin; exit 2 with the reason on stderr
// blocks (stdout stays empty for Claude).
if (process.argv[1] === SELF) {
	let payload = "";
	try {
		payload = readFileSync(0, "utf8");
	} catch {}
	const r = process.argv.indexOf("--runtime");
	const runtime = (r > 1 && process.argv[r + 1]) || "unknown";
	const direct = spawnSync(BIN, ["delete", "--runtime", runtime], { input: payload, encoding: "utf8" });
	if (direct.stderr) process.stderr.write(direct.stderr);
	if (direct.error) {
		process.stderr.write(`BLOCKED by the fleet delete guard: the guard host at ${BIN} could not run (${direct.error.message}). This block is final.\n`);
		process.exit(2);
	}
	process.exit(direct.status === 2 ? 2 : 0);
}
