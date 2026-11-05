# Proposal: tool models by tool and job (`config/tool-models.json`)

Status: draft for approval, revised after the owner's note that a tool gets a key only when its code starts a model. No code yet. Replaces the flat `rules[]` list of #666 (merged) and the sites in #667 (merged), #668 and #669 (both stay open).

## Problem

Today one flat list is keyed by internal call sites (`squad-lead`, `voice-rewrite`, `model-pool`). It has hidden fallbacks: env var, then `config/*` file, then entry, then a built-in default; the done-done judge falls through the route chain. Workers cannot name a model per job type ("frontend work uses X, cheap verification uses Y"), and a tool cannot say which of its own jobs uses which model.

## Shape

Top-level key = a tool whose code starts a model in this repo (`done-done`, `no-mistakes`, `workers`). Second level = a job type. Each job = one explicit `{harness, model, effort?}`. Each tool reads exactly its own `<tool>.<job>` entry. Call sites that are not an owner tool live under `internal`. The lead or worker picks the job by complexity; no rule picks it.

```json
{
  "done-done": {
    "judge": { "harness": "claude", "model": "claude-haiku-5-5" }
  },
  "no-mistakes": {
    "review": { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" }
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

Values copy today's built-ins where one exists (squad lead, judge, review, supervision engine, pool, voice rewrite, route chain). The `inbox-*` and `voice-relay` ids and the four non-lead `workers` rows have no built-in today: they are starting options, unverified, for you to edit.

## Keys kept, with the line that starts the model

A key exists only when code in this repo starts a model from it. `sign-off` reads no entry: it is a board, and the agent that files a card does the model work. `first-draft` has no key: its model start is in another repo, so add it when that repo's start line is cited. `done-done.cheap-verification` and `no-mistakes.cheap-verification` are dropped: no line here starts them.

| Key | Line that starts the model |
|---|---|
| `done-done.judge` | `core/merge-card/merge-card:314` (`done-done check --judge answerer:pi`), `:377` (claude judge) |
| `no-mistakes.review` | `core/pipeline-quota-failover/pi-quota-failover:375` (`exec "$real_pi"` with the chain model from `:80-95`) |
| `workers.squad-lead` | `bin/jg-spawn.sh:4856` (`__MODELFLAG__` into the launch); model chosen at `:879` and `:2196` |
| `workers.frontend`, `.backend`, `.cheap-verification`, `.hard` | the same `bin/jg-spawn.sh:4856` for any worker. Marked: nothing reads these rows until Phase 2; the lead picks one by complexity. Drop them if `config/crew-dispatch.json` stays the only worker choice |
| `internal.supervision-engine` | `bin/jg-supervision-engine-lib.sh:365` (`--model "$model"`) |
| `internal.model-pool` | `core/account-pool/bin/jg-model-pool:143,213` name the model; `pi-quota-failover:178` calls it and `:375` starts it |
| `internal.route-chain` | `core/merge-card/merge-card:278` then `:314`; `core/account-pool/bin/jg-model-pool:314` |
| `internal.voice-rewrite` | `bin/jg-voice.py:60` (command) and `:257` (`subprocess.run`) |
| `internal.inbox-stt` | `bin/jg-inbox.sh:1195` (`--model-id "$STT_MODEL"`) |
| `internal.inbox-ask` | `bin/jg-inbox.sh:1262` (`--model-id "$ASK_MODEL"`) |
| `internal.voice-relay` | `bin/jg-voice-relay.py:548` (`model_id=self.options.model`) |

## Read rules (Phase 2)

- `bin/jg-tool-models.sh get <tool> <job>` prints `harness model effort` and logs `TOOL_MODELS: used <tool>.<job> = <harness> <model> <effort>`.
- A missing file, key or field, bad JSON, an unverified harness, a bad effort, or a model the allow-list refuses (`jg_model_allowlist_require`) stops with one line naming the file and the key, for example `TOOL_MODELS: config/tool-models.json: no entry "no-mistakes.review"`. No default, no prefix stripping, no second source.
- A site that can run one harness only (judge on a non-pi harness, voice rewrite on non-claude) stops the same way.
- `check` validates every entry in the file. The default file ships as `docs/examples/tool-models.json`; bootstrap copies it to `config/` once when absent and never overwrites.

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

1. **Remove the other sources.** Yes: delete `JG_INBOX_*_MODEL`, `JG_VOICE_MODEL`, `config/inbox-*-model`, `config/voice-model`, the model tokens of `config/squad-lead-harness`, and the built-in model strings in code. The per-lead pin `config/squad_leads/<id>/harness` is a harness pin: recommend keeping it as the one explicit override, logged when used.
2. **Failover.** Quota failover stays, only through the listed `internal.route-chain`, one log line per step. A judge or review that is dry then moves down that list, not through a hidden one. Say no if you want it to stop instead.
3. **Worker job rows** (`frontend`, `backend`, `cheap-verification`, `hard`) have no reader until Phase 2 and overlap `config/crew-dispatch.json`: keep them as the options list, or drop them and leave worker choice to crew-dispatch.
4. **#668 and #669** stay open untouched; after you approve, their sites are re-done on this shape, and Overwatch decides whether to close them.
5. `config/crew-dispatch.json` (per-task profiles) is out of scope and unchanged.
