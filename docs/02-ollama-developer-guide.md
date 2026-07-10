# Ollama Developer Guide

> **Document ID:** `ollama-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Official Ollama documentation and `ollama/ollama`; exact official Context7 entry not publicly discoverable

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Purpose and architecture

Ollama is a model runtime and management service for running local or hosted models through a CLI and HTTP API. On Windows, the application normally runs in the user context and exposes a local API at:

```text
http://localhost:11434/api
```

Core components:

```text
CLI / desktop app / API client
            │
            ▼
      Ollama HTTP server
       ├─ model registry
       ├─ model scheduler
       ├─ prompt/template layer
       ├─ inference backend
       └─ local model store
```

The model name is not a sufficient reproducibility identifier. Record the model digest, Ollama version, Modelfile, runtime parameters, and hardware profile.

## 2. Windows installation and verification

The standard installer runs without requiring administrator rights and uses the user profile by default. Model files can consume tens or hundreds of gigabytes.

Verify:

```powershell
ollama --version
ollama list
ollama ps
```

Run a model:

```powershell
ollama run gemma4
```

Confirm the API:

```powershell
Invoke-RestMethod http://localhost:11434/api/tags
```

## 3. Core CLI

```text
ollama run MODEL          Start an interactive model session
ollama pull MODEL         Download or update a model
ollama list               List locally available models
ollama show MODEL         Inspect model metadata and Modelfile
ollama ps                 List loaded/running models
ollama stop MODEL         Unload a model
ollama create NAME -f F   Build a model from a Modelfile
ollama copy SRC DST       Copy or retag a model
ollama rm MODEL           Delete a local model
ollama serve              Run the server explicitly
ollama launch             Configure and launch supported integrations
```

Use `ollama help COMMAND` for the installed version's exact options.

## 4. Environment variables

Common variables include:

- `OLLAMA_HOST`: server bind address. Keep loopback binding unless remote access is required.
- `OLLAMA_MODELS`: alternate model-storage directory.
- runtime and scheduler variables supported by the installed release.

On Windows, quit the tray application before changing environment variables, update user or system variables, then restart Ollama.

Example:

```powershell
[Environment]::SetEnvironmentVariable(
  'OLLAMA_MODELS',
  'D:\OllamaModels',
  'User'
)
```

Do not expose `0.0.0.0:11434` to an untrusted network without authentication, TLS termination, firewall restrictions, and request controls.

## 5. REST API patterns

### Chat

```powershell
$body = @{
  model = 'gemma4'
  messages = @(
    @{ role = 'system'; content = 'You are a precise Android automation planner.' }
    @{ role = 'user'; content = 'Return one JSON action.' }
  )
  stream = $false
} | ConvertTo-Json -Depth 8

Invoke-RestMethod `
  -Method Post `
  -Uri http://localhost:11434/api/chat `
  -ContentType 'application/json' `
  -Body $body
```

### Generate

```powershell
$body = @{
  model = 'gemma4'
  prompt = 'Explain the ADB client-server-daemon architecture.'
  stream = $false
} | ConvertTo-Json

Invoke-RestMethod -Method Post `
  -Uri http://localhost:11434/api/generate `
  -ContentType 'application/json' `
  -Body $body
```

### Embeddings

Use the embedding endpoint with an embedding-capable model. Normalize input batching and record the embedding model digest because vectors from different models are not interchangeable.

### Management endpoints

The API supports operations for listing, showing, pulling, creating, copying, deleting, and inspecting running models. Treat pull/create/delete operations as administrative actions and separate them from ordinary inference permissions.

## 6. Streaming

Streaming endpoints return newline-delimited JSON objects. A client must:

1. read incrementally;
2. parse each complete line;
3. accumulate message or response content;
4. detect the final object;
5. preserve final timing and token statistics;
6. handle cancellation and partial output.

Do not call `ReadToEnd()` for long-running streams if responsive cancellation matters.

## 7. Modelfile

A Modelfile defines a derived model. Main instructions include:

