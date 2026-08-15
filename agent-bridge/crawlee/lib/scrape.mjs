// lib/scrape.mjs — the Crawlee engine behind both faces of the bridge.
//
// One module of pure functions; the CLI (crawlee_cli.mjs) and the MCP server
// (crawlee_mcp_server.mjs) are thin dispatch shells over it. Nothing here
// touches stdout — diagnostics belong to the callers' stderr channels.
//
// Honest limitations, surfaced as `{error}` results rather than lies:
//   * HTTP mode (default) uses CheerioCrawler — fast, but no JavaScript. A
//     JS-rendered page yields whatever static HTML the server sent.
//   * Chromium mode (scrape_with_js / mode:"chromium") needs `playwright`
//     installed next to this package. When it isn't, the error says so —
//     no fabricated partial data.
//   * Crawlee's own retry/blocked handling applies (`retryOnBlocked`); a page
//     that refuses to be scraped fails honestly.

import * as cheerio from 'cheerio';

const MAX_HTML = 150_000; // raw HTML kept for link extraction / pagination

/** Collapse whitespace like a reader: `a\n\n b ` → `a b`. */
function collapse(text) {
  return (text || '').replace(/\s+/g, ' ').trim();
}

/**
 * Fetch `url` and return `{ url, title, html, text }` — `text` the collapsed
 * readable text (capped at maxChars), `html` the raw document (capped at
 * MAX_HTML) for parsers that need structure. `mode` selects the engine:
 * "http" (Cheerio, no JS) or "chromium" (Playwright, renders JS first).
 */
export async function scrapeUrl({
  url,
  mode = 'http',
  maxChars = 20_000,
  retries = 1,
  timeoutSecs = 30,
}) {
  if (mode === 'chromium') {
    return scrapeWithPlaywright({ url, maxChars, retries, timeoutSecs });
  }

  let CheerioCrawler = null;
  try {
    ({ CheerioCrawler } = await import('crawlee'));
  } catch {
    return { error: 'Crawlee is not installed — run: cd agent-bridge/crawlee && npm install' };
  }

  let title = '';
  let html = '';
  let text = '';
  const crawler = new CheerioCrawler({
    maxRequestsPerCrawl: 1,
    maxRequestRetries: Math.max(0, retries),
    requestHandlerTimeoutSecs: Math.max(5, timeoutSecs),
    retryOnBlocked: true,
    requestHandler: async ({ request, $ }) => {
      title = collapse($('title').first().text()) || collapse($('h1').first().text());
      html = $.html().slice(0, MAX_HTML);
      text = collapse($('body').first().text()).slice(0, maxChars);
    },
  });

  try {
    await crawler.run([url]);
  } catch (e) {
    return { error: `Scrape failed: ${String(e?.message || e)}` };
  }
  if (!title && !text) {
    return { error: 'No content extracted — the page may be blocked or empty.' };
  }
  return { url, title, text, html: html || undefined };
}

/** Chromium-mode scrape: render JS via Playwright, then extract like HTTP. */
async function scrapeWithPlaywright({ url, maxChars, retries, timeoutSecs }) {
  let PlaywrightCrawler = null;
  try {
    ({ PlaywrightCrawler } = await import('crawlee'));
  } catch {
    return { error: 'Crawlee is not installed — run: cd agent-bridge/crawlee && npm install' };
  }

  let title = '';
  let html = '';
  let text = '';
  const crawler = new PlaywrightCrawler({
    maxRequestsPerCrawl: 1,
    maxRequestRetries: Math.max(0, retries),
    requestHandlerTimeoutSecs: Math.max(10, timeoutSecs),
    retryOnBlocked: true,
    requestHandler: async ({ page }) => {
      title = collapse(await page.title());
      html = (await page.content()).slice(0, MAX_HTML);
      text = collapse(await page.locator('body').first().innerText()).slice(0, maxChars);
    },
  });

  try {
    await crawler.run([url]);
  } catch (e) {
    const msg = String(e?.message || e);
    const hint = msg.includes('playwright') || msg.includes('chromium')
      ? ' — install with: cd agent-bridge/crawlee && npm install playwright && npx playwright install chromium'
      : '';
    return { error: `JS scrape failed${hint}: ${msg}` };
  }
  if (!title && !text) {
    return { error: 'No content extracted — the page may be blocked or empty.' };
  }
  return { url, title, text, html: html || undefined };
}

/**
 * Pull article-ish links out of a listing page: anchors whose text reads like
 * a headline (10–120 chars) and whose href is a real URL. Dedupes and caps at
 * maxResults. Degrades to an empty list when html is absent.
 */
