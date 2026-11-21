export function safeSize(x: unknown): number {
  return typeof x === "string" ? x.length : 0;
}
