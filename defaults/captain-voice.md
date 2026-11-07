# Captain voice

This file is the one place that says how a message to the captain must sound.
Every captain-facing message obeys it: the Telegram chat, the chat replies, the parent-channel lines a Squad Lead sends up, and the primary chat.
`bin/jg-voice.py` reads this file each time it runs, so an edit here changes behaviour at once with no code change.
To change the style for one home, copy this file to `config/captain-voice.md` and edit the copy.
That copy replaces this file whole.
A role file beside this one (`captain-voice-overwatch.md`, `captain-voice-squad-lead.md`, `captain-voice-worker.md`) adds a personality for that role.
A role file adds tone only. It cannot change any rule or setting in this file.

## How to write

- The base rule set is ASD-STE100 Simplified Technical English. Its core rules, written out:
  - Write in the active voice. Name who does the action.
  - Keep a sentence short: 20 words or fewer for an instruction, 25 or fewer for a fact. The `max-sentence-words` setting below enforces the upper bound.
  - Give one instruction or one fact per sentence. Write an instruction as a command ("Approve the PR").
  - Keep a paragraph to one topic and six sentences or fewer.
  - Use one word for one meaning, and use the same word every time. Do not swap in a synonym.
  - Use simple words. Do not use slang, idioms or jokes.
  - Use simple tenses: the simple past, the simple present and the simple future.
  - Keep the articles "a", "an" and "the". Do not drop them to save space.
  - Do not stack more than three nouns in a row. Break a long noun phrase into a short clause.
  - Use a list for steps and for two or more items.
- Put the outcome first. Then the consequence. Then the decision the captain must take, if any.
- A reply or report that answers an ask carries an ask block, in this order: a `Your ask:` line that quotes his words and carries their date, then a `Done:` line, a `Not done:` line and a `Next:` line, and one proof link (`https://...`). Write `Not done: nothing.` when nothing was left undone. `bin/jg-voice.py` refuses a reply or report that breaks the block; a short acknowledgement that answers no ask stays allowed.
- A pull request always carries its full `https://...` URL and what it did for the user. A bare number like "PR 108" tells the captain nothing.
- Use the captain's nouns: the fix, the PR, the review, the decision, the blocker, the worker, the project, the local copy.
- Mark anything not yet verified as unverified.
- Use a list when a paragraph would carry two or more items.
- In chat, address the captain at least once. In a commit, a PR, a brief, code or a comment, never address anyone.

## Settings

Each setting is one line, `- name: value`.
`mode` says what the checker does when a message breaks a rule:

- `rewrite` - when the message holds a banned term, a model rewrites the whole message in plain sentences and the result is checked again.
  Nothing is sent with a banned term in it.
  If the rewrite fails, the message is refused with an instruction to re-draft it.
  A word is never swapped inside a sentence.
- `warn` - report only. The message goes out unchanged.
- `block` - refuse the message and list what to fix, with no model rewrite.
  A sender that can rewrite itself (a chat reply) uses this.
- `off` - do nothing.

A line `mode.<channel>` overrides `mode` for one send point: `chat-reply`, `parent-channel` or `telegram`.

- mode: rewrite
- mode.chat-reply: block
- max-sentence-words: 25

## Internal terms

The checker finds each pattern in the text of a message, ignoring case, and never inside a URL, a `key=value` token or a code span.
The first column is a Python regular expression. Write `\|` for an alternative.
The second column is the plain idea to say instead.
The checker gives it to the rewriting model as guidance, and shows it to an author whose message is refused.
It is never pasted into the sentence, so a term never breaks the grammar around it.
A second column that starts with `?` says only the author or the model can judge what the term means in the sentence.
Rows run top to bottom, so put a long phrase above the short word inside it.
Delete a row to allow a term. Add a row to ban one.

| Pattern | Say instead |
|---|---|
| `(?-i:\bMAIN\b)` | ? say "I", or name what the lead decided |
| `\bwf-\d+[a-z0-9-]*( worker\| lane)?` | worker |
| `\bmerge[- ]card judge\b` | merge review |
| `\bmerge[- ]card\b` | proof card |
| `\bmerge guard\b` | merge check |
| `\blanes? (parked\|paused)\b` | ? say what the work waits for and what releases it |
| `\bbot token\b` | ? say "sign-in key" and what the captain must do, if anything |
| `\blanes\b` | workers |
| `\blane\b` | worker |
| `\bworktrees?\b\|\bprimary checkout\b\|\blocal-main\b\|\bcheckout\b` | local copy |
| `\bcleanups? (is \|was \|are \|were \|gets \|got )?(refused\|refuses\|blocked)\b\|\brefus(ed\|es\|al)\b[^.\n]{0,20}\b(cleanup\|teardown)\b\|\bteardown (is \|was )?refus\w*` | ? say what keeps the work from being cleaned up, for example "the change is not merged yet" |
| `\bsignatures?\b` | ? say who must approve, and what they approve |
| `\bteardown\b` | cleanup |
| `\bbriefs?\b` | instructions |
| `\btask ids?\b\|\bstatus files?\b\|\bmetadata\b` | ? leave it out unless the captain needs it to act |
| `\bwatchers?\b\|\bheartbeats?\b\|\bwakes?\b` | ? say "notification" or "monitoring" |
| `\bneeds-decision\b` | needs your decision |
| `\bfix-review\b` | review finding to fix |
| `\bchecks-passed\b` | checks passed |
| `\bask-user\b\|\bdecision holds?\b` | ? name the decision or the wait |
| `\bfail(s\|ed)?[- ]closed\b` | stops safely when something goes wrong |
| `\bfail(s\|ed)?[- ]open\b` | continues without that protection |
| `\bfail loudly\b` | reports the missing requirement |
| `\bharness(es)?\b\|\bbackends?\b\|\badapters?\b` | ? say "worker tool", and only when the tool choice blocks work |
| `\byolo\b\|\bdelivery mode\b\|\bdirect-PR\b\|\blocal-only\b` | ? say who approves the merge |
| `\bcontext budget\b\|\bpipeline step\b` | ? say the concrete result |
| `(?<![\w/.-])(?:[\w.-]+/)+[\w.-]+\.md\b` | ? name what the file says and give the board link, never the file path |
| `\bPR\s*#?\d+\b\|\bpull request #?\d+\b` | ? write the full https:// URL and what the PR does for the user |
| `\bgates?\b` | ? say "check", or name what must pass |
| `\barmed\b` | ? say "switched on" or "ready" |
| `\bmergeability\b` | whether it can merge |
| `\bmerge commits?\b` | ? say "the merged change" |
| `\brelease[ /]c-\d+\b\|\bc-\d+\b` | ? say "the release", and name its number only if the captain needs it |
| `\bpending checks?\b` | checks still running |
