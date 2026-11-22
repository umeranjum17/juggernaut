---
name: spotrep
description: Use when the captain invokes /spotrep or asks for a quick status check - only what needs him now, then three lines of work.
user-invocable: true
metadata:
  internal: true
---

# /spotrep

A spot report is the short form of `/sitrep`: first what needs the captain, then three lines of work.
It only reads. It never steers, starts, merges, drains the wake queue, or writes a record.

## Data

1. Run `snapshot_result=$(jg report bearings-snapshot --json) && snapshot=$(printf '%s\n' "$snapshot_result" | jq -c '.data')` once. The snapshot command documentation owns the fields and every bucket.
   Never sort an item into a bucket yourself, and read no other fleet state.
2. Run `questions_result=$(jg ticket backlog questions --json) && questions=$(printf '%s\n' "$questions_result" | jq -c '.data')` once for the open questions on the board.
   An item that is in both lists is one item.
3. Gemini 4 Neon, through agy, writes the reply: with `swarms_result=$(jg plan swarm-check status --short) && swarms=$(printf '%s\n' "$swarms_result" | jq -r '.data.stdout')` as a third fact, run `printf '%s\n%s\n%s\n' "$snapshot" "$questions" "$swarms" | python3 -I core/report-writer/bin/report-writer.py write spotrep --facts -` and send its output; `core/report-writer/README.md` owns the route.
   If it fails, report its message; never write the reply yourself or on another model.

## Reply

The model writes in ASD-STE100 Simplified Technical English: short active sentences, one fact per sentence.
Follow AGENTS.md section 9 for words: no internal terms, outcome first, a full `https://...` URL for every PR.
Keep the reply to 15 lines or fewer, with no local file path: a finished Recon is "ready to read", with its board link when it has one.

**Needs you (<count>)**, one line for each item, in this order:

1. Decisions: the snapshot's Captain's Call decisions and the board questions, each with its options and the
   recommended option.
2. PRs to approve or merge, each with its full URL.
3. Sign-ins, credentials or spend, each with the one action.
4. Blockers that only the captain can clear.
5. Finished results to read: Recon reports among the snapshot's recent completions, each as ready to read.

When the list is empty, write `Nothing needs you now.` and the number of items checked.
A missing field in the snapshot is unverified; say so in one line.

**Work**, up to four lines:

- Landed: the count of the snapshot's recent completions, and the three newest by name.
- Underway: the count of live workers, and the name of each worker the snapshot shows as stuck.
- Next: the count of queued items, and the first blocker or date.
- Swarms: give one line per running swarm from the `swarms` fact; leave this line out when it prints `no swarm is running`.

End with: `Say /sitrep for the full list, or /debrief to walk this session's events and open decisions one by one.`

`/spotrep` reads the durable records, so it works in a new session and after a restart; `/debrief` reads the visible session.
