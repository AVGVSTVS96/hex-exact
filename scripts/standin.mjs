// hex for the simulator: runs on the Mac beside it (scripts/sim), on 127.0.0.1:$PORT. Reads go
// through to hex with its token, long polls included, so the screens show what hex shows. Writes
// never reach hex: a run that answers, sends or removes changes nothing of yours. Each is answered
// as hex would, and listed in $WRITES so a flow can show what it sent.
//   HEX_URL=… HEX_TOKEN=… PORT=… WRITES=<file> node scripts/standin.mjs
import { appendFileSync } from "node:fs";
import { createServer } from "node:http";

const { HEX_URL, HEX_TOKEN, PORT, WRITES } = process.env;
const headers = { authorization: `Bearer ${HEX_TOKEN}` };

const body = async (request) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
};

// What a write answers: an answer, a note or a put-away says which thread it reached; a photo gets
// an id; a setting comes back as saved; anything else is done with nothing to say.
const replies = [
  [/^POST \/asks\/[^/]+\/(answer|note|dismiss)$/, () => ({ thread: "", topic: "", settled: 0, missed: 0 })],
  [/^POST \/media$/, (_, n) => ({ id: `standin-${n}`, kind: "photo" })],
];

const day = (back, hour, minute) => {
  const d = new Date();
  d.setDate(d.getDate() - back);
  d.setHours(hour, minute, 0, 0);
  return d.toISOString();
};

// Ideas (/ideas, /ideas/:id) are made up where his hex doesn't serve them yet: two with something found,
// the rest floated, some checked.
const check = (back, hour, news, finding) => ({ at: day(back, hour, news ? 40 : 0), news, finding });
const idea = (id, title, topic, said, back, day_, checks) => ({ id, status: "idea", title, topic, thread: `standin:${topic}`, project: "", said, at: day(back, 10, 0), looking: day_ !== "", day: day_, found: checks.some((c) => c.news), checks });
const ideas = [
  idea("t-2", "A pot rail over the island", "Kitchen remodel", "what about a rail over the island for the pans, brass maybe, about 90 cm", 12, "Sunday", [
    check(0, 13, true, "Two makers cut brass to 90 cm. Forge & Co: €64, ships in a week (https://forge.example/rails). Atelier Laiton: €92, three weeks (https://laiton.example). Nobody stocks one ready-made."),
    check(7, 9, false, "Still nothing ready-made at 90 cm; the nearest is 100 cm, too long for the island."),
    check(14, 9, false, "Looked at three shops; all sell 60 or 100 cm only."),
  ]),
  idea("t-3", "The night train home from Lisbon", "Lisbon trip", "could we take the night train back instead of flying", 9, "Friday", [check(2, 9, true, "No rail strike is called for the 22nd: the union vote was put off to December. The sleeper still runs Fridays, €89 a berth.")]),
  idea("t-8", "Ask readers what they want more of", "Newsletter", "maybe a short survey before issue 20, not now", 5, "", []),
  idea("t-9", "A second bike for guests", "Bike repair", "if a cheap one turns up, something to lend people", 20, "Saturday", [check(1, 9, false, "Nothing under €150 in a medium frame this week.")]),
  idea("t-10", "Open shelves instead of the top cupboards", "Kitchen remodel", "would open shelves look better than the top cupboards", 30, "", []),
  idea("t-11", "A reading light by the sofa", "Home", "the corner is too dark to read in", 3, "", []),
  idea("t-12", "Move the newsletter to Sundays", "Newsletter", "sunday mornings might get more opens", 40, "", [check(25, 9, false, "Sunday sends open about 4% better in two studies; the gap is small.")]),
];

