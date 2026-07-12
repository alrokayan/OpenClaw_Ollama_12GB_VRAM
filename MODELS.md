# MODELS.md -- local model catalog for the "Recommend best model for my VRAM" step

Keep this up to date. The menu step (run.ps1 `Recommend-Model`) reads this table +
detects GPU VRAM, then recommends the strongest model that fits with a usable
context, plus the exact setup to apply.

## How the fit is computed

Total VRAM needed = model weights + KV cache + ~overhead. On a shared desktop,
assume ~3 GB of the card is already used by Windows + apps (measured on this box).

KV cache (per token) scales with `layers x kv_heads x head_dim`:

    KV_bytes ~= 2 (K+V) x layers x kv_heads x head_dim x ctx x bytes_per_elem

- FP16 KV cache: `bytes_per_elem = 2`.
- **q8_0 KV cache: `bytes_per_elem = 1` (HALF)** -- enable with
  `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`. Near-lossless.
- q4_0 KV cache is unreliable in Ollama (mis-loads / CPU spill) -- avoid.

So: recommend the biggest model whose `weights + q8_0-KV(desired ctx) + 3 GB` fits
the card. Prefer a strong model at a solid context over a weak model at a huge one.

## Catalog

Columns: ollama id | params | quant | weights (GB) | max ctx | quality | notes.
`kv @128k q8_0` is the measured/estimated KV-cache size at 128k with q8_0.

| ollama id | params | quant | weights GB | max ctx | kv @128k q8_0 | quality | notes |
|---|---|---|---:|---:|---:|---|---|
| qwen3.5:latest    | 9.7B | Q4_K_M | ~5.6 | 262144 | ~2.8 GB | strong | **verified: 128k @ q8_0 = 100% GPU on 12 GB (razor-thin, ~0.2 GB free)** |
| qwen2.5:14b       | 14B  | Q4_K_M | ~9   | 131072 | ~4 GB   | strong | likely too big for 128k on 12 GB; try 32-64k |
| qwen2.5:7b        | 7B   | Q4_K_M | ~4.7 | 131072 | ~2.2 GB | good   | more headroom than 9.7B; weaker |
| llama3.1:8b       | 8B   | Q4_K_M | ~4.9 | 131072 | ~2.3 GB | good   | strong tool-use |
| llama3.2:3b       | 3B   | Q4_K_M | ~2   | 131072 | ~1.2 GB | ok     | fits 128k easily; weakest reasoning |

(Rows beyond qwen3.5 are estimates -- verify by loading at the target ctx and
checking `ollama ps` for `100% GPU` + `nvidia-smi` free VRAM, like we did.)

## This machine (RTX 4070 Ti, 12 GB) -- current pick

- Model: **qwen3.5:latest**, context **131072 (128k)**.
- Ollama env: `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`.
- OpenClaw: `models.providers.ollama` num_ctx / contextWindow / contextTokens = 131072.
- Caveat: only ~0.2 GB VRAM free at 128k -- keep other GPU apps minimal, or drop
  to ~96k for margin. A base64 tool result still needs the `toolResultMaxChars`
  cap (context size alone does not stop a flood).
