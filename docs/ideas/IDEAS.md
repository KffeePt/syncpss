# Ideas

This folder contains exploratory design documents for features that are being
considered for `syncpss` but have not yet been committed to the active
development roadmap.

## Purpose

`docs/ideas/` is a low-friction space for capturing and fleshing out feature
concepts before they graduate into formal implementation plans or tracked issues.

Documents here may be:

- **Rough sketches** — just enough to preserve the idea and its core
  motivation.
- **Detailed plans** — fully specified designs ready to be converted into
  implementation work when prioritized.
- **Exploratory research** — notes on feasibility, trade-offs, or alternative
  approaches for an open question.

Nothing in this folder implies a commitment to build. Ideas are promoted to
active work by moving their key decisions and implementation order into the
relevant tracking system and updating `docs/PENDING.md` accordingly.

## Conventions

- One file per feature idea, named in `UPPER_SNAKE_CASE.md`.
- Include a **Status** line at the top of each file:
  - `idea / not started` — captured, not yet designed.
  - `in design` — actively being refined.
  - `ready` — design is complete and waiting for prioritization.
  - `promoted` — moved to active work; file kept for historical reference.
- Link back to the originating section in `docs/PENDING.md` or a GitHub issue
  when applicable.
- Prefer concrete data models, API sketches, and implementation orders over
  abstract descriptions.

## Index

| File | Feature | Status |
|---|---|---|
| [FILESHARING.md](./FILESHARING.md) | LAN file sharing via SCP | `idea / not started` |
