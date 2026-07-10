# OpenClawm Developer Guide

> **Document ID:** `openclawm-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** GitHub repository `qzc0429/openclawm`; exact Context7 entry not found

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Project identity

`OpenClawm` is an offline installer-generation project for distributing an OpenClaw runtime. It is not the OpenClaw agent runtime itself. The repository combines:

- a Rust cross-platform installer;
- PowerShell packaging automation;
- a Bun-based download page;
- a payload directory containing the actual OpenClaw runtime;
- configurable installer text and download-page appearance;
- GitHub Actions support for building macOS artifacts.

This distinction matters: changing OpenClawm changes installation and distribution behavior, while changing the payload changes the installed OpenClaw runtime.

## 2. Repository model

```text
openclawm/
├─ installer/                     # Rust installer source
├─ packaging/
│  ├─ package.ps1                 # release packaging entry point
│  └─ prepare-universal-runtime.ps1
├─ payload/openclaw-startup/      # runtime files to install
├─ config/ui.toml                 # installer text and interaction settings
├─ web/                           # Bun download site
│  └─ public/downloads/
│     └─ manifest.json            # generated artifact catalog
└─ .github/workflows/             # remote build workflows
```

Keep the installer, payload, and distribution metadata versioned independently. A useful release identifier is:

```text
installerVersion + payloadVersion + manifestSchemaVersion
```

## 3. Prerequisites

Recommended Windows build host:

- Windows 11 x64
- PowerShell 7
- Git and Git LFS
- Rust stable toolchain with required targets
- Bun
- Node.js runtimes required by the payload-generation script
- code-signing certificate for production releases
- sufficient storage for multiple platform runtimes and archives

Verify:

```powershell
$PSVersionTable.PSVersion
rustc --version
cargo --version
bun --version
git lfs version
```

## 4. Preparing the runtime payload

The payload is copied into each offline package. It must be self-contained for the target operating system or contain a launcher capable of selecting a bundled runtime.

To prepare a universal runtime from a locally installed OpenClaw module:

```powershell
Set-Location C:\src\openclawm
.\packaging\prepare-universal-runtime.ps1
```

Expected categories include:

```text
payload/openclaw-startup/
├─ openclaw/              # application files
├─ node/windows/          # Windows Node runtime
├─ node/linux-x64/        # Linux runtime
├─ node/macos-x64/        # Intel macOS runtime
└─ node/macos-arm64/      # Apple Silicon runtime
```

Before packaging, validate that the payload contains no development secrets, private `.env` files, transient caches, local absolute paths, or machine-specific credentials.

## 5. Building release packages

Basic packaging:

```powershell
.\packaging\package.ps1 -Version 1.0.0
```

Multiple targets:

```powershell
.\packaging\package.ps1 `
  -Version 1.0.0 `
  -Targets x86_64-pc-windows-msvc,x86_64-unknown-linux-musl
```

Important parameters:

- `-Version`: release version embedded in artifacts and manifest metadata.
- `-StartupDir`: alternate payload source.
- `-Targets`: Rust target triples to build.
- `-SkipBuild`: repackage existing binaries without recompiling.

Do not use `-SkipBuild` unless build inputs and binaries are already verified. It can accidentally publish stale code under a new version.

## 6. Cross-compilation constraints

Windows can build the Windows target directly. Linux MUSL may be cross-compiled when the repository's linker setup supports it. Apple targets normally require a macOS runner with Xcode SDK access. Therefore, use GitHub Actions or a controlled macOS build host for:

- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

Store the exact Rust toolchain, target list, lockfile, and runner image in release metadata.

## 7. Installer contract

Representative invocation:

```powershell
.\openclaw-installer.exe `
  --archive .\payload\openclaw-runtime.zip `
  --passive `
  --launch-args '--mode quick'
```

Common options:

- `--archive`: runtime archive path.
- `--install-dir`: destination override.
- `--ui`: alternate TOML UI configuration.
- `--passive`: non-interactive operation.
- `--launch-args`: default arguments written to generated launchers.
- `--reboot`: optional reboot after installation.

Generated launchers typically include PowerShell, CMD, and POSIX shell variants. Preserve argument boundaries when forwarding user input. Never concatenate untrusted input into a shell command string.

## 8. Configuration

Installer copy is controlled through `config/ui.toml`, for example:

```toml
app_name = "OpenClaw"
welcome = "OpenClaw offline installer"
success = "OpenClaw installation completed."
confirm_before_install = true
```

The download site can expose branding and artifact-selection settings in a site configuration file. Keep visual configuration separate from artifact integrity data.

## 9. Manifest design

`manifest.json` should be treated as a public release API. Recommended fields:

```json
{
  "schemaVersion": 1,
  "releaseVersion": "1.0.0",
  "generatedAt": "2026-07-10T12:00:00Z",
  "artifacts": [
    {
      "os": "windows",
      "arch": "x86_64",
      "filename": "OpenClaw-OneClick-1.0.0.exe",
      "sha256": "...",
      "size": 123456789,
      "signature": "..."
    }
  ]
}
```

Validate the manifest against a JSON Schema in CI. Never derive download paths directly from unsanitized query parameters.

## 10. Release pipeline

A production pipeline should perform:

1. clean checkout;
2. dependency lock verification;
3. payload generation;
4. unit and installer integration tests;
5. platform builds;
6. malware scanning;
7. SBOM generation;
8. checksum creation;
9. code signing and notarization where applicable;
10. manifest generation;
11. upload to immutable release storage;
12. smoke installation in disposable VMs.

## 11. Testing matrix

Test at minimum:

- interactive and passive install;
- clean install and upgrade;
- custom install directory;
- paths containing spaces and non-ASCII characters;
- missing or corrupt archive;
- insufficient disk space;
- interrupted installation;
- rollback after partial extraction;
- launch argument forwarding;
- uninstall or manual removal procedure;
- Windows standard-user execution;
- antivirus and SmartScreen behavior.

## 12. Security requirements

- Sign installers and publish SHA-256 checksums.
- Verify the runtime archive before extraction.
- Reject path traversal entries such as `../` in archives.
- Extract into a temporary directory, validate, then atomically move.
- Avoid requiring administrator rights unless the install target requires them.
- Do not bundle API keys or user configuration.
- Pin downloaded runtimes by version and checksum.
- Treat the web manifest as untrusted input inside the installer.

## 13. Troubleshooting

### Rust target is missing

```powershell
rustup target add x86_64-pc-windows-msvc
rustup target add x86_64-unknown-linux-musl
```

### Payload directory is empty

Run the preparation script or copy a complete runtime into `payload/openclaw-startup/`. CI should fail immediately when the directory is empty.

### GitHub Actions cannot access bundled runtimes

Confirm Git LFS is enabled, the payload paths are tracked, and the workflow performs `git lfs pull`.

### macOS build fails on Windows

Move the Apple build to a macOS runner. Apple SDK-dependent targets are not generally reproducible from a Windows-only host.

### Download page serves stale artifacts

Regenerate `manifest.json`, clear deployment caches, and verify the manifest's checksum values against uploaded files.
