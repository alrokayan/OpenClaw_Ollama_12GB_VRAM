# full-session-reset.ps1
# ---------------------------------------------------------------------------
# Clean-slate reset for the local OpenClaw + Ollama agent. Use when edited
# skills/config seem to have no effect, the agent behaves stale, or a session
# is wedged.
#
# Flow (each transition is gated by a loop-check, nothing is assumed):
#   1. Fire the Ollama stop AND gateway stop immediately -- do NOT wait here.
#   2. While Ollama shuts down, wipe the session store and recreate it.
#   3. Loop-check that Ollama has fully STOPPED, then start it.
#   4. Loop-check that Ollama is UP (API responds -- NOT warming a model).
#   5. Start the gateway.
#
# Why each clear matters:
#   - Restarting the Ollama server drops the loaded model, its KV/prompt cache,
#     and the request queue, and re-applies the tuned env below (env is read
#     ONLY at `ollama serve` start): 32k context (OpenClaw sends no num_ctx, so
#     this server default governs), q8_0 KV cache (halves KV VRAM), flash-attn
#     (required for quantized KV), keep-alive -1 (model stays resident).
#   - Wiping agents\main\sessions\ clears the conversation AND the cached
#     "skills-prompts" -- the usual reason edited skills seem to do nothing.
#
# NOTE: this ends any running AVD (the emulator is a child of the gateway).
# The model is NOT pre-warmed -- it loads on the first real message, so
# `ollama ps` is empty until then. That is expected, not a failure.
# ---------------------------------------------------------------------------

Write-Host '== 1/3  Stopping qwen3.5 & Gateway ==' -ForegroundColor Cyan
ollama stop qwen3.5:latest
openclaw gateway stop

Write-Host '== 2/3  Starting qwen3.5 ==' -ForegroundColor Cyan
while (ollama ps 2>$null | Select-String 'qwen3.5') { Start-Sleep -Milliseconds 300 }
$env:OLLAMA_CONTEXT_LENGTH  = '32768'
$env:OLLAMA_KV_CACHE_TYPE   = 'q8_0'
$env:OLLAMA_FLASH_ATTENTION = '1'
$env:OLLAMA_KEEP_ALIVE      = '-1'
Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardError "$env:LOCALAPPDATA\Ollama\serve-live.log" -RedirectStandardOutput "$env:LOCALAPPDATA\Ollama\serve-out.log"
Invoke-RestMethod 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body '{"model":"qwen3.5:latest","keep_alive":-1}' | Out-Null
while (-not (ollama ps 2>$null | Select-String 'qwen3.5')) { Start-Sleep 1 }

Write-Host '== 3/3  Session recreation & gateway restart ==' -ForegroundColor Cyan
$sessions = Join-Path $HOME '.openclaw\agents\main\sessions'
if (Test-Path $sessions) {
    Remove-Item -Recurse -Force $sessions
}
openclaw doctor --fix

ollama ps
Write-Host ''
Write-Host 'Process complete'
