# Operator setup — running the PR agent on a repo

Everything below is operator-side (repo admin + OCE console). The agent-side
contract lives in `POLL.md` and the phase skills next to this file.

## 1. Phase labels on the watched repo (idempotent, live-safe)

```bash
OCLAW_PR_LIVE=1 skills/pr-agent/scripts/pr_labels_bootstrap.sh
```

Creates/fixes the five labels: `phase/backlog` `phase/doing` `phase/review`
`phase/done` `phase/cancelled`.

## 2. GitHub PAT

Fine-grained PAT, repository access limited to the watched repo only, with an
expiration set:

| Permission | Level | Why |
|---|---|---|
| Metadata | Read-only | mandatory — pre-selected automatically |
| Issues | Read and write | cards are issues: create/comment/edit/close, `phase/*` labels |
| Pull requests | Read and write | triage, reviews, comments, **squash merge**, close |
| Contents | Read | clones and scratch checkouts — write is NOT needed (the agent never pushes) |
| Actions | Read | workflow runs (the checks fallback path) |
| Commit statuses | Read | legacy commit statuses (`GET /commits/{ref}/status`) |

The squash merge goes through the pull-requests permission, not contents —
and since the guardrails forbid the agent pushing anywhere, contents stays
read-only. If the watched repo is org-owned (e.g. `redhat-cop/skills`), the
org must also allow fine-grained PAT access (org settings → personal access
tokens).

**Known gap — verify before cutover.** The Checks API (check runs) cannot be
granted to fine-grained PATs at all (GitHub-Apps-only), and `gh pr checks`
reads check runs. Public repos expose check runs without a permission, but an
authenticated call from the fine-grained token can still 403. Smoke-test the
new token against a real PR before replacing the live one:

```bash
GH_TOKEN="$(cat ~/.config/oclaw-pr-agent/github-pat-new)" \
  gh pr checks <pr-number> --repo "${OCLAW_PR_REPO:-redhat-cop/skills}"
```

If that 403s: either keep a classic PAT for the agent, or switch
`run_checks.sh` to the fallback that works with this set — Actions workflow
runs by head SHA (`GET /actions/runs?head_sha=`) plus the combined commit
status. Nothing is lost for this repo: Skills CI (GitHub Actions) is the only
checker, there are no third-party check apps.

Keep it in a protected local file (never argv, never logs, never git).

## 3. Secret + two CredentialSources (egress is per-destination)

In the OCE namespace: one **Secret** holding the PAT, then two **bearer-token
CredentialSources** sharing it — they differ in `config.host` and, critically,
`env_var` (two sources delivering the same sandbox variable are refused at
revision build):

- `github-web` → `github.com:443`, **`env_var: GITHUB_TOKEN_WEB`** (git-over-https)
- `github-api` → `api.github.com:443`, **`env_var: GITHUB_TOKEN_API`** (gh REST)

Omit `protocol` from bearer-token configs (it selects the managed-MCP
validation branch and is refused). The sandbox agent receives opaque
placeholders in those env vars; the egress proxy substitutes the real value
into the `Authorization: Bearer` header for the configured `host:port:path`
only. The scripts already route per destination:
`GH_TOKEN="${GITHUB_TOKEN_API:-…}"` for `gh`, a credential helper with
`GITHUB_TOKEN_WEB` for git.

Bind both `cs_…` source IDs on the agent via
`"credentialSources": [{ "sourceId": "cs_…" }, …]` and deploy a new version.
The executing binaries (gh, git, curl, node) must be covered by the sandbox
`toolBinaries` or registration is refused with 409. If a `source-control`
network rule exists for `github.com` in the Installation, remove it — the
policy engine rejects credentialed endpoints it does not inspect
(`networkPolicies` needs `minItems: 1`; keep one harmless rule in its place).

Rotation note: changing the Secret alone leaves the gateway copy unchanged —
rotation = new secret + re-register the credential sources + redeploy.

## 4. Workspace duty section (agent AGENTS.md)

```markdown
# PR agent duty

You operate the GitHub PR agent for the watched repo
(OCLAW_PR_REPO, default redhat-cop/skills).

- On every pr-agent-poll automation tick: clone/pull the watched repo into
  the workspace, then follow skills/pr-agent/POLL.md exactly (dry-run unless
  the tick is live).
- GitHub credentials arrive as SEPARATE per-destination placeholders:
  GITHUB_TOKEN_API (gh REST, api.github.com) and GITHUB_TOKEN_WEB (git
  https, github.com). The egress proxy substitutes them into the
  Authorization header — never print them, never put them in argv or files.
  - Before ANY gh command: export GH_TOKEN="${GITHUB_TOKEN_API:-$GH_TOKEN}"
  - For git-over-https: use a credential helper with GITHUB_TOKEN_WEB
    (see skills/pr-agent/scripts/run_checks.sh). Plain curl to
    api.github.com is refused (curl is not a toolBinary); use gh.
  - NEVER download or install tools/binaries (jq, npm/pip packages from
    unknown repos). The pr-agent scripts need only gh. If something is
    missing, STOP and report it in the tick summary.
- Phase state = phase/* labels on card issues; exactly one at a time. The
  label swap IS the transition. Receipts as card comments.
- NEVER merge without all five guards: PR is in the watched repo + maintainer
  /LGTM + green checks + head SHA unchanged since review + mergeable.
  Maintainers: OCLAW_PR_MAINTAINERS (default eformat, hultzj).
- /cancel by a maintainer cancels the card immediately.
- One PR claimed per tick; max 2 concurrent per-PR sessions.
```

## 5. The pr-agent-poll automation

Gateway-local cron (not versioned by deploys). Schema: `{name, enabled,
schedule:{kind:"every",everyMs}, sessionTarget:"isolated", wakeMode:"now",
payload:{kind:"agentTurn", message, toolsAllow:[]}, delivery:{mode:"none"}}`.
Create it via the agent chat `automations` tool or the UI form. Payload:

```json
{
  "name": "pr-agent-poll",
  "enabled": true,
  "schedule": { "kind": "every", "everyMs": 900000 },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "This tick is LIVE: set OCLAW_PR_LIVE=1 for the tick; GitHub mutations are authorized for watched-repo cards only. PR agent poll tick. (1) If the watched repo (${OCLAW_PR_REPO:-redhat-cop/skills}) is absent from the workspace, clone it per skills/pr-agent/POLL.md §0; otherwise refresh it. (2) cd into the repo root and follow skills/pr-agent/POLL.md exactly — start with skills/pr-agent/scripts/pr_tick.sh. (3) For each READY-TO-MERGE finding, follow skills/pr-agent/references/pr-done.md guards before any merge. (4) End with the tick summary (created / claimed / ready-to-merge / cancelled).",
    "toolsAllow": []
  },
  "delivery": { "mode": "none" }
}
```

⚠️ **One poller per watched repo.** Two automations ticking the same repo
double-claim cards and race on transitions — disable the old one before a new
agent's poller goes live.

## 6. First live cycle (dogfood)

1. Egress smoke: `gh api repos/<watched-repo> --jq .default_branch` from the agent.
2. Open a throwaway PR (or wait for a real one).
3. Watch one full cycle: Backlog → Doing → Review → `/LGTM` → merged → Done,
   with receipts on the card.
4. Then leave the automation running (15 min cadence is a good steady state).
