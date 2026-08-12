#!/usr/bin/env python3
"""Alfred voice bridge: full-duplex Moshi-MLX over WebSocket.

The iPhone connects to ws://<mac-lan-ip>:8765 and streams float32 PCM
(mono, 24 kHz) framed at 1920 samples per message. This bridge feeds that
PCM through the same encode -> LmGen.step -> decode pipeline as moshi_mlx
local.py, then streams decoded speech back with identical framing.

Run:  python3 alf_voice_bridge.py [--port 8765]
"""

import argparse
import asyncio
import json
import queue
import time
import typing as tp
from multiprocessing import Process, Queue

import numpy as np
import sentencepiece
import websockets

import rustymimi
from moshi_mlx import models, utils

import huggingface_hub

SAMPLE_RATE = 24000
FRAME = 1920
BYTES_PER_FRAME = FRAME * 4  # float32 mono

HF = "kyutai/moshiko-mlx-q4"


def hf_download(path: str) -> str:
    return huggingface_hub.hf_hub_download(HF, path)


# ---------------------------------------------------------------------------
# Model process (mirrors moshi_mlx.local.server)
# ---------------------------------------------------------------------------


def server_proc(
    client_to_server: Queue,
    server_to_client: Queue,
    printer: tp.Callable[[str, str], None],
    text_q: Queue,
) -> None:
    import mlx.core as mx
    import mlx.nn as nn

    from moshi_mlx import models as md

    import os

    # Loaded once at startup in main(), then reused for every phone connection. Per-connection
    # (re)spawning would make the first frame wait ~40s for weights — a dead silence the phone
    # reads as a failed call.
    tokenizer_file = hf_download("tokenizer_spm_32k_3.model")
    text_tokenizer = sentencepiece.SentencePieceProcessor(tokenizer_file)
    mx.random.seed(299792458)

    printer("INFO", "loading q4 weights")
    lm_config = md.config_v0_1()
    model = md.Lm(lm_config)
    model.set_dtype(mx.bfloat16)
    nn.quantize(model, bits=4, group_size=32)
    model.load_weights(hf_download("model.q4.safetensors"), strict=True)
    printer("INFO", "warmup")
    model.warmup()
    printer("INFO", "model ready")

    def make_gen() -> md.LmGen:
        # A fresh stream state so a new conversation doesn't inherit a previous caller's context.
        return md.LmGen(
            model=model,
            max_steps=8000,
            text_sampler=utils.Sampler(),
            audio_sampler=utils.Sampler(),
            check=False,
        )

    gen = make_gen()
    server_to_client.put(b"start")
    while True:
        data = client_to_server.get()
        if isinstance(data, (bytes, bytearray)) and data == b"reset":
            gen = make_gen()
            server_to_client.put(b"start")
            continue
        data = mx.array(data).transpose(1, 0)[:, :8]
        text_token = gen.step(data)
        tk = text_token[0].item()
        if tk not in (0, 3):
            text = text_tokenizer.id_to_piece(tk).replace("▁", " ")
            text_q.put_nowait(text)
            printer("TOK", text)
        audio_tokens = gen.last_audio_tokens()
        if audio_tokens is not None:
            server_to_client.put_nowait(np.array(audio_tokens).astype(np.uint32))


class PrintWorker:
    """Cheap process-safe logger: model process pushes, a task prints."""

    def __init__(self) -> None:
        self.q: Queue = Queue()

    def __call__(self, kind: str, msg: str) -> None:
        self.q.put_nowait((kind, msg))

    async def drain(self) -> None:
        while True:
            try:
                kind, msg = self.q.get(block=False)
                print(f"[bridge] {kind} {msg}", flush=True)
            except queue.Empty:
                await asyncio.sleep(0.05)


def next_slot(getter: tp.Callable, timeout: float = 15.0):
    """Sample a streaming codec slot until it yields, with a safety bound."""
    t0 = time.time()
    while True:
        d = getter()
        if d is not None:
            return d
        if time.time() - t0 > timeout:
            return None
        time.sleep(0.005)


def next_encoded(tok) -> np.ndarray:
    d = next_slot(tok.get_encoded)
    if d is None:
        raise RuntimeError("codec encode stuck")
    return d


