# Build And Release

## Maintainer Release Fingerprint Flow

Maintainer release verification reads the plaintext maintainer ID from one of
these plaintext maintainer sources:

- the OS-level `SYNCPSS_MAINTAINER_ID` variable
- `%USERPROFILE%\.config\syncpss\maintainer-id.env`
- `%USERPROFILE%\.config\syncpss\release.identity`

The repo-side source of truth is:

- `config/maintainer_id.sha256`
- `config/signing_policy.json`

`config\maintainer_id.sha256` stores only the SHA-256 verifier, not the
plaintext maintainer ID, so the Windows release flow cannot reconstruct the
maintainer ID from that file alone.

If `SYNCPSS_MAINTAINER_ID` is missing during `scripts\cd.bat`, the Windows
release flow auto-loads the first plaintext maintainer file it finds, validates
that the value is exactly 32 alphanumeric characters, checks it against
`config\maintainer_id.sha256`, and then persists it for the current Windows
user. If no plaintext maintainer source exists, the flow fails with a direct
error instead of prompting for manual entry.

Maintainers can manage it directly with:

- `scripts\set_fingerprint.bat`
- `bash scripts/sh/set_fingerprint.sh`

Those helpers can set, remove, or rotate the maintainer ID and keep the repo's
expected maintainer hash aligned with the current value.
On Windows, `scripts\set_fingerprint.bat` now opens the release identity
manager, which also shows the current signing-policy state, lets you choose the
active release signing key from the detected Windows GPG secret keys, rotates
that key into verify-only history when needed, and syncs `git user.signingkey`
for the repo automatically.

## Release Signing Architecture

Official `syncpss` releases use a repo-tracked signing policy at:

- `config/signing_policy.json`

That policy controls:

- the single active OpenPGP release signing fingerprint
- the small verify-only fingerprint set reserved for historical release verification
- the GitHub account expected to publish verified release signatures
- the future Windows Authenticode policy for the installer `.exe`

Recommended maintainer custody model:

1. Keep the OpenPGP primary key offline for certification and recovery only.
2. Import only a dedicated release signing subkey onto the canonical Windows release PC.
3. Keep one encrypted offline backup of that release signing subkey.
4. Rotate the release fingerprint and update `config/signing_policy.json` if the release PC and encrypted backup are both lost.

The release flow enforces the active fingerprint from `config/signing_policy.json`.
It refuses to publish if:

- `gpg.exe` cannot be found
- no secret signing key is visible in the Windows keyring
- the active release fingerprint is missing
- `git user.signingkey` resolves to a different fingerprint
- the signing policy is malformed or still uses the placeholder fingerprint

Historical fingerprints listed under `gpg.verify_only_fingerprints` are for
verification tooling only. They are not allowed to publish new releases.

### Signing readiness helper

Before publishing, verify the Windows release machine with:

- `scripts\cd.bat --signing-readiness`
- `powershell -File scripts\ps1\release.ps1 -SigningReadiness`

That helper prints:

- the resolved `gpg.exe` path
- the detected Windows secret signing fingerprints
- the active policy fingerprint
- the final pass/fail signing readiness status

The same readiness report is available from option `[6]` inside
`scripts\set_fingerprint.bat`, so the maintainer can validate the canonical
release PC without leaving the identity manager.

## Runtime Master Fingerprint

Installers stage the release master fingerprint into:

- `~/.syncpss/config/master_fingerprint.sha256`

The TUI verification flow compares the installed local files against that
staged runtime fingerprint.

## Local build stages

### `scripts/build.bat`

This is the only Windows batch build entrypoint now.

By default it builds the full local release-prep set:

- `bin/syncpss-linux-x86_64`
- `bin/syncpss-linux-x86_64.sha256`
- `bin/install`
- `bin/install.sha256`
- `bin/master_fingerprint.sha256`
- `bin/syncpss-wsl-installer.exe`
- `bin/syncpss-wsl-installer.exe.sha256`
- `bin/installer.sh`
- `bin/installer.sh.sha256`
- `bin/uninstall_syncpss.sh`
- `bin/uninstall_syncpss.sh.sha256`
- `bin/syncpss-icon.svg`
- `bin/syncpss-icon.png`
- `bin/syncpss-icon.ico`

The compile cache/build tree lives under the Windows temp directory, not in the
repo. The repo-local `bin/` folder is the release staging area.

The orchestration lives in
[scripts/ps1/build.ps1](../../../scripts/ps1/build.ps1).

Supported modes:

- `scripts/build.bat`
  Builds everything
- `scripts/build.bat --tui-only`
  Builds only the Linux TUI artifact
- `scripts/build.bat --installer-only`
  Builds only the installer-side artifacts
- `scripts/build.bat --installer-only --skip-linux-installer`
  Builds only the Windows installer `.exe` plus helper scripts

If the selected WSL distro is missing the Linux build toolchain, `build.ps1`
installs it automatically by running `bash scripts/sh/installer.sh --build-deps`
inside the selected distro and then continues the build. That bootstrap installs
only the Linux build toolchain, and it runs only when the tools are actually
missing. The step may prompt for the WSL user's sudo password.

