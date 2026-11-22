# Requirements coverage map

Use this map for every light, full and complete Muster, including a survey that leads to a pack.
Depth sets the detail of the pack and the target size of each round.

## Before the first round

Read the relevant code, configuration, tests and project docs, including the current spec, decisions and `CONSTRAINTS.md` where present.
Trace the affected journeys and read any existing evidence for targets such as latency or availability.
For a new project, read the skeleton and available project docs and use the brief to identify what still needs an answer.
Keep a row for every category below in the round notes.
Add rows within a category when it contains independent requirements or decisions.
Record the requirement or question, its state and the source that supports it, such as a doc and section, an owner rule or a round and question ID.

## Functional requirements

| Category | What to establish |
|---|---|
| Users | Who uses, administers or supports the product, what each needs and who is excluded. |
| Journeys | How each affected journey starts, ends and hands off between people or systems. |
| Data | Inputs and outputs, source of truth, validation and effects on existing records. |
| Rules | Required decisions, state transitions, invariants and exceptions. |
| Edge and failure cases | Expected result and recovery at limits, on invalid input, on repeated actions and after partial failure. |
| Integrations | Which systems interact, who owns each contract and what happens when one is unavailable. |
| Permissions | Who may read, change, approve or delete each relevant resource and what happens when access is denied or revoked. |

## Non-functional requirements

| Category | What to establish |
|---|---|
| Performance | Numeric latency or throughput targets for named operations under a stated load, with units and a measurement method. |
| Scale | Expected and peak users, concurrency, traffic or data volume, with limits and behaviour when they are reached. |
| Availability | Service window, acceptable downtime, degradation and recovery targets, including recovery time and tolerable data loss where relevant. |
| Security | Assets to protect, trust boundaries, controls and the expected response when a control fails. |
| Privacy | What personal data is necessary, who can see it and how collection, sharing and deletion work. |
| Compliance | Applicable jurisdictions, obligations and evidence required to meet them. |
| Accessibility | Required standards, assistive technologies and journeys that must work with them. |
| Device and browser support | Supported devices, operating systems, browser versions and any reduced functionality. |
| Offline | What works without a connection and how retries and conflicts resolve when it returns. |
| Observability | What to measure, log or alert on, and who responds. |
| Cost | Budget, currency, period and workload or usage that the budget covers. |
| Data retention | Retention periods and deletion deadlines for each class of data, including logs and backups. |
| Localisation | Supported languages, regions, formats and fallback behaviour. |
| Deployment and rollback | Environments, rollout limits, migration and rollback conditions, and how to verify recovery. |
| Maintainability | Who maintains the feature and how to verify the required effort, documentation or support for routine changes. |

## Resolve gaps in rounds

A row begins open until the evidence or an owner decision gives it one of these outcomes.

- **Answered** means the desired behaviour or constraint is concrete and backed by an authoritative source or an explicit owner answer.
- **Accepted recommendation** means the owner accepted a proposed direction or target with its rationale and trade-off recorded.
- **Out of scope** means the exclusion and reason are explicit, with the owner's agreement when it changes product scope.

Existing behaviour is evidence about today.
Carry it forward as an answer when an agreed requirement or owner rule establishes that it should stay.
Keep a proposed default open while its acceptance is pending, unless an existing owner rule already authorises the choice.
A category is closed once all its rows have outcomes.

After each round, check every answer against a concrete scenario, a relevant failure or recovery case and any measurable limit.
Ask follow-ups when an answer depends on another decision, gives no expected result or leaves a target vague.
For example, turn “fast” into a proposed percentile, time limit and load for a named journey, then ask how to verify it.
Record supported platforms or standards by name and version where they define acceptance.
Reopen affected rows when a later answer contradicts an earlier one.
Keep running rounds until every category is closed, even after the depth's target number of questions.

Put the settled map in the spec or spec section and link to existing requirements where they already own the answer.
Link each in-scope requirement to its acceptance criterion or verifying journey.
Record each accepted direction with its rationale and trade-off in the spec or linked decision record.
Reference the settled requirements from the other pack documents that use them.
