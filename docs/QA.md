# QA Guide

This repo treats QA as part of implementation, not a cleanup step after code is "done".

The goal is simple:

- protect installer-critical and recovery-critical flows from unsafe behavior
- make failures deterministic and testable
- keep regressions out of release builds

## Main Entry Point

The preferred local Windows QA entrypoint is:

- `scripts/run_tests.bat`

Useful modes:

- `scripts/run_tests.bat`
  Runs repo structure checks, syntax linting, configure/build validation, and the installer QA harness.
- `scripts/run_tests.bat --static-only`
  Runs structure, lint, and build validation without the scenario harness.
- `scripts/run_tests.bat --lint-only`
  Runs the fastest early-warning checks only.

## Rule Model

This repo uses two rule levels.

### Hard Rules

Hard rules are never worked around. If a change cannot satisfy a hard rule, the change is not ready.

### Soft Rules

Soft rules can be bypassed only within reason, only when really needed, and only when no safer practical option exists. Any bypass should be called out in the PR or handoff notes with:

- what was bypassed
- why it was necessary
- what risk remains
- what follow-up should remove the exception

## Scope Priorities

All QA work should prioritize these surfaces first:

- Windows WSL bootstrap
- Linux installer and uninstaller
- distro and Linux user selection
- GitHub auth, SSH setup, and private repo bootstrap
- VeraCrypt and GPG recovery flows
- final Windows shortcut launch flow

If time is limited, protect those flows before working on broader TUI polish.

## Hard Rules

- Every destructive or privileged action must stay inside the managed boundary.
- No `rm -rf`, `remove_all`, `install`, `chown`, mount cleanup, shortcut cleanup, or similar action may run on an unchecked path.
- Empty paths, root-like paths, unresolved relative paths, control-character paths, and unmanaged Windows-mounted paths must fail closed.
- Installer and uninstaller path checks must go through shared validation helpers instead of one-off logic.
- User input, env overrides, config fields, and command output used for decisions must be validated and normalized before use.
- Single-token fields must reject multiline input.
- Secret or hostile input must never be interpolated into shell snippets unsafely.
- Prefer argv-style process launching in C++ and distinct shell arguments in bash.
- Final installer status must reflect real step outcomes. "Run now" is allowed only on true success.
- Expected failure modes in installer-critical flows must have explicit user-facing outcomes:
  what failed, what was left untouched, whether retry is safe, and what to do next.
- New installer-critical behavior must ship with automated coverage or deterministic failure injection.
- Manual QA is not a substitute for missing automated coverage in installer-critical flows.
- Tests must be safe to run locally and in CI without touching unmanaged user data.
- No raw privileged tool output should leak below the TUI/log frame when the UI is active.

## Soft Rules

- Add focused smoke coverage even when a full scenario harness test is already present.
- Prefer small, composable helpers over large flow-local validation blocks.
- Prefer structured parsing over text scraping whenever the upstream tool supports it.
- Keep failure messages specific and recovery-oriented instead of generic.
- Add abuse tests for new user-controlled fields, even if the field seems low risk.
- Keep test fixtures deterministic and readable over highly clever mocking.
- When manual QA is still useful, write down the exact steps and expected outcomes.
- Extend existing harnesses before inventing a second test mechanism for the same surface.

## Required QA Thinking For Any Change

For every non-trivial change, answer these questions before calling it done:

1. What input controls this behavior?
2. What paths, files, mounts, or privileged actions can it touch?
3. What happens on malformed input, missing dependencies, timeouts, and partial state?
4. What user-visible result appears on failure?
5. What automated test proves the safe path?
6. What automated test proves the unsafe path is rejected?

If those answers are unclear, the change is not ready yet.

## Installer-Critical Expectations

Changes in installer-critical code should usually include:

- `bash -n` coverage for touched shell scripts
- deterministic fake-command coverage for external tools
- at least one failure-path test, not just a success-path test
- validation coverage for malicious or malformed input
- final-summary verification when step status or launch readiness changes

Recommended fake-command targets include:

- `wsl.exe`
- `gh`
- `git`
- `gpg`
- `veracrypt`
- `curl`
- `sudo`
- `mountpoint`
- `cmd.exe`

## Managed Boundary Policy

Anything that deletes, replaces, mounts, unmounts, or rewrites state must honor the managed-path policy.

The installer/uninstaller managed allowlist includes only the known repo-owned targets such as:

- `~/.syncpss`
- `~/.config/syncpss`
- optional `~/.password-store`
- optional `~/.gnupg`
- `/usr/local/bin/syncpss`
- `/usr/local/bin/syncpass`
- `/etc/syncpass`
- `/mnt/keys`
- known Windows shortcut/runtime paths

Anything outside that boundary is unmanaged and must be left untouched.

## Failure Injection Standards

When behavior depends on external tools or system state, tests should simulate:

- command failure
- malformed output
- timeout
- partial success
- inconsistent state between steps
- hostile input through env/config/user selection

Prefer PATH-injected stubs and fixture files over real system mutation.

## Manual QA

Manual QA still matters, but it is a final confidence pass, not the main safety net.

Use manual QA for:

- UX validation
- copy clarity
- TUI redraw behavior
- real integration smoke checks after automated coverage already exists

Do not rely on manual QA alone for:

- destructive path safety
- parsing correctness
- retry/recovery branch coverage
- hostile input handling
- privileged command failure behavior

## Release And PR Checklist

Before merging installer-critical changes, we should normally have:

- passing repo test entrypoints
- passing installer QA harness scenarios relevant to the change
- shell syntax checks for touched scripts
- a note for any soft-rule exception
- clear mention of residual risks if any scenario could not be automated yet

If a hard rule is violated, stop and fix that before merge.
