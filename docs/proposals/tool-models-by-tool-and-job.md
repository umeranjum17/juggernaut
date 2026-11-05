# Proposal: tool models by tool and job (`config/tool-models.json`)

Status: draft for approval, revised twice: a tool gets a key only when its code starts a model, and (owner, Telegram 276-277) only a tool with an AI engine gets a key, with the file as an override of that engine's own default. No code yet. Replaces the flat `rules[]` list of #666 (merged) and the sites in #667 (merged), #668 and #669 (both stay open).

## Problem

Today one flat list is keyed by internal call sites (`squad-lead`, `voice-rewrite`, `model-pool`). It has hidden fallbacks: env var, then `config/*` file, then entry, then a built-in default; the done-done judge falls through the route chain. Workers cannot name a model per job type ("frontend work uses X, cheap verification uses Y"), and a tool cannot say which of its own jobs uses which model.

## Shape

Rule from the owner: a tool that has an AI engine can be configured here; a tool without one needs no key. Every tool that uses AI owns its own engine with its own default model. `config/tool-models.json` only overrides that default, per job.

Top-level key = a tool with an AI engine whose code starts a model (`done-done`, `no-mistakes`, `first-draft`, `workers`). Second level = a job type. Each job = one explicit `{harness, model, effort?}`. Each tool reads exactly its own `<tool>.<job>` entry. AI call sites that are not an owner tool live under `internal`. The lead or worker picks the job by complexity; no rule picks it.

The file lists overrides. The example below is the shipped example: it shows today's default of each tool, so you can copy a block and edit it. Delete a block and that tool uses its own default again.

```json
{
  "done-done": {
    "judge": { "harness": "claude", "model": "claude-haiku-5-5" }
  },
  "no-mistakes": {
    "review": { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" }
  },
  "first-draft": {
    "generate": { "harness": "claude", "model": "claude-sonnet-5-5" },
    "judge":    { "harness": "codex", "model": "gpt-6.1-sol" }
  },
  "workers": {
    "squad-lead":         { "harness": "claude", "model": "opus", "effort": "max" },
    "frontend":           { "harness": "claude", "model": "sonnet", "effort": "high" },
    "backend":            { "harness": "codex", "model": "gpt-6-luna", "effort": "medium" },
    "cheap-verification": { "harness": "pi", "model": "ollama-cloud/deepseek-v4.1-flash" },
    "hard":               { "harness": "claude", "model": "opus", "effort": "max" }
  },
  "internal": {
    "supervision-engine": { "harness": "claude", "model": "sonnet" },
    "model-pool":         { "harness": "claude", "model": "claude-haiku-5-5" },
    "voice-rewrite":      { "harness": "claude", "model": "claude-haiku-5-5" },
    "inbox-stt":          { "harness": "pi", "model": "amazon-bedrock/amazon.nova-lite-v1:0" },
    "inbox-ask":          { "harness": "pi", "model": "amazon-bedrock/amazon.nova-pro-v1:0" },
    "voice-relay":        { "harness": "pi", "model": "amazon-bedrock/amazon.nova-sonic-v1:0" },
    "route-chain": [
      { "id": "route:ollama-cloud/deepseek-v4.1-flash", "provider": "ollama-cloud", "harness": "opencode", "model": "ollama-cloud/deepseek-v4.1-flash", "billing": "plan" },
      { "id": "route:commandcode/deepseek/deepseek-v4.1-flash", "provider": "commandcode", "harness": "pi", "model": "commandcode/deepseek/deepseek-v4.1-flash", "billing": "plan" },
      { "id": "route:openai-codex/gpt-6-luna", "provider": "codex", "harness": "codex", "model": "openai-codex/gpt-6-luna", "billing": "plan" },
      { "id": "route:kimi-coding/kimi-for-coding", "provider": "kimi-coding", "harness": "kimi", "model": "kimi-coding/kimi-for-coding", "billing": "plan" },
      { "id": "route:cursor/auto", "provider": "cursor", "harness": "cursor", "model": "auto", "billing": "plan" },
      { "id": "route:openai-codex/gpt-6.1-sol", "provider": "codex", "harness": "codex", "model": "openai-codex/gpt-6.1-sol", "billing": "plan", "only": "hard" }
    ]
  }
}
```

Values copy each tool's own default where one exists (squad lead, judge, review, first-draft, supervision engine, pool, voice rewrite, route chain). The `inbox-*` and `voice-relay` ids and the four non-lead `workers` rows have no built-in today: they are starting options, unverified, for you to edit.

