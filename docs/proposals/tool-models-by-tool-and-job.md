# Proposal: tool models by tool and job (`config/tool-models.json`)

Status: draft for approval, revised five times: a tool gets a key only when its code starts a model; only a tool with an AI engine gets a key, and the file overrides that engine's own default (owner, Telegram 276-277); first-draft, no-mistakes, learn-from-mistakes and done-done each get a key with their own jobs (owner, Telegram 279); every job value may be one entry or an ordered array of entries, picked by quota and spread across signed-in accounts (owner, Telegram 288-289); the owner approved the JSON design (Telegram 301), and speech-to-text defaults to a local on-device model, never cloud (owner rule of 4 Nov, Telegram 303). No code yet. Replaces the flat `rules[]` list of #666 (merged) and the sites in #667 (merged), #668 and #669 (both stay open).

## Problem

Today one flat list is keyed by internal call sites (`squad-lead`, `voice-rewrite`, `model-pool`). It has hidden fallbacks: env var, then `config/*` file, then entry, then a built-in default; the done-done judge falls through the route chain. Workers cannot name a model per job type ("frontend work uses X, cheap verification uses Y"), and a tool cannot say which of its own jobs uses which model.

## Shape

Rule from the owner: a tool that has an AI engine can be configured here; a tool without one needs no key. Every tool that uses AI owns its own engine with its own default model. `config/tool-models.json` only overrides that default, per job.

Top-level key = a tool with an AI engine whose code starts a model (`done-done`, `no-mistakes`, `first-draft`, `learn-from-mistakes`, `workers`). Second level = a job type. Each job value = one explicit entry `{harness, model, account?, effort?}`, or an ordered array of such entries (see "Arrays: pick by quota, spread across accounts"). Each tool reads exactly its own `<tool>.<job>` entry. AI call sites that are not an owner tool live under `internal`. The lead or worker picks the job by complexity; no rule picks it.

The file lists overrides. The example below is the shipped example: it shows today's default of each tool, so you can copy a block and edit it. Delete a block and that tool uses its own default again.

