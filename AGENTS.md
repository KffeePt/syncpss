# syncpss repository guidance

syncpss is a C++17 terminal password manager with Linux/WSL and Windows installer
flows. Keep changes evidence-based and preserve the release/install contract.

## Boundaries

- Treat `src/tui/` as the interactive application UI and `src/installer/` plus
  `scripts/` as installer/release code with separate review risk.
- Do not change `.github/workflows/`, `CMakeLists.txt`, `manifest.xml`, install
  destinations, staged asset names, or managed-path rules unless the request
  explicitly requires it.
- Keep destructive or privileged filesystem operations behind the existing
  validation helpers and managed-path checks described in `docs/QA.md`.
- Preserve the repository's CRLF style for existing Windows-facing files.

## Verification

- Start with `git status --short --branch`, `git log -1 --oneline`, and targeted
  `rg` searches before editing.
- For UI changes, use the narrowest source file and run at least the static QA
  entrypoint: `python tests/run.py --static-only`.
- Run `git diff --check` and inspect the final diff for accidental CI, packaging,
  installer, or installation-path changes.
- When dependencies permit, run the full test entrypoint and the relevant CMake
  build. Report blocked checks explicitly rather than weakening them.

## Security

- Prefer argv-style process execution in C++ and separate shell arguments in
  scripts. Validate user, environment, config, and command-output data before
  using it for path or release decisions.
- Never expose plaintext passwords or raw privileged tool output in the TUI or
  logs. Keep cryptographic and release-signing behavior within the existing
  helpers and policy files.
