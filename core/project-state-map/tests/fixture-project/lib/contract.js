// Fixture project with known states. Do not run.
export const TICKET = { id: str, stage: oneOf('queued', 'working', 'review', 'done'), owner: opt(str) }
export const GATE = { state: oneOf('open', 'closed') }
