const API_URL = (
  import.meta.env.VITE_API_URL || ""
).replace(/\/+$/, "");

export async function apiFetch<T>(
  path: string,
  token: string,
  init: RequestInit = {},
): Promise<T> {
  const headers = new Headers(init.headers);

  headers.set("Authorization", `Bearer ${token}`);
  headers.set("Accept", "application/json");

  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  const response = await fetch(
    `${API_URL}${path.startsWith("/") ? path : `/${path}`}`,
    {
      ...init,
      headers,
    },
  );

  if (!response.ok) {
    const details = await response.text().catch(() => "");
    throw new Error(
      `Backend returned ${response.status}` +
        (details ? `: ${details.slice(0, 200)}` : ""),
    );
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}