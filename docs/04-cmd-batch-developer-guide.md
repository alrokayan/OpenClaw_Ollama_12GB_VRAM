# Windows CMD and Batch Developer Guide

> **Document ID:** `cmd-batch-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** CMD language behavior plus Context7 `/tboy1337/blinter` batch-analysis documentation

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Role of CMD

`cmd.exe` is Windows' legacy command processor and the interpreter for `.bat` and `.cmd` files. It remains important because installers, build tools, Android utilities, and MCP client configurations may invoke commands through `cmd /c`.

Prefer PowerShell for structured automation. Use CMD when compatibility, startup speed, or an existing batch ecosystem requires it.

## 2. Invocation modes

```cmd
cmd /c command     rem run and exit
cmd /k command     rem run and remain open
```

In JSON configuration on Windows, MCP clients sometimes require:

```json
{
  "command": "cmd",
  "args": ["/c", "npx", "-y", "scrcpy-mcp"]
}
```

## 3. Variables and expansion

```cmd
set NAME=value
echo %NAME%
set "SAFE=value with spaces"
```

Use `set "NAME=value"` to avoid accidental trailing spaces.

Inside parenthesized blocks, `%VAR%` is expanded when the block is parsed. Enable delayed expansion for values that change during execution:

```cmd
setlocal EnableDelayedExpansion
set COUNT=0
for %%F in (*.apk) do (
  set /a COUNT+=1
  echo !COUNT!: %%F
)
endlocal
```

Do not use delayed expansion blindly with data containing `!`; exclamation marks may be consumed.

## 4. Positional parameters

```cmd
%0      rem script name
%1      rem first argument
%*      rem all arguments
%~dp0   rem drive and path of the script
%~f1    rem full path of argument 1
```

Reliable script root:

```cmd
set "SCRIPT_DIR=%~dp0"
```

## 5. Quoting

CMD quoting is context-sensitive. General rules:

- quote paths containing spaces;
- place the entire `set` assignment inside quotes;
- avoid nested `cmd /c` layers;
- test special characters `& | < > ^ ( ) % !`;
- pass arguments separately when another API supports arrays.

Example:

```cmd
"C:\Android\platform-tools\adb.exe" -s emulator-5554 shell wm size
```

## 6. Command chaining and exit status

```cmd
command1 && command2   rem command2 only if command1 succeeds
command1 || command2   rem command2 only if command1 fails
command1 & command2    rem always run both
```

Check `%ERRORLEVEL%`:

```cmd
adb devices
if errorlevel 1 (
  echo ADB failed 1>&2
  exit /b 1
)
```

`if errorlevel N` means greater than or equal to `N`; test from highest to lowest when differentiating values.

## 7. Redirection and pipes

```cmd
command >out.log 2>err.log
command >>combined.log 2>&1
command1 | command2
```

When redirecting inside a parenthesized block, escaping may be required. Be careful when a pipeline launches commands in separate `cmd.exe` contexts.

## 8. Control flow

```cmd
if exist "%FILE%" echo Found
if /i "%MODE%"=="debug" echo Debug mode

for %%F in (*.apk) do echo %%~fF
for /f "usebackq delims=" %%L in ("devices.txt") do echo %%L
```

Labels and subroutines:

```cmd
call :HealthCheck
if errorlevel 1 exit /b 1
exit /b 0

:HealthCheck
adb get-state >nul 2>&1
exit /b %ERRORLEVEL%
```

Use `exit /b` inside batch scripts so the parent shell is not terminated.

## 9. Environment isolation

```cmd
setlocal
set "ANDROID_SERIAL=emulator-5554"
adb shell getprop ro.product.model
endlocal
```

`setlocal` prevents environment changes from leaking to the caller.

## 10. ADB and scrcpy examples

```cmd
@echo off
setlocal
set "SERIAL=emulator-5554"

adb -s "%SERIAL%" get-state >nul 2>&1 || (
  echo Device unavailable: %SERIAL% 1>&2
  exit /b 1
)

scrcpy -s "%SERIAL%" --no-audio --max-size=1600
exit /b %ERRORLEVEL%
```

## 11. Common parsing failures

### Variable appears stale in a loop

Use delayed expansion or restructure the loop.

### Path ending in backslash breaks quoting

Normalize paths and avoid constructing quoted command strings manually.

### Parentheses in paths or data

Quote data and minimize use of large parenthesized blocks.

### `%` in generated scripts

Escape a literal percent as `%%` in a batch file.

### Unicode output is corrupted

CMD's code-page behavior is inconsistent across programs. Prefer UTF-8-aware PowerShell for multilingual data. `chcp 65001` helps some tools but is not a universal fix.

## 12. Batch linting with Blinter

The Context7 source for this section is the Blinter project. Typical workflow:

```cmd
python -m pip install blinter
blinter script.cmd
blinter . --recursive --summary
```

Use linting to detect:

- missing delayed expansion setup;
- suspicious infinite loops;
- unsafe or inefficient command patterns;
- line-length and style issues;
- problems across called scripts.

A linter cannot model every CMD parsing edge case. Keep integration tests for real command execution.

## 13. Production guidelines

- Start with `@echo off`.
- Use `setlocal`.
- Quote assignments as `set "NAME=value"`.
- Return explicit exit codes.
- Log stderr separately during diagnostics.
- Avoid destructive wildcard commands.
- Avoid `curl | cmd` installation patterns.
- Prefer PowerShell for JSON, HTTP, complex data, and robust error handling.

## 14. Context7 snapshot

See `context7-raw/cmd-batch-context7-snapshot.md` for the retrieved Blinter reference and batch examples.
