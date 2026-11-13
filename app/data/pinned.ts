// A thread's pinned status post, read into sections the task page draws: a heading (bold, a
// "Title:" line, or a known word like Done or Next) starts one, bullets are its items, a fence is
// code. Done sections start folded. The stable app reads it the same way (src/live/pinned.ts).

type Mark = 'done' | 'working' | 'needs' | 'failed' | 'idle';
type Line = { kind: 'item' | 'code' | 'text'; text: string; mark: Mark; url: string };
type Section = { title: string; mark: Mark; folded: boolean; lines: Line[] };

const BULLET = /^\s*(?:[-*•·◦▪]|\d+[.)])\s+/u;
const LINK = /\[(?<label>[^\]]+)\]\((?<url>https?:\/\/[^)\s]+)\)/u;
const WHOLE_BOLD = /^(?<bold>\*\*|__)(?<title>[^:*_]{1,40}:)(?<rest>.*?)\k<bold>$/u;
const PIN = /^📌\s*/u;
const URL = /https?:\/\/[^\s)]+[^\s).,;:!?'"]/u;
const FENCE = /^\s*```/u;
const HEADING_EMOJI = /^(?:\p{Extended_Pictographic}️?\s*)+/u;
const TITLES =
  /^(?<title>(?:\*\*|__)?(?:done|running|working|in progress|pending|waiting on you|blocked on you|your call|known|known problems|next|later|live|links)\b[^:]{0,30}):(?:\*\*|__)?\s*(?<rest>.+)$/iu;
const EMOJI_MARKS: [RegExp, Mark][] = [
  [/^(?:✅|☑️|✔️|✔|✓)\s*/u, 'done'],
  [/^(?:❌|⚠️|🔴|🛑)\s*/u, 'failed'],
  [/^(?:🔄|⏳|🏃|🟡)\s*/u, 'working'],
  [/^(?:❓|👉|🟢)\s*/u, 'needs'],
];

const plain = (text: string) => text.replaceAll(/\*\*|__/gu, '').trim();

const linked = (text: string) => {
  const link = LINK.exec(text);
  const url = link?.groups?.url ?? URL.exec(text)?.[0] ?? '';
  return { text: plain(link ? text.replace(LINK, '$<label>') : text), url };
};

const sectionMark = (title: string): Mark =>
  /\b(?:done|shipped|finished|live)\b/iu.test(title) ? 'done'
  : /\b(?:running|working|in progress|underway)\b/iu.test(title) ? 'working'
  : /\b(?:waiting on you|your call|needs you|blocked on you|for you|to decide)\b/iu.test(title) ? 'needs'
  : /\b(?:known|problem|broken|fail|blocked|stuck)\b/iu.test(title) ? 'failed'
  : 'idle';

const item = (text: string, mark: Mark): Line => {
  const found = EMOJI_MARKS.find(([emoji]) => emoji.test(text));
  return { kind: 'item', ...linked(found ? text.replace(found[0], '') : text), mark: found ? found[1] : mark };
};

const headingOf = (line: string): string | undefined => {
  const bold = /^\*\*(?<title>[^*]+)\*\*:?$/u.exec(line)?.groups?.title;
  if (bold !== undefined) return bold.replace(HEADING_EMOJI, '').replace(/:$/u, '').trim();
  const bare = plain(line);
  return bare.length <= 60 && bare.endsWith(':') && !BULLET.test(line) ? bare.slice(0, -1).replace(HEADING_EMOJI, '').trim() : undefined;
};

export const pinSections = (text: string): Section[] => {
  const sections: Section[] = [];
  let current: Section = { title: '', mark: 'idle', folded: false, lines: [] };
  const lines = text.split('\n').values();
  for (const raw of lines) {
    if (FENCE.test(raw)) {
      const code: string[] = [];
      for (let next = lines.next(); next.done !== true && !FENCE.test(next.value); next = lines.next()) code.push(next.value);
      current.lines.push({ kind: 'code', text: code.join('\n'), mark: 'idle', url: '' });
      continue;
    }
    const line = raw.trim().replace(PIN, '');
    if (!line) continue;
    const { title, rest } = TITLES.exec(line.replace(WHOLE_BOLD, '$<bold>$<title>$<bold>$<rest>'))?.groups ?? {};
    const heading = title === undefined ? headingOf(line) : plain(title);
    if (heading) {
      if (current.title || current.lines.length) sections.push(current);
      const mark = sectionMark(heading);
      current = { title: heading, mark, folded: mark === 'done', lines: rest === undefined ? [] : [item(rest, mark)] };
    } else if (BULLET.test(line)) {
      current.lines.push(item(line.replace(BULLET, ''), current.mark));
    } else {
      current.lines.push({ kind: 'text', ...linked(line), mark: 'idle' });
    }
  }
  if (current.title || current.lines.length) sections.push(current);
  return sections;
};
