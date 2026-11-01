# lookout-adapter

`lookout-juggernaut` turns this fleet's real data into the `lookout.fleet.v1` document that [Lookout](https://github.com/umeranjum17/lookout) shows (its contract is `docs/adapter.md` there).

```
lookout-juggernaut [--home DIR] [--no-build]          # print the JSON
lookout-juggernaut --serve [--port N] [--bind ADDR]   # the last good snapshot at once from /fleet.json (rebuilt every 30 s in the background; its generated_at says how old), for `lookout serve --adapter http://…/fleet.json`
```

It reads fleet lifecycle data directly from the read-only `fleet-flow` reader and maps it into Lookout's contract; it does not use the legacy dashboard builder or its generated files. It also reads registered-home records and whitelisted lane metadata. No home or state data is written, and no secrets are copied.

Sources: `/proc` and the memory gate for `hosts`; `jg-flow` lifecycle rows and registered-home records for `homes`, `lanes`, `workers` and recent `merges`. `quota` lists every registered Claude and Codex account from `claude-accounts/bin/jg-quota-view` (Main's own login named apart as reserved). The adapter currently returns empty `releases` and `incidents` lists.

Test with fixture homes: `bash addons/lookout-adapter/tests/test.sh`. The test uses the pinned `lookout-axi@0.1.0` CLI; no Lookout clone is needed.

## Service

`wiring.sh` replaces `jg-dashboard.service` with `jg-dashboard-lookout.service`, which runs `fleet-serve`: the adapter, the pinned `lookout-axi@0.1.0` package and `lookout-front` on the dashboard address (tailnet IP, port 4390). The service uses the published package and needs no Lookout source clone. Reads need no token; `/tickets`, `/needs`, `/backlog`, `/measure` and `/overview` answer 301 to the sign-off board (its address from `state/signoff-board.url`, token dropped). Run `wiring.sh --dry-run` first. The apply starts the same command on a spare port (`SPARE_PORT`, 4395), checks `/api/fleet` and the redirect with curl, then stops the old unit and starts the new one. The legacy dashboard has been removed, so installation cannot roll back to it. Install from a merged-main clone, since the unit names its path.
