import type { Answer, Result, Sources } from './app.contract.d.ts';
import { HEX_TOKEN, HEX_URL } from './hex.ts';

// hex's voice server, on the tailnet. hex.ts is written at build from the stable app's settings
// (scripts/hex-env), so the token never enters the repository.
export const grants = `net.fetch ${HEX_URL}`;

type CallBody = { id?: unknown; ended?: unknown; title?: unknown; preview?: unknown; turns?: unknown };
const none: Result<'loadLatest'> = { id: '', title: '', live: false, turns: [] };

async function read(path: string): Promise<unknown> {
  const response = await fetch(`${HEX_URL}${path}`, { exactTimeout: 10000, headers: { authorization: `Bearer ${HEX_TOKEN}` } });
  if (!response.ok) throw new Error(`hex answered ${response.status}`);
  return response.json();
}

const text = (value: unknown) => (typeof value === 'string' ? value : '');

const sources: Sources = {
  // The newest call, and while it's live, what each side has said so far.
  loadLatest: async () => {
    const list = (await read('/calls')) as { calls?: CallBody[] };
    const newest = list.calls?.[0];
    if (!newest || typeof newest.id !== 'string') return none;
    const live = newest.ended === undefined;
    const record = live ? ((await read(`/calls/${encodeURIComponent(newest.id)}`)) as CallBody) : newest;
    const turns = Array.isArray(record.turns) ? record.turns : [];
    return {
      id: newest.id,
      title: text(newest.title) || text(newest.preview),
      live,
      turns: turns.map((turn: { who?: unknown; at?: unknown; text?: unknown }, index: number) => ({
        id: `${index}`,
        who: turn.who === 'you' ? 'you' : 'voice',
        text: text(turn.text),
      })),
    };
  },
};
export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
