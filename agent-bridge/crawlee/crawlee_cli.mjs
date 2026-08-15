#!/usr/bin/env node
// crawlee_cli.mjs — the one-shot face of the Crawlee bridge.
//
// Contract (mirrors the browser-use CLI's honesty):
//   * One JSON request object on stdin, then EOF. Requests:
//       {"op":"scrape","url":"...","mode":"http"|"chromium","maxChars":N,"retries":N,"timeoutSecs":N}
//       {"op":"articles","url":"...","mode":"http"|"chromium","maxResults":N}
//       {"op":"search","query":"...","site":"example.com"?,"maxResults":N}
//       {"op":"paginated","url":"...","maxPages":N,"nextSelector":"..."?,"mode":"http"|"chromium"}
//   * Exactly one JSON object line on stdout — the result, or `{"error": "…"}`
//     for a page-level failure. stdout carries nothing else.
//   * Infrastructure failures (missing node_modules, bad request) go to stderr
//     with a nonzero exit — the caller treats those as "can't run at all".
//
// Run:  node crawlee_cli.mjs < request.json
import { log } from 'crawlee';
import { scrapeUrl, extractArticles, searchWeb, scrapePaginated } from './lib/scrape.mjs';

// stdout carries ONLY the JSON result — silence crawlee's INFO chatter
// (it would otherwise land between the request and the result line).
log.setLevel(log.LEVELS.ERROR);

const stdin = await new Promise(resolve => {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { data += chunk; });
  process.stdin.on('end', () => resolve(data));
});

function fail(message) {
  console.error(`crawlee-cli: ${message}`);
  process.exit(1);
}

let request;
try {
  request = JSON.parse(stdin);
} catch {
  fail(`invalid JSON on stdin: ${stdin.slice(0, 120)}`);
}
if (!request || typeof request !== 'object' || !request.op) {
  fail('missing "op" in request');
}

let result;
try {
  switch (request.op) {
    case 'scrape':
      result = await scrapeUrl(request);
      break;
    case 'articles':
      result = await extractArticles(request);
      break;
    case 'search':
      result = await searchWeb(request);
      break;
    case 'paginated':
      result = await scrapePaginated(request);
      break;
    default:
      fail(`unknown op "${request.op}"`);
  }
} catch (e) {
  result = { error: `Bridge error: ${String(e?.message || e)}` };
}

console.log(JSON.stringify(result ?? { error: 'Bridge returned no result.' }));
