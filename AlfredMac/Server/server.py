import os
import sys
import time
import uuid

import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoTokenizer, pipeline

MODEL_NAME = os.environ.get("MODEL_NAME", "Qwen/Qwen2.5-4B-Instruct")
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))

app = FastAPI(title="Alfred Local Server")


# ---------------------------------------------------------------------------
# Schemas (OpenAI-compatible subset)
# ---------------------------------------------------------------------------

class Message(BaseModel):
    role: str
    content: str


class ChatCompletionRequest(BaseModel):
    model: str | None = None
    messages: list[Message]
    stream: bool = False
    max_tokens: int | None = None
    temperature: float | None = None


# ---------------------------------------------------------------------------
# Model lifecycle
# ---------------------------------------------------------------------------

tokenizer: AutoTokenizer | None = None
model: AutoModelForCausalLM | None = None


def load_model() -> None:
    global tokenizer, model

    print(f"Loading model: {MODEL_NAME}...")
    try:
        tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME, trust_remote_code=True)
        model = AutoModelForCausalLM.from_pretrained(
            MODEL_NAME,
            torch_dtype=torch.float16,
            device_map="auto",
            trust_remote_code=True,
        )
    except Exception as exc:
        print(f"Failed to load model '{MODEL_NAME}': {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"Model '{MODEL_NAME}' loaded successfully.")


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.on_event("startup")
async def startup() -> None:
    load_model()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models() -> dict:
    return {
        "object": "list",
        "data": [
            {"id": MODEL_NAME, "object": "model"}
        ],
    }


@app.post("/v1/chat/completions")
async def chat_completions(body: ChatCompletionRequest) -> dict:
    if tokenizer is None or model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    messages = [{"role": m.role, "content": m.content} for m in body.messages]

    prompt = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )

    pipe = pipeline(
        "text-generation",
        model=model,
        tokenizer=tokenizer,
    )

    max_new = body.max_tokens or 512
    temp = body.temperature or 0.7

    outputs = pipe(
        prompt,
        max_new_tokens=max_new,
        temperature=temp,
        do_sample=True,
        return_full_text=False,
    )

    generated = outputs[0]["generated_text"] if outputs else ""

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": body.model or MODEL_NAME,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": generated},
                "finish_reason": "stop",
            }
        ],
    }


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print(f"Server ready at http://localhost:{PORT}")
    uvicorn.run(app, host=HOST, port=PORT)
