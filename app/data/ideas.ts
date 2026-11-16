import type { Result, Sources } from '../app.contract.d.ts';
import { enc, kept, watch, write } from './hex.ts';
import { proofLinks } from './proof.ts';
import { at, bool, list, num, str, type Json } from './parse.ts';

// What hex's check found, as it wrote it: words with links among them. The words read without the
// links (a link in brackets goes, one in the text keeps its site's name), which sit under them.
const LINKS = /https?:\/\/[^\s)]*[^\s).,;:!?'"]/gu;
const words = (finding: string) =>
  finding
    .replaceAll(/\s*\((?:see\s+)?https?:\/\/[^\s)]+\)/gu, '')
    .replaceAll(LINKS, (url) => url.replace(/^https?:\/\/(?:www\.)?/u, '').replace(/[:/].*$/u, ''))
    .trim();

const idea = (i: Json): Result<'watchIdeas'>['ideas'][number] => ({
  id: str(i.id),
  status: str(i.status),
  title: str(i.title),
  topic: str(i.topic),
  thread: str(i.thread),
  project: str(i.project),
  said: str(i.said),
  at: at(i.at),
  looking: bool(i.looking),
  day: str(i.day),
  found: bool(i.found),
  checks: list(i.checks, (c) => ({
    at: at(c.at),
    news: bool(c.news),
    words: words(str(c.finding)),
    links: proofLinks(str(c.finding)),
  })),
});

export const ideas: Partial<Sources> = {
  watchIdeas: () => watch('/ideas', (b) => ({ version: num(b.version), ideas: list(b.ideas, idea) })),
  keptIdeas: async (_args, _store, storage) => kept<Result<'keptIdeas'>>(storage, '/ideas'),
  // One idea, also once it's started or dropped, so its page stays as it was until it's left.
  watchIdea: ([id]) => watch(`/ideas/${enc(id)}`, (b) => ({ version: num(b.version), idea: idea(b) })),
  // seen | start | keep | stop | look (on `day`, 0 Sunday) | drop
  ideaDo: async ([id, verb, day]) => {
    const r = await write('POST', `/ideas/${enc(id)}/${verb}`, verb === 'look' ? { day } : undefined);
    return { id, verb, ok: r.ok, error: r.error };
  },
  // key: "app-…", made by the screen, so a resend after a lost reply isn't sent twice.
  addToIdea: async ([id, text, key]) => {
    const r = await write('POST', `/ideas/${enc(id)}/add`, { text, key });
    return { ok: r.ok, error: r.error };
  },
};
