import type { Result, Sources } from '../app.contract.d.ts';
import { ask } from './asks.ts';
import { enc, read, watch, write } from './hex.ts';
import { at, bool, list, num, obj, str, strings, type Json } from './parse.ts';

const call = (c: Json, live: string): Result<'watchCalls'>['calls'][number] => ({
  id: str(c.id), started: at(c.started), ended: at(c.ended), ending: str(c.end), source: str(c.from), voice: str(c.voice),
  title: str(c.title), reason: str(c.reason), why: str(c.why), summary: str(c.summary), waiting: strings(c.waiting),
  seconds: num(c.seconds), tasks: typeof c.tasks === 'number' ? c.tasks : Array.isArray(c.tasks) ? c.tasks.length : 0,
  preview: str(c.preview), live: str(c.id) === live || (c.ended === undefined && str(c.id) !== ''),
});

const record = (b: Json): Result<'loadCall'> => ({
  call: call(b, b.ended === undefined ? str(b.id) : ''),
  turns: list(b.turns, (t) => ({ who: str(t.who), at: num(t.at), text: str(t.text) })),
  tasks: list(b.tasks, (t) => ({ id: str(t.id), state: str(t.state), at: num(t.at), text: str(t.text) })),
  moments: list(b.moments, (m) => ({ at: num(m.at), kind: str(m.kind), text: str(m.text), media: str(obj(m.media).id) })),
});

export const calls: Partial<Sources> = {
  watchCalls: () =>
    watch('/calls', (b) => ({ version: num(b.version), live: str(b.live), calls: list(b.calls, (c) => call(c, str(b.live))) })),
  // A call's whole record. The live one follows hex as it changes; an ended one is read once (hex
  // holds only the live call's reads).
  loadCall: async ([id, live]) => (live ? watch(`/calls/${enc(id)}`, record) : record(obj(await read(`/calls/${enc(id)}`)))),
  removeCall: async ([id]) => {
    const r = await write('DELETE', `/calls/${enc(id)}`);
    return { ok: r.ok, error: r.error };
  },
  // What hex is doing for the live call: its agents' lines and the questions it put on screen.
  watchActivity: () =>
    watch('/activity', (b) => ({
      version: num(b.version),
      call: str(b.call),
      tasks: list(b.tasks, (t) => ({ id: str(t.id), state: str(t.state), text: str(t.text), to: str(t.to), line: str(t.line) })),
      asks: list(b.asks, (c) => ({ at: at(c.at), ask: ask(obj(c.ask)), answer: str(c.answer), answered: c.answer !== undefined })),
    })),
};
