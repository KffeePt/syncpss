# Installer Style And Flow

## Goal

The Windows bootstrap installer and the Linux/WSL `installer.sh` should feel like two parts of one guided setup flow:

- Windows bootstrap handles host readiness, WSL setup, staging, and launch.
- Linux/WSL installer handles identity, private repo setup, GPG, pass, install, and verification assets.

Both installers should optimize for confidence, clarity, and safe recovery.

## Tone

- Direct and friendly.
- Concrete about what happens next.
- Avoid vague wording like "processing" or "working on it" when a clearer action is possible.
- Prefer "your private password-store repo" over generic phrases like "target repo".
- Prefer "Linux user setup" over "first-run setup" when the user is really choosing a distro username/password.

## Flow Principles

### 1. Explain The Boundary

The Windows installer should make it obvious that:

- Windows-side setup prepares WSL, local launcher assets, and staging.
- Linux/WSL completes the actual syncpss install.

The Linux installer should make it obvious that:

- The public `syncpss` repo is the app.
- The private password-store repo is the user's encrypted data repo.

### 2. Use Named Phases

Progress and headers should be grouped into recognizable phases:

- Prepare
- Fetch
- Authenticate
- Secure
- Install
- Verify

### 3. Keep Risk Language Honest

Potentially disruptive actions should say exactly what will happen:

- replace the local password store
- replace the local `~/.gnupg`
- install a WSL distro
- enable Windows WSL features

### 4. Preserve Escape Routes

Interactive screens should always show how to leave:

- `[Esc]` or `[q]` for TUI pages
- clear yes/no defaults in shell and Windows prompts

## Content Rules

### Windows Bootstrap

- Tell the user why admin is needed.
- When WSL is missing, say that Windows features may need enabling and a reboot may be required.
- When no distro exists, clearly recommend Ubuntu or Kali.
- When a second terminal opens, explain that the user should finish Linux username/password setup there and then return.

### Linux / WSL Installer

- Remind the user that passwords live in a private repo they control.
- Default the repo name to `password-store`, unless `SYNCPSS_PRIVATE_REPO_NAME` overrides it.
- Distinguish clearly between:
  - runtime verification assets
  - local backups
  - temporary safety backups

## Backup Language

- Local backups should be described as the manifest-based container flows used by the product, not as generic `.bak` archives.
- The `keys` container carries only `.gnupg` backup material.
- The `backup` container carries the portable store snapshot and migration metadata.
- Temporary overwrite/rebase backups are separate operational safety backups and should not be described as the same thing.

## Notes Language

- Notes are stored inside encrypted `pass` entries.
- Legacy `~/.syncpss/notes.json` is migration input only.
- The UI should continue to explain that notes are encrypted alongside the entry, not written as plaintext runtime files.

## Future UI Guidance

- Prefer one integrated password management screen over many top-level menu items.
- Configuration should stay grouped by intent:
  - Account & Store
  - Security & Recovery
  - Setup & Maintenance
- Help pages should be scrollable and quittable with `q`.