- `FROM` — required base model or local model path;
- `PARAMETER` — runtime defaults such as context or sampling settings;
- `TEMPLATE` — prompt serialization template;
- `SYSTEM` — default system message;
- `ADAPTER` — LoRA or QLoRA adapter;
- `LICENSE` — license metadata;
- `MESSAGE` — seed conversation history;
- `REQUIRES` — minimum Ollama version.

Example:

```dockerfile
FROM gemma4
SYSTEM You are an Android automation planner. Return strict JSON only.
PARAMETER temperature 0.1
PARAMETER num_ctx 32768
```

Build and inspect:

```powershell
ollama create android-planner -f .\Modelfile
ollama show android-planner --modelfile
ollama run android-planner
```

Avoid embedding secrets, user data, or environment-specific absolute paths in a Modelfile.

## 8. Model imports

Ollama can create models from supported local weight formats by referencing a directory or file in `FROM`. After import, test deterministic prompts and compare outputs before replacing a production model.

```dockerfile
FROM D:\models\my-model.gguf
```

```powershell
ollama create my-model -f .\Modelfile
```

## 9. Tool calling and structured output

For agent systems:

- choose a model that supports tool calling reliably;
- send machine-readable tool schemas;
- validate all arguments independently of the model;
- apply allowlists and bounds checks;
- never execute arbitrary shell strings directly from model output;
- use JSON Schema validation and retry invalid outputs with a corrective prompt.

Tool calling grants intent, not authorization. The host policy engine remains responsible for approval.

## 10. Thinking-capable models

Some models separate reasoning into a `thinking` field and final response content. Applications should define a policy for whether to store, display, discard, or redact that field. Do not assume reasoning traces are required for accurate operation, and do not place secrets in prompts simply because the trace is hidden from the UI.

## 11. Context length and memory

Context length increases memory use. Current Ollama documentation describes VRAM-dependent defaults and recommends larger contexts for coding and agent tasks. Select context based on measured need rather than maximum capability.

For an Android agent, reduce token pressure by retaining:

- current goal;
- compact running summary;
- latest screen description;
- active plan and constraints;
- recent actions and outcomes;

Discard repeated screenshots, stale XML trees, and verbose historical observations.

## 12. Performance engineering

Measure:

- model load time;
- prompt evaluation rate;
- generation rate;
- total request latency;
- CPU, RAM, GPU, and VRAM use;
- context size;
- concurrent request behavior;
- model unload/reload frequency.

Optimization sequence:

1. choose an appropriately sized model;
2. verify GPU offload;
3. reduce context and prompt size;
4. use quantization suitable for quality requirements;
5. avoid unnecessary concurrency;
6. keep frequently used models warm when memory allows;
7. separate vision and reasoning models when beneficial.

## 13. Agent integration

Recommended boundary:

```text
Android perception -> normalized state -> Ollama planner
                  -> validated action JSON -> policy engine
                  -> ADB/scrcpy/UIAutomator2 executor
```

The model should never be the only control boundary. Validate package names, coordinates, text length, shell commands, file paths, and destructive operations.

## 14. Troubleshooting

### Server not reachable

```powershell
Get-Process ollama -ErrorAction SilentlyContinue
Test-NetConnection localhost -Port 11434
ollama serve
```

### Model not found

```powershell
ollama list
ollama pull MODEL
```

### Models stored on the wrong drive

Set `OLLAMA_MODELS` at user scope, fully quit Ollama, move or re-pull models, then restart.

### Slow first request

The model may be loading into memory. Compare first-token latency with subsequent requests and inspect `ollama ps`.

### Out of memory

Use a smaller or more aggressively quantized model, reduce context, reduce concurrency, or free GPU/CPU memory.

### Remote client cannot connect

Check `OLLAMA_HOST`, Windows Firewall, network profile, reverse proxy, and whether the server intentionally binds beyond loopback.

## 15. Security checklist

- Keep the API on loopback by default.
- Do not treat local model output as trusted code.
- Separate model-management and inference permissions.
- Scan imported models and verify provenance.
- Record model digests.
- Redact secrets from prompts and logs.
- Rate-limit agent loops.
- Enforce an execution allowlist outside the model.
