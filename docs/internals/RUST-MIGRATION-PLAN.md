# syncpss Rust migration and agent interface

Date: 2026-10-20. Status: implementation plan; the production runtime is still
C++17. The immediate maintenance delivery repairs and reinstalls that runtime.
Nothing below labels an unimplemented Rust command as available.

## Outcome and compatibility contract

Ship a Rust password manager with one command registry serving the CLI, TUI,
setup wizard and AI clients, including Hermes computer use. Replace the C++ and
large Bash/PowerShell implementation in stages, keeping the existing vault
readable and the existing launch/install paths stable throughout.

Keep these contracts until an explicit future migration is agreed:

- `~/.password-store` and standard pass/GPG encrypted entry compatibility.
- `~/.gnupg`, `~/.ssh/syncpss_ed25519`, existing Git remotes and branches.
- `/usr/local/bin/syncpss`, the `syncpass` alias, `/etc/syncpass`.
- `~/.syncpss`, `~/.config/syncpss`, existing runtime JSON and INI readers.
- Windows `%USERPROFILE%\\.syncpss` launch helpers, the Start Menu shortcut,
  and the selected WSL distro/user.
- Existing release asset names, checksums, detached signatures and master
  fingerprint input order while mixed-version installations exist.
- Startup reaches the menu within three seconds even when an update exists.
- Telemetry stays off by default; retention and rotation continue to apply.

Do not introduce a new vault format, re-encrypt the vault, change GPG keys,
rotate credentials, or reset private Git history as a side effect of installing.
Rust owns orchestration; audited GPG/pass and VeraCrypt executables can remain
backends. Reimplementing cryptography is outside this migration.

## Evidence from the current repository

| Current surface | Migration responsibility |
| --- | --- |
| `src/main.cpp` | Argument parsing, noninteractive output, exit codes |
| `src/store/`, `src/git/`, `src/ssh/`, `src/crypto/` | Typed vault and backend services |
| `src/util/` | Path, process, config, clipboard, logging and release policy |
| `src/tui/` | Terminal frontend over the same services and dispatcher |
| `scripts/sh/installer.sh` | Resumable setup state machine and dependency adapters |
| `src/installer/linux/` | Narrow privileged install transaction |
| `src/installer/win/` and `scripts/ps1/` | Windows/WSL detection, shortcuts, packaging |
| `tests/installer_qa/run.sh` | Existing hostile-input and recovery fixtures |
| `.github/workflows/pr-checks.yml` | Existing Linux and Windows acceptance gates |

The C++ entrypoint previously ignored all arguments. The bootstrap downloaded
only the wizard, although the wizard sources `managed_paths.sh` immediately.
The previous security patch also contained a malformed public-key block. These
are immediate repair work, not work deferred to the rewrite.

## Rust workspace

Create a parallel workspace under `rust/` first. Its development binary is
`syncpss-next`; it does not replace the installed application until acceptance.

```text
rust/
  crates/
    syncpss-core/       domain models, errors, registry, dispatcher, policy
    syncpss-platform/   validated paths, processes, Linux/WSL/Windows adapters
    syncpss-vault/      pass/GPG entries, notes, backups, Git sync
    syncpss-setup/      detection, plan, checkpoints, install transaction
    syncpss-cli/        CLI, JSON and JSONL presentation
    syncpss-tui/        terminal frontend and setup views
    syncpss-agent/      MCP stdio adapter and Hermes configuration export
```

Dependency direction is frontend -> dispatcher/policy -> services -> platform.
The TUI never shells out to its own CLI. MCP never calls screen coordinates to
read a password. The same service operations run behind all transports.

Use `clap` builder definitions from registry metadata, `serde`/`serde_json`,
typed errors, and `zeroize`/secret wrappers. Evaluate Ratatui/crossterm for the
TUI and the official Rust MCP SDK for the transport. Pin reviewed dependency
versions and Cargo.lock at implementation time, record licenses/MSRV, and run
advisory/license checks. Keep native unsafe code confined to reviewed platform
adapters; do not use a crate choice as evidence of security by itself.

## Central command registry

Use a compiled, typed registry, not a mutable JSON file that supplies arbitrary
shell commands. Every descriptor contains:

- Stable ID and schema version; CLI route, aliases and help text.
- Typed input/output schemas, examples and typed handler binding.
- Supported platforms and dependency requirements.
- Read/write/destructive classification; required capabilities and privileges.
- Secret input/output classification and redaction policy.
- Timeout/cancellation behavior, resource lock, idempotency and retry policy.
- Whether planning/dry-run is supported, and its side-effect-free handler.
- Audit event metadata and machine error codes.

