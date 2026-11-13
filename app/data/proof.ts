// A finished task's proof, as hex writes it: words with links (GitHub, Telegram messages, pages)
// among them. The list shows the words with each link named; the done page lists the links.

const LINKS = /https?:\/\/[^\s)]*[^\s).,;:!?'"]|telegram:-100\d+:\d+/gu;

const linkName = (url: string) => {
  const { repo, kind, ref } =
    /^https?:\/\/github\.com\/[^/]+\/(?<repo>[^/#?]+)(?:\/(?<kind>pull|commit)\/(?<ref>\w+))?/u.exec(url)?.groups ?? {};
  if (repo !== undefined) return ref === undefined ? repo : `${repo} ${kind === 'pull' ? '#' : ''}${ref.slice(0, 7)}`;
  const message = /^https:\/\/t\.me\/c\/\d+\/(?<number>\d+)$/u.exec(url)?.groups;
  if (message) return `message ${message.number}`;
  return url.replace(/^https?:\/\/(?:www\.)?/u, '').replace(/[:/].*$/u, '');
};

const urlOf = (found: string) => {
  const key = /^telegram:-100(?<chat>\d+):(?<message>\d+)$/u.exec(found)?.groups;
  return key ? `https://t.me/c/${key.chat}/${key.message}` : found;
};

export const proofWords = (proof: string) => proof.replaceAll(LINKS, (found) => linkName(urlOf(found))).trim();

export const proofLinks = (proof: string) =>
  [...new Set((proof.match(LINKS) ?? []).map(urlOf))].map((url) => ({ label: linkName(url), url }));
