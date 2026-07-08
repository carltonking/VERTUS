// Google News RSS headlines (no API key). A topical search when given a query, else the top feed.
// Shared by web-flagged cloud routines to ground the LLM in current headlines.

export async function searchHeadlines(query: string, limit = 10): Promise<string[]> {
  const q = query.trim();
  const url = q
    ? `https://news.google.com/rss/search?q=${encodeURIComponent(q)}&hl=en-US&gl=US&ceid=US:en`
    : `https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en`;
  try {
    const res = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0" } });
    if (!res.ok) return [];
    const xml = await res.text();
    const titles = [...xml.matchAll(/<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/g)]
      .map((m) => m[1].trim())
      .filter(Boolean);
    return titles.slice(1, limit + 1); // first <title> is the feed name
  } catch {
    return [];
  }
}