One dispatch path validates input, resolves local authority, checks platform and
locks, executes the typed handler, then applies output redaction. Generate CLI
help/completions, registry JSON, JSON Schema, MCP tool descriptors and docs from
the descriptors. Policy enforcement is server-side; MCP annotations are hints.

Registry validation rejects duplicate IDs/routes, missing handlers, missing
schemas and sensitive commands without explicit policy. A command is exported
to AI clients only once it has an implemented handler and acceptance tests.

Initial Rust command contract (planned):

```text
syncpss --help | --version
syncpss tui
syncpss doctor --json
syncpss commands list --json
syncpss commands schema vault.entries.list --json
syncpss setup plan --json
syncpss setup wizard
syncpss setup apply --plan <id>
syncpss install plan | apply | rollback
syncpss update check | apply
syncpss vault list | search | create | edit | remove
syncpss vault copy <entry>
syncpss vault fill <entry> --target <bound-target>
syncpss sync status | pull | push | resolve
syncpss backup create | list | verify | restore
syncpss keys status | import | export
syncpss agent capabilities --json
syncpss agent hermes-config --json
syncpss mcp serve --stdio
```

Machine mode never prompts, paints ANSI/TUI frames, starts a browser, or writes
secrets to stdout. Standard envelopes contain `schema_version`, `request_id`,
`ok`, `data`, and a typed `error` with a safe suggested next action. JSONL progress
uses stderr or an explicit progress stream, keeping stdout valid JSON. Exit
codes: 0 success, 1 operation failed, 2 usage/schema error, 3 authority required,
4 dependency/setup needed, 5 conflict, 6 cancelled, 7 timeout. Unsupported
operations return a clear error rather than falling through into the TUI.

Do not take passwords in argv or environment variables. Human reveal requires
an explicit local terminal operation; secret input uses a protected prompt or
an explicitly selected input file descriptor. Agent transports do not export a
generic reveal/export-secret tool.

## Hermes and computer use

Use MCP over local stdio as the primary Hermes integration, with JSON CLI as a
second adapter for clients that cannot run MCP. Hermes documents `mcp_servers`
with `command` and `args`; confirm the actually installed Hermes client/version
before enabling it. The Windows `hermes.exe` alias and the local Janus Hermes
adapter are not evidence that this MCP client is configured or operational.

Example configuration to export after the Rust MCP server exists:

```yaml
mcp_servers:
  syncpss:
    command: /usr/local/bin/syncpss
    args: [mcp, serve, --stdio]
```

For a Windows-hosted client targeting this installation, export an argv form
using `C:\\Windows\\System32\\wsl.exe`, `-d <distro>`, `-u <linux-user>`,
`-- /usr/local/bin/syncpss mcp serve --stdio`; discover the distro/user instead
of hardcoding them in shipped defaults. Never install into Docker's WSL distro.
Only write Hermes configuration when explicitly configuring that integration;
merge the named entry and preserve unrelated servers and credentials.

Agent discovery returns redacted installation health and capability information.
Entry search returns only locally allowed metadata: even entry names can be
sensitive, so unrestricted vault enumeration is not the default capability.
For login workflows, implement a brokered credential-use operation:

1. Hermes identifies the browser/app and asks to use an allowed credential.
2. syncpss resolves the entry and validates a grant bound to the caller session,
   entry, operation, origin/app identity, selected field, expiry and use count.
3. The local broker checks current focus/origin and delivers the secret through
   an authenticated browser/native adapter directly to that target.
4. Return a receipt (success/denied/stale target), never plaintext. Record only
   redacted operation metadata; destroy/zero secret buffers on all exit paths.

Do not send a password as a computer-use `type(text)` tool argument: those
arguments can enter prompts and transcripts. No system-wide clipboard fallback
without a specifically scoped local choice. A native UIA/browser bridge needs a
target handshake and focus-change protection; if Hermes only accepts plaintext
keystrokes, credential filling remains unavailable until that bridge exists.
Model-generated origins, grants or approval fields cannot authorize themselves.
Treat page content and suggested commands as untrusted data.

Test with synthetic credentials in a fixture login page and assert the secret
never appears in tool arguments/results, logs, screenshots or error messages.
Test target switches, expired/replayed grants, wrong entries, disconnects and
attempts to use the MCP server as a shell or privileged installer.

## One-command installer and smart setup in Rust

The final release contains a Rust installer plus Rust runtime. Minimal shell
and PowerShell download shims are allowed for first launch on machines without
Rust; users do not install Cargo or build dependencies. All wizard decisions,
planning, validation, execution and recovery belong to the Rust setup crate.
The existing `install` and Windows installer asset names remain compatible.

