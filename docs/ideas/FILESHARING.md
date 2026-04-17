# Idea: File Sharing via SCP

Status: idea / not started
Source: `docs/PENDING.md` — "Share Files Subsystem"

---

## Summary

Add a LAN-first file sharing subsystem to the existing C++/ncurses `syncpss`
app using **SCP (Secure Copy Protocol)** as the primary transfer mechanism,
with optional `rsync` support for progress reporting.

The feature must be purely additive. All existing password-manager, sync,
backup, GPG, and configuration flows must continue to work identically
regardless of whether the sharing subsystem is installed, configured, or even
present.

---

## Motivation

`syncpss` already manages SSH keys and remote endpoints for `pass` sync.
Reusing that SSH infrastructure for peer-to-peer file transfers is a natural,
low-dependency extension that avoids introducing a second credentials system.

Key reasons to build this:

- Users who already trust the app's SSH keypairs can share files without a
  third-party service or a browser.
- The LAN-first model avoids cloud relay latency and keeps data off external
  servers.
- SCP is available wherever `openssh-client` is installed, which is a
  pre-existing requirement of the app.

---

## Design Constraints

1. **Non-blocking.** The sharing subsystem must not import at startup. Missing
   `sshd`, missing mDNS daemon, or a malformed share config must never block
   the main menu from loading.
2. **Privilege model preserved.** No automatic `sudo` at launch. Privilege
   escalation only on explicit, user-confirmed remediation steps (e.g. enabling
   `sshd`).
3. **Isolated module.** All new code lives under `src/share/`. No cross-linking
   into existing `src/store/`, `src/ssh/`, or `src/tui/` internals beyond the
   controller hook and the shared SSH utility helpers.
4. **Separate persistence.** Share-specific state (peers, transfer history,
   shared-path config) lives in `~/.syncpss/share_state.json`, never mixed with
   `metadata.json` or the pass store.
5. **SCP first, rsync optional.** SCP is the required transport because it is
   already available. `rsync` is an optional layer added only for progress
   reporting and resume support, loaded at runtime if present.
6. **Fallback-safe discovery.** mDNS peer discovery is optional. The user can
   always enter a hostname or IP manually if discovery is unavailable.

---

## Architecture

```
src/share/
├── share_model.hpp        # SharePeer, ShareEntry, TransferRecord value types
├── share_state.cpp/.hpp   # JSON persistence for share_state.json
├── share_discovery.cpp/.hpp  # mDNS/UDP peer broadcast and listener (optional)
├── share_pairing.cpp/.hpp    # Pairing handshake, fingerprint verification
├── share_transfer.cpp/.hpp   # SCP send/receive, optional rsync wrapper
├── share_diagnostics.cpp/.hpp # sshd status, port checks, WSL networking hints
└── share_controller.cpp/.hpp # TUI controller: all share screens and state machine
```

New TUI integration point in `src/tui/`:

```
src/tui/main_menu.cpp    # add "Share Files" as a top-level or sub-menu entry
```

No other existing files require changes.

---

## Data Model

### `~/.syncpss/share_state.json`

```jsonc
{
  "schema_version": 1,
  "shared_dirs": [
    { "label": "Photos", "path": "/home/user/Pictures", "readable": true, "writable": false }
  ],
  "known_peers": [
    {
      "id": "uuid-v4",
      "alias": "laptop",
      "hostname": "192.168.1.42",
      "port": 22,
      "fingerprint": "SHA256:...",
      "last_seen": "2026-04-16T20:00:00Z",
      "paired": true
    }
  ],
  "transfer_log": [
    {
      "id": "uuid-v4",
      "peer_id": "uuid-v4",
      "direction": "send",   // or "receive"
      "local_path": "/home/user/Pictures/photo.jpg",
      "remote_path": "/home/peer/Downloads/photo.jpg",
      "status": "completed", // "pending" | "in_progress" | "failed" | "completed"
      "bytes_total": 4194304,
      "bytes_transferred": 4194304,
      "started_at": "2026-04-16T20:01:00Z",
      "finished_at": "2026-04-16T20:01:08Z"
    }
  ]
}
```

### Value types in `share_model.hpp`

