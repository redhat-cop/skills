## Principles

1. **No direct commits to `main`** — everything through PRs, maintainers included
2. **Reviewers tagged explicitly**, CODEOWNERS as the backstop
3. **Docs ship with code** — behavior changes update the skill's docs in the same PR
4. **Structural changes get joint review** — two maintainers

## Approval tiers

| Change | Approval |
|---|---|
| Repo files (`scripts/`, `tests/`, `.github/`, `docs/`) | ≥1 maintainer |
| New skill | skill `owner` + ≥1 maintainer |
| Behavioral change to a skill | skill `owner` + ≥1 maintainer (2 maintainers if the owner is unavailable) |
| Structural (governance, validator rules, new top-level dirs) | 2 maintainers |

## Maintainers


## Ownership in practice

Every skill declares its `owner` in frontmatter, and every skill has a matching `CODEOWNERS` rule — the validator fails any PR where the pair is missing. Per-skill review requests therefore route to the person who knows the skill, with the maintainer group as safety net.

Triage target for unassigned PRs: **2 business days**.

## Intake

New skills start as a ["Skill proposal" issue](https://github.com/redhat-cop/skills/issues/new?template=skill-proposal.yml) — problem, audience, trigger phrases. Maintainers triage lightly; overlap checks happen before anyone writes SKILL.md. Bug fixes to existing skills go straight to PRs.

## Automation

PRs are tracked and processed by the repo's PR agent: a phase card per PR, receipts at every transition, and merges only after a maintainer `/LGTM` passes the five guards. The agent is advisory everywhere except the guarded merge — see the [PR workflow](pr-workflow.html).

The full model — path matrix, reviewer responsibilities, maintainer nomination — is [MAINTAINERS.md](https://github.com/redhat-cop/skills/blob/main/MAINTAINERS.md) in the repo.
