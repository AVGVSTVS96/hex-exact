import type { Result, Sources } from '../app.contract.d.ts';
import { keep, kept as read } from './hex.ts';

// The lists as hex last gave them, kept in app storage so a launch without Tailscale still shows
// them, marked as waiting for hex. A call isn't live from a kept list.
export const kept: Partial<Sources> = {
  keep: async ([path], _store, storage) => {
    await keep(storage, path);
    return { ok: true, error: '' };
  },
  keptTasks: async (_args, _store, storage) => read<Result<'keptTasks'>>(storage, '/tasks'),
  // A list kept before hex said what it decided has none.
  keptAsks: async (_args, _store, storage) => {
    const asks = await read<Result<'keptAsks'>>(storage, '/asks');
    return { ...asks, decided: asks.decided ?? [] };
  },
  keptCounts: async (_args, _store, storage) => read<Result<'keptCounts'>>(storage, '/tasks/summary'),
  keptCalls: async (_args, _store, storage) => {
    const calls = await read<Result<'keptCalls'>>(storage, '/calls');
    return { ...calls, live: '', calls: calls.calls.map((c) => ({ ...c, live: false })) };
  },
};
