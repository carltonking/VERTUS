# Alfred Fine-Tuning Plan

This folder trains four specialist models:

- Router: `Llama-3.2-1B-Instruct`, 3-way route classifier.
- Daily Driver: Qwen small general chat model.
- Planner: Qwen large/tool-use model.
- Coder: `Qwen2.5-Coder-7B-Instruct`.

## Reality Check

- Router can train locally with LoRA if memory allows.
- Daily Driver and Coder can train locally on high-memory Apple Silicon or cloud GPU using LoRA/QLoRA.
- Planner at 35B class usually needs cloud GPU, multi-GPU, or very slow CPU/offload training. Prefer LoRA only.
- Public datasets help, but Alfred-specific tool traces matter most for Planner and Coder.

## Router

Do not train the router directly on `DevQuasar/llm_router_dataset-synth` as 3-way data. That dataset is 2-way (`small_llm`, `large_llm`) and has no coder route. Use it only as seed data, then add Alfred-specific `coder_model` and `planner_model` examples.

Dataset format:

```jsonl
{"prompt":"Write a Python script...","route":"coder_model"}
{"prompt":"Schedule this and send email...","route":"planner_model"}
{"prompt":"Explain this topic...","route":"daily_driver"}
```

Run:

```bash
cd "/Users/carltonking/Code/01 - Projects/03 - ALFRED/Fine Tune/Llama 3.2 1B"
cp ../data/router_train.example.jsonl ../data/router_train.jsonl
source ../alfred_env/bin/activate
python train_router.py --data ../data/router_train.jsonl
```

## Daily Driver

Use SFT, not classification. Mix general chat/instruction data:

- `HuggingFaceTB/everyday-conversations-llama3.1-2k`
- `HuggingFaceTB/smoltalk`
- `tatsu-lab/alpaca`

Avoid over-weighting counseling data unless you want the assistant to behave like a support bot. If used, filter crisis/medical content and add refusal/safety examples.

## Planner

Train on tool-call transcripts using your exact Alfred tool schemas. Public data:

- `NousResearch/hermes-function-calling-v1`
- `Agent-Ark/Toucan-1.5M`
- `vonjack/Phi-3.5-mini-instruct-hermes-fc-json`
- `google/mobile-actions`

Best custom row shape:

```json
{
  "messages": [
    {"role": "system", "content": "You are Alfred Planner..."},
    {"role": "user", "content": "Find a free slot next Tuesday and draft an email."},
    {"role": "assistant", "tool_calls": [{"name": "calendar.search", "arguments": {"date": "next Tuesday"}}]},
    {"role": "tool", "name": "calendar.search", "content": "..."},
    {"role": "assistant", "tool_calls": [{"name": "email.draft", "arguments": {"tone": "concise"}}]}
  ]
}
```

## Coder

Start from `Qwen2.5-Coder-7B-Instruct`. Add:

- secure coding examples
- repo-level debugging traces
- Alfred automation scripts
- examples with tests, shell output, and patch diffs

Do not train on random low-quality generated code. It lowers reliability.

## Evaluation

Before using any trained model in Alfred:

- Router: route accuracy and confusion matrix on held-out Alfred prompts.
- Daily Driver: helpfulness, short-answer quality, refusal behavior.
- Planner: exact tool-call JSON validity, tool choice accuracy, multi-step success.
- Coder: unit-test pass rate, patch quality, security lint checks.
