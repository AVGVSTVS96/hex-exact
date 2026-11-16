import type { Result, Sources } from '../app.contract.d.ts';
import { enc, kept, read, watch, write } from './hex.ts';
import { proofLinks, proofWords } from './proof.ts';
import { at, bool, list, num, str, strings, type Json } from './parse.ts';

// Goals: what Bassim asked hex for and what it watches (hex's GET /goals), kept current by the long
// poll and kept on the phone so Goals opens on the last list it knew.
const goal = (g: Json): Result<'watchGoals'>['goals'][number] => ({
  id: str(g.id), title: str(g.title), group: str(g.group), topic: str(g.topic), app: str(g.app), run: str(g.run),
  link: str(g.link), state: str(g.state), line: str(g.line), ask: str(g.ask), words: strings(g.words),
  doneWhen: str(g.doneWhen), proof: proofWords(str(g.proof)), proofLinks: proofLinks(str(g.proof)),
  asked: at(g.asked), at: at(g.at),
});

const watched = (w: Json): Result<'watchGoals'>['watching'][number] => ({
  id: str(w.id), stopped: bool(w.stopped), title: str(w.title), topic: str(w.topic), run: str(w.run), every: str(w.every), next: at(w.next),
  asked: strings(w.asked), does: str(w.does), runs: list(w.runs, (r) => ({ at: at(r.at), said: str(r.said) })),
});

type Goal = Result<'watchGoals'>['goals'][number];
// What wants him first: working, waiting on him, not started, stopped, then reached.
const RANK: Record<string, number> = { working: 0, needs: 1, unstarted: 2, idle: 3, done: 4, dropped: 5 };

// Projects with work going on or a question waiting first, then the one that moved last; in each,
// its goals by rank, newest first. Not needed stays in `goals` (its page shows Undo) but leaves the list.
const goals = (b: Json): Result<'watchGoals'> => {
  const all = list(b.goals, goal);
  const byGroup = new Map<string, Goal[]>();
  for (const g of all) if (g.state !== 'dropped') byGroup.set(g.group, [...(byGroup.get(g.group) ?? []), g]);
  const busy = (gs: Goal[]) => gs.some((g) => g.state === 'working' || g.state === 'needs');
  const latest = (gs: Goal[]) => Math.max(...gs.map((g) => g.at));
  const order = [...byGroup.entries()].sort(([, a], [, b]) => Number(busy(b)) - Number(busy(a)) || latest(b) - latest(a));
  const rank = (g: Goal) => RANK[g.state] ?? 3;
  const ranked = order.flatMap(([, gs]) => [...gs].sort((x, y) => rank(x) - rank(y) || y.at - x.at));
  return {
    version: num(b.version),
    goals: [...ranked, ...all.filter((g) => g.state === 'dropped')],
    groups: order.map(([name, gs]) => ({
      name,
      states: gs.map((g) => g.state),
    })),
    watching: list(b.watching, watched),
  };
};

// id: the goal or watch it's about, so the screen knows which row the reply settles.
const sent = (id: string, r: { ok: boolean; error: string }) => ({ id, ok: r.ok, error: r.error, topic: '', missed: 0 });

export const goalSources: Partial<Sources> = {
  watchGoals: () => watch('/goals', goals),
  keptGoals: async (_args, _store, storage) => kept<Result<'keptGoals'>>(storage, '/goals'),
  // A goal reached before the list's week, as a Feed entry opens it.
  goalById: async ([id]) => goal((await read(`/goals/${enc(id)}`)) as Json),
  // verb: drop ("Not needed") | reopen ("Not what I asked") | undo.
  changeGoal: async ([id, verb]) => sent(id, await write('POST', `/goals/${enc(id)}/${verb}`)),
  // verb: stop | undo.
  changeWatch: async ([id, verb]) => sent(id, await write('POST', `/goals/w/${enc(id)}/${verb}`)),
};
