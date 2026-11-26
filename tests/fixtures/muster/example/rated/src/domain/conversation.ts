// Conversation: one user's question thread, from the first message until it is resolved.
// The state machine and invariants in docs/domain/model.md live here; callers only send commands.
import { DomainError } from "./errors.ts";
import { Handoff } from "./handoff.ts";

export type ConversationState = "awaiting_answer" | "answered" | "handed_off" | "resolved";
export type Message = { from: "user" | "bot"; text: string; sources: string[]; at: number };

const WEEK_MS = 7 * 24 * 3600 * 1000;

export class Conversation {
  readonly id: string;
  readonly userId: string;
  state: ConversationState;
  messages: Message[];
  handoff: Handoff | null;
  resolvedAt: number | null;
  rating: number | null;
  events: string[];

  private constructor(id: string, userId: string) {
    this.id = id;
    this.userId = userId;
    this.state = "awaiting_answer";
    this.messages = [];
    this.handoff = null;
    this.resolvedAt = null;
    this.rating = null;
    this.events = [];
  }

  static start(id: string, userId: string, text: string, now: number): Conversation {
    if (!text.trim()) throw new DomainError("a conversation starts with a question");
    const c = new Conversation(id, userId);
    c.messages.push({ from: "user", text, sources: [], at: now });
    c.events.push("ConversationStarted");
    return c;
  }

  receive(text: string, now: number): void {
    if (this.state !== "answered") throw new DomainError(`a ${this.state} conversation cannot take a follow-up`);
    this.messages.push({ from: "user", text, sources: [], at: now });
    this.state = "awaiting_answer";
    this.events.push("MessageReceived");
  }

  answer(text: string, sources: string[], now: number): void {
    if (this.state === "resolved") throw new DomainError("a resolved conversation takes no answer");
    if (this.state !== "awaiting_answer") throw new DomainError(`a ${this.state} conversation takes no answer`);
    if (sources.length === 0) throw new DomainError("an answer cites at least one answer source");
    this.messages.push({ from: "bot", text, sources, at: now });
    this.state = "answered";
    this.events.push("Answered");
  }

  handOff(reason: string, now: number): Handoff {
    if (this.handoff !== null && this.handoff.isOpen) throw new DomainError("a conversation has at most one open handoff");
    if (this.state !== "awaiting_answer") throw new DomainError(`a ${this.state} conversation cannot be handed off`);
    const h = Handoff.create(`${this.id}-h${now}`, this.id, reason);
    this.handoff = h;
    this.state = "handed_off";
    this.events.push("HandedOff");
    return h;
  }

  resolve(by: "user" | "agent", now: number): void {
    if (this.state === "answered" && by === "user") {
      // the user confirmed the answer
    } else if (this.state === "handed_off" && this.handoff !== null && this.handoff.state === "closed") {
      // the person closed the handoff
    } else {
      throw new DomainError(`a ${this.state} conversation cannot be resolved by the ${by}`);
    }
    this.state = "resolved";
    this.resolvedAt = now;
    this.events.push("Resolved");
  }

  reopen(now: number): void {
    if (this.state !== "resolved" || this.resolvedAt === null) throw new DomainError("only a resolved conversation can be reopened");
    if (now - this.resolvedAt > WEEK_MS) throw new DomainError("a conversation reopens only within 7 days of resolve");
    this.state = "awaiting_answer";
    this.resolvedAt = null;
    this.rating = null;
    this.events.push("Reopened");
  }

  rate(score: number): void {
    if (this.state !== "resolved") throw new DomainError("only a resolved conversation can be rated");
    if (!Number.isInteger(score) || score < 1 || score > 5) throw new DomainError("a rating is a whole number from 1 to 5");
    if (this.rating !== null) throw new DomainError("a conversation is rated once per resolve");
    this.rating = score;
    this.events.push("Rated");
  }

  static restore(raw: Conversation): Conversation {
    const c = Object.assign(Object.create(Conversation.prototype), raw) as Conversation;
    if (raw.handoff) c.handoff = Handoff.restore(raw.handoff);
    return c;
  }
}