Detection checks OS/architecture, Linux vs WSL, distro/user, existing installation
health, dependency availability, configuration and existing key/vault presence.
Offer install, repair, update or resume based on that evidence. Preserve existing
identity/vault choices and explain missing prerequisites. Do not purge before
updating. Browser auth, PIN entry and sudo are explicit interactive handoffs;
machine mode returns `interaction_required` with a resumable operation ID.

The wizard and CLI share this state machine:

```text
detect -> validate -> plan -> acquire/verify -> prepare -> apply -> verify -> done
                         failure -> checkpoint -> retry or rollback
```

Plans bind release tag, digests/signatures, platform, target user, exact paths,
required privileges and current-state fingerprint. Revalidate state before apply.
Use same-filesystem staging and atomic rename, a per-install lock, durable
checkpoint journal, health checks and rollback of changed application files.
Keep a versioned backup of binaries/helpers/metadata; do not copy raw private
keys into an application update backup. Never journal passwords/tokens.

Signature trust is bundled with the executable/bootstrap and checked against
the signing policy. Do not trust an asset and checksum from the same origin
alone. Handle signing subkeys using their authorized primary certificate;
test real GPG verification and key rotation. Pin one release across all assets;
no mixture of mutable `latest` URLs. Missing signatures fail closed.

Linux privilege is limited to exact system targets. WSL orchestration remains
under the selected Windows/Linux user, with an isolated privileged install step.
Native Windows vault support is a later platform milestone; Windows -> WSL
remains the supported path during compatibility migration.

## Delivery sequence and acceptance gates

| Milestone | Deliverable | Required evidence before progressing |
| --- | --- | --- |
| 0: repair and reinstall | Current C++ runtime, working bootstrap, three-second cap | Real public-key parsing; tamper/missing-helper/exit-code tests; current QA; installed binary hash and PTY startup |
| 1: Rust control surface | Workspace, typed registry, CLI doctor/setup-plan, schema export | Cargo fmt/clippy/tests; CLI and generated-schema consistency; unknown commands and noninteractive failures |
| 2: vault services | Config/path/process adapters, pass/GPG, Git, SSH, notes | C++/Rust fixture parity; read/write synthetic vaults; traversal, symlink, secret-redaction and cancellation tests |
| 3: Rust setup | Plan/apply/resume/repair/rollback for Linux and Windows/WSL | Fresh install/update/interrupted update; wrong-user and hostile-path rejection; repeated apply; rollback; shortcut parity |
| 4: agent interface | MCP transport, capability policy, Hermes config export | Real local Hermes handshake and tools/list/call; revoked/expired capability tests; no secret output |
| 5: credential broker | Origin/app-bound filling through native adapter | Synthetic login end-to-end; target-change/replay protection; transcript and screenshot redaction |
| 6: Rust TUI | All current screens over the dispatcher, setup views | Clipboard lease, sync conflict, GPG/VeraCrypt recovery parity; three-second PTY test; terminal restore on error |
| 7: release cutover | Signed Rust artifacts promoted at existing paths | Linux/Windows build matrix and existing CI green; upgrade and rollback from current installation; release checklist |
| 8: retirement | Remove replaced C++/wizard code and temporary bridges | Every old feature mapped to tested Rust handler; no hidden shell business logic; documented rollback window |

Keep each milestone reviewable and mergeable. Start Rust checks beside existing
CI, then make them required once the workspace exists. Do not remove existing
CMake/installer checks to make a partial port green. Cut over one service at a
time; keep the last working runtime until the replacement meets its gate.

Before cutover, use cargo-deny/audit or an equivalent maintained advisory policy,
cross-platform fmt/clippy/test/build, synthetic-vault integration tests, registry
schema compatibility, MCP conformance, installer fault injection, fuzzing of
paths/config/RPC inputs, and a real rollback exercise. Benchmarks measure startup,
registry discovery and vault-list latency against the current runtime; no
performance claim without measurement.

## First implementation tickets after this plan

1. Create workspace and `syncpss-next doctor/commands/setup plan`; registry is
   authoritative and descriptors only include implemented operations.
2. Port config and validated process/path services with shared fixtures from
   existing QA. Add per-operation timeouts and bounded output collection.
3. Port pass/GPG and Git/SSH services while preserving file formats and identity.
4. Implement the Rust install transaction and setup state machine, then replace
   the wizard views and add signed packaging behind existing asset names.
5. Add MCP/Hermes discovery, capability enforcement and brokered filling.
6. Complete TUI parity, exercise recovery/rollback and promote Rust artifacts.

## References checked for this design

- [Hermes MCP configuration](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/mcp.md)
- [MCP tools and schemas](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
- [clap command parser](https://docs.rs/clap/latest/clap/)
- [zeroize guarantees and limitations](https://docs.rs/zeroize/latest/zeroize/)
