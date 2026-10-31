#!/usr/bin/env node
// Command-line entry for the supervisor-work policy. The shell lexer is loaded
// from the Juggernaut checkout named by --lexer, so the feature carries none.
// Usage: node jg-supervisor-work-decide.mjs --lexer <checkout>/bin/jg-arm-command-policy.mjs
//          [--squad-lead] --command <cmd>
// Prints `allow`, or `deny<TAB><code><TAB><reason>`. Exits 2 on bad usage.
import * as url from "node:url";
import { bindLexer, decision } from "./jg-supervisor-work-command-policy.mjs";

const argv = process.argv.slice(2);
const valueOf = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
const lexerPath = valueOf("--lexer");
const command = valueOf("--command");

if (lexerPath === undefined || command === undefined) {
  process.stderr.write("usage: jg-supervisor-work-decide.mjs --lexer <path> [--squad-lead] --command <cmd>\n");
  process.exit(2);
}

bindLexer(await import(url.pathToFileURL(lexerPath).href));
const result = decision(command, { squad_lead: argv.includes("--squad-lead") });
const verdict = result.decision === "allow" ? "allow" : `deny\t${result.code}\t${result.reason}`;
process.stdout.write(`${verdict}\n`);
