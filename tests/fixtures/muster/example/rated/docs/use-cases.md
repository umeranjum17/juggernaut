# Use-case catalogue

## Use cases

| ID | Actors | Goal | Main flow | Alternate flow | Failure flow | Journeys | Domain objects |
| --- | --- | --- | --- | --- | --- | --- | --- |
| get-a-cited-answer | User, help desk bot | Get an answer backed by a source. | The user asks a question and the bot replies with a cited answer. | The user asks a follow-up and the bot answers it in the same conversation. | The bot refuses to send an answer without a source. | `first-question-gets-answer`, `follow-up-question`, `answer-without-source-refused` | `Conversation` |
| get-agent-help | User, help desk bot, support agent | Get human help when the bot lacks an answer. | The bot records why it could not answer and requests a handoff. | A support agent accepts the handoff and closes it with a resolution note. | The bot refuses a handoff without a reason or a second handoff. The agent cannot accept a closed handoff. | `bot-hands-off-unknown`, `handoff-without-reason-refused`, `agent-closes-handoff`, `closed-handoff-cannot-be-accepted`, `second-handoff-refused` | `Conversation`, `Handoff` |
| finish-or-reopen | User, help desk bot | Close a solved conversation while keeping a path back to help. | The user confirms the conversation is resolved. | The user reopens it within a week. | The bot refuses a new answer on a resolved conversation or a reopen after one week. | `user-confirms-resolved`, `answer-after-resolve-refused`, `reopen-within-a-week`, `reopen-after-a-week-refused` | `Conversation` |
| rate-a-resolution | User, help desk bot | Record feedback on a resolved conversation. | The user submits a score from 1 to 5 and the bot stores it. | Reopening clears the score, and the user can rate the conversation after resolving it again. | The bot refuses a rating before resolution, an out-of-range score, or a second score. | `rate-after-resolve`, `rate-before-resolve-refused`, `rating-out-of-range-refused`, `second-rating-refused`, `reopen-clears-rating` | `Conversation` |
