# Pending Work

This file captures work that is intentionally postponed so it stays visible
without affecting the current app flow.

## Share Files Subsystem

Status: postponed

Planned feature:

- Add a LAN-first Share Files area to the existing C++/ncurses `syncpss` app.
- Keep the feature additive and non-blocking so normal password, sync, setup,
  and configuration flows continue to work unchanged.
- Run the main app unprivileged by default.
- Escalate only for explicit, user-confirmed remediation actions.

Privilege model:

- `WSL/Linux`: use `sudo` only for package install, `sshd` config edits, or
  service restart actions that affect the Linux host.
- `Windows`: use elevated PowerShell only for WSL2 host-side networking fixes
  such as `netsh interface portproxy`.
- Never self-escalate at startup.

Implementation notes:

- Keep Share Files isolated under a new `src/share/` module and a dedicated TUI
  controller layer.
- Persist share-specific state separately from the existing password-store and
  runtime config files.
- Make discovery and transfers lazy so missing dependencies do not block the
  rest of the app.
- Prefer `rsync` for transfer progress, with `scp` as a fallback.
- Treat mDNS/UDP discovery, pairing, and SSH remediation as optional layers that
  can fail without breaking unrelated menus.

Suggested order when resuming:

1. Add the share-specific data model and persistence layer.
2. Add WSL and SSH diagnostics without wiring them into startup.
3. Add discovery and pairing as an isolated screen flow.
4. Add transfer flows and progress reporting.
5. Add any privileged remediation helpers last.

Open questions to confirm before implementation:

- Whether discovery should depend on system mDNS support, bundled fallback code,
  or an optional runtime dependency.
- Whether sshd config changes should be patchable by the TUI or only presented
  as copy-paste instructions.
- Whether Share Files should appear as a top-level menu item or stay inside a
  sub-menu.

