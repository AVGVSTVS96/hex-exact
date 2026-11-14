import type { Answer, Sources } from './app.contract.d.ts';
import { asks } from './data/asks.ts';
import { build, call } from './data/call.ts';
import { calls } from './data/calls.ts';
import { kept } from './data/kept.ts';
import { voice } from './data/settings.ts';
import { tasks } from './data/tasks.ts';

// hex's address is written at build (scripts/hex-env), so the grant is every https origin.
export const grants = 'net.fetch https:\nfs.read app:/data\nfs.write app:/data';

const sources = { ...call, ...build, ...calls, ...tasks, ...asks, ...voice, ...kept } as Sources;

export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
