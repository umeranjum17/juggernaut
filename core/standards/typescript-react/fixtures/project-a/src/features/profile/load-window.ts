export async function loadWindow(): Promise<Response> {
  return window.fetch("/api/profile");
}
