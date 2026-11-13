import type { Result, Sources } from '../app.contract.d.ts';
import { bool, list, num, obj, str } from './parse.ts';

// The live call is the Swift shell's. Its native module (modules/apple/Hex.swift) answers what it
// is now and says when it changes, so these resources follow it; with no module (the web, a build's
// bake) they answer idle.

const idle: Result<'callState'> = {
  status: 'idle', id: '', muted: false, hexMuted: false, interrupted: false, started: 0, error: '', ending: '', seconds: 0, shell: false,
};

export const call: Partial<Sources> = {
  callState: (_args, _store, _storage, native) => {
    if (!native?.available) return idle;
    native.watch('call');
    const s = native.call({ op: 'call' });
    return {
      status: str(s.status) || 'idle', id: str(s.id), muted: bool(s.muted), hexMuted: bool(s.hexMuted), interrupted: bool(s.interrupted),
      started: num(s.started), error: str(s.error), ending: str(s.ending), seconds: num(s.seconds), shell: bool(s.shell),
    };
  },
  captions: (_args, _store, _storage, native) => {
    if (!native?.available) return { call: '', turns: [] };
    native.watch('captions');
    const c = native.call({ op: 'captions' });
    return { call: str(c.call), turns: list(c.turns, (t) => ({ id: str(t.id), who: str(t.who), text: str(t.text), at: num(t.at) })) };
  },
  // op: start | mute | end. voice and about only start a call; about is a task id or "asks".
  callCommand: async ([op, voice, about], _store, _storage, native) => {
    if (!native?.available) return { ok: false, error: 'Calls run in the hex Exact app on the phone.' };
    const r = obj(await native.later({ op, voice, about }));
    return { ok: bool(r.ok), error: str(r.error) };
  },
};
