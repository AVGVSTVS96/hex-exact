// hex's JSON, made to the app's shapes: every field present, of its type. A field hex leaves out
// comes as "", 0, false or [].

export type Json = Record<string, unknown>;

export const str = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '');
export const num = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
export const bool = (v: unknown): boolean => v === true;
export const obj = (v: unknown): Json => (v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Json) : {});
export const list = <T>(v: unknown, map: (item: Json, index: number) => T): T[] => (Array.isArray(v) ? v.map((x, i) => map(obj(x), i)) : []);
export const strings = (v: unknown): string[] => (Array.isArray(v) ? v.map(str) : []);
/** An instant: hex sends ISO strings or epoch milliseconds. */
export const at = (v: unknown): number => {
  if (typeof v === 'number') return v;
  const ms = typeof v === 'string' ? Date.parse(v) : NaN;
  return Number.isFinite(ms) ? ms : 0;
};
