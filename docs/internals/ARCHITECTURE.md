# Architecture

## Overview

`syncpss` is split into two major areas:

1. The main password-manager application
2. The installer pipeline

The application side is the ncurses TUI that manages a standard `pass` store.
The installer side prepares Linux/WSL systems, installs binaries, and writes
the runtime configuration.

## Source layout

### Main application

- [src/main.cpp](../../../src/main.cpp)
- [src/tui/](../../../src/tui)
- [src/store/](../../../src/store)
- [src/git/](../../../src/git)
- [src/ssh/](../../../src/ssh)
- [src/crypto/](../../../src/crypto)
- [src/util/](../../../src/util)

### Installer components

- Linux installer binary:
  [src/installer/linux/main_installer.cpp](../../../src/installer/linux/main_installer.cpp)
- Windows WSL helper:
  [src/installer/win/main.cpp](../../../src/installer/win/main.cpp)
- Linux setup wizard script:
  [scripts/sh/installer.sh](../../../scripts/sh/installer.sh)
- Clipboard lease + Windows helper integration:
  [src/util/clipboard_core.cpp](../../../src/util/clipboard_core.cpp)
- Metadata ledger:
  [src/util/entry_metadata.cpp](../../../src/util/entry_metadata.cpp)

## Binary outputs

The repo produces these user-facing binaries:

- `syncpss`
  The Linux TUI application
- `install`
  The Linux installer binary that performs privileged final setup
- `syncpss-wsl-installer.exe`
  The Windows helper that prepares `%USERPROFILE%\\.syncpss`, stages `installer.sh` and the release assets into the selected WSL user home, and can launch the installer automatically after staging

## TUI data files

- `~/.syncpss/notes.json`
  Legacy plaintext-note migration source only.
- `~/.syncpss/metadata.json`
  Optional audit ledger for creation, modification, deletion, and sync history.
- `%USERPROFILE%\\.syncpss\\clear_syncpss_clipboard.ps1`
  Windows helper used by clipboard lease tasks when the TUI is running through WSL.

New notes live inside encrypted `pass` entries, and metadata logging is disabled by default.

## Current menu structure

The current main TUI menu is organized around:

- View / Search Passwords
- Add Password
- Modify Password
- Delete Password
- Sync
- Backup / Restore
- Manage GPG Keys
- Configuration

`Configuration` now contains both `Homer mode` and `Uninstall`, while
`Manage GPG Keys` includes selecting the active key, generating a new key,
backup/restore, and public-key export.

## Why the installer is split

The installer is intentionally split into stages:

- Windows helper stage:
  keeps Windows-specific WSL discovery and file copy logic out of Linux code
- Linux shell stage:
  handles package managers, GitHub auth, and interactive setup ergonomically
- Linux installer binary stage:
  handles privileged file installation and config writing in a small, auditable program

That split reduces complexity inside any single component and makes it easier to
debug failures by stage.
