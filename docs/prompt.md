# Documentation Inventory Task

Using Context7 (and official documentation where appropriate), create a comprehensive documentation inventory for the following technologies:

- OpenClawm
- Ollama
- PowerShell
- Windows CMD
- Android Debug Bridge (ADB)
- Android Virtual Devices (AVD)
- Android SDK Manager
- Android Studio
- QEMU Emulator
- Windows 11
- scrcpy
- scrcpy-mcp
- DroidClaw
- uiautomator2

## Verification Step (do this first)

- For each technology, run a Context7 library search (resolve-library-id or equivalent) **and** a web search to confirm it's a real, publicly documented project and to find its canonical name/repo.
- Some names — **OpenClawm**, **scrcpy-mcp**, and **DroidClaw** in particular — may be niche, private, or misspelled.
- If a technology has no Context7 match and no verifiable official documentation, state that plainly in its section ("No indexed or official documentation found for X") instead of producing a table with invented rows.
- Confirm URLs actually resolve before including them.
- Do not summarize the documentation itself.

## Output Format

Output one Markdown table per technology with these columns:

- Documentation Name
- Source (Official, GitHub, Google, Microsoft, Community, etc.)
- Documentation URL
- Context7 Library ID (if applicable)
- Last Updated
- Documentation Size (pages/files/snippets/sections if available)
- Coverage (API, CLI, Guides, Tutorials, Architecture, Examples, Troubleshooting, Reference, FAQ, etc.)
- Completeness Rating (1–5)
- Notes (strengths, weaknesses, overlap with other docs)

## Column Notes

- **Last Updated / Documentation Size:** Fill in only if the source actually exposes this (Context7 metadata, GitHub last-commit date, docs-site "last modified," etc.). If not verifiable, write "Not available" — don't estimate or guess.
- **Completeness Rating:** An editorial judgment, not sourced data. Use:
  - **5** = comprehensive official reference + guides + API + examples, actively maintained
  - **4** = solid official docs, minor gaps
  - **3** = adequate but partial (e.g., API reference only)
  - **2** = minimal/stub or clearly outdated
  - **1** = fragmentary/unofficial/unverified

## Requirements

- Enumerate all documentation sets available in Context7 for each technology.
- Prefer official documentation over mirrors.
- Include GitHub documentation repositories when indexed.
- Include version-specific documentation when available.
- Do not omit archived or legacy documentation if Context7 indexes it.
- Do not invent entries, URLs, dates, sizes, or IDs for anything you can't verify — state "not found" or "not available" rather than fabricating a plausible-looking answer.
- Sort documentation by completeness (best first).

## End of Each Technology Section

At the end of each technology section, provide:

- Total documentation sets found
- Estimated total documentation size (aggregate only verified sizes; note if the figure is partial)
- Recommended primary documentation
- Recommended supplemental documentation

## Final Output

- Produce the output as pure Markdown.