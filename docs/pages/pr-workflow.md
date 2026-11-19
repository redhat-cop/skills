## The PR agent

Every non-draft PR to this repo is picked up by the **PR agent** — an automation that tracks it on a *phase card* (a GitHub issue carrying exactly one `phase/*` label) and drives it through Backlog → Doing → Review → Done. The agent does the legwork; **humans own every merge** through an explicit `/LGTM`.

| Phase | What the agent does | What you do |
|---|---|---|
| `phase/backlog` | Creates the card, posts a **triage receipt** (what it is, type, size/risk, which CI jobs will matter) | nothing |
| `phase/doing` | Claims the card (oldest first, one per tick), runs checks, posts a **checks report** with a GREEN/RED/PENDING verdict | fix anything CI or the report flags; push and the card re-enters Doing automatically |
| `phase/review` | Posts an **advisory review** on the PR against the contribution contract and records the reviewed head SHA on the card | wait for a maintainer |
| `phase/done` | After a maintainer `/LGTM`: re-verifies the merge guards, squash-merges, posts the receipt, closes the card | celebrate |

Draft PRs get no card until marked ready. Re-opened PRs get a fresh card.

## Maintainer commands

Both commands must be on their own line in a comment (on the PR or the card) and only count from a maintainer:

- **`/LGTM`** — approves the merge. The agent still re-verifies the guards below at merge time; if you approved an older head, the card bounces back to Doing for fresh checks.
- **`/cancel`** — abandons the contribution: the agent closes the PR *and* the card (`phase/cancelled`), no questions asked.

## The merge guards

The agent merges only when **all five** hold *right now* — never from a cached state:

1. **Repo identity** — the PR lives in the watched repo, nowhere else
2. **Maintainer `/LGTM`** present
3. **Checks green** at this moment
4. **Head SHA unchanged** since the review that recorded it (`LGTM-SHA:` marker)
5. **Mergeable** (no conflicts)

Any guard failing → no merge, and the card says why. Receipts: every transition posts a card comment, so the card is the complete audit trail of the PR's life.

## Running the agent

The agent ships **in this repo** as one installable skill: [pr-agent](../skills/pr-agent/) — the orchestrator (`SKILL.md` + the `POLL.md` tick entry point), the five phase procedures under [references/](../skills/pr-agent/references/) (triage, checks, review, guarded merge, cancel), and the operator runbook ([operator-setup.md](../skills/pr-agent/references/operator-setup.md)). A watched repo needs the five `phase/*` labels, a PAT bound for `github.com` + `api.github.com`, and the `pr-agent-poll` automation; the tick is dry-run unless it explicitly goes live.

Invariants worth knowing: one PR claimed per tick, max two concurrent per-PR sessions, the agent never force-pushes and never starts CI (it only observes), and no merge ever happens without the guards above.
