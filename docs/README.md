# syncpss Docs

This folder documents the current `syncpss` system layout, install flow, and release flow.

GitHub Actions now run the shared validation workflow on pushes and pull requests, and the release flow can offer to open a PR into `main` when you publish from a different branch.

The main trust boundary is:

- public repo: application source and published release assets
- private repo: each user's password store
- local runtime: user-owned config, staged install assets, and optional metadata

## Documents

- [Architecture](architecture.md)
- [Installer Flow](installer-flow.md)
- [Installer Style And Flow](installer-style-and-flow.md)
- [Build And Release](build-and-release.md)
- [Runtime Config And Store](runtime-config-and-store.md)

## Quick map

- Main TUI source: [src/main.cpp](../src/main.cpp)
- TUI implementation: [src/tui](../src/tui)
- Linux installer binary: [src/installer/linux/main_installer.cpp](../src/installer/linux/main_installer.cpp)
- Windows WSL helper: [src/installer/win/main.cpp](../src/installer/win/main.cpp)
- Linux setup script: [scripts/sh/installer.sh](../scripts/sh/installer.sh)
- Windows clipboard helper: [src/util/clipboard_core.cpp](../src/util/clipboard_core.cpp)
- Runtime notes migration source: [~/.syncpss/notes.json](../src/store/store.cpp)
- Audit metadata ledger: [~/.syncpss/metadata.json](../src/util/entry_metadata.cpp)
- Release automation: [scripts/cd.bat](../scripts/cd.bat), [scripts/ps1/release.ps1](../scripts/ps1/release.ps1), [scripts/sh/release.sh](../scripts/sh/release.sh)
- Cloud CI workflow: [.github/workflows/pr-checks.yml](../.github/workflows/pr-checks.yml)

`notes.json` is legacy migration input only; new notes live inside encrypted `pass` entries.

## Current UI features

- `Add Password` supports manual and combo flows.
- `Modify Password` can update only the password, or edit the full structured entry.
- `View / Search Passwords` supports live search, folder navigation, notes viewing, and folder-aware delete.
- Startup splash and clipboard notices are both skippable with any key.
- Clipboard notices auto-return after a short delay instead of blocking indefinitely.
- `Configuration` includes `Homer mode` and `Uninstall`.
- `Manage GPG Keys` now includes selecting a configured key, generating a new key, backup/restore, and public-key export.
