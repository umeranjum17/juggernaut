// Handoff: the move of a conversation to a person, with the reason the bot could not answer.
// Invariants live here, never in a caller: a reason is required; only a waiting handoff can be accepted;
// only an accepted handoff can be closed, and closing needs a note.
import { DomainError } from "./errors.ts";

export type HandoffState = "waiting" | "accepted" | "closed";

export class Handoff {
  readonly id: string;
  readonly conversationId: string;
  readonly reason: string;
  state: HandoffState;
  agent: string | null;
  note: string | null;
  events: string[];

  private constructor(id: string, conversationId: string, reason: string) {
    this.id = id;
    this.conversationId = conversationId;
    this.reason = reason;
    this.state = "waiting";
    this.agent = null;
    this.note = null;
    this.events = ["HandoffRequested"];
  }

  static create(id: string, conversationId: string, reason: string): Handoff {
    if (!reason.trim()) throw new DomainError("a handoff needs a reason");
    return new Handoff(id, conversationId, reason);
  }

  accept(agent: string): void {
    if (this.state !== "waiting") throw new DomainError(`a ${this.state} handoff cannot be accepted`);
    this.state = "accepted";
    this.agent = agent;
    this.events.push("HandoffAccepted");
  }

  close(note: string): void {
    if (this.state !== "accepted") throw new DomainError(`a ${this.state} handoff cannot be closed`);
    if (!note.trim()) throw new DomainError("closing a handoff needs a note");
    this.state = "closed";
    this.note = note;
    this.events.push("HandoffClosed");
  }

  get isOpen(): boolean {
    return this.state !== "closed";
  }

  static restore(raw: Handoff): Handoff {
    return Object.assign(Object.create(Handoff.prototype), raw) as Handoff;
  }
}
