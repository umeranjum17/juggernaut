export interface Profile { first: string; last: string }
export async function getProfile(): Promise<Profile> {
  const r = await fetch("/api/profile");
  return (await r.json()) as Profile;
}