// Goals (/goals) are his own where his hex serves them; made up only where it doesn't yet: the Lisbon
// trip of the drawings, and what hex watches.
const goal = (id, title, group, state, line, words, doneWhen, proof, at) => ({ id, title, group, topic: group, app: "telegram", run: "standin-lisbon", link: "", state, line, ask: "", words, doneWhen, proof, asked: day(3, 10, 0), at });
const watching = (id, title, topic, every, said, extra = []) => ({ id, stopped: false, title, topic, run: "", every, next: day(-1, 9, 0), asked: [], does: `Check ${title.toLowerCase()} and say what changed.`, runs: [{ at: day(0, 9, 0), said }, ...extra] });
const goals = {
  version: 1,
  goals: [
    goal("t-11", "A hotel near Alfama under €180", "Lisbon trip", "working", "Checking three that have a lift", ["find us somewhere in alfama, not over 180 a night, and it needs a lift"], "A room is booked in Alfama, under €180 a night, with a lift.", "", day(0, 15, 28)),
    goal("t-12", "A day in Sintra", "Lisbon trip", "needs", "9:15 or 11:40 train?", ["plan a day in sintra, not too early"], "Train times and a plan for the day are in the topic.", "", day(0, 13, 12)),
    goal("t-13", "Dinner on Saturday night", "Lisbon trip", "unstarted", "", ["somewhere good for dinner saturday, fish"], "A table for two is booked for Saturday.", "", day(1, 9, 0)),
    goal("t-1", "Flights, aisle seats", "Lisbon trip", "done", "", ["book us both ways, direct if you can, and i want the aisle"], "Both flights are booked, with an aisle seat each way.", "Out Friday 9:05, back Sunday 7:05, both direct. €296 for the two of you.", day(0, 15, 10)),
    goal("t-14", "A brass pot rail, 90 cm", "Kitchen remodel", "unstarted", "", ["find a pot rail that fits over the hob"], "One is ordered, cut to 90 cm.", "", day(2, 11, 0)),
    goal("t-5", "Book the installer", "Kitchen remodel", "done", "", ["get the installer in before the 25th"], "A date before the 25th is booked.", "Morning of the 22nd, two hours, €180 paid on the day.", day(1, 16, 20)),
  ],
  watching: [
    watching("rail-strike", "Rail strike on the 22nd", "Lisbon trip", "every day at 9 AM", "No strike called. The union vote was put off to December.", [{ at: day(1, 9, 0), said: "No strike called yet. The union meets on Thursday." }, { at: day(2, 9, 0), said: "Nothing new about a strike." }]),
    watching("passport", "Passport renewal", "Lisbon trip", "every Monday at 10 AM", "Still in the queue. It said 3 weeks on the 2nd."),
    watching("hinges", "Soft-close hinges in stock", "Kitchen remodel", "every day at 8 AM", "Back in stock at €8 each."),
  ],
};

let writes = 0;
createServer(async (request, response) => {
  const url = new URL(request.url, "http://standin");
  // Ideas are his own where his hex serves /ideas; made up only where it doesn't yet.
  const one = /^\/ideas(?:\/([^/]+))?$/.exec(url.pathname);
  const served = one && (await fetch(`${HEX_URL}/ideas`, { headers }).then((r) => r.status !== 404, () => false));
  if (request.method === "GET" && one && !served) {
    if (url.searchParams.get("after")) await new Promise((done) => setTimeout(done, 25_000));
    const found = one[1] ? ideas.find((i) => i.id === one[1]) : { ideas };
    if (found) response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ version: 1, ...found }));
    else response.writeHead(404).end();
    return;
  }
  const goalsServed = url.pathname === "/goals" && (await fetch(`${HEX_URL}/goals`, { headers }).then((r) => r.status !== 404, () => false));
  if (request.method === "GET" && url.pathname === "/goals" && !goalsServed) {
    if (url.searchParams.get("after")) await new Promise((done) => setTimeout(done, 25_000));
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(goals));
    return;
  }
  if (request.method === "GET") {
    try {
      const upstream = await fetch(HEX_URL + url.pathname + url.search, { headers });
      response.writeHead(upstream.status, { "content-type": upstream.headers.get("content-type") ?? "application/json" });
      response.end(Buffer.from(await upstream.arrayBuffer()));
    } catch {
      response.writeHead(502).end();
    }
    return;
  }
  const sent = await body(request);
  const line = `${request.method} ${url.pathname}`;
  writes += 1;
  if (WRITES) appendFileSync(WRITES, `${line} ${request.headers["content-type"]?.startsWith("application/json") ? sent : `(${sent.length} bytes)`}\n`);
  const reply = replies.find(([path]) => path.test(line))?.[1](sent, writes);
  if (reply) response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(reply));
  else response.writeHead(204).end();
}).listen(Number(PORT), "127.0.0.1");
