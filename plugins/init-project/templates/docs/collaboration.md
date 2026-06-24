# Async team collaboration

This is the **protocol standard** for git-mediated async collaboration between
teammates. It is the contract the AI agent follows when a teammate needs another
teammate's input but can't reach them in real time. There is no network transport
and no shared service: questions, answers, and handoffs move only through
**committed docs + `git push`/`pull`**. A SessionStart hook surfaces "it's your
turn" items at the start of a session; the agent does every write per this doc.

`CLAUDE.md` carries only the thin wiring (a Standards-index row and a short
working-agreement pointer); the full model lives here.

## Scope

This is one of **three non-overlapping note-surfaces** — keep them distinct:

- **`docs/collaboration.md` / `docs/collaboration/`** (this surface) — questions
  and handoffs aimed at a **specific teammate**: "we need Bob's input on X."
- **[`docs/todo.md`](todo.md)** — *my own* engineering loose ends, deferred fixes,
  and tech debt I noticed. Not aimed at anyone else.
- **[`docs/priorities.md`](priorities.md)** — the business roadmap / ranked
  what-matters-now, owned by the `/dick` advisor.

If a note is for someone else, it belongs here. If it's a thing *I* still owe the
codebase, it's a todo. If it's a business priority call, it's a priority. This doc
does not restate what those two cover.

## Identity

Identity is keyed on **`git config --get user.email`** — nothing else. There is no
account system, no auth, no separate identity store; the email a teammate already
commits with *is* their identity.

