# Auto-generated. Brings the LLM provider up before the gateway.
# Ollama tuning -- these env vars are read ONLY when `ollama serve` starts, so set
# them here before launching it:
#   OLLAMA_CONTEXT_LENGTH  32768  = the model's context window (OpenClaw does not
#                                    pass num_ctx, so this server default governs)
#   OLLAMA_KV_CACHE_TYPE   q8_0   = 1-byte KV cache (halves KV VRAM vs FP16)
#   OLLAMA_FLASH_ATTENTION 1      = required for quantized KV cache
#   OLLAMA_KEEP_ALIVE      -1     = keep the model resident (no ~90s cold reloads)
$env:OLLAMA_CONTEXT_LENGTH  = '32768'
$env:OLLAMA_KV_CACHE_TYPE   = 'q8_0'
$env:OLLAMA_FLASH_ATTENTION = '1'
$env:OLLAMA_KEEP_ALIVE      = '-1'
Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardError "$env:LOCALAPPDATA\Ollama\serve-live.log" -RedirectStandardOutput "$env:LOCALAPPDATA\Ollama\serve-out.log"
foreach ($i in 1..30) { try { Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 > $null; break } catch { Start-Sleep 2 } }
openclaw gateway restart
