// helpdesk CLI: the public operations a journey drives. One JSON file is the store.
// Usage: node src/cli.ts <store.json> [--now <ms>] <command> <conversation> [args...]
// Prints `ok <state>` on success, `refused: <rule>` (exit 1) when a domain rule refuses, usage errors exit 2.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { Conversation } from "./domain/conversation.ts";
import { DomainError } from "./domain/errors.ts";

function fail(msg: string, code: number): never {
  process.stdout.write(msg + "\n");
  process.exit(code);
}

const args = process.argv.slice(2);
const store = args.shift();
if (!store) fail("usage: cli.ts <store.json> [--now <ms>] <command> <conversation> [args...]", 2);
let now = Date.now();
if (args[0] === "--now") {
  args.shift();
  now = Number(args.shift());
}
const [command, id, ...rest] = args;
if (!command || !id) fail("usage: cli.ts <store.json> [--now <ms>] <command> <conversation> [args...]", 2);

const db: Record<string, Conversation> = {};
if (existsSync(store)) {
  for (const [k, v] of Object.entries(JSON.parse(readFileSync(store, "utf8")) as Record<string, Conversation>)) db[k] = Conversation.restore(v);
}
const conv = (): Conversation => db[id] ?? fail(`refused: no conversation ${id}`, 1);
const sources = rest.filter((_, i) => rest[i - 1] === "--source");
const text = rest.filter((a, i) => a !== "--source" && rest[i - 1] !== "--source").join(" ");

try {
  switch (command) {
    case "start": db[id] = Conversation.start(id, rest[0] ?? "", rest.slice(1).join(" "), now); break;
    case "answer": conv().answer(text, sources, now); break;
    case "receive": conv().receive(text, now); break;
    case "handoff": conv().handOff(text, now); break;
    case "accept": { const h = conv().handoff; if (!h) fail("refused: no handoff", 1); h.accept(text); break; }
    case "close-handoff": { const h = conv().handoff; if (!h) fail("refused: no handoff", 1); h.close(text); break; }
    case "resolve": conv().resolve(text === "agent" ? "agent" : "user", now); break;
    case "reopen": conv().reopen(now); break;
    case "rate": conv().rate(Number(text)); break;
    case "show": fail(JSON.stringify({ state: conv().state, handoff: conv().handoff?.state ?? null, rating: conv().rating }), 0);
    default: fail(`helpdesk: unknown command ${command}`, 2);
  }
} catch (e) {
  if (e instanceof DomainError) fail(`refused: ${e.message}`, 1);
  throw e;
}
writeFileSync(store, JSON.stringify(db));
fail(`ok ${db[id].state}`, 0);
