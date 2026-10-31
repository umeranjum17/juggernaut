# brief-inherit

Shared worker instructions for every home's briefs. `config/brief-include-shared.md` in the primary home is
propagated byte-exactly (or as an absence) to squad lead homes and appended, shared first, before the home-local
`config/brief-include.md` in the `# Home brief additions` section of ship and scout briefs. Squad Lead charters take
neither include. A present path that is not a readable regular file, or text carrying its own
`Delivery contract: mode=` line, stops the scaffold before anything is written. The text is static, never executed.

- `bin/jg-brief-inherit-lib.sh` - `jg_brief_inherit_shared` (brief side) and `jg_brief_inherit_config` (adds the item to
  `JG_INHERITABLE_CONFIG`). The fork's two seam lines source it from `$JG_ADDONS_DIR` (default
  `$JG_HOME/projects/juggernaut-addons`); absent feature means Kun's behavior, no error, also under `set -e`.
- `tests/brief-inherit-e2e.sh <juggernaut-checkout>` - drives the checkout's real `jg-brief.sh` and `jg-config-push.sh`.
  A checkout without the seam gets a temp copy with the seam applied. Present must equal the pre-seam fork's output: the checkout itself when it lacks the seam, otherwise a temp copy with `tests/pre-seam-reference.patch` (fork PR 114 reversed) applied. Absent must be Kun's.

No install step: the feature works through the seam, so there is nothing to wire or uninstall.
