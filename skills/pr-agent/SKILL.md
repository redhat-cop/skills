---
name: pr-agent
description: >-
  Orchestrates the GitHub PR agent lifecycle — poll tick, phase routing,
  triage, checks, review, guarded merge, cancel — for the watched repo. Use
  on pr-agent-poll ticks or when working a PR phase card.
license: Apache-2.0
metadata:
  version: "0.1.0"
  maturity: experimental
  owner: eformat
  domain: github-automation
---

# PR agent orchestrator

## When to use

- The `pr-agent-poll` automation fires (isolated session).
- The operator asks to "run the PR agent tick" or "check the PR cards".
- Any work on a PR phase card — the phase procedures live in `references/`.

## Preconditions

1. A checkout of the **watched repo** is present in the workspace (clone/pull
   it if absent) and is the working directory for all commands. The watched
   repo is `OCLAW_PR_REPO`, default `redhat-cop/skills`; the examples
   in this skill use that default.
2. `gh` and `git` are available; `GITHUB_TOKEN` env is set by the sandbox
   (a placeholder the egress proxy substitutes — never print it).
3. Live mode only when `OCLAW_PR_LIVE=1` is set by the automation tick. Without
   it, everything is a dry-run that must perform zero writes.

## Phase routing

| Card state | Procedure (references/) | Next |
|---|---|---|
| `phase/backlog` | (tick claims it) → [pr-triage.md](references/pr-triage.md) | `phase/doing` |
| `phase/doing` | [pr-checks.md](references/pr-checks.md) | `phase/review` (green) / stay (red) |
| `phase/review` | [pr-review.md](references/pr-review.md) | `phase/done` on guarded merge |
| `phase/review` + `/LGTM` ready | [pr-done.md](references/pr-done.md) | `phase/done` |
| `/cancel` or PR closed unmerged | [pr-cancel.md](references/pr-cancel.md) | `phase/cancelled` |

Read the procedure matching the card's state; each is self-contained. The
scripts they call live in `scripts/` next to this file.

## Guardrails (non-negotiable)

- Merge requires ALL of: maintainer `/LGTM`, checks green, head SHA unchanged
  since review (`LGTM-SHA:` marker), PR mergeable. Maintainers are
  `OCLAW_PR_MAINTAINERS` (default `eformat,hultzj`).
- One PR claimed per tick; max 2 concurrent per-PR sessions.
- Never force-push; never push to `main`; checkouts are throwaway scratch dirs.
- Every transition posts a receipt comment on the card.

## Tick procedure

Follow `POLL.md` (next to this file) exactly. It is the automation's entry
point and includes the resume semantics for cards left mid-phase.

## Operating this on a repo

Set-up (labels, credentials, automation payload, workspace duty section) is in
`references/operator-setup.md`.
