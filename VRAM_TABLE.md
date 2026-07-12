## Estimated VRAM Required for the KV Cache

*Approximate FP16/BF16 KV-cache usage in GiB, assuming a batch size of 1.*

| Model | 2K | 4K | 8K | 16K | 32K | 64K | 128K | 256K* |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Llama 3.2 3B | ~0.11 | ~0.22 | ~0.44 | ~0.88 | ~1.75 | ~3.5 | ~7 | ~14 |
| Llama 3 8B | ~0.13 | ~0.25 | ~0.5 | ~1 | ~2 | ~4 | ~8 | ~16 |
| Qwen 2.5 14B | ~0.19 | ~0.38 | ~0.75 | ~1.5 | ~3 | ~6 | ~12 | ~24 |
| Qwen 2.5 32B | ~0.25 | ~0.5 | ~1 | ~2 | ~4 | ~8 | ~16 | ~32 |
| Llama 3 70B | ~0.31 | ~0.63 | ~1.25 | ~2.5 | ~5 | ~10 | ~20 | ~40 |

### Assumptions and limitations

- Estimates use a 16-bit KV cache—FP16 or BF16—and a batch size of 1.
- Values are calculated from each model’s layer count, number of key-value heads, and attention-head dimension. Parameter count alone does not determine KV-cache size.
- KV-cache usage scales approximately linearly with context length and batch size. For example, a batch size of 2 requires roughly twice as much cache memory.
- Quantizing model weights does not automatically quantize the KV cache. Unless explicitly configured otherwise, a 4-bit model may still use a 16-bit KV cache.
- Runtime block allocation, padding, attention implementation, and memory fragmentation can increase actual VRAM usage.
- These figures cover only the KV cache. Model weights, activations, CUDA buffers, and runtime overhead require additional VRAM.
- A listed context length is a memory projection, not a guarantee that the model or runtime supports it. For example, the original Llama 3 models were configured for an 8K context, while Llama 3.2 and Qwen 2.5 variants support longer contexts.

\*The 256K column is a theoretical memory projection and may exceed the model’s native context limit.

The revised values use the published architecture configurations for [Llama 3 8B](https://huggingface.co/NousResearch/Meta-Llama-3-8B/blob/main/config.json), [Llama 3 70B](https://huggingface.co/NousResearch/Meta-Llama-3-70B/blob/main/config.json), [Qwen 2.5 14B](https://huggingface.co/Qwen/Qwen2.5-14B/tree/main), and [Qwen 2.5 32B](https://huggingface.co/Qwen/Qwen2.5-32B/blob/main/config.json).
