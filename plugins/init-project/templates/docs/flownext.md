# /flownext Implementation

Whenever /flownext:work is invoked, assume the user is about to step away from their computer and may be unavailable for an extended period. Your responsibility is to continue working autonomously and drive the assigned epic(s) or tasks to completion while they are away.

Before beginning work, use your final interaction with the user to gather any information that could become a blocker later. Ask all necessary clarifying questions, confirm assumptions, identify ambiguities, and collect any missing requirements, preferences, constraints, or decision-making criteria you may need.

Do not prematurely begin execution if critical information is missing. Continue questioning until you are confident you can proceed independently.

Once you have sufficient information, explicitly tell the user that you have everything you need and that you can take it from there. Then proceed with the work autonomously, making reasonable decisions where necessary and documenting any assumptions you make along the way.

The goal is to maximize progress during the user's absence and avoid situations where work stalls because a question could have been asked before they left.


## Closing the spec — automatic, not optional

`/flow-next:work` deliberately does **not** close a spec when it finishes — closing it is YOUR job, and you do it **automatically, without waiting for the user to ask**.

When ALL of the following hold for the spec you were driving:

1. Every task in the spec reports `status: done` (`flowctl show <spec-id> --json`).
2. `flowctl validate --spec <spec-id> --json` passes (`valid: true`, zero errors).
3. The spec-completion review — when a review backend is configured — reached verdict SHIP (`completion_review_status: ship`).
4. The epic's tests / Quick commands are green.

…then immediately:

```bash
flowctl spec close <spec-id>
```

then commit the resulting `.flow/` state change (`chore(flow): close <spec-id>`) and mention the closure in your wrap-up to the user.

If ANY criterion fails, do NOT close — fix the gap first, or, if genuinely blocked, leave the spec open and state exactly which criterion failed and why.

Note: `flowctl` is bundled, not globally installed (`which flowctl` failing is expected). Use the same `$FLOWCTL` the /flow-next skills resolve — the plugin's bundled `scripts/flowctl`, falling back to `.flow/bin/flowctl` when it was installed locally via `/flow-next:setup`.
