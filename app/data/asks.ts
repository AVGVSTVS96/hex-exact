import type { Result, Sources } from '../app.contract.d.ts';
import { enc, read, watch, write } from './hex.ts';
import { at, bool, list, num, obj, str, strings, type Json } from './parse.ts';

type Ask = Result<'watchAsks'>['asks'][number];

export const place = (p: Json) => ({ app: str(p.app), place: str(p.place), task: str(p.task), call: str(p.call), link: str(p.link) });

export const ask = (a: Json): Ask => ({
  id: str(a.id),
  kind: str(a.kind),
  task: str(a.task),
  app: str(a.app),
  topic: str(a.topic),
  at: at(a.at),
  question: str(a.question),
  context: str(a.context),
  why: str(a.why),
  tag: str(a.tag),
  multiple: bool(a.multiple),
  options: list(a.options, (o) => ({
    label: str(o.label),
    value: str(o.value),
    pick: bool(o.pick),
    detail: str(o.detail),
    shot: typeof o.shot === 'number' ? o.shot : -1,
    aspect: num(o.shape),
  })),
  links: list(a.links, (l) => ({ label: str(l.label), url: str(l.url) })),
  pictures: list(a.pictures, (p) => ({ id: str(p.id), aspect: num(p.shape) })),
  places: list(a.places, place),
  was: strings(a.was),
});

// id: the ask it's about, so the screen knows which question the reply settles.
const sent = (id: string, r: { ok: boolean; error: string; reply: unknown }): Result<'answerAsk'> => {
  const reply = obj(r.reply);
  return { id, ok: r.ok, error: r.error, topic: str(reply.topic), missed: num(reply.missed) };
};

export const asks: Partial<Sources> = {
  // Everything that waits on Bassim: questions, stuck runs, fresh results, the last check.
  watchAsks: () =>
    watch('/asks', (b) => {
      const check = obj(b.check);
      return {
        version: num(b.version),
        asks: list(b.asks, ask),
        stuck: list(b.stuck, (s) => ({ id: str(s.id), app: str(s.app), title: str(s.title), why: str(s.why), action: str(s.action), mark: str(s.mark), at: at(s.at), request: str(s.request), sent: bool(s.sent) })),
        fresh: list(b.fresh, (f) => ({ id: str(f.id), app: str(f.app), topic: str(f.topic), title: str(f.title), line: str(f.line), at: at(f.at), read: bool(f.read) })),
        check: { at: at(check.at), why: str(check.why), fixed: num(check.fixed), flagged: num(check.flagged) },
      };
    }),
  loadCheck: async () => {
    const b = obj(await read('/asks/check'));
    const note = (n: Json) => ({ title: str(n.title), text: str(n.text), did: str(n.did) });
    return {
      at: at(b.at),
      why: str(b.why),
      read: Object.entries(obj(b.read)).map(([label, n]) => ({ label, n: num(n) })),
      fixed: list(b.fixed, note),
      flagged: list(b.flagged, note),
    };
  },
  loadWords: async ([id]) => {
    const b = obj(await read(`/asks/${enc(id)}/words`));
    return { place: str(b.place), at: at(b.at), text: str(b.text) };
  },
  // labels: one, or several for a question that takes more than one. media: ids from POST /media.
  answerAsk: async ([id, labels, media]) =>
    sent(id, await write('POST', `/asks/${enc(id)}/answer`, { ...(labels.length === 1 ? { label: labels[0] } : { labels }), ...(media.length ? { media } : {}) })),
  // hex's picks taken together, one after another; the first refusal stops the rest.
  answerPicks: async ([ids, labels]) => {
    for (const [i, id] of ids.entries()) {
      const r = await write('POST', `/asks/${enc(id)}/answer`, { label: labels[i] });
      if (!r.ok) return { ok: false, error: r.error };
    }
    return { ok: true, error: '' };
  },
  noteAsk: async ([id, text, media]) => sent(id, await write('POST', `/asks/${enc(id)}/note`, { text, ...(media.length ? { media } : {}) })),
  dismissAsk: async ([id]) => sent(id, await write('POST', `/asks/${enc(id)}/dismiss`)),
  undoAsk: async ([id]) => sent(id, await write('POST', `/asks/${enc(id)}/undo`)),
  actStuck: async ([id]) => sent(id, await write('POST', `/stuck/${enc(id)}/act`)),
  readFresh: async ([id]) => sent(id, await write('POST', `/fresh/${enc(id)}/read`)),
};