```cpp
struct SharePeer {
    std::string id;          // UUID v4
    std::string alias;
    std::string hostname;
    uint16_t    port{22};
    std::string fingerprint; // SSH host key SHA256
    std::string last_seen;   // ISO-8601
    bool        paired{false};
};

struct SharedDir {
    std::string label;
    std::string path;
    bool        readable{true};
    bool        writable{false};
};

enum class TransferDirection { Send, Receive };
enum class TransferStatus    { Pending, InProgress, Failed, Completed };

struct TransferRecord {
    std::string      id;
    std::string      peer_id;
    TransferDirection direction;
    std::string      local_path;
    std::string      remote_path;
    TransferStatus   status;
    uint64_t         bytes_total{0};
    uint64_t         bytes_transferred{0};
    std::string      started_at;
    std::string      finished_at;
};
```

---

## SCP Transfer Layer (`share_transfer`)

### Send

```
scp -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=~/.syncpss/share_known_hosts \
    -P <port> \
    <local_path> <user>@<hostname>:<remote_path>
```

- Use `popen` / `fork+exec` with line-buffered stderr to parse progress.
- Parse the `\r`-terminated progress line emitted by OpenSSH `scp -v` for
  bytes transferred.
- On non-zero exit: classify the error string to produce a structured
  `TransferError { code, detail, remediation_hint }`.

### Receive (pull from peer)

```
scp -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=~/.syncpss/share_known_hosts \
    -P <port> \
    <user>@<hostname>:<remote_path> <local_path>
```

### Optional rsync overlay

If `rsync` is detected at runtime, replace the `scp` call with:

```
rsync -avz --progress \
      -e "ssh -p <port> -o StrictHostKeyChecking=yes \
              -o UserKnownHostsFile=~/.syncpss/share_known_hosts" \
      <local_path> <user>@<hostname>:<remote_path>
```

Parse `rsync`'s `--progress` output (`\r`-terminated lines) for live byte
counts. Fall back silently to `scp` if `rsync` is absent.

### Separate known-hosts file

Use `~/.syncpss/share_known_hosts` (not `~/.ssh/known_hosts`) so peer
fingerprints managed by the share subsystem never pollute the user's main SSH
trust store.

---

## Discovery Layer (`share_discovery`) — Optional

### mDNS broadcast

- Advertise service type `_syncpss-share._tcp` on port 22 (or user-configured
  SSH port) using the system `avahi-daemon` on Linux or `dns-sd` on macOS.
- If neither is available, skip discovery silently — manual entry still works.

### Fallback: UDP beacon (no mDNS daemon required)

- Broadcast a short JSON beacon on `255.255.255.255:54321` every 5 seconds
  while the Share screen is open.
- Beacon payload: `{ "app": "syncpss", "alias": "<hostname>", "port": 22, "fp": "<sha256>" }`
- Listen for beacons from peers and add them to a transient discovered-peers
  list (not persisted until user pairs).
- Stop broadcasting when the user leaves the Share screen.

---

## Pairing Flow (`share_pairing`)

1. User opens **Share Files → Discover / Add Peer**.
2. Discovered peers appear in a list. User selects one (or types hostname/IP
   manually).
3. App performs `ssh-keyscan -p <port> <hostname>` and shows the fingerprint.
4. User confirms the fingerprint out-of-band (e.g. reads it from the peer's
   Share screen).
5. On confirmation, the fingerprint is written to `~/.syncpss/share_known_hosts`
   and `paired: true` is set in `share_state.json`.
6. App attempts a test connection (`ssh -o BatchMode=yes ... exit`) to verify
   reachability before marking the peer active.

Pairing is one-directional per device — both sides must pair each other.

---

## Diagnostics Layer (`share_diagnostics`)

Checks run lazily when the Share menu is first opened:

| Check | Tool | Action on failure |
|---|---|---|
| `sshd` running | `systemctl is-active sshd` | Offer guided enable steps |
| SSH port reachable | `nc -z localhost <port>` | Show copy-paste `sshd_config` snippet |
| WSL port proxy | `netsh interface portproxy show all` | Offer elevated PowerShell snippet |
| `scp` available | `which scp` | Error + install hint |
| `rsync` available | `which rsync` | Non-fatal, disables rsync layer |
| `avahi-daemon` running | `systemctl is-active avahi-daemon` | Non-fatal, disables mDNS |

