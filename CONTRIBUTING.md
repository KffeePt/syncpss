# Contributing

## Workflow

- Open an issue or draft PR for behavior changes, installer changes, or data-model changes before large edits.
- Keep password-store data and personal secrets out of the public repo.
- Prefer focused PRs with clear before/after behavior.

## Local Development

- Linux/WSL builds:
  `scripts\build.bat` from Windows or `bash scripts/sh/build.sh` from Linux/WSL.
- PR checks build the Linux TUI and the Windows installer helper.
- Shell install scripts should continue to pass `bash -n`.

## Privacy And Security Expectations

- Do not add new plaintext secret storage outside the encrypted `pass` store without explicit maintainer approval.
- Metadata collection defaults are intentionally conservative; new telemetry or host-identifying fields should remain opt-in.
- Installer changes should preserve release-asset verification and avoid introducing raw-branch trust paths.

## Maintainer-Only Release Fingerprint Flow

- Public contributors do not need any maintainer ID.
- The maintainer-side source of truth is `config/maintainer_id.sha256`.
- Maintainer release tooling reads the plaintext maintainer ID from the OS-level `SYNCPSS_MAINTAINER_ID` variable only.
- If `SYNCPSS_MAINTAINER_ID` is missing during `scripts\cd.bat`, the Windows flow now bootstraps it from `config\maintainer_id.sha256`:
  enter the existing maintainer ID to persist it for the current Windows user, or rotate it intentionally.
- Use `scripts\set_fingerprint.bat` on Windows or `bash scripts/sh/set_fingerprint.sh` on Linux/WSL to set, remove, or rotate it.
- Release publishing also requires a usable Windows GPG secret key because release tags are now GPG-signed and the main downloadable release assets get detached `.asc` signatures. On Windows, install or import the signing key through Gpg4win before publishing.
- Runtime fingerprint verification is separate: installers stage `master_fingerprint.sha256` into `~/.syncpss/config/master_fingerprint.sha256`, and the TUI verifies against that local file.
