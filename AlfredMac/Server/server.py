import json
import os
import sys
import urllib.request

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse

# ---------------------------------------------------------------------------
# Alfred Local Server — OpenAI-compatible SSE bridge.
#
# Serves the OpenAI wire shape at 8080 (`/v1/chat/completions`) that
# HermesSession's ToolCallingProvider (and AlfrediOS's HermesProvider) consume:
#   data: {"choices":[{"delta":{"content":"..."}}]}
#   data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"...",
#         "function":{"name":"read_file","arguments":"{\"path\":..."}}]}}]}
#   data: [DONE]
#
# Upstream is the already-running local Ollama server (tool-capable models
# like qwen3:4b). The Qwen2.5-4B transformers path needs a multi-GB model
# download; Ollama is resident and speaks the same OpenAI-compatible SSE, so
# the bridge proxies it and keeps the 8080 interface identical.
# ---------------------------------------------------------------------------

HOST = os.environ.get("HOST", "0.0.0.0")


def _default_port() -> int:
    # Honor PORT only when it is a real port. Dev shells commonly export
    # PORT=0 (or empty), which would make uvicorn bind a random port and the
    # 8080 interface would silently vanish.
    raw = os.environ.get("PORT", "")
    try:
        port = int(raw)
        if 1 <= port <= 65535:
            return port
    except (TypeError, ValueError):
        pass
    return 8080


PORT = _default_port()
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
# Any requested model id is served by this local Ollama model.
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3:4b")

app = FastAPI(title="Alfred Local Server (Ollama bridge)")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Tool-call logging
# ---------------------------------------------------------------------------

def make_tool_logger():
    """Returns an SSE-chunk callback that prints `[TOOL] read_file called: …`
    once per read_file call, as soon as its streamed arguments parse."""
    tracked = {}      # tool_call index -> accumulated arguments string
    logged = set()    # indices already logged

    def on_chunk(obj: dict) -> None:
        try:
            choices = obj.get("choices") or []
            delta = (choices[0] or {}).get("delta") or {}
        except Exception:
            return
        for tc in delta.get("tool_calls") or []:
            idx = tc.get("index", 0)
            fn = tc.get("function") or {}
            name = fn.get("name") or ""
            if "read_file" in name:
                tracked.setdefault(idx, "")
            args = fn.get("arguments") or ""
            if args and idx in tracked:
                tracked[idx] += args
            if idx in tracked and idx not in logged:
                try:
                    path = json.loads(tracked[idx]).get("path", "?")
                    print(f"[TOOL] read_file called: {path}", flush=True)
                    logged.add(idx)
                except Exception:
                    pass  # arguments still partial — wait for the next fragment

    return on_chunk


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "upstream": OLLAMA_URL, "model": OLLAMA_MODEL}


@app.get("/v1/models")
async def list_models() -> dict:
    return {"object": "list", "data": [{"id": OLLAMA_MODEL, "object": "model"}]}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    body["model"] = OLLAMA_MODEL  # whatever the client asked for, Ollama serves this
    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        f"{OLLAMA_URL}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    stream = bool(body.get("stream", False))

    def forward():
        log_chunk = make_tool_logger()
        try:
            with urllib.request.urlopen(req, timeout=300) as upstream:
                for raw in upstream:
                    line = raw.decode("utf-8", errors="replace")
                    if line.startswith("data: "):
                        data = line[6:].strip()
                        if data != "[DONE]":
                            try:
                                log_chunk(json.loads(data))
                            except Exception:
                                pass
                    yield line
        except Exception as exc:
            print(f"[server] upstream error: {exc}", file=sys.stderr, flush=True)
            yield f"data: {json.dumps({'error': str(exc)})}\n\n"
            yield "data: [DONE]\n\n"

    if stream:
        return StreamingResponse(
            forward(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    try:
        with urllib.request.urlopen(req, timeout=300) as upstream:
            return JSONResponse(content=json.loads(upstream.read()))
    except Exception as exc:
        return JSONResponse(status_code=502, content={"error": str(exc)})


if __name__ == "__main__":
    import uvicorn

    print(
        f"Server ready at http://localhost:{PORT} "
        f"(bridge -> {OLLAMA_URL}, model {OLLAMA_MODEL})",
        flush=True,
    )
    uvicorn.run(app, host=HOST, port=PORT)
