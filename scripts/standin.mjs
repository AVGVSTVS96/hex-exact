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

// Feed (/feed) is made up, the same each run, so its flows show the drawn days without hex.
const day = (back, hour, minute) => {
  const d = new Date();
  d.setDate(d.getDate() - back);
  d.setHours(hour, minute, 0, 0);
  return d.toISOString();
};
const story = (id, kind, title, body, topic, at, opens) => ({ id, kind, title, body, topic, at, opens, links: [], pictures: [] });
const feed = (before) =>
  before
    ? { version: 0, older: 0, entries: [story("done:t-7", "done", "Renewed the domain for two years", "bassim.run is paid through November 2028, €24.", "Sites", day(3, 11, 5), "t-7")] }
    : {
        version: 1,
        older: Date.parse(day(1, 0, 0)),
        entries: [
          story("done:t-1", "done", "Booked both flights, aisle seats", "Out Friday 9:05, back Sunday 7:05, both direct. €296 for the two of you.", "Lisbon trip", day(0, 15, 10), "t-1"),
          story("found:rail:1", "found", "Two makers will cut a brass pot rail to length", "Nobody stocks one at 90 cm, but both cut to order. The cheaper is €64 and ships in a week.", "Kitchen remodel", day(0, 13, 40), "t-2"),
          story("decided:standin-ask", "decided", "Took the Saturday slot at the bike shop", "It was Saturday at 10 or a ten-day wait, and you ride on Sunday.", "Bike repair", day(0, 9, 12), "standin-ask"),
          story("found:strike:1", "found", "No rail strike is called for the 22nd", "The union vote was put off to December.", "Lisbon trip", day(0, 9, 0), "t-3"),
          story("done:t-4", "done", "Issue 13 went out to 412 readers", "Opened by 61% in the first hour. Two replies are waiting in the topic.", "Newsletter", day(0, 8, 30), "t-4"),
          story("done:t-5", "done", "Booked the installer for the 22nd", "Morning slot, two hours, €180 paid on the day.", "Kitchen remodel", day(1, 16, 20), "t-5"),
          story("found:hinge:1", "found", "The soft-close hinges are back in stock", "Same price as before, €8 each; twelve would do every door.", "Kitchen remodel", day(1, 10, 0), "t-6"),
        ],
      };

let writes = 0;
createServer(async (request, response) => {
  const url = new URL(request.url, "http://standin");
  if (request.method === "GET" && url.pathname === "/feed") {
    // A long poll for what's new waits as hex would, and nothing changes.
    if (url.searchParams.get("after")) await new Promise((done) => setTimeout(done, 25_000));
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(feed(url.searchParams.get("before"))));
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
