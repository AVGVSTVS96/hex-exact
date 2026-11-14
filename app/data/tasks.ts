import type { Result, Sources } from '../app.contract.d.ts';
import { ask } from './asks.ts';
import { enc, watch, write } from './hex.ts';
import { pinSections } from './pinned.ts';
import { proofLinks, proofWords } from './proof.ts';
import { at, bool, list, num, obj, str, type Json } from './parse.ts';

const track = (t: Json) => ({ at: at(t.at), state: str(t.state) });
const step = (s: Json, i: number) => ({
  id: str(s.id) || `${i}`, at: at(s.at), ended: at(s.end), kind: str(s.kind), text: str(s.text), state: str(s.state),
  detail: str(s.detail), result: str(s.result), agent: str(s.agent),
});
// via: the app the agent runs in (t3 opens it in T3 Code). Its steps come only on a task's page.
const agent = (a: Json) => ({
  id: str(a.id), label: str(a.label), state: str(a.state), who: str(a.who), since: at(a.since),
  ended: at(a.end), line: str(a.line), result: str(a.result), link: str(a.link), via: str(a.via),
  steps: list(a.steps, step),
});

const row = (t: Json): Result<'watchTasks'>['tasks'][number] => ({
  id: str(t.id), app: str(t.app), thread: str(t.thread), name: str(t.name), where: str(t.where), place: str(t.place),
  state: str(t.state), running: bool(t.running), line: str(t.line), since: at(t.since), at: at(t.at), link: str(t.link),
  track: list(t.track, track), agents: list(t.agents, agent),
});

export const tasks: Partial<Sources> = {
  watchTasks: () =>
    watch('/tasks', (b) => ({
      version: num(b.version),
      tasks: list(b.tasks, row),
      finished: list(b.finished, (f) => ({
        id: str(f.id), title: str(f.title), topic: str(f.topic), app: str(f.app), proof: str(f.proof), at: at(f.at), run: str(f.run), link: str(f.link),
        said: proofWords(str(f.proof)), links: proofLinks(str(f.proof)),
      })),
    })),
  // The toolbar's badge: threads that need Bassim, threads working, and everything that's his.
  watchCounts: () => watch('/tasks/summary', (b) => ({ needs: num(b.needs), working: num(b.working), yours: num(b.yours) })),
  // A task's page; hex answers a thread with steps, or a page (a place without a run) without.
  watchTask: ([id]) =>
    watch(`/tasks/${enc(id)}`, (t) => ({
      kind: 'steps' in t ? 'task' : 'page',
      ...row(t),
      needs: str(t.needs),
      pin: str(t.pin),
      lately: list(t.lately, (l) => ({ at: at(l.at), state: str(l.state), text: str(l.text) })),
      steps: list(t.steps, step),
      plan: list(t.plan, (p) => ({ text: str(p.text), state: str(p.state) })),
      asks: list(t.asks, ask),
      pins: pinSections(str(t.pin)),
    })),
  watchChat: ([id]) =>
    watch(`/tasks/${enc(id)}/chat`, (b) => ({
      version: num(b.version),
      sends: bool(b.sends),
      total: num(b.total),
      turns: list(b.turns, (t, i) => ({
        id: `${i}`,
        source: str(t.from),
        text: str(t.text),
        media: list(t.media, (m) => ({ id: str(m.id), kind: str(m.kind), aspect: num(m.shape) })),
      })),
      waiting: list(b.waiting, (w) => ({ key: str(w.key), text: str(w.text), at: at(w.at) })),
    })),
  // key: "app-…", made by the screen, so a resend after a lost reply isn't sent twice.
  sendChat: async ([id, text, key, media]) => {
    const r = await write('POST', `/tasks/${enc(id)}/chat`, { text, key, ...(media.length ? { media } : {}) });
    return { ok: r.ok, error: r.error };
  },
  stopTask: async ([id]) => {
    const r = await write('POST', `/tasks/${enc(id)}/stop`);
    return { id, ok: r.ok, error: r.error, topic: '', missed: 0 };
  },
  // During a call: bring a task, or everything that waits ("asks"), into it.
  talkAbout: async ([about]) => {
    const r = await write('POST', about === 'asks' ? '/asks/talk' : `/tasks/${enc(about)}/talk`);
    return { ok: r.ok, error: r.error };
  },
};
