# Installer Flow

## Windows entrypoint

[main.cpp](C:/Users/santi/Documents/GitHub/syncpss/src/installer/win/main.cpp)
builds `syncpss-wsl-installer.exe`.

Its responsibilities are intentionally narrow:

1. Verify or bootstrap Windows-side dependencies such as `git` and `gh`
2. Elevate with UAC when needed
3. Enable WSL when needed
4. If no distro is installed yet, offer Ubuntu or Kali and open a second terminal for first-run Linux user setup
5. Enumerate WSL distros
6. Enumerate Linux user homes under `\\wsl.localhost\<distro>\home`
7. Prepare `%USERPROFILE%\\.syncpss`, including the Windows clipboard helper and staged release metadata
8. Create the Start Menu shortcut that launches the WSL TUI directly
9. Copy `installer.sh` plus staged release assets into the selected `~/.syncpss/helpers/`
10. Optionally open a separate WSL terminal that runs `installer.sh` automatically

## Linux shell setup

[installer.sh](C:/Users/santi/Documents/GitHub/syncpss/scripts/sh/installer.sh)
is the interactive Linux/WSL wizard.

It handles:

1. Runtime dependency installation
2. Optional build dependency installation
3. Optional `gh auth login` for private repo bootstrap
4. Optional `git user.name` and `git user.email`
5. SSH key discovery or generation
6. Clipboard copy of the SSH public key
7. Pinned GitHub host-key verification before SSH bootstrap is trusted
8. Install-health detection with `Install`, `Repair`, `Reinstall/Update`, and `Uninstall`
9. `pass` initialization
10. `~/.password-store` repo bootstrap
11. Initial README, `manifest.xml`, and `.syncpss-store.sha256` creation
12. Initial version tag creation
13. Release-channel download and verification of `install`, `syncpss`, and uninstall assets
14. Download and execution of the Linux privileged finalizer binary

The public bootstrap path is release-first:

1. [install.sh](C:/Users/santi/Documents/GitHub/syncpss/install.sh) downloads the latest published `installer.sh`
2. it verifies `installer.sh.sha256`
3. it executes the verified installer locally

## Linux installer binary

[main_installer.cpp](C:/Users/santi/Documents/GitHub/syncpss/src/installer/linux/main_installer.cpp)
builds the Linux `install` binary.

It is still the final privileged step. It:

1. installs `syncpss` into `/usr/local/bin/syncpss`
2. creates `/usr/local/bin/syncpass`
3. writes `~/.syncpss/config.json`
4. writes `/etc/syncpass/config`

## Why there is no second shell installer

The old split between the tiny bootstrap script and the real WSL setup script was removed.

There is now only:

- [install.sh](C:/Users/santi/Documents/GitHub/syncpss/install.sh)
  a tiny bootstrap that downloads and verifies the published `installer.sh` release asset
- [installer.sh](C:/Users/santi/Documents/GitHub/syncpss/scripts/sh/installer.sh)
  the real Linux/WSL setup wizard
- `install`
  the privileged Linux installer binary

## Uninstall flow

There is a matching uninstall path:

- Windows helper:
  [purge.bat](C:/Users/santi/Documents/GitHub/syncpss/scripts/purge.bat)
- PowerShell selector:
  [purge.ps1](C:/Users/santi/Documents/GitHub/syncpss/scripts/ps1/purge.ps1)
- Linux/WSL uninstall script:
  [uninstall_syncpss.sh](C:/Users/santi/Documents/GitHub/syncpss/scripts/sh/uninstall_syncpss.sh)

The Windows helper copies `uninstall_syncpss.sh` into the selected WSL user's
`~/.syncpss/helpers/` staging area and can launch it there. The Linux script then removes:

- `/usr/local/bin/syncpss`
- `/usr/local/bin/syncpass`
- `/etc/syncpass`
- `~/.syncpss`
- `~/.local/bin/syncpss`
- `~/.local/bin/syncpass`

## Notes and metadata

Legacy plaintext notes can still exist in:

- `~/.syncpss/notes.json`

New notes are stored inside encrypted `pass` entries.

It can also write a lightweight audit trail to:

- `~/.syncpss/metadata.json`

Metadata logging is opt-in and disabled by default.

It can also optionally purge `~/.password-store` and `~/.gnupg`.

## Backup containers

The store now uses two manifest-based encrypted container types:

- `keys`
  A VeraCrypt container that carries only the `.gnupg` backup material.
- `backup`
  A portable store backup format with `manifest.xml`, a store snapshot, `.git`,
  `.gnupg`, and exported JSON data for restore/migration workflows.