```json
{
  "done-done": {
    "author": { "harness": "claude", "model": "claude-haiku-5-5", "effort": "low" },
    "judge":  { "harness": "claude", "model": "claude-haiku-5-5" }
  },
  "no-mistakes": {
    "review":             { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" },
    "fix":                { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" },
    "review-after-round": { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" },
    "fix-after-round":    { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" }
  },
  "first-draft": {
    "generate": { "harness": "claude", "model": "claude-sonnet-5-5" },
    "judge":    { "harness": "codex", "model": "gpt-6.1-sol" }
  },
  "learn-from-mistakes": {
    "worker": { "harness": "claude", "model": "claude-haiku-5-5" },
    "judge":  { "harness": "claude", "model": "claude-sonnet-5-5" }
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
    "inbox-stt":          { "harness": "hex", "model": "parakeet-unified-en-0.6b-Q8_0" },
    "inbox-ask":          { "harness": "pi", "model": "amazon-bedrock/amazon.nova-pro-v1:0" },
    "voice-relay":        { "harness": "hex", "model": "parakeet-unified-en-0.6b-Q8_0" },
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

Values copy each tool's own default where one exists (squad lead, done-done, first-draft, learn-from-mistakes judge, supervision engine, pool, voice rewrite, route chain). The `no-mistakes` fix and after-round rows copy the review row because Juggernaut pins one model today. The `learn-from-mistakes.worker` row has no default in that tool today (see the engines section). The `inbox-ask` id and the four non-lead `workers` rows have no built-in today: they are starting options, unverified, for you to edit. The `inbox-stt` and `voice-relay` rows are local on-device (see the speech-to-text section); the `hex` row for `inbox-stt` was run here.

## Arrays: pick by quota, spread across accounts

Owner (Telegram 288-289): "Each can have arrays as well based on quota and round robin with multiple accounts if available", "Not just a single option". So any `<tool>.<job>` value, and any `internal.<site>` value, is one entry or an ordered array. The array is a list of options the owner wrote down. It is not a router and no new picker is built.

```json
{
  "no-mistakes": {
    "review": [
      { "harness": "pi",    "model": "claude-bridge/claude-haiku-5-5", "account": "work" },
      { "harness": "pi",    "model": "claude-bridge/claude-haiku-5-5", "account": "personal" },
      { "harness": "codex", "model": "gpt-6-luna", "effort": "medium" }
    ],
    "fix": { "harness": "pi", "model": "claude-bridge/claude-haiku-5-5" }
  }
}
```

Entry fields: `harness`, `model` (required), `effort` (optional), `account` (optional). `account` is the id of a login in this home's account pool (`config/account-pool`). Omit it and the pool chooses among the signed-in accounts of that route. A one-entry array and a bare entry mean the same.

**Reuse, no new picker.** Phase 2 adds no selection logic. Each step below already exists:

| Step | Existing owner | What it does today |
|---|---|---|
| Rule for choosing among options | skill `quota-array-dispatch` (`.agents/skills/quota-array-dispatch/SKILL.md`) | Reads quota-axi's default TOON once. Drops a candidate that fails eligibility, reasoning-class fit or the runway floor. Ranks the rest by `spendPriority`. No array-order or harness bias in a tie. Malformed config is an error. Uncertainty keeps a candidate eligible. |
| Ordered pick from a quota snapshot | `bin/jg-quota-choose.sh` | Takes `--candidate <harness:model>` in order and prints the first one that quota allows, or `none` and exit 1. Limit in its own header: one provider family per harness. |
| Row join, one account per row | `quota_row` in `bin/jg-quota-axi-lib.sh` (used by `bin/jg-dispatch-resolve.sh`) | Binds a candidate to the quota row of its own account (schema 6), then ranks eligible candidates by `spendPriority`. |
| Shape check of an entry | `bin/jg-profile.jq` (`profiles()` takes one object or an array; `profile_bad` checks harness, model, effort, provider, floor) | Phase 2 adds `account` to `profile_bad`. The tool-models check and the dispatch profiles then share one validator. |
| Spread across accounts of one route | `core/account-pool/bin/jg-model-pool` (`pick`, `next`) and `config/account-pool` | `pick` takes the signed-in account that is not resting and has the most room, above the rest floor (`JG_ACCOUNT_POOL_REST_FLOOR`, default 15%). `next` rests the account in use and moves to another. Spawn prints and records `account=<id>`. |

How an array resolves in one run:

1. Read the entries in file order. Check every entry: shape (`bin/jg-profile.jq`) and model allow-list (`jg_model_allowlist_require`). One bad entry stops the run; nothing is skipped silently.
2. Read quota once (quota-axi default TOON). Apply the skill's gates. Pick by `spendPriority`; when the skill's rule leaves a tie, the first listed entry wins.
3. If the chosen route has several signed-in accounts and the entry has no `account`, `jg-model-pool pick` chooses the account. When the entry names an `account`, that account is used if it is not resting; if it is resting, the entry is not eligible and the next option is considered.
4. If a run hits its limit midway, `jg-model-pool next` rests that account and the next run picks another.
5. If no entry is eligible, the tool stops with one plain line naming the file and key. It does not fall to the tool's default (see decision 8).

What "round robin" means here, stated plainly: the account pool picks the account with the most room and rests an account that hits its limit. Load therefore spreads over the accounts without a counter, but it is not a strict turn-by-turn rotation. A strict rotation would need new code in `jg-model-pool`; see decision 9.

The lead or worker still chooses the job (`workers.frontend`, `workers.hard`). The array lists options for that job. No rule picks the job.

## Speech-to-text is local, on-device

Owner rule (4 Nov, Telegram 303): speech-to-text runs on the device, never in the cloud. So the defaults of `internal.inbox-stt` and `internal.voice-relay` are no longer `amazon-bedrock/...`. They are `{ "harness": "hex", "model": "parakeet-unified-en-0.6b-Q8_0" }`.

- **Runtime:** Hex 3.1.1 (`~/.local/bin/hex`, Linux beta), command `hex model transcribe <wav> [--model <id>]`. It loads the model in the CLI process and does not need the Hex app to be running.
- **Model:** Parakeet Unified English 0.6B, Q8_0 GGUF, 731 MB, already installed and checksum-verified here (`hex model status`). Voice-activity model: `silero-vad-v6.2-F32`.
- **Device:** `hex model check` reports `ready` on the NVIDIA RTX 3090 (vulkan). The host also lists the CPU and the AMD iGPU (`hex model devices`).
- **Verified here (not only read):** I made a 4.4-second 16 kHz mono WAV with a local text-to-speech voice (piper, `en_US-lessac-medium`) from the sentence "Please check the status of the open pull request and tell me when the checks are green." `hex model transcribe` returned exactly that sentence in 0.8 s wall time. A silent chime WAV returned an empty line, which `jg-inbox.sh` already treats as "transcription came back empty". One synthetic sample on one host is proof that it runs here. It is not an accuracy measure on the captain's voice.
- **`harness` value `hex`:** `hex` is not an agent harness. It is an STT-only runtime, valid only for the `inbox-stt` and `voice-relay` keys. Phase 2 adds it to the entry check for those two keys and nowhere else, and the check refuses it for any agent job. Other STT runtimes are not listed because I did not verify them (a `faster-whisper-base` cache exists under `~/.cache/huggingface`, but the Python package is not installed).
- **What changes in code (Phase 2):** `bin/jg-inbox.sh` `say` stops calling `aws bedrock-runtime converse` for audio and calls `hex model transcribe` on the WAV it already builds. The region and AWS profile settings then apply to `ask` only.
- **`voice-relay` caveat:** it is a speech-in, speech-out session (Nova Sonic). A local default covers only the listening half (`hex`, same model). The speaking half and the reasoning step have no local engine here yet, and I did not test one. Until you pick one, `voice-relay` has no complete local default. Decision 11.

## Keys kept, with the line that starts the model

A key exists only when code starts a model from it: code in this repo, or for the four tools with their own repo the source named in its row (read on disk; see the engines section). `sign-off` reads no entry: it is a board, and the agent that files a card does the model work. `done-done.cheap-verification` and `no-mistakes.cheap-verification` are dropped: no line here starts them.

| Key | Line that starts the model |
|---|---|
| `done-done.judge` | Juggernaut side: `core/merge-card/merge-card:314` (`done-done check --judge answerer:pi`), `:377` (claude judge). Tool side: `done-done-axi` 0.6.24 `dist/judge.js:162` (`askAgent`) from `dist/judge.js:143`, which spawns at `dist/agents.js:446`; judge model chosen at `dist/agents.js:425` |
| `done-done.author` | `done-done-axi` `dist/agents.js:369` (`selectAgent` returns `agentRun`), spawn at `dist/agents.js:446`; default `CHEAP.claude` at `dist/config.js:43` |
| `no-mistakes.review` | Juggernaut side: `core/pipeline-quota-failover/pi-quota-failover:375` (`exec "$real_pi"` with the chain model from `:80-95`). Tool side: no-mistakes `internal/daemon/manager.go:341` (`agent.NewWithOptions` with `cfg.AgentProfileFor(name)`), profile from `internal/config/config.go:1724`; role `reviewer` pinned by `internal/config/review_agents.go:17,36` |
| `no-mistakes.fix`, `.review-after-round`, `.fix-after-round` | the same start (`manager.go:341`); roles `fixer`, `reviewer_after_round`, `fixer_after_round` at `internal/config/review_agents.go:17-20` |
| `learn-from-mistakes.worker` | `learn-from-mistakes-axi` 0.12.0 `src/runners/index.mjs:105` (`spawn(bin, args, ...)` inside `call` at `:145`), reached from `src/steps/agent-step.mjs:53` for the steps analyse (`steps/analyse.mjs:60`), propose (`steps/propose.mjs:137`) and incident (`steps/incident.mjs:42`); model flag built at `src/runners/claude.mjs:9` and `src/runners/pi.mjs:11` |
| `learn-from-mistakes.judge` | the same start (`runners/index.mjs:105`) for the verify step (`steps/verify.mjs:65`); judge model chosen at `src/runners/index.mjs:39` |
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

## Do these tools have their own engine today?

All four do. I read the source of each on this machine; none is a guess. Starts are listed in the keys table above.

### first-draft

Yes. I read the installed package `first-draft-axi` 0.5.0 (`~/.local/lib/node_modules/first-draft-axi/src`, MIT, repo `umeranjum17/first-draft`) and ran `first-draft-axi doctor` (no paid call):

- It resolves its own engine: an authenticated Claude or Codex subscription through BYOKit (`src/byokit.mjs:127` `resolveEngine`).
- It has its own default model: `claude-sonnet-5-5` for Claude and `gpt-6.1-sol` for Codex (`src/byokit.mjs:122`). `doctor` reports `byokit:claude / claude-sonnet-5-5` on this machine.
- It has its own override already: `first-draft-axi init --agent byokit:<route> --model <model>` saves one (`src/cli.mjs:514-530`), and `--model <id>` overrides it for one run (`src/cli.mjs:319`).
- It has a separate judge that must use a different engine than the generator (`src/judge.mjs:39`, `src/judge-fallback.mjs:5`).

So no ticket to give it an engine. Jobs: `generate` (the options) and `judge` (the critic). What is missing is only the read of this file: follow-up ticket, in the `first-draft` repo and not part of this PR: **first-draft reads `first-draft.generate` and `first-draft.judge` from `config/tool-models.json` when it runs inside a Juggernaut home, and logs the line below.** Until that lands, its blocks do nothing, and `docs/configuration.md` says so.

### no-mistakes

Yes. Source: `projects/no-mistakes` in the Overwatch home (a clone at `v1.85.3-8-g8225612e`; the installed binary is `v1.84.0`, so a line may differ in that build). The daemon creates one agent per configured harness (`internal/daemon/manager.go:341`), each with a `model` and `effort` profile from `agent_config` (`internal/config/config.go:1724`, `agentcfg.Profile` at `internal/agentcfg/agentcfg.go:90`). Its own default is empty: the harness keeps its own default model. Four review-loop roles can pin a harness, model and effort: `reviewer`, `fixer`, `reviewer_after_round`, `fixer_after_round` (`internal/config/review_agents.go:17-20,36`). I did not open the daemon's local config file (a protected login and config file), so I do not state what this machine pins there. Jobs: `review`, `fix`, `review-after-round`, `fix-after-round`. Today Juggernaut also pins the review model one level up, in `pi-quota-failover:375`. Follow-up ticket in the `no-mistakes` repo: read `no-mistakes.<job>` from this file, and log the line below.

### learn-from-mistakes

Yes, with one gap. Source: installed `learn-from-mistakes-axi` 0.12.0 (`~/.local/lib/node_modules/learn-from-mistakes-axi/src`, MIT). It has two roles, `worker` (analyse, propose, incident) and `judge` (verify), each with its own runner (claude, codex, opencode, pi, gemini, acp; `src/runners/index.mjs:17`). The judge has its own default: on claude with no model of its own it runs `claude-sonnet-5-5` (`src/runners/index.mjs:38-39`). The worker has no default: it refuses to run with no model (`src/steps/agent-step.mjs:24`, `src/runners/index.mjs:147`), by design ("never picks one for them"). So `learn-from-mistakes.worker` in the example is a starting option, not a default, and this file would be its first source. Follow-up tickets in the `learn-from-mistakes` repo: (1) read `learn-from-mistakes.<job>` from this file and log the line below; (2) decide whether the worker gets a default of its own.

### done-done

Yes. Source: installed `done-done-axi` 0.6.24 (`~/.local/lib/node_modules/done-done-axi/dist`, Apache-2.0). It has an author agent that runs the capture (`dist/agents.js:366-369`, default `CHEAP.claude` = `claude-haiku-5-5`, effort `low`, at `dist/config.js:43`; the cost guard comment at `dist/config.js:36` says a default is always the cheap one) and a judge (`dist/agents.js:420-428`; defaults: `JUDGE_DEFAULT` = `openai-codex/gpt-6-luna` for the pi answerer at `dist/config.js:41`, else the agent's `CHEAP` model). Both start through `askAgent`/`spawn` (`dist/agents.js:695,446`). Jobs: `author`, `judge`. Follow-up ticket in the `done-done` repo: read `done-done.<job>` from this file and log the line below. Today Juggernaut passes the judge only through `core/merge-card/merge-card:314,377`.

### sign-off

Stays without a key: it starts no model (the agent that files a card does the model work; the Go-deeper dispatcher resumes that agent's own Claude session and picks no model). Say if you want a key anyway.

## Read rules (Phase 2)

- Each tool owns its default in its own code, once. A tool asks `bin/jg-tool-models.sh resolve <tool> <job> --default "<harness> <model> [effort]"` and gets back the effective `harness model effort` and, when an account applies, `account=<id>`. For an array, `resolve` calls the existing quota pick (section "Arrays") and returns the one entry it chose. No entry means the tool's own default. A missing file is valid and means all defaults.
- Every run logs one stable line, so the token and value metrics can read it: `TOOL_MODELS tool=<tool> job=<job> source=default|file entry=<n|single|default> of=<count> harness=<h> model=<m> effort=<e|none> account=<id|none>`. `source=file` means an entry in `config/tool-models.json` was used. `entry` is its place in the array (from 1), `single` for a bare entry, `default` when the file had none. `account` is the pool account that the run used, or `none` when the harness has no pool. `source=default` means the tool's own default was used. The line goes to the run's stderr and is appended to `state/tool-models.log` with a leading `ts=<iso8601>`. One line per run; no other format.
- A bad entry stops with one plain line naming the file and the key, for example `TOOL_MODELS: config/tool-models.json: "no-mistakes.review": model "x" is not in the model allow-list`. A bad entry is: bad JSON, an entry with a missing field, an unverified harness, a bad effort, or a model the allow-list refuses (`jg_model_allowlist_require`). In an array the check runs on every entry, not only the chosen one, and the message names the entry place, for example `"no-mistakes.review[2]"`. The tool does not fall back to its default for a bad entry.
- An array with no eligible entry stops with one plain line naming the file and key. It never moves to the default on its own.
- No prefix stripping, no env var, no second file, no precedence chain: the file entry or the tool's default, nothing between.
- A site that can run one harness only (judge on a non-pi harness, voice rewrite on non-claude) stops the same way when the entry names another harness.
- `check` validates every entry in the file. `docs/examples/tool-models.json` is documentation and is not copied to `config/` by bootstrap, because absence already means the defaults.

## Prior art

OpenCode (MIT, `agent.<name>.model` as `provider/model-id`; a subagent with no model inherits the primary agent's) is the pick: per-role key, explicit model string. I took the shape of "role name maps to a model", and rejected the inherit-from-parent fallback. Aider (Apache-2.0) names three roles, `main`, `weak` (commit messages, summaries) and `editor`, each with its own model: I took the idea of job types by purpose (cheap vs hard). Claude Code (proprietary, all rights reserved; nothing reusable, ideas only) takes a `model` per subagent definition, with an inherit default: I took per-role model, and rejected inherit. LiteLLM router (MIT outside `enterprise/`) maps a `model_name` group to several deployments with routing and fallbacks. I did not take its router: arrays here are a list the owner writes, picked by the quota-array code this repo already has (`quota-array-dispatch`, `bin/jg-quota-choose.sh`, `core/account-pool/bin/jg-model-pool`), with no random shuffle and no fallback the file does not list. No code copied from any of the four.

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

1. **The latest steers replace earlier rules.** The cuts of `first-draft` (and my earlier answer on its engine) are replaced by the engines section above.  The earlier "the default file lists every entry, and a missing entry stops" is replaced by "no entry = the tool's own default, logged". Say if you still want a visible full file copied into `config/` at bootstrap; I recommend not, because the log line already shows what ran.
2. **Remove the other sources.** Yes: delete `JG_INBOX_*_MODEL`, `JG_VOICE_MODEL`, `config/inbox-*-model`, `config/voice-model` and the model tokens of `config/squad-lead-harness`. The built-in model string stays once in each tool as that tool's own default (this part of the earlier "remove the built-in strings" is replaced). The per-lead pin `config/squad_leads/<id>/harness` is a harness pin: recommend keeping it as the one explicit override, logged when used.
3. **Failover.** Quota failover stays, only through the listed `internal.route-chain` (built-in list when no entry), one log line per step. Open point: decision 10 may remove `route-chain`. A judge or review that is dry then moves down that list, not through a hidden one. Say no if you want it to stop instead.
4. **Worker job rows** (`frontend`, `backend`, `cheap-verification`, `hard`) have no reader until Phase 2, no default of their own, and overlap `config/crew-dispatch.json`: keep them as the options list, or drop them and leave worker choice to crew-dispatch.
5. **Log file.** I propose `state/tool-models.log` for the metrics reader. Say if the metrics use another place.
6. **Arrays reuse our own picker.** Arrays use the existing quota-array selection and account pool, with no new picker (see "Arrays"). I recommend this. The one gap is strict round robin (decision 9).
7. **#668 and #669** stay open untouched; after you approve, their sites are re-done on this shape, and Overwatch decides whether to close them.
8. **No eligible entry in an array.** I recommend the tool stops with a plain line and does not fall to its own default, because a silent fall is the hidden behaviour the owner refused. Say if you want the default as the last resort.
9. **Round robin.** Today the pool picks the most room and rests a full account; it does not rotate in turns. I recommend keeping that. If you want strict turns, it is a small change in `jg-model-pool` in Phase 2, and I need your word first.
10. **Remove `internal.route-chain`? (open, you have not said yes.)** You asked what it is. It is the ordered list of fallback routes (provider, harness, model, plan billing) that `core/account-pool/bin/jg-route-chain-lib.sh` walks when a judge or review has no quota left: ollama-cloud, commandcode, codex, kimi, cursor, then codex sol for hard jobs only. It does the one thing a job's array now does. I recommend removing the key: each job's own array becomes its fallback list, walked by the same quota pick, and the shared hidden list goes. Cost: every job that relies on the chain today must get its own array in the file, or it has only its default. Phase 2 would then re-do #668 on that basis.
11. **`voice-relay` local default.** Listening is local (`hex`, above). Speaking and reasoning are not. Options: (a) keep `voice-relay` off until a local speech-out engine is chosen; (b) split it into `voice-relay.listen` (hex), `voice-relay.think` (any agent harness) and `voice-relay.speak` (a local text-to-speech engine, for example piper, which ran here when I made the test sample). I recommend (b), but it is a bigger change than a model swap, so I need your word.
12. `config/crew-dispatch.json` (per-task profiles) is out of scope and unchanged.
