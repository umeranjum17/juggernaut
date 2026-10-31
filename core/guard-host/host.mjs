// Guard host: the one place a guard rule plugs into.
// A rule is one Rego package under policy/guard/, evaluated by OPA against the frozen fact document
// this file gathers: input.tool, input.command, input.cwd, input.home, and input.calls - every gh or
// gh-axi invocation in the command, with the repository this clone resolves for it (--repo, then
// GH_REPO, then this clone's own origin, never another remote). Policy decides and the host acts, so
// a new guard is one .rego file plus its _test.rego and nothing here changes; this repo's own
// .claude/settings.json wires it, so it needs no installer. A refusal is final and names the rule
// that made it; with no OPA reachable the host says so rather than block work no rule ever judged.
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const POLICY = `${dirname(dirname(dirname(SELF)))}/policy/guard`; // rules live here; OPA loads all of policy/

// Simple commands, split on ; | & and newlines outside quotes, then unshell-quoted into words.
function commands(command) {
	const out = [""];
	let quote = "";
	for (let i = 0; i < command.length; i++) {
		const c = command[i];
		if (!quote && ";|&\n".includes(c)) { if (out[out.length - 1].trim()) out.push(""); continue; }
		if (c === "\\" && quote !== "'") { out[out.length - 1] += c + (command[++i] ?? ""); continue; }
		out[out.length - 1] += c;
		if (c === quote) quote = "";
		else if (!quote && (c === '"' || c === "'")) quote = c;
	}
	const unquote = (word) => word.replace(/^("([\s\S]*)"|'([\s\S]*)')$/, (_all, _q, double, single) => double ?? single);
	return out.filter((segment) => segment.trim()).map((segment) => (segment.match(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+/g) ?? []).map(unquote));
}

// A remote url names owner/repo; a path or file:// url publishes nothing.
function repoFromUrl(url) {
	let rest = String(url ?? "").replace(/\.git$/, "");
	if (!rest || /^(\/|\.\/|\.\.\/|~|file:\/\/)/.test(rest)) return "";
	if (rest.includes("://")) rest = rest.slice(rest.indexOf("://") + 3).replace(/^[^/]*\//, "");
	else if (rest.includes(":")) rest = rest.slice(rest.indexOf(":") + 1);
	else return "";
	const parts = rest.replace(/\/$/, "").split("/");
	return parts.length >= 2 ? parts.slice(-2).join("/") : "";
}

// This clone's own origin, never another remote: a fork clone must not fall back to its parent.
function originOf(cwd) {
	try {
		return repoFromUrl(execFileSync("git", ["-C", cwd, "remote", "get-url", "origin"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim());
	} catch { return ""; }
}

function explicitRepo(args) {
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--repo" || a === "-R") return args[i + 1] ?? "";
		if (a.startsWith("--repo=")) return a.slice(7);
		if (/^-R./.test(a)) return a.slice(2).replace(/^=/, "");
	}
	return "";
}

// Every gh or gh-axi call in the command, with the repository it would write to: what the caller
// named, else GH_REPO, else this clone's origin. The rule decides which calls are writes.
function callsIn(command, cwd) {
	const calls = [];
	for (const word of commands(command)) {
		let at = 0;
		while (at < word.length && /^\w+=/.test(word[at])) at++;
		if (!/(^|\/)(gh-axi|gh)$/.test(word[at] ?? "")) continue;
		calls.push({ group: word[at + 1] ?? "", verb: word[at + 2] ?? "", repo: explicitRepo(word.slice(at + 1)) });
	}
	if (!calls.length) return calls;
	const origin = originOf(cwd);
	for (const call of calls) call.repo = (call.repo || process.env.GH_REPO || "").trim() || origin;
	return calls;
}

// The refusal messages every rule produced, or [] to allow. One OPA call reads every rule at once.
function decide(facts) {
	let out;
	try {
		out = execFileSync(process.env.OPA || "opa", ["eval", "--format=json", "--data", dirname(POLICY), "-I", "data.guard"], {
			input: JSON.stringify(facts), encoding: "utf8", stdio: ["pipe", "pipe", "pipe"],
		});
	} catch (e) {
		if (e.code === "ENOENT") return [];
		throw new Error(`opa eval failed: ${String(e.stderr || e.message).trim()}`);
	}
	const guard = JSON.parse(out).result?.[0]?.expressions?.[0]?.value ?? {};
	return Object.entries(guard).flatMap(([rule, body]) => (body?.deny ?? []).map((msg) => `[${rule}] ${msg}`));
}

// CLI for the Claude Code PreToolUse hook and the core's own pretool checker: a payload on stdin,
// and exit 2 with the reasons on stderr blocks the call. --list prints the rules this repo ships,
// which is how a new rule shows it changed no core file.
if (process.argv[1] === SELF) {
	if (process.argv.includes("--list")) {
		const rules = readdirSync(POLICY).filter((f) => f.endsWith(".rego") && !f.endsWith("_test.rego")).map((f) => f.replace(/\.rego$/, ""));
		process.stdout.write(`${rules.sort().join("\n")}\n`);
	} else {
		let payload = {};
		try { payload = JSON.parse(readFileSync(0, "utf8")); } catch {}
		const command = String(payload?.tool_input?.command ?? ""), cwd = payload?.cwd || process.cwd();
		const facts = { tool: String(payload?.tool_name ?? "").toLowerCase(), command, cwd, home: process.env.JG_HOME || "", calls: callsIn(command, cwd) };
		let messages = [];
		try { messages = decide(facts); } catch (e) { process.stderr.write(`guard-host: ${e.message}\n`); }
		if (messages.length) { process.stderr.write(`${messages.join("\n")}\n`); process.exit(2); }
	}
}
