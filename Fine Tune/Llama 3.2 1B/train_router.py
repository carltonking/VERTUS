#!/usr/bin/env python3
"""
Train Llama 3.2 1B as a 3-way Alfred router.

Expected dataset JSONL rows:
{"prompt": "write a python script...", "route": "coder_model"}
{"prompt": "make a plan for...", "route": "planner_model"}
{"prompt": "what is the capital...", "route": "daily_driver"}

Valid routes: daily_driver, planner_model, coder_model
"""

from __future__ import annotations

import argparse
from pathlib import Path

from datasets import load_dataset
from trl import SFTConfig, SFTTrainer
from unsloth import FastLanguageModel


VALID_ROUTES = {"daily_driver", "planner_model", "coder_model"}
SYSTEM_PROMPT = (
    "You are Alfred Router. Classify the user prompt into exactly one route: "
    "daily_driver, planner_model, or coder_model. Output only the route name."
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="../data/router_train.jsonl")
    parser.add_argument("--output", default="./router_lora_final")
    parser.add_argument("--base-model", default="unsloth/Llama-3.2-1B-Instruct")
    parser.add_argument("--max-seq-length", type=int, default=512)
    parser.add_argument("--epochs", type=float, default=3)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--grad-accum", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    return parser.parse_args()


def format_rows(examples: dict, tokenizer) -> dict:
    texts: list[str] = []
    for prompt, route in zip(examples["prompt"], examples["route"]):
        route = str(route).strip()
        if route not in VALID_ROUTES:
            raise ValueError(f"Invalid route {route!r}; expected one of {sorted(VALID_ROUTES)}")

        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": str(prompt).strip()},
            {"role": "assistant", "content": route},
        ]
        texts.append(tokenizer.apply_chat_template(messages, tokenize=False) + tokenizer.eos_token)
    return {"text": texts}


def main() -> None:
    args = parse_args()
    data_path = Path(args.data).expanduser()
    if not data_path.exists():
        raise FileNotFoundError(f"Router dataset not found: {data_path}")

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.base_model,
        max_seq_length=args.max_seq_length,
        load_in_4bit=True,
    )

    model = FastLanguageModel.get_peft_model(
        model,
        r=16,
        lora_alpha=16,
        lora_dropout=0,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    )

    dataset = load_dataset("json", data_files=str(data_path), split="train")
    formatted_dataset = dataset.map(lambda batch: format_rows(batch, tokenizer), batched=True)

    train_args = SFTConfig(
        output_dir="./router_lora_output",
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        num_train_epochs=args.epochs,
        learning_rate=args.learning_rate,
        fp16=True,
        logging_steps=10,
        save_strategy="epoch",
        report_to="none",
        max_length=args.max_seq_length,
        dataset_text_field="text",
    )

    trainer = SFTTrainer(
        model=model,
        processing_class=tokenizer,
        train_dataset=formatted_dataset,
        args=train_args,
    )
    trainer.train()

    model.save_pretrained(args.output)
    tokenizer.save_pretrained(args.output)
    print(f"Training complete. LoRA adapters saved to {args.output}")


if __name__ == "__main__":
    main()