def next_decoded(tok) -> tp.Optional[np.ndarray]:
    return next_slot(tok.get_decoded)


async def handle_phone(websocket, c2s, s2c, text_q, printer) -> None:
    print("[bridge] phone connected (model already live)", flush=True)

    mimi_file = hf_download("tokenizer-e351c8d8-checkpoint125.safetensors")
    tok = rustymimi.StreamTokenizer(mimi_file)

    # Signal a fresh conversation and wait until the model acknowledges, so this connection
    # is guaranteed inside a clean stream before its first frame is fed in.
    c2s.put(b"reset")
    got = await asyncio.get_running_loop().run_in_executor(None, next_slot, s2c.get)
    if got is None:
        await websocket.close()
        return

    # Warmup the codec exactly like moshi_mlx.local.full_warmup
    for i in range(4):
        pcm = np.zeros(FRAME, np.float32)
        tok.encode(pcm)
        next_encoded(tok)
        if i == 0:
            continue
        tok.decode(np.zeros((1, 8), np.uint32))
        next_decoded(tok)

    print("[bridge] pipeline ready - streaming", flush=True)

    in_q: queue.Queue = queue.Queue()
    out_q: queue.Queue = queue.Queue()

    # Counters shared across asyncio tasks (thread-safe enough for telemetry).
    stats = {
        "frames_in": 0,
        "encoded": 0,
        "decoded": 0,
        "frames_out": 0,
        "text_tokens": 0,
    }

    async def status_loop():
        while True:
            await asyncio.sleep(2)
            print(
                f"[bridge] {stats['frames_in']} in | "
                f"{stats['encoded']} enc | {stats['decoded']} dec | "
                f"{stats['frames_out']} out | {stats['text_tokens']} tok",
                flush=True,
            )

    async def recv_pcm():
        buf = bytearray()
        while True:
            data = await websocket.recv()
            if isinstance(data, str):
                continue
            buf += data
            while len(buf) >= BYTES_PER_FRAME:
                frame = bytes(buf[:BYTES_PER_FRAME])
                del buf[:BYTES_PER_FRAME]
                in_q.put_nowait(np.frombuffer(frame, dtype=np.float32).copy())
                stats["frames_in"] += 1

    async def encode():
        while True:
            try:
                pcm = in_q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.002)
                continue
            tok.encode(pcm)
            c2s.put_nowait(next_encoded(tok))
            stats["encoded"] += 1

    async def generate():
        while True:
            data = s2c.get()
            if isinstance(data, (bytes, bytearray)):
                continue
            tok.decode(np.array(data).astype(np.uint32))
            out = next_decoded(tok)
            if out is not None:
                out_q.put_nowait(out)
                stats["decoded"] += 1
            await asyncio.sleep(0)

    async def send_pcm():
        while True:
            try:
                out = out_q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.003)
                continue
            await websocket.send(out.astype(np.float32).tobytes())
            stats["frames_out"] += 1

    async def send_transcript():
        while True:
            try:
                text = text_q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.05)
                continue
            await websocket.send('{"text":' + json.dumps(text) + "}")
            stats["text_tokens"] += 1

    try:
        await asyncio.gather(
            recv_pcm(),
            encode(),
            generate(),
            send_pcm(),
            send_transcript(),
            printer.drain(),
            status_loop(),
        )
    finally:
        print("[bridge] phone disconnected", flush=True)


async def main(port: int) -> None:
    # One model process for the bridge's whole life: the ~40s weight load happens here, at
    # startup, instead of on the phone's first frame.
    c2s: Queue = Queue()
    s2c: Queue = Queue()
    text_q: Queue = Queue()
    printer = PrintWorker()
    proc = Process(target=server_proc, args=(c2s, s2c, printer, text_q))
    proc.daemon = True
    proc.start()

    async def handler(websocket):
        await handle_phone(websocket, c2s, s2c, text_q, printer)

    async with websockets.serve(handler, "0.0.0.0", port, max_size=None):
        print(f"[bridge] listening on ws://0.0.0.0:{port} (kill with Ctrl-C)", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    try:
        asyncio.run(main(args.port))
    except KeyboardInterrupt:
        print("[bridge] bye", flush=True)
