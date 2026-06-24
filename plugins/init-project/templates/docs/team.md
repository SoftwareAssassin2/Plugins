# Team

The registry / org chart for **async team collaboration** — see
[`docs/collaboration.md`](collaboration.md) for the full protocol. This file is a
**fixed, hook-parseable markdown table**: one person per row, built incrementally
as teammates identify themselves (the first-run register path in the protocol
doc). Readers skip the header and `|---|` separator rows.

- `handle` — the person's stable key, the **stored git-email slug** (written at
  registration, never re-derived by readers).
- `name` — display name; display-only.
- `git-email` — the identity **match key** (`git config --get user.email`).
- `computer-name` — a secondary recognition hint; never a match key.
- `reports-to` — the `handle` of the person they report to.

> **Private-repo only.** This file is committed and pushed and lives in history
> permanently. Minimize fields; never record secrets. See the PII caveat in
> [`docs/collaboration.md`](collaboration.md).

| handle | name | git-email | computer-name | reports-to |
|---|---|---|---|---|
| alice | Alice Example (placeholder — replace) | alice@example.com | alice-laptop | |