All results are cached for the session and shown in a **Diagnostics** sub-screen
within Share Files. No check auto-remediates without explicit user confirmation.

---

## TUI Screen Flow

```
Main Menu
└── Share Files                       ← new top-level entry
    ├── Browse / Send Files           ← file picker → pick peer → confirm → transfer
    ├── Receive from Peer             ← pick peer → pick remote path → pull
    ├── Transfer History              ← paginated log from transfer_log
    ├── Manage Peers
    │   ├── Discover / Add Peer       ← mDNS + manual entry → pairing flow
    │   ├── Known Peers               ← list, rename alias, unpair, remove
    │   └── Shared Directories        ← configure which local dirs are exposed
    └── Diagnostics                   ← sshd, network, dependency status
```

Each screen is implemented as a dedicated controller class in
`share_controller.cpp` following the same pattern as existing TUI controllers.
No global state is introduced.

---

## Privilege Model

| Action | Mechanism | Who approves |
|---|---|---|
| Install `sshd` | `sudo apt install openssh-server` | User reads command, confirms in TUI |
| Enable/start `sshd` | `sudo systemctl enable --now sshd` | Same |
| Edit `sshd_config` | Present diff as copy-paste text | User applies manually or confirms |
| WSL port proxy | Elevated PowerShell one-liner shown | User copies and runs |
| All else | Unprivileged | — |

The app never runs `sudo` autonomously. It constructs the exact command and
shows it; the user runs it (or presses **Y** in a confirmation dialog that
pipes it through `sudo`).

---

## Implementation Order

Phase 1 — Data foundation (no TUI changes)

1. Define `share_model.hpp` value types.
2. Implement `share_state.cpp` — JSON load/save, migration for `schema_version`.
3. Write unit tests for persistence round-trips.

Phase 2 — Diagnostics (read-only, safe to ship early)

4. Implement `share_diagnostics.cpp` — all checks, no auto-remediation.
5. Wire into a minimal "Share Files → Diagnostics" stub screen.

Phase 3 — Manual peer + transfer

6. Implement `share_transfer.cpp` — SCP send/receive, error classification.
7. Implement `share_pairing.cpp` — `ssh-keyscan`, fingerprint confirmation,
   `share_known_hosts` write.
8. Build "Add Peer (manual)" + "Browse / Send Files" screens.

Phase 4 — Discovery

9. Implement `share_discovery.cpp` — UDP beacon first, then optional mDNS.
10. Wire discovery into "Discover / Add Peer" screen.

Phase 5 — rsync overlay + polish

11. Add rsync runtime detection and progress parsing.
12. Transfer History screen.
13. Shared Directories config screen.
14. Full diagnostics remediation hints.

---

## Open Questions

- **Discovery approach:** Should UDP beacon be the default and mDNS be a
  compile-time optional, or should both always be compiled in and toggled at
  runtime by availability of the system daemon?
- **Menu placement:** Top-level "Share Files" entry vs. a sub-item inside a
  new "Network" group alongside "Sync". Top-level is simpler to navigate but
  grows the main menu.
- **sshd config ownership:** Should the TUI offer to patch `sshd_config`
  (write `AllowUsers`, set `Port`) or only present copy-paste snippets? Patching
  is more ergonomic but requires `sudo` and careful diff logic.
- **Pull vs push from receiver side:** Should the receiving peer be able to
  browse the sender's shared directories and pull files, or must the sender
  always initiate? Pull requires `sshd` and proper `AllowUsers` on the sender;
  push only requires `sshd` on the receiver.
- **Windows-side sharing:** Is sharing scoped to WSL/Linux only, or should the
  Windows helper (`syncpss-wsl-installer.exe`) eventually expose Windows paths
  as transfer targets?

---

## Non-Goals (for this iteration)

- Encrypted-at-rest file vault (files travel over SSH, which is already
  encrypted in transit).
- Bandwidth throttling UI.
- Multi-file queuing / batch scheduling.
- Mobile peer support.
- Relay/proxy for peers outside the LAN.