- **`user.email` is the single match key.** It is also the source of a person's
  `handle` (see [Handles](#handles)). Routing, registration, and inbox lookup all
  key off the email.
- **`user.name` is a display value only — never a match key.** It is used to make
  output friendly *after* the email identity is confirmed, and as the `name`
  column in `team.md`. Two people can share a display name; they can never share
  an email.
- **Computer/hostname is a secondary hint only** — recorded in `team.md` as
  `computer-name` to help a human recognize a row, never used to decide who you
  are. This keeps identity stable across machine changes and dev containers
  (where the container hostname differs from the host).

Identity is read **at the project root**: `git -C <project_root> config --get
user.email`, which resolves repo-local then global config.

### Confirm before attributing

The agent never silently assumes who you are before writing anything attributed to
you. There are three identity cases:

1. **No `user.email`** (even if `user.name` is set) — a **graceful, non-attributing
   state**. Dev containers may have no mounted `.gitconfig` at all. The hook stays
   silent; the agent does not guess or attribute. Nothing breaks.
2. **`user.email` present but not in `team.md`** — the hook emits a **register
   advisory**. On the **first run**, the agent asks the person **who they are**
   (display name) **and who they report to**, then records both in `docs/team.md`.
   No attributed content is written until the person confirms.
3. **`user.email` is in `team.md`** — recognized. No prompt; the agent proceeds.

## Team registry — `docs/team.md`

[`docs/team.md`](team.md) is a lightweight registry / org chart kept in a **fixed,
hook-parseable GitHub-style markdown table**. Columns, in order:

| Column | Meaning |
|---|---|
| `handle` | the person's stable key — the **stored git-email slug** (written at registration, never re-derived by readers) |
| `name` | display name (`user.name`); display-only |
| `git-email` | the identity **match key** (`user.email`) |
| `computer-name` | a secondary recognition hint; never a match key |
| `reports-to` | the `handle` of the person they report to — a lightweight org chart |

The table is built incrementally as people identify themselves (the first-run
register path above). A reader (hook or agent) parses it by **skipping the header
row and the `|---|` separator row**, then reading one person per remaining row,
trimming each cell.

**`handle` is unique.** Registration must detect a **slug collision** — two
distinct emails that slug to the same handle (e.g. `bob@x.com` and `bob@y.com`
both → `bob`). On a collision, **stop** and instruct the operator to pick a
disambiguated handle (e.g. `bob-x` / `bob-y`) and record it explicitly, so inboxes
and routing are never ambiguous. Because the handle is *stored*, the disambiguated
value sticks; readers never re-derive it.

## Handles

A **handle** is a person's stable key: a **slug of their git-email**, computed
once at registration:

1. lowercase the whole email;
2. replace every run of non-`[a-z0-9]` characters with a single `-`;
3. trim leading and trailing `-`.

So `Bob.Smith@Example.com` → `bob-smith-example-com`. The handle is used for
**inbox filenames** (`docs/collaboration/<handle>.md`) and in the `asker` /
`assignee` / `author` fields of threads. It is the slug — **not** the display name
— that appears in all routing fields. (On a collision, the operator-chosen
disambiguated handle is stored in `team.md` and used verbatim.)

## Thread / turn / status model

A collaboration item is an **append-only thread** living in the **assignee's
inbox**: `docs/collaboration/<assignee-handle>.md`. Append-only is the whole
discipline — **nothing is ever edited in place**; new state is a new turn.

### Thread header

A thread opens with a fixed, single-line **thread header**:

```
## thread:<id> | asker:<handle> | assignee:<handle> | subject:<text>
```

- `<id>` — a thread identifier unique within the inbox file.
- `asker` / `assignee` — **handles** (slugs, never display names). They are set
  once and **never change** for the life of the thread.
- `subject` — a short human-readable summary.

### Turns

Under the header, each contribution is a **turn**: an **ASCII** header line
followed by a free-form markdown body.

```
### turn <n> | author:<handle> | status:<enum> | <iso-ts>
```

- `<n>` — the **per-thread monotonic counter** and the **ordering key**. Turn 1,
  then 2, then 3… It increments by one per appended turn within the thread.
- `author` — the handle of whoever wrote the turn.
- `status` — the enum below, carried **per turn**.
- `<iso-ts>` — an ISO-8601 wall-clock timestamp. **Display-only.** Remote clocks
  and timezones are unreliable, so timestamps are *never* used for ordering — the
  counter `<n>` is. (Rationale mirrors how git-bug orders operations by a Lamport
  counter rather than wall-clock.)

The body below the header is free-form markdown — **include context liberally** so
the assignee can dig into specifics without a back-channel: link files, paste the
relevant snippet, name the spec/task, state the decision at stake.

### Status enum and effective status

`status` ∈ `awaiting-assignee | awaiting-asker | resolved`.

A thread's **effective status is the status of its highest-`<n>` turn.** Because
turns are append-only and status is never edited in place, a later turn
*supersedes* the earlier one — you read the latest turn to know where the thread
stands.

### Status routing — only the asker resolves

Routing reads the thread header's `asker` / `assignee` **handles** plus the latest
turn's status:

- `awaiting-assignee` → it's the **assignee's** turn (a question or a push-back is
  waiting for them).
- `awaiting-asker` → it's the **asker's** turn (the assignee has replied).
- `resolved` → done; nobody is alerted.

The rules:

- **Only the asker resolves.** An assignee reply appends a turn with
  `awaiting-asker` — **never** `resolved`. The assignee answers; the asker decides
  whether that answer closes it.
- **Push-back is just another turn.** If the asker isn't satisfied (more context
  needed, an edge case to explore), they append a turn with `awaiting-assignee`,
  bouncing it back. This supports **unbounded rounds** of back-and-forth.
- The asker closes by appending a turn with `resolved`.

```
awaiting-assignee  --(assignee replies)-->  awaiting-asker
awaiting-asker     --(asker pushes back)-->  awaiting-assignee
awaiting-asker     --(asker accepts)------>  resolved
```

### Concurrent appends

Two people appending to the **same thread** at the same time is resolved by
**re-pull + re-append**, never a hand-merge: pull, observe the now-highest `<n>`,
and append your turn as the next `<n>`. Ordering stays deterministic by the
counter. (If same-thread collisions ever get frequent, the documented upgrade path
is **thread-per-file** — `docs/collaboration/threads/<id>.md` with
`asker`/`assignee`/`status` frontmatter — but v1 is per-assignee inbox files.)

## The trigger and the round-trip

### Trigger

When the user says, in any conversation, something like **"we need Bob's input on
this"** / **"get Bob's input"** / **"ask Bob about X"**, the agent recognizes the
intent and:

1. **Fuzzy-matches** the named person against `docs/team.md`. If they're absent,
   **offer to add them** (the register path: name + who-they-report-to → a new
   `team.md` row, with the slug-collision check).
2. **Appends a new thread** to that person's inbox
   (`docs/collaboration/<assignee-handle>.md`) with an opening turn at
   `awaiting-assignee` and **liberally-included context** (see Turns).
3. Optionally re-enters a targeted `/flow-next:interview` to sharpen the question —
   but the core mechanism is brokering the Q&A, not the interview.

### Round-trip

```
Asker:    append thread (awaiting-assignee), git push
Assignee: SessionStart hook surfaces "1 thread awaiting you" → append answer
          (awaiting-asker), git push
Asker:    SessionStart hook surfaces "Bob answered" → resolve (resolved)
          OR push back (awaiting-assignee) for another round
```

Freshness is **"as of your last pull"** — the hook never fetches. When something
might be stale, `git pull` first.

### Persist the answer to the real artifact

A resolved thread is the *record of the conversation*, not the *home of the
decision*. When an answer settles something, **persist it back to the artifact it
belongs to** — update the spec/task via `flowctl`, change the code, or write a
decision into [`docs/decisions.md`](decisions.md) — **in addition to** appending
the resolving turn. The thread should never be the only place a decision lives.

## Private-repo / PII caveat

`docs/team.md` (names, machine names, an org chart) and everything under
`docs/collaboration/` (the discussions) are **committed and pushed**, and they
live in git history **permanently** — `git rm` removes the file from `HEAD` but
**not** from history. Therefore:

- **Use this only in a private repository.**
- **Minimize fields** — record only what routing needs; omit anything sensitive
  you don't have to store.
- **Never write secrets** (tokens, passwords, customer PII, keys) into a thread or
  into `team.md`. There is no redaction and no expiry.
