# Project state map

The project state map shows, for each project you choose, its states and moving parts as one card on the sign-off board.
A state is a closed set of values the code moves through, such as a ticket stage.
A moving part is a server, timer, client, store or job.
The map is made from the code. No project file is ever changed.

## How a map is made
- A script searches the project with grep for candidate states and parts.
- A small model reads only those hits and writes a map.
- A script looks up every cited line again and drops each line that is not there.
- A script draws the card in the "State map" group, with pictures, and no model call.

## Turn it on for a project
1. Put the board file in `config/fleet-board`, one path on one line.
2. Add a line `<project-dir> opt-in` to `config/project-state-map`.
   A line without the word `opt-in` names the project but sends nothing to the model.
3. Run `core/project-state-map/bin/psm-refresh.sh tick <home>`.
   The scheduled tick runs the same command.

## Privacy and cost
- A private project sends code excerpts to the model provider only after you add its `opt-in` word.
- `--max-usd N` caps one read, default 0.05, and 0 turns the read step off.
- `--replay <file>` reads a saved reply and sends nothing.
- Files with secret-looking names are never searched or sent.

## Commands
- `psm-refresh.sh tick <home>` refreshes every opted-in project whose code changed, and is silent when nothing changed.
- `psm-refresh.sh ask <home> <project> [--force]` asks for a fresh map by project name or directory.
  It says `unchanged` and names the current card when the code has not changed, and `--force` reads again.
- `psm-refresh.sh list <home>` shows each project in the config and its current card, or that it has none yet.

A card is kept per project. A new card replaces the old one, which is dismissed from the board.

## Wide reports
A Recon report that names three or more of a project's states and parts must carry the map.
Link the card id `state-map-<project>-...` or add a "State map" heading.
The rule warns for one week after the first check, then refuses the report at cleanup.
A line `warn` in `config/project-state-map-wide` keeps it at warning.
A project with no stored map is skipped.

## Check
`core/project-state-map/README.md` lists each script and its test.
`bash core/project-state-map/tests/psm-first-run.test.sh` runs the first run on copies of the fixture project.
