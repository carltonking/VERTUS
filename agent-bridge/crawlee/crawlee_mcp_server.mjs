#!/usr/bin/env node
// crawlee_mcp_server.mjs — the agentic face of the Crawlee bridge.
//
// An MCP stdio server so Hermes can scrape on demand, without an API key and
// without shipping a scraper into the model's head. Registered in
// ~/.alfred/agent-servers.json via agent-bridge/crawlee-mcp-wrapper.sh.
//
// stdout is the JSON-RPC channel — nothing else may ever write to it (the
// scrape engine is silent; errors surface as `{error}` tool results).
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { log } from 'crawlee';

import { scrapeUrl, extractArticles, searchWeb, scrapePaginated } from './lib/scrape.mjs';

// stdout is the JSON-RPC channel — a single crawlee INFO line would corrupt
// it for Hermes. Errors surface as `{error}` tool results instead.
log.setLevel(log.LEVELS.ERROR);

const MODES = z.enum(['http', 'chromium']);

function textResult(value) {
  return { content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] };
}

const server = new McpServer({ name: 'crawlee', version: '1.0.0' });

server.tool(
  'scrape_website',
  'Fetch a single URL and return its title and readable text. Use HTTP mode by default (fast, no JavaScript); pass mode="chromium" when the page renders its content with JS.',
  {
    url: z.string().url(),
    mode: MODES.optional().default('http'),
    maxChars: z.number().int().min(200).max(50_000).optional().default(20_000),
    retries: z.number().int().min(0).max(5).optional().default(1),
  },
  async ({ url, mode, maxChars, retries }) => {
    const result = await scrapeUrl({ url, mode, maxChars, retries });
    return textResult(result);
  }
);

server.tool(
  'scrape_multiple',
  'Fetch several URLs and return each one\'s title and readable text. Runs with limited concurrency (3 at a time).',
  {
    urls: z.array(z.string().url()).min(1).max(10),
    mode: MODES.optional().default('http'),
    maxChars: z.number().int().min(200).max(50_000).optional().default(10_000),
    retries: z.number().int().min(0).max(5).optional().default(1),
  },
  async ({ urls, mode, maxChars, retries }) => {
    // Indexed writes keep results aligned with the requested order — a caller
    // mapping results[i] back to urls[i] must never get a shuffled array.
    const results = new Array(urls.length);
    let cursor = 0;
    const worker = async () => {
      while (cursor < urls.length) {
        const index = cursor++;
        results[index] = await scrapeUrl({ url: urls[index], mode, maxChars, retries });
      }
    };
    await Promise.all([worker(), worker(), worker()]);
    return textResult(results);
  }
);

server.tool(
  'scrape_with_js',
  'Fetch a URL with a real browser (Playwright/Chromium) so JavaScript-rendered content is included. Slower than HTTP mode; needed for single-page apps and dynamic feeds. Returns title and readable text.',
  {
    url: z.string().url(),
    maxChars: z.number().int().min(200).max(50_000).optional().default(20_000),
    retries: z.number().int().min(0).max(5).optional().default(1),
    timeoutSecs: z.number().int().min(10).max(120).optional().default(40),
  },
  async ({ url, maxChars, retries, timeoutSecs }) => {
    const result = await scrapeUrl({ url, mode: 'chromium', maxChars, retries, timeoutSecs });
    return textResult(result);
  }
);

server.tool(
  'scrape_search',
  'Search the web (DuckDuckGo HTML — no API key) and return top results with titles, URLs and snippets. Optionally narrow to one site, e.g. site="example.com".',
  {
    query: z.string().min(1).max(200),
    site: z.string().optional(),
    maxResults: z.number().int().min(1).max(20).optional().default(10),
  },
  async ({ query, site, maxResults }) => {
    const result = await searchWeb({ query, site, maxResults });
    return textResult(result);
  }
);

server.tool(
  'scrape_paginated',
  'Follow pagination on a listing page (CSS "next" links by default) and return each page\'s readable text, up to maxPages.',
  {
    url: z.string().url(),
    maxPages: z.number().int().min(1).max(10).optional().default(3),
    nextSelector: z.string().optional(),
    mode: MODES.optional().default('http'),
  },
  async ({ url, maxPages, nextSelector, mode }) => {
    const result = await scrapePaginated({ url, maxPages, nextSelector, mode });
    return textResult(result);
  }
);

server.tool(
  'extract_articles',
  'Extract article links from a listing page (headline-sized anchors to real URLs, with snippets). Returns up to maxResults entries.',
  {
    url: z.string().url(),
    mode: MODES.optional().default('http'),
    maxResults: z.number().int().min(1).max(30).optional().default(20),
  },
  async ({ url, mode, maxResults }) => {
    const result = await extractArticles({ url, mode, maxResults });
    return textResult(result);
  }
);

await server.connect(new StdioServerTransport());
