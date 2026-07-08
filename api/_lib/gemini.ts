// Google Gemini helper — chat + multimodal (vision) in one call. Free tier: ~1M TPM, no card.

const MODEL = process.env.GEMINI_MODEL || "gemini-2.5-flash-lite";

/** Text-only completion. */
export function geminiText(system: string, user: string, temperature = 0.5): Promise<string | null> {
  return generate(system, [{ text: user }], temperature);
}

/** Vision: send a prompt + an inline image (base64). Gemini reads the image directly — no OCR step. */
export function geminiVision(
  system: string,
  prompt: string,
  imageBase64: string,
  mimeType = "image/jpeg",
  temperature = 0.3
): Promise<string | null> {
  return generate(system, [{ text: prompt }, { inlineData: { mimeType, data: imageBase64 } }], temperature);
}

/** Watch a YouTube video and answer a question about it. Gemini ingests the URL natively (visual +
 *  audio) — no download/transcription. Needs a video-capable model (flash-lite may not qualify), so this
 *  uses GEMINI_VIDEO_MODEL (default gemini-2.5-flash) rather than the lite chat model. */
export function geminiYouTube(
  system: string,
  prompt: string,
  youtubeUrl: string,
  temperature = 0.4
): Promise<string | null> {
  const model = process.env.GEMINI_VIDEO_MODEL || "gemini-2.5-flash";
  return generate(system, [{ text: prompt }, { fileData: { fileUri: youtubeUrl } }], temperature, model);
}

async function generate(system: string, parts: unknown[], temperature: number, model: string = MODEL): Promise<string | null> {
  const key = process.env.GEMINI_API_KEY;
  if (!key) return null;
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: system ? { parts: [{ text: system }] } : undefined,
        contents: [{ role: "user", parts }],
        generationConfig: { temperature },
      }),
    });
    if (!res.ok) return null;
    const data: any = await res.json();
    const text: string = (data?.candidates?.[0]?.content?.parts ?? [])
      .map((p: any) => p?.text)
      .filter(Boolean)
      .join("");
    return text.trim() || null;
  } catch {
    return null;
  }
}