## Keys kept, with the line that starts the model

A key exists only when code starts a model from it: code in this repo, or for `first-draft` the installed package named in its row. `sign-off` reads no entry: it is a board, and the agent that files a card does the model work. `first-draft` has a key: see the next section. `done-done.cheap-verification` and `no-mistakes.cheap-verification` are dropped: no line here starts them.

| Key | Line that starts the model |
|---|---|
| `done-done.judge` | `core/merge-card/merge-card:314` (`done-done check --judge answerer:pi`), `:377` (claude judge) |
| `no-mistakes.review` | `core/pipeline-quota-failover/pi-quota-failover:375` (`exec "$real_pi"` with the chain model from `:80-95`) |
| `workers.squad-lead` | `bin/jg-spawn.sh:4856` (`__MODELFLAG__` into the launch); model chosen at `:879` and `:2196` |
| `workers.frontend`, `.backend`, `.cheap-verification`, `.hard` | the same `bin/jg-spawn.sh:4856` for any worker. Marked: nothing reads these rows until Phase 2; the lead picks one by complexity. Drop them if `config/crew-dispatch.json` stays the only worker choice |
| `first-draft.generate`, `first-draft.judge` | in the `first-draft-axi` 0.5.0 package (repo `umeranjum17/first-draft`), `src/byokit.mjs:53` (`backendOn` starts the Claude or Codex CLI with `model`); defaults at `src/byokit.mjs:122` (`DEFAULT_MODELS`) and, for the judge, `src/judge.mjs:39` (`judgeOf`) and `src/judge-fallback.mjs:5` |
| `internal.supervision-engine` | `bin/jg-supervision-engine-lib.sh:365` (`--model "$model"`) |
| `internal.model-pool` | `core/account-pool/bin/jg-model-pool:143,213` name the model; `pi-quota-failover:178` calls it and `:375` starts it |
| `internal.route-chain` | `core/merge-card/merge-card:278` then `:314`; `core/account-pool/bin/jg-model-pool:314` |
| `internal.voice-rewrite` | `bin/jg-voice.py:60` (command) and `:257` (`subprocess.run`) |
| `internal.inbox-stt` | `bin/jg-inbox.sh:1195` (`--model-id "$STT_MODEL"`) |
| `internal.inbox-ask` | `bin/jg-inbox.sh:1262` (`--model-id "$ASK_MODEL"`) |
| `internal.voice-relay` | `bin/jg-voice-relay.py:548` (`model_id=self.options.model`) |

## First-draft: does it have its own engine today?

Yes. I read the installed package `first-draft-axi` 0.5.0 (`~/.local/lib/node_modules/first-draft-axi/src`, MIT, repo `umeranjum17/first-draft`) and ran `first-draft-axi doctor` (no paid call):

- It resolves its own engine: an authenticated Claude or Codex subscription through BYOKit (`src/byokit.mjs:127` `resolveEngine`).
- It has its own default model: `claude-sonnet-5-5` for Claude and `gpt-6.1-sol` for Codex (`src/byokit.mjs:122`). `doctor` reports `byokit:claude / claude-sonnet-5-5` on this machine.
- It has its own override already: `first-draft-axi init --agent byokit:<route> --model <model>` saves one (`src/cli.mjs:514-530`), and `--model <id>` overrides it for one run (`src/cli.mjs:319`).
- It has a separate judge that must use a different engine than the generator (`src/judge.mjs:39`, `src/judge-fallback.mjs:5`).

So no ticket to give it an engine. What is missing is only the read of this file. Follow-up ticket, in the `first-draft` repo and not part of this PR: **first-draft reads `first-draft.generate` and `first-draft.judge` from `config/tool-models.json` when it runs inside a Juggernaut home, and logs the line below.** Until that lands, the two `first-draft` blocks do nothing, and `docs/configuration.md` says so.

## Read rules (Phase 2)

