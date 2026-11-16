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

let writes = 0;
createServer(async (request, response) => {
  const url = new URL(request.url, "http://standin");
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
