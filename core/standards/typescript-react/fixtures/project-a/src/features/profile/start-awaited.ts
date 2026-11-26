import { getProfile } from "../../shared/api/client";
export async function startAwaited(): Promise<string> {
  const p = await getProfile();
  return p.first;
}
