import type { Result, Sources } from '../app.contract.d.ts';
import { read, write } from './hex.ts';
import { list, obj, str, type Json } from './parse.ts';

const settings = (b: Json): Result<'loadSettings'> => {
  const s = obj(b.settings);
  const choice = (c: Json) => ({ id: str(c.id), label: str(c.label) });
  return {
    voice: str(s.voice), personality: str(s.personality), pace: str(s.pace), words: str(s.words),
    personalities: list(b.personalities, choice), paces: list(b.paces, choice),
  };
};

export const voice: Partial<Sources> = {
  // How hex talks on every call, phone calls too: kept on hex, not the phone.
  loadSettings: async () => settings(obj(await read('/settings'))),
  // field: voice | personality | pace | words
  saveSetting: async ([field, value]) => {
    const r = await write('PUT', '/settings', { [field]: value });
    return { ok: r.ok, error: r.error };
  },
};
