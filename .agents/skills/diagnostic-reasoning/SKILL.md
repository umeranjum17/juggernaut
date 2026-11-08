---
name: diagnostic-reasoning
description: >-
  Agent-only procedure for diagnosing reported bugs.
  Use before scoping a reported bug and before acting on a diagnostic report.
  Owns end-user-aligned reproduction, causal separation, divergent-path and history inspection, counterfactual testing, and disconfirming evidence.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug and before acting on a diagnostic report.
This skill is the single owner of Juggernaut's bug-diagnosis reasoning procedure.
Juggernaut applies it when briefing delegated investigation and evaluating the resulting evidence, without taking over project-specific investigation itself.

## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Test the causal explanation

Inspect the failing path and a proven path where the intended behavior is known to work.
Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.

## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.

## Make the implicit state machine explicit

Use this fix type when the bug is a state that should not exist: a flag pair, status string, or file that can hold a combination nothing is meant to produce, or a transition that several scripts perform on their own.
That is an implicit state machine, and patching one symptom leaves the other writers free to break it again.

1. Find the machine: list every value the state can take and every place that reads or writes it (`git grep`).
2. Write its transition table: each allowed from-state, event, and to-state, and name the combinations that must be impossible.
3. Give it one owner: one function or script performs every transition and refuses an undeclared one with a named reason; all other callers go through it.
4. Test each transition: one integration test per allowed transition and one per refused transition, through the real caller.

The [state-machine index](../../../docs/state-machines.md) lists each table with its owner, and `jg-machine` prints a record's state and legal moves.

Keep the change inside the machine you found.
Converting machines the bug did not touch is a separate task.

## Vet a measured number before reporting it

Apply this to every timing, cost, count, or rate you are about to report or act on, such as merge minutes, quota use, or a test duration.
A number is a claim, so answer these before it leaves your hands:

- What exactly was measured, and over which start and end points?
- How many runs back it, and how far apart are the best and worst?
- Was the machine otherwise idle, or did other lanes share it?
- What is the baseline, measured the same way on the same inputs?
- Does the number include setup, cache warm-up, or waiting that the reader will not expect?
- Could a different explanation produce the same figure?
- Can the reader repeat it with the command you used?

Report the number with its run count and conditions, or label it unverified.
One run is an anecdote, not a rate.

## After two failed fixes, test the premise

Two fixes that failed for different reasons often share one belief you never checked.
Before a third attempt, stop and write that belief as one plain sentence, for example "the file is read before the lock is taken".
List the fixes that depend on it, then design the smallest check that could prove it false.
Run that check first.
If the premise is false, discard the fixes built on it and restart from what the check showed.
If it holds, say so, and look for a second shared belief before you try again.
The fix budget in the brief still applies: a premise check does not reset the count.

Premise habit adapted from pstack, MIT licence, by Lauren Tan (github.com/backnotprop/pstack).