The separate `scripts/ci.bat` flow can be pointed at either the local
artifacts or the GitHub release channel via `--local` or `--release`. Use that
when you need to validate the download/install path rather than the staged
Windows-built binaries. Normal user installs now default to the published
release channel; local asset install paths are maintainer-only override flows.
The public release path can also be pinned to a specific tag with
`SYNCPSS_RELEASE_TAG=vX.Y.Z`.

## Release flow

### Windows release entrypoint

[release.ps1](../../../scripts/ps1/release.ps1)
is the authoritative release script on Windows.

It:

1. validates semver rules
2. checks the current published version
3. optionally stages and commits a dirty worktree
4. runs `build.bat`
5. verifies required assets
6. creates detached ASCII-armored GPG signatures (`.asc`) for the main downloadable release assets
7. creates and locally verifies a GPG-signed Git tag for the release
8. pushes the current branch and signed tag
9. can offer to open a pull request into `main` when the current branch is not `main`
10. creates or overwrites the requested tag/release and marks it as the latest production release

### Release assets

The release flow expects these files in `bin/`:

- `syncpss-linux-x86_64`
- `syncpss-linux-x86_64.sha256`
- `manifest.xml`
- `manifest.xml.sha256`
- `install`
- `install.sha256`
- `master_fingerprint.sha256`
- `syncpss-wsl-installer.exe`
- `syncpss-wsl-installer.exe.sha256`
- `installer.sh`
- `installer.sh.sha256`
- `uninstall_syncpss.sh`
- `uninstall_syncpss.sh.sha256`
- `syncpss-release-binaries.zip`

That runtime fingerprint is still intentional. Signed tags and detached GPG
signatures prove the release origin and downloaded asset authenticity, while
`master_fingerprint.sha256` is still what the installer/TUI use later to verify
the installed local runtime payload.

Detached signatures are generated for the main downloadable assets:

- `syncpss-linux-x86_64.asc`
- `manifest.xml.asc`
- `install.asc`
- `syncpss-wsl-installer.exe.asc`
- `installer.sh.asc`
- `uninstall_syncpss.sh.asc`
- `master_fingerprint.sha256.asc`
- `syncpss-release-binaries.zip.asc`

The checksum sidecars remain for installer/update verification, but they are no
longer given redundant `.sha256.asc` signatures.

That gives you:

- a `Verified` GitHub release tag when the matching public GPG key is registered on GitHub
- downloadable detached signatures for the main release assets

Maintainers can verify locally with:

- `git tag -v vX.Y.Z`
- `gpg --verify bin/<asset>.asc bin/<asset>`

The installer-side release assets stage into `~/.syncpss/helpers/` in WSL. The
Windows installer can now open a WSL terminal and run
`bash ~/.syncpss/helpers/installer.sh` automatically after staging.
Public install and update flows fetch release assets directly from the selected
GitHub release without requiring `gh auth`. GitHub authentication is only
required when the installer needs to inspect or create the user's private
password-store repo.

## CI

[pr-checks.yml](../../.github/workflows/pr-checks.yml) runs the shared validation workflow on pushes, pull requests, and manual dispatch.

The required job names are:

- `linux-checks`
- `windows-installer-check`

GitHub Actions do not publish releases. The authoritative release flow is:

- build locally with `scripts\build.bat`
- validate locally with `scripts\ci.bat`
- publish locally with `scripts\cd.bat`

## Signing prerequisites

Release publishing now requires a usable local GPG release signing subkey.

Recommended maintainer setup:

1. Ensure `gpg` is installed.
2. Update `config/signing_policy.json` so `gpg.active_release_fingerprint` and `gpg.allowed_release_fingerprints` contain the intended release signing fingerprint.
3. Ensure `git config user.signingkey` points at that exact release signing fingerprint, or leave it unset and let the policy choose the active fingerprint.
4. Verify the release machine before publishing:
   `scripts\cd.bat --signing-readiness`
5. Let the release script create the signed tag and detached asset signatures automatically.

On Windows, release publishing now expects the signing key to be available in
the native Windows GPG environment, for example through Gpg4win.

## Windows installer code-signing

`config/signing_policy.json` also reserves policy for Windows Authenticode
signing:

- `windows_codesign.phase`
- `windows_codesign.required`
- `windows_codesign.allowed_thumbprints`
- `windows_codesign.subject_hint`

Phase 1 keeps Authenticode optional. Phase 2 makes it a release requirement for
`bin\syncpss-wsl-installer.exe`. When `windows_codesign.required` is set to
`true`, the release flow and the signing readiness helper both require:

- a built `bin\syncpss-wsl-installer.exe`
- a valid Authenticode signature on that file
- a signer thumbprint listed in `windows_codesign.allowed_thumbprints`

That keeps the released Linux artifacts tied to your local WSL environment
instead of a GitHub-hosted runner, while still letting GitHub validate pushes
and pull requests in the cloud.
