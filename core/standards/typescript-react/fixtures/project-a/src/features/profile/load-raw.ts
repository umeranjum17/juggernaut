export async function loadRaw(): Promise<unknown> {
  const r = await fetch("/api/raw");
  return r.json();
}
