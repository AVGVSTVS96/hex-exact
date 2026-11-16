import type { Result, Sources } from '../app.contract.d.ts';
import { enc, kept, read, watch, write } from './hex.ts';
import { at, list, num, str, type Json } from './parse.ts';

type Feed = Result<'watchFeed'>;

const feedOf = (b: Json): Feed => ({
  version: num(b.version),
  entries: list(b.entries, (e) => ({
    id: str(e.id),
    kind: str(e.kind),
    title: str(e.title),
    body: str(e.body),
    topic: str(e.topic),
    at: at(e.at),
    opens: str(e.opens),
    links: list(e.links, (l) => ({ label: str(l.label), url: str(l.url) })),
    pictures: list(e.pictures, (p) => ({ id: str(p.id), aspect: num(p.shape) })),
  })),
  older: num(b.older),
});

// Older stretches don't change once written, so each is read once a launch.
const stretches = new Map<number, Feed>();

export const feed: Partial<Sources> = {
  // The newest stretch of Feed, kept current by hex's long poll.
  watchFeed: () => watch('/feed', feedOf),
  keptFeed: async (_args, _store, storage) => kept<Feed>(storage, '/feed'),
  // `reach` stretches older than `from`, oldest last: the list asks for one more as it reaches its end.
  olderFeed: async ([from, reach]) => {
    const entries: Feed['entries'] = [];
    let before = from;
    for (let i = 0; i < reach && before > 0; i += 1) {
      const stretch = stretches.get(before) ?? feedOf((await read(`/feed?before=${before}`)) as Json);
      stretches.set(before, stretch);
      entries.push(...stretch.entries);
      before = stretch.older;
    }
    return { version: 0, entries, older: before };
  },
  // During a call: bring an entry into it, as a task's Talk does.
  discussFeed: async ([id]) => {
    const r = await write('POST', `/feed/${enc(id)}/talk`);
    return { ok: r.ok, error: r.error };
  },
};