- Each tool owns its default in its own code, once. A tool asks `bin/jg-tool-models.sh resolve <tool> <job> --default "<harness> <model> [effort]"` and gets back the effective `harness model effort`. No entry means the tool's own default. A missing file is valid and means all defaults.
- Every run logs one stable line, so the token and value metrics can read it: `TOOL_MODELS tool=<tool> job=<job> source=default|file harness=<h> model=<m> effort=<e|none>`. `source=file` means the entry in `config/tool-models.json` was used. `source=default` means the tool's own default was used. The line goes to the run's stderr and is appended to `state/tool-models.log` with a leading `ts=<iso8601>`. One line per run; no other format.
- A bad entry stops with one plain line naming the file and the key, for example `TOOL_MODELS: config/tool-models.json: "no-mistakes.review": model "x" is not in the model allow-list`. A bad entry is: bad JSON, an entry with a missing field, an unverified harness, a bad effort, or a model the allow-list refuses (`jg_model_allowlist_require`). The tool does not fall back to its default for a bad entry.
- No prefix stripping, no env var, no second file, no precedence chain: the file entry or the tool's default, nothing between.
- A site that can run one harness only (judge on a non-pi harness, voice rewrite on non-claude) stops the same way when the entry names another harness.
- `check` validates every entry in the file. `docs/examples/tool-models.json` is documentation and is not copied to `config/` by bootstrap, because absence already means the defaults.

## Prior art

OpenCode (MIT, `agent.<name>.model` as `provider/model-id`; a subagent with no model inherits the primary agent's) is the pick: per-role key, explicit model string. I took the shape of "role name maps to a model", and rejected the inherit-from-parent fallback. Aider (Apache-2.0) names three roles, `main`, `weak` (commit messages, summaries) and `editor`, each with its own model: I took the idea of job types by purpose (cheap vs hard). Claude Code (proprietary, all rights reserved; nothing reusable, ideas only) takes a `model` per subagent definition, with an inherit default: I took per-role model, and rejected inherit. LiteLLM router (MIT outside `enterprise/`) maps a `model_name` group to several deployments with routing and fallbacks: I rejected that, because its shuffle and fallback are the hidden behaviour the owner refused; only our explicit `internal.route-chain` list remains. No code copied from any of the four.

## Every call site in #666, #667, #668, #669

| PR | Today's tag | Site | New key |
|---|---|---|---|
| #666 | `squad-lead` | `bin/jg-harness.sh` `squad_lead_line` | `workers.squad-lead` |
| #666 | `done-done-judge` | `core/merge-card/merge-card` `tool_models_judge` | `done-done.judge` |
| #666 | `supervision-engine` | `bin/jg-supervision-engine-lib.sh` | `internal.supervision-engine` |
| #667 | `no-mistakes-review` | `core/pipeline-quota-failover/pi-quota-failover` | `no-mistakes.review` |
| #668 | `route-chain` | `core/account-pool/bin/jg-route-chain-lib.sh` | `internal.route-chain` |
| #668 | `model-pool` | `core/account-pool/bin/jg-model-pool` | `internal.model-pool` |
| #669 | `voice-rewrite` | `bin/jg-voice.py` `rewrite_command` | `internal.voice-rewrite` |
| #669 | `inbox-stt` | `bin/jg-inbox.sh` `need_stt_model` | `internal.inbox-stt` |
| #669 | `inbox-ask` | `bin/jg-inbox.sh` `need_ask_model` | `internal.inbox-ask` |
| #669 | `voice-relay` | `bin/jg-voice-relay.py` `resolve_settings` | `internal.voice-relay` |

## Decisions for the owner (recommendation first)

1. **This steer replaces two earlier rules.** The earlier "the default file lists every entry, and a missing entry stops" is replaced by "no entry = the tool's own default, logged". Say if you still want a visible full file copied into `config/` at bootstrap; I recommend not, because the log line already shows what ran.
2. **Remove the other sources.** Yes: delete `JG_INBOX_*_MODEL`, `JG_VOICE_MODEL`, `config/inbox-*-model`, `config/voice-model` and the model tokens of `config/squad-lead-harness`. The built-in model string stays once in each tool as that tool's own default (this part of the earlier "remove the built-in strings" is replaced). The per-lead pin `config/squad_leads/<id>/harness` is a harness pin: recommend keeping it as the one explicit override, logged when used.
3. **Failover.** Quota failover stays, only through the listed `internal.route-chain` (built-in list when no entry), one log line per step. A judge or review that is dry then moves down that list, not through a hidden one. Say no if you want it to stop instead.
4. **Worker job rows** (`frontend`, `backend`, `cheap-verification`, `hard`) have no reader until Phase 2, no default of their own, and overlap `config/crew-dispatch.json`: keep them as the options list, or drop them and leave worker choice to crew-dispatch.
5. **Log file.** I propose `state/tool-models.log` for the metrics reader. Say if the metrics use another place.
6. **#668 and #669** stay open untouched; after you approve, their sites are re-done on this shape, and Overwatch decides whether to close them.
7. `config/crew-dispatch.json` (per-task profiles) is out of scope and unchanged.