export function articleLinksFrom({ html, maxResults = 20 }) {
  if (!html) return [];
  const $ = cheerio.load(html);
  const seen = new Set();
  const out = [];
  $('a[href]').each((_, el) => {
    if (out.length >= maxResults) return false;
    const title = collapse($(el).text());
    if (title.length < 10 || title.length > 120) return;
    const href = $(el).attr('href') || '';
    if (!/^https?:\/\//i.test(href)) return;
    const clean = href.split('#')[0];
    if (!clean || seen.has(clean)) return;
    seen.add(clean);
    const snippet = collapse($(el).closest('article, li, div').first().text()).slice(0, 160);
    out.push({ title, url: clean, description: snippet || undefined });
  });
  return out;
}

/** Extract article links from a listing page (extract_articles). */
export async function extractArticles({ url, mode = 'http', maxResults = 20, retries = 1, timeoutSecs = 30 }) {
  const page = await scrapeUrl({ url, mode, maxChars: 60_000, retries, timeoutSecs });
  if (page.error) return page;
  const articles = articleLinksFrom({ html: page.html || '', maxResults });
  if (!articles.length) return { error: 'No article links found on that page.', url, title: page.title };
  return { url, title: page.title, articles };
}

/**
 * Web search through a JS-free HTML endpoint (no key). Tries DuckDuckGo's
 * HTML endpoint first (no consent wall, the same choice BrowserUseClient
 * makes); DDG serves an anomaly page to plain fetches often enough that a
 * failed parse falls back to Bing's HTML endpoint, which is more lenient.
 * `site` narrows the query to one domain. Real URLs are unwrapped from DDG's
 * redirect and Bing's bounce.
 */
export async function searchWeb({ query, site, maxResults = 10, timeoutSecs = 15 }) {
  const q = site ? `${query} site:${site}` : query;
  const ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
  const fetchHtml = async (url) => {
    const res = await fetch(url, {
      headers: { 'User-Agent': ua },
      signal: AbortSignal.timeout(timeoutSecs * 1000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.text();
  };

  // DDG first.
  let html;
  try {
    html = await fetchHtml('https://html.duckduckgo.com/html/?q=' + encodeURIComponent(q));
  } catch {
    html = null;
  }
  let results = [];
  if (html) {
    const $ = cheerio.load(html);
    $('.result').each((_, el) => {
      if (results.length >= maxResults) return false;
      const a = $(el).find('a.result__a').first();
      const title = collapse(a.text());
      if (!title) return;
      const raw = a.attr('href') || '';
      const unwrapped = raw.match(/uddg=([^&]+)/);
      const url = unwrapped ? decodeURIComponent(unwrapped[1]) : raw;
      const snippet = collapse($(el).find('.result__snippet').first().text()) || undefined;
      results.push({ title, url, snippet });
    });
  }

  // Bing fallback (DDG served an anomaly page, or threw).
  if (!results.length) {
    try {
      html = await fetchHtml('https://www.bing.com/search?q=' + encodeURIComponent(q));
      const $ = cheerio.load(html);
      $('li.b_algo').each((_, el) => {
        if (results.length >= maxResults) return false;
      const a = $(el).find('h2 a').first();
      const title = collapse(a.text());
      if (!title) return;
      // Current Bing b_algo links are direct external URLs; unescape the one
      // entity cheerio leaves raw. (Google-style /url?q= bounces do not occur.)
      const url = (a.attr('href') || '').replace(/&amp;/g, '&');
      const snippet = collapse($(el).find('.b_caption p').first().text()) || undefined;
      results.push({ title, url, snippet });
      });
    } catch {
      // Both engines failed — fall through to the honest empty-result error.
    }
  }

  if (!results.length) return { error: 'No search results.' };
  return { query: q, results };
}

/**
 * Follow a paginated listing up to maxPages, returning each page's text.
 * `nextSelector` is a CSS selector (default: common "next" patterns). Stops
 * when a page has no next link, or revisits an earlier page.
 */
export async function scrapePaginated({
  url,
  maxPages = 3,
  nextSelector = 'a[rel="next"], a:contains("Next"), a:contains("next"), button:contains("Next")',
  mode = 'http',
  retries = 1,
  timeoutSecs = 30,
}) {
  const pages = [];
  let current = url;
  for (let i = 0; i < Math.max(1, Math.min(maxPages, 10)) && current; i++) {
    const page = await scrapeUrl({ url: current, mode, maxChars: 8_000, retries, timeoutSecs });
    if (page.error) {
      return pages.length ? { pages, error: `${page.error} (after ${pages.length} page(s))` } : page;
    }
    pages.push({ url: current, title: page.title, text: page.text });

    if (!page.html) break;
    const $ = cheerio.load(page.html);
    let next = null;
    $(nextSelector).each((_, el) => {
      if (next) return;
      const href = $(el).attr('href');
      if (href && href !== '#' && !href.startsWith('javascript:')) next = href;
    });
    if (!next) break;
    let resolved;
    try {
      resolved = new URL(next, current).toString();
    } catch {
      break;
    }
    if (pages.some(p => p.url === resolved)) break; // loop guard
    current = resolved;
  }
  return { pages };
}
