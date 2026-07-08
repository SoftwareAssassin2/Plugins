---
title: Listener cap off-by-one vs sender + unterminated EOF line decoded (fn-5.9)
date: "2026-07-08"
track: bug
category: integration
module: plugins/speak/bin/speak
tags: [wire-protocol, size-cap, off-by-one, newline, listener, bounded-capture, contract]
problem_type: runtime-error
symptoms: Newline-less EOF tail reached decode/enqueue; 65537-byte frame passed the 65536 cap
root_cause: Cap re-derived without the newline the sender counts; pre-hardening leniency for unterminated lines kept
resolution_type: fix
---

## Problem
The fn-5.9 listener bounded-capture landed with two wire-contract misses caught by codex impl-review: (1) a final UNTERMINATED line at EOF was still passed to decode/enqueue — a foreign client's truncated (or deliberately newline-less) tail could be spoken even though C2 defines a frame as newline-terminated and the task required newline-less frames dropped BEFORE decode; (2) the listener's over-cap check used `> SPEAK_MAX_FRAME_BYTES` on the line BODY while the sender (`build_frame`) counts sid+tab+b64+NEWLINE against the same 65536 cap — so a 65536-byte body (65537-byte frame) passed the listener but could never have been produced by a compliant sender (off-by-one on which side of the cap the delimiter lives).

## What Didn't Work
Preserving the .3 reader's "process a final unterminated line" arm (`read || [ -n "$line" ]`) as a robustness nicety — under a byte-capped hardened reader that leniency became a contract violation. And re-deriving the cap check locally ("line > cap") instead of mirroring the sender's exact arithmetic ("sid+1+b64+1 <= cap").

## Solution
`plugins/speak/bin/speak` listener_accept_lines: a failed read with a non-empty line (EOF, no newline) is logged (`newline-less line at EOF`) and dropped before decode; the cap check became `nbytes >= SPEAK_MAX_FRAME_BYTES` (body + newline > cap), exactly mirroring build_frame's pre-check; same `>=` fix in process_frame_line's secondary guard. Proof asserts a valid-looking newline-less frame is never spoken and the exact 65536-byte-body boundary is rejected.

## Prevention
When a size cap is shared by a sender and a receiver, one side's check must be written BY COPYING the other side's arithmetic (including whether delimiters count), never re-derived — and any "tolerate malformed input" leniency inherited from a pre-hardening reader must be re-justified against the wire contract after hardening. Boundary-test the exact cap value (cap-1 accepted, cap rejected), not just a grossly-over value.
