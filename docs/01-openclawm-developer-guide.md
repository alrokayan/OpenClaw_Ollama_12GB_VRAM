# OpenClawm Developer Guide

> **Document ID:** `openclawm-developer-guide`
> **Updated:** 2026-07-10
> **Status:** Source-complete developer reference
> **OpenClawm source:** `qzc0429/openclawm` commit `9068d3b1a6e9e27761419830af8c1e01113d8de8`

This guide inventories every OpenClawm-owned function, option, argument,
configuration field, workflow input, launcher, and artifact at the pinned
source commit.

> **Bundled payload at that commit:** OpenClaw `2026.4.1` and Node.js `22.22.2`

The thousands of compiled files under
`payload/openclaw-startup/openclaw/` are a vendored payload. They
are deliberately treated as an opaque dependency, not misreported as
OpenClawm functions. OpenClawm installs that payload and forwards runtime
arguments to it; it does not own the OpenClaw command tree or
`openclaw.json` schema.

Primary source links:

- [OpenClawm pinned tree](https://github.com/qzc0429/openclawm/tree/9068d3b1a6e9e27761419830af8c1e01113d8de8)
- [Rust installer source](https://github.com/qzc0429/openclawm/blob/9068d3b1a6e9e27761419830af8c1e01113d8de8/installer/src/main.rs)
- [Packaging script](https://github.com/qzc0429/openclawm/blob/9068d3b1a6e9e27761419830af8c1e01113d8de8/packaging/package.ps1)
- [Runtime preparation script](https://github.com/qzc0429/openclawm/blob/9068d3b1a6e9e27761419830af8c1e01113d8de8/packaging/prepare-universal-runtime.ps1)
- [Web source](https://github.com/qzc0429/openclawm/tree/9068d3b1a6e9e27761419830af8c1e01113d8de8/web)
- [macOS workflow](https://github.com/qzc0429/openclawm/blob/9068d3b1a6e9e27761419830af8c1e01113d8de8/.github/workflows/build-macos-offline.yml)
- [Version-matched OpenClaw 2026.4.1 CLI reference](https://github.com/openclaw/openclaw/blob/v2026.4.1/docs/cli/index.md)

Context7 was checked for both `OpenClawm` and `OpenClaw`.
There is no separate Context7 entry for `qzc0429/openclawm`. The
matching high-reputation runtime entry is
`/openclaw/openclaw/v2026.4.1`, which matches the vendored payload.
Context7 also verified Clap's derived Boolean/default/help behavior. Repository
source remains authoritative for the exact OpenClawm interface.

---

## 1. Scope and ownership boundary

OpenClawm is a thin offline distribution system with five owned layers:

1. a Rust archive installer;
2. a PowerShell runtime-preparation script;
3. a PowerShell multi-target packaging script;
4. a Bun static download server and browser application;
5. a manually dispatched GitHub Actions workflow for macOS packages.

It does not implement OpenClaw models, channels, agents, tools, gateway
configuration, onboarding, credentials, state migration, or model downloads.
Those features belong to the runtime copied into the payload.

The public OpenClawm interfaces are:

- `openclaw-installer` options;
- top-level parameters for the two PowerShell scripts;
- generated installer wrappers and installed runtime launchers;
- `config/ui.toml`;
- `web/public/site.config.json`;
- `web/public/downloads/manifest.json`;
- Bun server `--host` and `--port` arguments;
- the GitHub workflow `version` input.

All Rust, PowerShell, and JavaScript functions are internal implementation
details. They are documented because changes to them alter public behavior.

## 2. Independent version axes

OpenClawm has several unrelated version values. Changing one does not update
the others.

| Version axis | Value at the pinned commit | Controlled by | Effect |
| --- | --- | --- | --- |
| OpenClawm source | `9068d3b1...` | Git commit | Installer and packaging implementation |
| Rust crate | `0.1.0` | `installer/Cargo.toml` | Cargo package metadata only |
| Package label default | `0.1.0` | `package.ps1 -Version` | Inner ZIP, outer archive names, manifest `version` |
| Workflow label default | `1.0.10` | Workflow input | Value passed to `-Version` |
| Vendored OpenClaw | `2026.4.1` | Payload `package.json` | Runtime commands and configuration schema |
| Vendored Node | `22.22.2` | `RUNTIME_SOURCE.txt` | Runtime executables |
| Required Node range | `>=22.14.0` | OpenClaw `package.json` | Declared minimum runtime version |
| Manifest schema | No version field | Packaging code | Consumers infer the current shape |

`package.ps1 -Version 2.0.0` does not change the Rust crate,
OpenClaw, Node, build metadata, manifest schema, or workflow default.

Record all version axes in release notes. The checked-in payload was prepared
on Windows and contains Windows-specific native packages. A Rust installer
cross-compiled for macOS or Linux does not prove that the shared JavaScript
payload works there.

## 3. Repository and generated-file map

```text
openclawm/
|-- installer/
|   |-- Cargo.toml
|   |-- Cargo.lock
|   +-- src/main.rs
|-- packaging/
|   |-- package.ps1
|   +-- prepare-universal-runtime.ps1
|-- payload/openclaw-startup/
|   |-- openclaw/                    # vendored OpenClaw module
|   |-- node/
|   |   |-- windows/node.exe
|   |   |-- linux-x64/node
|   |   |-- macos-arm64/node
|   |   +-- macos-x64/node
|   +-- RUNTIME_SOURCE.txt
|-- config/ui.toml
|-- web/
|   |-- package.json
|   |-- src/server.ts
|   |-- scripts/build.ts
|   +-- public/
|       |-- index.html
|       |-- app.js
|       |-- styles.css
|       |-- site.config.json
|       +-- downloads/manifest.json
+-- .github/workflows/build-macos-offline.yml
```

Generated paths:

```text
dist/
|-- assets/openclaw-runtime-<version>.zip
|-- build/<target>/...
|-- node-cache/...
|-- node-tmp/...                      # temporary
+-- release/openclaw-offline-<target>-v<version>.<zip|tar.gz>

web/public/downloads/
|-- openclaw-offline-<target>-v<version>.<zip|tar.gz>
+-- manifest.json
```

`installer/target/` is Cargo output. Release archives and
intermediate `dist` paths are ignored by Git. Node binaries under
`payload/openclaw-startup/node/**` use Git LFS.

## 4. Prerequisite matrix

| Operation | Required tools and conditions |
| --- | --- |
| Inspect source | Git; Git LFS when payload binaries are required |
| Prepare runtime | Windows PowerShell, `node` on `PATH`, installed OpenClaw module, Windows `node.exe`, `robocopy`, `tar`, network access to `nodejs.org` |
| Package host target | PowerShell with `Compress-Archive`, Rust, Cargo, rustup, installed target, nonempty payload |
| Package non-Windows | Corresponding Rust target and GNU tar with `--mode`; optional `chmod` |
| Serve/build web files | Bun |
| Run macOS workflow | GitHub Actions, LFS content, macOS runner, Homebrew, PowerShell, Rust targets, GNU tar |

The preparation script is Windows-oriented. Its defaults use
`APPDATA` and `ProgramFiles`, and it calls
`robocopy`.

```powershell
$PSVersionTable.PSVersion
node --version
rustc --version
cargo --version
rustup target list --installed
tar --help
bun --version
git lfs version
```

## 5. End-to-end data flow

1. `prepare-universal-runtime.ps1` deletes and rebuilds
   `payload/openclaw-startup`.
2. It copies one installed OpenClaw module and Windows Node executable, then
   downloads three additional Node executables.
3. `package.ps1` compresses that startup directory into one shared
   runtime ZIP.
4. For each Rust target it builds or reuses an installer, then stages the
   installer, the same runtime ZIP, optional UI TOML, and wrapper scripts.
5. It archives the stage, calculates SHA-256, copies the archive to the web
   directory, and records the successful target in the manifest.
6. An outer wrapper starts the Rust installer.
7. The installer extracts the runtime, writes three launchers plus
   `launch.args`, and on Windows attempts a global command shim.
8. A launcher selects a native OpenClaw entry or bundled Node plus
   `openclaw/openclaw.mjs`, then forwards arguments.

There is no automatic onboarding, gateway installation, runtime launch,
uninstall, upgrade transaction, or state migration.

---

## 6. Runtime preparation script

### 6.1 Complete syntax

```powershell
.\packaging\prepare-universal-runtime.ps1 `
  [-ProjectRoot <string>] `
  [-OpenClawModule <string>] `
  [-WindowsNodeExe <string>] `
  [-NodeVersion <string>]
```

There are no positional parameters, switches, parameter sets, validation
attributes, or pipeline-input parameters.

### 6.2 Every top-level parameter

| Parameter | Type | Default | Behavior |
| --- | --- | --- | --- |
| `-ProjectRoot` | `string` | Parent of the `packaging` directory | Root for payload, cache, scratch, and output paths |
| `-OpenClawModule` | `string` | `$env:APPDATA\npm\node_modules\openclaw` | Directory recursively copied into `payload/openclaw-startup/openclaw` |
| `-WindowsNodeExe` | `string` | `$env:ProgramFiles\nodejs\node.exe` | Copied to Windows-specific and legacy generic Node locations |
| `-NodeVersion` | `string` | Empty | Empty runs `node -v` and strips the leading `v`; otherwise used verbatim in URLs |

```powershell
.\packaging\prepare-universal-runtime.ps1 `
  -ProjectRoot C:\src\openclawm `
  -OpenClawModule C:\runtime\openclaw `
  -WindowsNodeExe C:\runtime\node.exe `
  -NodeVersion 22.22.2
```

The script does not verify that `-NodeVersion` satisfies the copied
module's `engines.node` declaration.

### 6.3 Every preparation function

| Function | Arguments | Return/output | Exact role |
| --- | --- | --- | --- |
| `Download-IfMissing` | `Url:string`, `OutFile:string` | No pipeline output | Returns when the cache file exists; otherwise calls `Invoke-WebRequest -Uri <Url> -OutFile <OutFile>` |
| `Extract-NodeFromTarArchive` | `ArchivePath:string`, `OutPath:string` | Writes one executable | Clears output and shared scratch, runs `tar -xf <archive> -C <scratch>`, finds the first `\bin\node` path, and copies it |

Neither helper validates checksums, signatures, size, version, or freshness.

### 6.4 Preparation algorithm and external arguments

The top-level script:

1. derives `NodeVersion` with `node -v` when needed;
2. fails if the module or Windows Node executable is missing;
3. deletes the complete `payload/openclaw-startup` directory;
4. recreates payload, node, and cache directories;
5. copies the module with:

   ```text
   robocopy <OpenClawModule> <openclawTarget> /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
   ```

6. accepts `robocopy` exit codes 0 through 7 and fails on 8 or higher;
7. copies Windows Node to `node/windows/node.exe` and
   `node/node.exe`;
8. downloads and extracts the following files;
9. deletes the scratch directory;
10. writes `RUNTIME_SOURCE.txt`.

| Platform runtime | Download name | Payload destination |
| --- | --- | --- |
| Linux x64 | `node-v<version>-linux-x64.tar.xz` | `node/linux-x64/node` |
| macOS arm64 | `node-v<version>-darwin-arm64.tar.gz` | `node/macos-arm64/node` |
| macOS x64 | `node-v<version>-darwin-x64.tar.gz` | `node/macos-x64/node` |

The base URL is
`https://nodejs.org/dist/v<version>/<archive-name>`.
Windows arm64 and Linux arm64 are not prepared.

### 6.5 Cache, deletion, and provenance behavior

- Cache: `dist/node-cache`.
- Shared extraction scratch: `dist/node-tmp`.
- Existing cache files are trusted without re-download or verification.
- The payload is deleted before downloads are validated; a failure can leave
  an incomplete payload.
- Only the Node executable is copied from each non-Windows archive.
- `RUNTIME_SOURCE.txt` records absolute source-machine paths.
- `Set-Content -Encoding UTF8` has PowerShell-version-dependent BOM
  behavior.

## 7. Packaging script

### 7.1 Complete syntax

```powershell
.\packaging\package.ps1 `
  [-ProjectRoot <string>] `
  [-StartupDir <string>] `
  [-Version <string>] `
  [-Targets <string[]>] `
  [-SkipBuild]
```

There are no positional parameters, parameter sets, wildcard target expansion,
or validation attributes.

### 7.2 Every top-level parameter

| Parameter | Type | Default | Behavior |
| --- | --- | --- | --- |
| `-ProjectRoot` | `string` | Parent of `packaging` | Controls installer, UI, payload, `dist`, and web paths |
| `-StartupDir` | `string` | Empty | Becomes `<ProjectRoot>\payload\openclaw-startup`; must exist and contain a file |
| `-Version` | `string` | `0.1.0` | Inserted verbatim into inner ZIP, outer archive, and manifest |
| `-Targets` | `string[]` | Empty array | Empty derives the `host:` triple from `rustc -vV` |
| `-SkipBuild` | switch | False | Reuses target release binaries |

```powershell
# Host target
.\packaging\package.ps1 -Version 1.0.0

# Multiple targets
.\packaging\package.ps1 `
  -Version 1.0.0 `
  -Targets x86_64-pc-windows-msvc,x86_64-unknown-linux-musl

# Repackage existing binaries
.\packaging\package.ps1 `
  -Version 1.0.1 `
  -Targets x86_64-pc-windows-msvc `
  -SkipBuild
```

`-Version` is not validated as SemVer or sanitized as a filename.

### 7.3 Every packaging function

| Function | Arguments | Return/output | Exact role |
| --- | --- | --- | --- |
| `Write-Utf8NoBomFile` | Mandatory `Path:string` and `Content:string` | Writes file | Uses `UTF8Encoding(false)` for wrapper scripts |
| `Get-GnuTarPath` | None | Path or `$null` | Checks `tar --help` for `--mode`, then Git's `usr\bin\tar.exe` |
| `Compress-ArchiveWithRetry` | Mandatory `SourcePath` and `DestinationPath`; `Retries=4`; `DelaySeconds=2` | Writes ZIP | Calls optimal forced `Compress-Archive` and retries caught failures |

The retry helper is used for the shared runtime ZIP. The final Windows outer
ZIP is compressed directly without retry.

### 7.4 Target selection and build behavior

The script obtains installed targets once with:

```text
rustup target list --installed
```

For each target:

- a string containing `windows` is classified as Windows;
- all other target strings are classified as Unix-like;
- Windows expects `installer.exe`; others expect `installer`;
- without `-SkipBuild`, uninstalled targets are warned and skipped;
- Cargo failures and missing binaries warn and skip that target;
- with `-SkipBuild`, Cargo is skipped but the binary must exist;
- partial success is accepted; zero packages is a terminating error.

The build command is:

```text
cargo build --release --target <target> --manifest-path <ProjectRoot>\installer\Cargo.toml
```

For `x86_64-unknown-linux-musl` only, the script temporarily appends
to `RUSTFLAGS`:

```text
-C linker=rust-lld -C link-self-contained=yes
```

The original value is restored in a `finally` block.

### 7.5 Four-stage packaging pipeline

Stage 1 creates
`dist/assets/openclaw-runtime-<Version>.zip` from every child of
`StartupDir`. The same inner ZIP is used for every target.

Stage 2 builds or reuses
`installer/target/<target>/release/installer[.exe]`.

Stage 3 deletes and recreates `dist/build/<target>` with:

```text
<stage>/
|-- openclaw-installer[.exe]
|-- payload/openclaw-runtime.zip
+-- config/ui.toml                 # only when source file exists
```

Windows adds:

- `install-passive.cmd`;
- `install.ps1`;
- `OpenClaw-OneClick.cmd`.

Non-Windows adds:

- `install-passive.sh`;
- `install.sh`;
- `OpenClaw-OneClick.sh`;
- `OpenClaw-OneClick.command`.

Output names:

```text
dist/release/openclaw-offline-<windows-target>-v<Version>.zip
dist/release/openclaw-offline-<other-target>-v<Version>.tar.gz
```

Non-Windows packaging calls:

```text
tar --force-local --mode=755 -czf <output> -C <stage> .
```

This forces 755 on every archive entry.

Each successful archive is hashed with SHA-256, lowercased, measured, copied
to `web/public/downloads`, and added to the in-memory manifest.
Stale older downloads are not removed.

Stage 4 overwrites the manifest with only current-run successful targets.
Separate Windows and macOS runs do not merge package lists.

### 7.6 Outer bundle wrappers

| Wrapper | Fixed installer arguments | Interaction |
| --- | --- | --- |
| `install-passive.cmd` | `--passive --archive <ZIP>`, then `%*` | Passive |
| `install.ps1` | `--archive <ZIP>`, then `@args` | Interactive by default |
| `OpenClaw-OneClick.cmd` | None; forwards `%*` | No user args means implicit passive |
| `install-passive.sh` | `--passive --archive <ZIP>`, then live args | Passive |
| `install.sh` | `--archive <ZIP>`, then live args | Interactive by default |
| `OpenClaw-OneClick.sh` | None; forwards live args | No user args means implicit passive |
| `OpenClaw-OneClick.command` | Same as one-click shell wrapper | macOS double-click entry |

Wrapper arguments are installer arguments, not OpenClaw runtime arguments,
except when supplied as the value of `--launch-args`.

---

## 8. Rust installer command line

### 8.1 Complete grammar

```text
openclaw-installer[.exe]
  [--archive <PATH>]
  [--ui <PATH>]
  [--install-dir <PATH>]
  [--passive]
  [--reboot]
  [--launch-args <STRING>]
  [-h|--help]
```

The installer has no positional arguments, subcommands, repeatable options,
environment bindings, response files, or authored short aliases other than
Clap's help alias. It has no authored `--version` flag.

### 8.2 Every installer option and argument

| Option | Argument type | Default | Semantics |
| --- | --- | --- | --- |
| `--archive <PATH>` | Required `PathBuf` value | `payload/openclaw-runtime.zip` | Runtime ZIP; resolved against CWD or installer directory and must exist |
| `--ui <PATH>` | Required `PathBuf` value | `config/ui.toml` | TOML file; missing file uses compiled defaults |
| `--install-dir <PATH>` | Required optional `PathBuf` value | OS local-data path | Destination; relative value remains relative to process CWD |
| `--passive` | Boolean flag | False | Skips install and reboot confirmations |
| `--reboot` | Boolean flag | False | Requests OS reboot after successful install |
| `--launch-args <STRING>` | Required string; hyphen-leading value allowed | Empty | Persists whitespace-split OpenClaw defaults |
| `-h`, `--help` | No value | N/A | Prints generated help |

Clap 4.5 supplies help automatically. The source omits Clap's
`version` command attribute, so Cargo version `0.1.0` is
not exposed as an installer flag.

```powershell
# No arguments also means passive
.\openclaw-installer.exe

# Explicit interactive install
.\openclaw-installer.exe `
  --archive .\payload\openclaw-runtime.zip `
  --install-dir C:\Tools\OpenClaw

# Passive install with safe global runtime defaults
.\openclaw-installer.exe `
  --archive .\payload\openclaw-runtime.zip `
  --passive `
  --launch-args "--profile offline --no-color"

# Passive install followed by unprompted reboot
.\openclaw-installer.exe --passive --reboot
```

Do not use the old example `--launch-args "--mode quick"`.
OpenClaw 2026.4.1 does not define `--mode` as a root option.
Command-specific options belong after their command at runtime invocation.

### 8.3 No-argument and passive-mode matrix

The installer computes:

```text
effective_passive = --passive OR process_received_no_arguments
```

| Invocation | Effective passive | Install prompt | Reboot prompt |
| --- | --- | --- | --- |
| No arguments | Yes | Never | No reboot requested |
| Only `--reboot` | No | Controlled by TOML | Yes |
| `--passive` | Yes | Never | No reboot requested |
| `--passive --reboot` | Yes | Never | Never; reboot is sent |
| Any value option without `--passive` | No | Controlled by TOML | Yes when requested |

Double-clicking a no-argument one-click wrapper therefore bypasses
`confirm_before_install = true`. Passing any option changes that
behavior unless `--passive` is also supplied.

### 8.4 Input path resolution

`--archive` and `--ui` use this precedence:

1. absolute path;
2. existing path relative to current working directory;
3. existing path relative to the installer executable directory;
4. original unresolved path.

A missing UI file produces compiled defaults. A missing archive terminates
after any interactive confirmation. `--install-dir` does not use
this resolver.

### 8.5 Default installation directory

The installer asks the Rust `dirs` crate for the local data
directory, then appends `OpenClaw` on Windows or
`openclaw` elsewhere.

| OS | Typical default |
| --- | --- |
| Windows | `%LOCALAPPDATA%\OpenClaw` |
| Linux | `$XDG_DATA_HOME/openclaw` or `~/.local/share/openclaw` |
| macOS | `~/Library/Application Support/openclaw` |

If local data cannot be resolved, fallback is
`<current-working-directory>/openclaw`.

### 8.6 Installation sequence and errors

The installer:

1. parses options;
2. resolves archive and UI paths;
3. loads UI configuration or defaults;
4. prints name, welcome, destination, and archive;
5. optionally asks `Continue installation? [y/N]`;
6. accepts only case-insensitive `y` or `yes`;
7. checks that the archive exists;
8. creates the destination;
9. extracts the ZIP;
10. writes launchers and `launch.args`;
11. attempts the Windows shim, treating failure as a warning;
12. prints success and default launcher;
13. optionally handles reboot.

Most errors propagate through `anyhow::Result` and terminate
nonzero. User cancellation returns success. An unsupported reboot platform
prints a message and returns success.

## 9. Rust type and function reference

### 9.1 Types

| Type | Fields | Role |
| --- | --- | --- |
| `Cli` | `archive:PathBuf`, `ui:PathBuf`, `install_dir:Option<PathBuf>`, `passive:bool`, `reboot:bool`, `launch_args:String` | Complete Clap model |
| `UiConfig` | `app_name:String`, `welcome:String`, `success:String`, `confirm_before_install:bool` | TOML plus defaults |

### 9.2 Every Rust function and local closure

| Function or closure | Signature/arguments | Result | Behavior |
| --- | --- | --- | --- |
| `UiConfig::default` | `()` | `UiConfig` | Four compiled UI defaults |
| `main` | `()` | `Result<()>` | Orchestrates the complete install |
| `resolve_input_path` | `path:&Path`, `exe_dir:Option<&Path>` | `PathBuf` | Applies path precedence |
| `load_ui_config` | `path:&Path` | `Result<UiConfig>` | Missing file defaults; present file is TOML-deserialized |
| `default_install_dir` | `()` | `PathBuf` | Selects local-data path, then CWD fallback |
| `confirm` | `prompt:&str` | `Result<bool>` | Flushes, reads one line, accepts `y` or `yes` |
| `extract_archive` | `archive_path:&Path`, `install_dir:&Path` | `Result<()>` | Opens ZIP, validates enclosed paths, creates and copies entries |
| `generate_launchers` | `install_dir:&Path`, `launch_args:&str` | `Result<()>` | Writes argument file and three launchers; chmods Unix candidates |
| `set_exec_if_exists` | Local closure taking `relative:&str` | `Result<()>` | Chmods an existing Unix candidate to 0755 |
| `write_launch_args` | `path:&Path`, `args:&str` | `Result<()>` | Splits whitespace and writes one token per line |
| `windows_ps1_script` | `()` | Static string | PowerShell launcher source |
| `windows_cmd_script` | `()` | Static string | CMD launcher source |
| `unix_sh_script` | `()` | Static string | POSIX launcher source |
| `default_launcher_name` | `()` | Static string | PowerShell on Windows; shell elsewhere |
| `try_create_global_command_shim` | `install_dir:&Path` | `Result<()>` | Writes Windows roaming npm shim; otherwise no-op |
| `trigger_reboot` | `passive:bool` | `Result<()>` | Optionally confirms and invokes OS reboot |

There are no exported Rust library functions, public modules, traits, enums,
installer subcommands, or callback APIs.

### 9.3 Archive extraction properties

Implemented:

- `ZipArchive` reads Deflate-capable ZIPs;
- `enclosed_name()` rejects escaping paths;
- directory and parent entries are created;
- same-path files are overwritten;
- ZIP Unix modes are restored on Unix.

Not implemented:

- archive hash or signature verification;
- clearing stale install files;
- staging plus atomic replacement;
- rollback;
- free-space preflight;
- decompression-size limits;
- upgrade/version comparison;
- uninstall metadata.

An overlay reinstall can leave stale files.

### 9.4 Reboot commands

| OS | Command | Notes |
| --- | --- | --- |
| Windows | `shutdown /r /t 8` | Eight-second delay |
| Linux | `sh -c "systemctl reboot \|\| reboot"` | Shell fallback |
| macOS | `sh -c "shutdown -r +0"` | Immediate request |
| Other | None | Logs unsupported and succeeds |

Passive reboot is unprompted.

## 10. Installed runtime launchers

Every installation writes:

- `launch.args`;
- `run-openclaw.ps1`;
- `run-openclaw.cmd`;
- `run-openclaw.sh`.

### 10.1 Persistent argument file

`--launch-args` is one string, but
`write_launch_args` uses plain `split_whitespace()`.

```text
Input: --profile offline --log-level info

File:
--profile
offline
--log-level
info
```

Quotes and escapes are not parsed. Values containing spaces cannot be
represented portably. CMD and POSIX launchers later rebuild an unquoted
default-argument string, adding another word-splitting boundary.

Use persistent defaults only for whitespace-free root flags. Pass complex or
command-specific values at invocation time.

### 10.2 Runtime argument order

```text
<runtime entry> <tokens from launch.args> <caller arguments>
```

Whether a later duplicate option wins belongs to OpenClaw.

### 10.3 Native entry search order

| Launcher | Candidate order |
| --- | --- |
| PowerShell/CMD | `openclaw.exe`, `bin\openclaw.exe`, `openclaw\openclaw.exe` |
| POSIX shell | `openclaw`, `bin/openclaw`, `openclaw/openclaw`; executable files only |

Native entries win over Node plus `openclaw.mjs`.

### 10.4 Node fallback

Windows:

1. `node/windows/node.exe`;
2. `node/node.exe`;
3. `openclaw/openclaw.mjs`.

POSIX:

| OS/architecture | Bundled candidate |
| --- | --- |
| Linux `x86_64` or `amd64` | `node/linux-x64/node` |
| Darwin `arm64` or `aarch64` | `node/macos-arm64/node` |
| Darwin `x86_64` | `node/macos-x64/node` |
| Other, when executable | `node/node` |

POSIX finally tries `node` from `PATH`. Failure to find a
native entry or Node plus `openclaw.mjs` returns status 1.

### 10.5 Exit status and live arguments

- PowerShell and CMD return the payload exit status.
- POSIX uses `exec`.
- PowerShell forwards `@args` as an array.
- CMD forwards `%*`.
- POSIX forwards live arguments with shell-preserved boundaries.

### 10.6 Windows global shim

The installer creates or overwrites:

```text
%APPDATA%\npm\openclaw.cmd
```

It quotes the installed `run-openclaw.cmd` and forwards
`%*`. Failure is a warning. The installer does not add the npm
directory to `PATH@@ and creates no Unix symlink.

### 10.7 Discover the bundled runtime interface

```powershell
.\run-openclaw.ps1 --version
.\run-openclaw.ps1 --help
.\run-openclaw.ps1 <command> --help
```

OpenClawm forwards but does not define runtime commands. The payload's own
help is authoritative, especially for plugin-added commands. Sensible
persistent defaults include version-supported root flags such as
`--profile <name>` and `--no-color`.

---

## 11. Installer UI configuration

### 11.1 Complete schema

`config/ui.toml` accepts the fields represented by
`UiConfig`:

| Field | Type | Compiled default | Use |
| --- | --- | --- | --- |
| `app_name` | string | `OpenClaw` | Banner name |
| `welcome` | string | `Welcome to OpenClaw offline installer.` | Intro line |
| `success` | string | `Installation completed.` | Completion line |
| `confirm_before_install` | boolean | `true` | Confirmation when effective passive is false |

```toml
app_name = "OpenClaw"
welcome = "OpenClaw offline installer"
success = "OpenClaw installation completed."
confirm_before_install = true
```

Behavior:

- missing file -> all compiled defaults;
- partial file -> missing fields use per-field defaults;
- invalid TOML or wrong type -> terminating error;
- unknown fields are ignored by the current Serde definition;
- empty strings are accepted;
- no localization selector or schema version exists;
- confirmation cannot override implicit passive mode.

## 12. Actual manifest contract

Fields proposed in the old guide, including `schemaVersion`,
`releaseVersion`, `artifacts`, `filename`,
`os`, `arch`, and `signature`, are not
implemented.

### 12.1 Complete producer schema

```json
{
  "app": "openclaw",
  "version": "1.0.0",
  "generated_at": "2026-07-10T12:34:56",
  "packages": [
    {
      "target": "x86_64-pc-windows-msvc",
      "file": "openclaw-offline-x86_64-pc-windows-msvc-v1.0.0.zip",
      "sha256": "lowercase-hex-digest",
      "size": 123456789
    }
  ]
}
```

### 12.2 Every root field

| Field | Type | Producer | Browser behavior |
| --- | --- | --- | --- |
| `app` | string | Constant `openclaw` | Ignored |
| `version` | string | Exact `-Version` | Ignored |
| `generated_at` | string | Local `Get-Date` format `s`; no zone | Ignored |
| `packages` | array | Current-run successful targets | Used if array, else empty |

### 12.3 Every package field

| Field | Type | Meaning |
| --- | --- | --- |
| `target` | string | Rust target triple |
| `file` | string | Relative download filename |
| `sha256` | string | Lowercase full SHA-256 |
| `size` | integer | Archive byte length |

The web page displays only 12 digest characters. Neither browser nor installer
verifies the digest.

### 12.4 Producer and fallback differences

`package.ps1` overwrites the manifest, includes only current-run
successes, emits local time without offset, and uses
`Set-Content -Encoding UTF8`.

`web/scripts/build.ts` creates a fallback only when the file has
zero size:

- `app: "openclaw"`;
- `version: "0.0.0"`;
- UTC ISO timestamp;
- empty `packages`.

It does not validate a nonempty manifest.

## 13. Bun web server

### 13.1 Package scripts

| Command | Expansion |
| --- | --- |
| `bun run dev` | `bun run src/server.ts` |
| `bun run serve` | `bun run src/server.ts` |
| `bun run build` | `bun run scripts/build.ts` |

`dev` and `serve` are identical. `build` only
ensures the downloads directory and fallback manifest.

### 13.2 Complete server syntax

```powershell
bun run dev -- --host 127.0.0.1 --port 8787
```

| Option | Value | Default | Parser behavior |
| --- | --- | --- | --- |
| `--host <string>` | Next token | `0.0.0.0` | First exact match in `Bun.argv` |
| `--port <string>` | Next token converted with `Number()` | `8787` | Bun validates/rejects resulting port |

There are no short aliases, `--name=value` support, help, validation
layer, TLS arguments, document-root argument, authentication, or log option.
Unknown tokens are ignored. A missing value can consume the next option token.

Default `0.0.0.0` exposes every interface. Use
`127.0.0.1` for local testing.

### 13.3 Every server function and handler

| Function/handler | Arguments | Return | Behavior |
| --- | --- | --- | --- |
| `readArg` | `name:string`, `fallback:string` | string | Finds `--<name>` and returns next truthy token, else fallback |
| `Bun.serve fetch` | `req:Request` | `Response` | Decodes path, maps root, normalizes under public root, checks prefix/existence, serves file |

Responses:

- `/` -> `/index.html`;
- failed root-prefix check -> 403;
- missing path -> 404;
- existing path -> static file;
- query string does not affect selection.

No explicit cache headers, CSP, TLS, authentication, access log, compression
policy, or directory listing policy is defined.

## 14. Browser application and site configuration

### 14.1 Every browser function

| Function | Arguments | Return | Behavior |
| --- | --- | --- | --- |
| `detectOS` | None | `windows`, `macos`, `linux`, or `unknown` | Checks user-agent platform and text |
| `pickRecommended` | `packages`, `os` | First match or undefined | Finds target containing `windows`, `apple-darwin`, or `linux` |
| `formatSize` | `bytes` | Display string | B below 1024, else KB/MB/GB with one decimal |
| `applySiteConfig` | None | Promise | Fetches JSON, writes text and three CSS variables; keeps defaults on error |
| `render` | None | Promise | Configures page, detects OS, fetches manifest, renders recommendation and list |

The terminal `render().catch(...)` handler writes the error message
to the detected-OS element. It defines no retry action.

### 14.2 Complete `site.config.json` fields

| Field | Expected type | Fallback | Destination |
| --- | --- | --- | --- |
| `kicker` | string | `OpenClaw Offline` | `#site-kicker` |
| `title` | string | Built-in Chinese title | `#site-title` |
| `subtitle` | string | Built-in Chinese subtitle | `#site-subtitle` |
| `accent` | CSS value | `#2b7a57` | `--accent` |
| `backgroundA` | CSS value | `#f7f5ea` | `--bg-a` |
| `backgroundB` | CSS value | `#d7efe0` | `--bg-b` |

JavaScript `value || fallback` semantics apply. Empty, zero, false,
null, and missing values use fallback. There is no schema/type validation.

### 14.3 DOM and CSS contract

Required IDs:

- `site-kicker`;
- `site-title`;
- `site-subtitle`;
- `detected-os`;
- `recommended-link`;
- `package-list`.

Configurable CSS: `--accent`, `--bg-a`,
`--bg-b`. Static CSS: `--card`, `--text`,
`--muted`.

### 14.4 Recommendation limitations

- CPU architecture is ignored.
- First OS-substring match wins.
- Apple Silicon can be recommended to an Intel Mac.
- Unknown systems see no recommendation but retain the full list.
- Manifest filenames become relative links without schema validation.
- Digest is displayed, not enforced.

## 15. Web build module

`web/scripts/build.ts` has no named functions or CLI options. Its
top-level module:

1. resolves and creates `web/public/downloads`;
2. checks `Bun.file(manifestPath).size`;
3. writes the four-field fallback only when size is zero;
4. prints the downloads directory.

It does not validate JSON or fields, compare archives, calculate hashes,
remove stale downloads, bundle, minify, or generate HTML.
