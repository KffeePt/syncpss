# Runtime Config And Store

## Password store model

`syncpss` does not store passwords in a custom format.

It manages a standard `pass` store rooted at:

- `~/.password-store`

The store now keeps:

- encrypted notes inside the `pass` entry payload itself
- `~/.syncpss/metadata.json`
  optional audit metadata for creation, modification, deletion, and sync events

Legacy plaintext `~/.syncpss/notes.json` is migration-only input and should not be used for new notes.

The TUI shells out safely to `pass` through the shared subprocess helper in
[process.cpp](C:/Users/santi/Documents/GitHub/syncpss/src/util/process.cpp).

Automatic local backup directories are split by purpose:

- `~/.syncpss/store-backups`
  automatic backups of `~/.password-store`
- `~/.syncpss/gnupg-backups`
  automatic backups of `~/.gnupg`

The current retention policy keeps:

- the newest 10 store backups
- the newest 20 `.gnupg` backups

## Runtime config

The primary runtime config is:

- `~/.syncpss/config.json`

The schema is represented in:

- [runtime_config.hpp](C:/Users/santi/Documents/GitHub/syncpss/src/util/runtime_config.hpp)
- [runtime_config.cpp](C:/Users/santi/Documents/GitHub/syncpss/src/util/runtime_config.cpp)

It stores:

- GitHub username/email/repo
- saved private repo name
- managed SSH key path
- selected GPG key
- metadata logging toggles
- notes storage mode
- password-store path/branch
- installation metadata

## Entry metadata

The metadata ledger can record:

- original entry name and current path
- creation mode and modification history
- deletion timestamps
- host identity fields such as hostname, IP, and MAC when explicitly enabled

Metadata logging is off by default.

This is intentionally kept separate from the encrypted password payload so the
TUI can track workflow state without changing `pass` entry contents.

The current schema is append-only at the event level and is designed to answer:

- whether an entry was created in manual mode or combo mode
- which machine last modified it
- when it was deleted
- what the entry path was at each stage

## Legacy config compatibility

The older INI file is still written for compatibility:

- `/etc/syncpass/config`

The adapter logic lives in:

- [config.cpp](C:/Users/santi/Documents/GitHub/syncpss/src/util/config.cpp)

`syncpss` prefers the JSON runtime config when available.

## Store versioning and hash tracking

The git sync layer now tracks a store version and hash file:

- `.syncpss-store.sha256`

The relevant logic is in:

- [git.cpp](C:/Users/santi/Documents/GitHub/syncpss/src/git/git.cpp)

When local store changes are synced, the code:

1. computes a deterministic hash of tracked store files
2. writes `.syncpss-store.sha256`
3. commits the change
4. creates the next `v0.0.xxxx` store tag

That gives the private `pass-store` repo an auditable progression of sync points.

## Manifest-based backup containers

Portable VeraCrypt containers now use `manifest.xml` instead of the older
`pub.xml` name.

The supported manifest types are:

- `keys`
  carries only `.gnupg` backup material for GPG restore
- `backup`
  carries a portable store snapshot intended for both backup and migration

The `backup` container format can include:

- `manifest.xml`
- `store.json`
- `password-store/`
- `.gnupg/`
- `.git/`

The root password-store itself also keeps a top-level `manifest.xml` so the
store has a standardized self-description even outside the portable container.
