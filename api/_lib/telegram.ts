// Telegram Bot API helpers for the Alfred Lite cloud bot (native fetch, no deps).

const API = (token: string) => `https://api.telegram.org/bot${token}`;

/** Sends a message to a chat, chunked to Telegram's 4096-char limit. */
export async function sendMessage(token: string, chatId: string | number, text: string): Promise<void> {
  for (const chunk of chunked(text)) {
    await fetch(`${API(token)}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text: chunk }),
    }).catch(() => {});
  }
}

/** Resolves a Telegram file_id to its bytes (getFile → file_path → download). */
export async function downloadFile(token: string, fileId: string): Promise<Uint8Array | null> {
  try {
    const meta = await fetch(`${API(token)}/getFile?file_id=${encodeURIComponent(fileId)}`).then((r) => r.json());
    const path = meta?.result?.file_path;
    if (!path) return null;
    const res = await fetch(`https://api.telegram.org/file/bot${token}/${path}`);
    if (!res.ok) return null;
    return new Uint8Array(await res.arrayBuffer());
  } catch {
    return null;
  }
}

/** Largest photo size's file_id from a Telegram message (photos come as an ascending-size array). */
export function largestPhotoId(message: any): string | null {
  const photos = message?.photo;
  if (!Array.isArray(photos) || photos.length === 0) return null;
  return photos[photos.length - 1]?.file_id ?? null;
}

function chunked(text: string, max = 4000): string[] {
  if (!text) return [];
  if (text.length <= max) return [text];
  const out: string[] = [];
  let rest = text;
  while (rest.length > max) {
    const slice = rest.slice(0, max);
    let cut = slice.lastIndexOf("\n");
    if (cut < 0) cut = slice.lastIndexOf(" ");
    if (cut < 0) cut = max;
    out.push(rest.slice(0, cut).trim());
    rest = rest.slice(cut).replace(/^[\n ]+/, "");
  }
  if (rest.trim()) out.push(rest.trim());
  return out;
}
