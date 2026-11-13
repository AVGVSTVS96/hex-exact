import type { Result, Sources } from '../app.contract.d.ts';
import { INSTALL_URL } from '../hex.ts';
import { write } from './hex.ts';
import { bool, list, num, obj, str, type Json } from './parse.ts';

// The live call is the Swift shell's. Its native module (modules/apple/Hex.swift) answers what it
// is now and says when it changes, so these resources follow it; with no module (the web, a build's
// bake) they answer idle.

const idle: Result<'callState'> = {
  status: 'idle', id: '', muted: false, hexMuted: false, interrupted: false, started: 0, error: '', ending: '', seconds: 0, shell: false, demo: false,
};

const NO_SHELL = 'Calls run in the hex Exact app on the phone.';

const media = (m: Json) => ({ id: str(m.id), kind: str(m.kind), aspect: num(m.aspect) });

export const call: Partial<Sources> = {
  callState: (_args, _store, _storage, native) => {
    if (!native?.available) return idle;
    native.watch('call');
    const s = native.call({ op: 'call' });
    return {
      status: str(s.status) || 'idle', id: str(s.id), muted: bool(s.muted), hexMuted: bool(s.hexMuted), interrupted: bool(s.interrupted),
      started: num(s.started), error: str(s.error), ending: str(s.ending), seconds: num(s.seconds), shell: bool(s.shell), demo: bool(s.demo),
    };
  },
  captions: (_args, _store, _storage, native) => {
    if (!native?.available) return { call: '', turns: [] };
    native.watch('captions');
    const c = native.call({ op: 'captions' });
    return {
      call: str(c.call),
      turns: list(c.turns, (t) => ({ id: str(t.id), who: str(t.who), text: str(t.text), at: num(t.at), media: list(t.media, media), note: str(t.note) })),
    };
  },
  // op: start | mute | end | demo. voice and about only start a call; about is a task id or "asks".
  // prefs: the phone's sounds, haptics and persona, which the shell keeps for the call's feedback
  // and its Live Activity.
  callCommand: async ([op, voice, about, prefs], _store, _storage, native) => {
    if (!native?.available) return { ok: false, error: NO_SHELL };
    const r = obj(await native.later({ op, voice, about, ...prefs }));
    return { ok: bool(r.ok), error: str(r.error) };
  },
  // A photo or video into the live call, from the camera or Photos: the shell shows it in the call's
  // words at once and says there how it went.
  shareMedia: async ([source], _store, _storage, native) => {
    if (!native?.available) return { ok: false, error: NO_SHELL };
    const r = obj(await native.later({ op: 'share', source }));
    return { ok: bool(r.ok), error: str(r.error) };
  },
  // Send again what didn't reach the call.
  retryShare: async ([key], _store, _storage, native) => {
    if (!native?.available) return { ok: false, error: NO_SHELL };
    const r = obj(await native.later({ op: 'retry', key }));
    return { ok: bool(r.ok), error: str(r.error) };
  },
  // Photos and videos for a composer: picked, uploaded to hex (POST /media), answered as ids.
  attachMedia: async ([source, most], _store, _storage, native) => {
    if (!native?.available) return { ok: false, error: NO_SHELL, media: [] };
    const r = obj(await native.later({ op: 'attach', source, most }));
    return { ok: bool(r.ok), error: str(r.error), media: list(r.media, media) };
  },
  // A call held elsewhere (a phone call), ended from here.
  hangUp: async ([id]) => {
    const r = await write('DELETE', '/session', { sessionId: id });
    return { ok: r.ok, error: r.error };
  },
};

export const build: Partial<Sources> = {
  // The newest build scripts/ship put on the install link, beside the one running (0 off the phone).
  checkBuild: async (_args, _store, _storage, native) => {
    const running = native?.available ? num(native.call({ op: 'build' }).number) : 0;
    const response = await fetch(`${INSTALL_URL}/latest.json`, { exactTimeout: 20000, cache: 'no-store' });
    if (!response.ok) throw new Error(`the install link answered ${response.status}`);
    const latest = obj(await response.json());
    return { latest: num(latest.number), running, install: str(latest.install) };
  },
};
