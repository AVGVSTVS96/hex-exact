import { HEX_TOKEN, HEX_URL } from '../hex.ts';

// hex's voice server, on the tailnet. hex.ts is written at build from the stable app's settings
// (scripts/hex-env), so neither its address nor its token enters the repository.

const headers = { authorization: `Bearer ${HEX_TOKEN}` };

export const enc = encodeURIComponent;

/** What hex said when it refused, or how it couldn't be reached, as the stable app words it. */
async function refusal(response: Response): Promise<Error> {
  const text = await response.text().catch(() => '');
  let message = text;
  try {
    message = (JSON.parse(text) as { error?: { message?: string } }).error?.message ?? text;
  } catch {}
  return new Error(message.slice(0, 300) || `hex answered ${response.status}`);
}

const UNREACHABLE = 'Cannot reach hex. Check that Tailscale is on, then try again.';

/** One read. A failure fails the resource, which keeps its last answer. */
export async function read(path: string): Promise<unknown> {
  const response = await fetch(`${HEX_URL}${path}`, { exactTimeout: 90000, headers }).catch(() => {
    throw new Error(UNREACHABLE);
  });
  if (!response.ok) throw await refusal(response);
  return response.json();
}

/** One write. hex's refusals (4xx) come back as an answer the screen shows; a lost connection too. */
export async function write(method: string, path: string, body?: unknown): Promise<{ ok: boolean; error: string; reply: unknown }> {
  const response = await fetch(`${HEX_URL}${path}`, {
    method,
    exactTimeout: 60000,
    headers: body === undefined ? headers : { ...headers, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }).catch(() => null);
  if (!response) return { ok: false, error: UNREACHABLE, reply: null };
  if (!response.ok) return { ok: false, error: (await refusal(response)).message, reply: null };
  const text = await response.text();
  return { ok: true, error: '', reply: text ? JSON.parse(text) : null };
}

/**
 * A view of hex that stays current: hex holds each `GET <path>?after=<version>` until something
 * changes (25 s at most), and Exact's long poll asks again with the version of the last reply, one
 * request at a time, backing off when hex can't be reached. Each reply is mapped to the resource's
 * shape and commits as its answer; an end (a refusal, a 404) fails the resource, which keeps the
 * last answer until it is asked again.
 */
export function watch<T>(path: string, map: (body: Record<string, unknown>) => T): Promise<T> {
  return fetch(`${HEX_URL}${path}`, {
    headers,
    exactLongPoll: { cursor: 'after', from: 'version' },
    exactStream: (event) => {
      if (event.type === 'error') throw new Error(event.message || UNREACHABLE);
      return map(JSON.parse(String(event.data)) as Record<string, unknown>);
    },
  });
}
