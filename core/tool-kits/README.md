# tool-kits

A tool kit is one workflow with one tool: the data a Specialist worker needs to run that tool and to prove it ran.
The design and the build plan are in `data/fable-recon-type-design/report.md`; this folder is slice 1 of that plan: the kit core and the `takeone` kit. Nothing calls it yet; the worker type, its done check and its cleanup are slice 2.

## Layout

- `bin/jg-tool-kit.sh` - the one command: `list`, `resolve "<ask>"`, `section <kit> [<task>]`, `board`, `receipt <task> --card <key> <path>...`, `check <task>`. Its header owns the usage, the exit codes and the environment.
- `build-words.txt` - words that make an ask a Ship and not a Specialist (one per line).
- `kits/<name>/` - one folder per kit, found by folder, so adding a kit edits no shared file:
  - `kit.json` - `name`, `says`, `names` (spellings of the kit or tool that name it), `words` (phrases that suggest it), `tool` (`bin`, `min` version, `doctor`), `spends`, `card` (the board card type), `record` (the tool's run-record files to save) and `outputs` (globs of the files to hash).
  - `brief.md` - the stage text the scaffold puts in the instructions: starts with `Tool kit: <name>`; `{task}`, `{data}` and `{tool-kit}` are filled by `section`.
  - `check.sh <task kit folder> <board file> <card json>` - the kit's own check: no model, one last line, `PASS - ...` and exit 0, or `refused: <reason>` and exit 1.
  - `asks.txt` - `<kit or none> | <ask>` lines that `resolve` must answer as written.
  - `journey.sh` - the kit's end-to-end proof on the real tool, run by `journeys/tool-kit.sh`. A kit that spends model quota or money has `journey-spend.sh` instead, run only by `journeys/tool-kit-spend.sh`.
- `tests/fixture-kits/` - two tiny kits (`alpha`, `beta`) and their `asks.txt`: the rules that need two kits.

## Contract

- **Pick.** `resolve` reads only the words of the ask: a kit the ask names wins; else a build word makes it a Ship (`none`); else exactly one kit's words pick it; two kits or none give `none`. A name is matched anywhere in the ask, so an ask that names a kit and also says "build" still gets the kit.
- **Evidence.** A kit's evidence is `data/<task>/kit/`: `record/` (the tool's own run record), `receipt.json` (kit, tool version, card key, name, size, sha256 and film length of each output) and the card on the board. `report.md` sits in `data/<task>/` and names the card key.
- **Check.** `check <task>` refuses unless the kit the instructions name exists, the receipt names that kit with a tool version at or above the kit's `min`, the board holds a card of the kit's type under the receipt's key, the kit's `check.sh` passes, and `report.md` names the card. The board is the one merge cards use (`jg_board_file`), so a Squad Lead home with no board uses its parent's.
- **Exit codes.** A refusal prints `jg-tool-kit: refused: <reason>` and exits 1. A crashed kit check, a missing kit folder or a bad receipt also exit 1. A caller must refuse on every exit code but 0.
- **Spending.** A kit's `journey-spend.sh` runs only through `journeys/tool-kit-spend.sh`, which skips unless it is given `--approved` (guard 1) and whose `.done-done.yaml` entry has a `spends` line (guard 2).

## The takeone kit

A motion film only (`takeone motion --no-ai`), never a recorded take, which films the live desktop. Its check ties four things: the film `render.json` names, the film's measured length against frames divided by the frame rate (within 0.1 s), the receipt's hash and the hash on the card (and the card's copy beside the board). `journey.sh` makes a real film and breaks each of these in turn.
