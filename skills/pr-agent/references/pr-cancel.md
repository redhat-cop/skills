# PR cancel (Cancelled phase)

## When to use

- The tick detected a maintainer `/cancel` on the PR or card.
- The tick detected a PR closed without merging.
- The operator asks to abandon a card.

## Procedure

1. Confirm the trigger (one of):
   - `/cancel` comment by a maintainer (`OCLAW_PR_MAINTAINERS`, default
     `eformat`, `hultzj`) on PR or card;
   - PR state = closed and merged = false;
   - explicit instruction from the operator.

2. **If triggered by maintainer `/cancel`: close the PR as well** — a
   maintainer cancelling means the whole contribution is abandoned, and an
   open PR with a cancelled card reads as alive:

```bash
gh pr close <n> --repo "${OCLAW_PR_REPO:-redhat-cop/skills}" \
  --comment "Cancelled by pr-agent on maintainer /cancel (card <card-issue>)."
```

3. Post the receipt:

```bash
skills/pr-agent/scripts/pr_card.sh comment <card-issue> <<EOF
## 🤖 Cancelled

- reason: <maintainer /cancel by @<login> | PR closed unmerged | owner request>
- PR: <url>
- closed at: <UTC timestamp>
EOF
```

4. Transition and close:

```bash
skills/pr-agent/scripts/pr_card.sh set-phase <card-issue> cancelled
skills/pr-agent/scripts/pr_card.sh close <card-issue>
```

## Rules

- `/cancel` by a maintainer wins over everything, including a pending
  READY-TO-MERGE state.
- No deletion, no reopening PRs, no arguments on the PR — the receipt is the
  record.
- If the same PR is later reopened, the tick treats it as a new PR and creates
  a fresh card.
