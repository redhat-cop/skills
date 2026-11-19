# Contributing

Thanks for contributing a skill. This document is the contract: what a skill looks like here, the quality bar, and how it gets merged.

## Before you start

- One skill per PR, one clear purpose. If two ideas keep showing up together, ship the workflow as one skill.
- Open a ["Skill proposal" issue](https://github.com/redhat-cop/skills/issues/new?template=skill-proposal.yml) first for anything new — it catches overlap and naming early. Bug fixes to existing skills don't need one.
- Check the existing catalog for overlap; extend rather than duplicate.

## Anatomy of a skill

```
skills/<skill-name>/
├── SKILL.md          # required — frontmatter + instructions
├── references/       # optional — docs the agent reads on demand
├── scripts/          # optional — deterministic helpers the agent runs
├── assets/           # optional — templates, images, data files
├── examples/         # optional — input/output examples
└── evals/evals.json  # optional — checked-in test prompts (see Evals)
```

One level only: `skills/<skill-name>/SKILL.md`. Deeper nesting is invisible to some harnesses (Pi, Oh My Pi, DeepSeek) and rejected by CI.

## Frontmatter contract

Everything not defined by the [Agent Skills spec](https://agentskills.io/specification) goes in `metadata`, so skills stay portable:

```yaml
---
name: my-skill                    # kebab-case, <=64 chars, must equal the directory name
description: >-                   # what it does + when to use it; <=500 chars hard, <=200 target
  Provisions a kind cluster with OpenShift AI. Use when the user asks to
  "set up a local cluster", "demo environment", or "sandbox RHOAI".
license: Apache-2.0
allowed-tools: Read Grep Bash     # optional; space-separated; scope narrowly
metadata:
  version: "0.1.0"                # semver, required
  maturity: experimental          # experimental | stable | deprecated, required
  owner: github-handle            # required; who reviews changes to this skill
  domain: openshift               # optional free tag, shows in the index
---
```

Rules the validator enforces (blocking):

- `name` — kebab-case, ≤64 chars, matches the directory
- `description` — non-empty, no angle brackets, ≤500 chars (DeepSeek renders only name+description into its catalog and truncates at 500); target ≤200; say *when* to use it
- `metadata.version` — semver `X.Y.Z` (quote it: `version: "1.0.0"`)
- `metadata.maturity` — `experimental`, `stable`, or `deprecated`
- `metadata.owner` — GitHub handle of the skill owner
- Body starts with a `# <Title>` H1 and contains a `## When to use` section
- No hardcoded `/home/<user>/` paths — use `~/`
- No hidden unicode (zero-width, bidi controls, nbsp) — these are invisible in review and unsafe in prompts
- Skill names unique across the repo; a `CODEOWNERS` rule per skill

Warnings (non-blocking, but fix them): description >200 chars, SKILL.md >500 lines (move detail into `references/`), missing license, deprecated without `metadata.replaced-by`.

## Portability rules (all harnesses)

1. **`allowed-tools` is advisory.** Some harnesses ignore it (Kiro CLI, Qoder). Never make it the only safety mechanism — state human-approval gates in the body ("ask before running `oc apply`").
2. **No harness-only features.** No `context: fork`, no hooks in skill packages — Claude-only constructs make the skill dead weight elsewhere.
3. **Harness-neutral instructions.** No "run the `/slash-command`" phrasing; describe actions imperatively so any agent can follow them.
4. **Progressive disclosure.** Keep SKILL.md under 500 lines; put detail in `references/` with "when to read this" pointers; deterministic steps become `scripts/`.

## Quality bar

Your PR must include **validation evidence** — at least one of:

- You ran the skill's workflow on realistic inputs and say what happened
- A peer confirms they ran it (in the PR thread)
- A checked-in `evals/evals.json` with concrete assertions
- Explicit test steps a reviewer can follow

Also expected: example input/output in the skill (or `examples/`), MCP servers / env vars / network access documented (`compatibility` frontmatter when needed), and `allowed-tools` scoped to exactly what the skill calls.

## Evals

Eval suites live at `skills/<name>/evals/evals.json`:

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": "basic-invocation",
      "prompt": "Scaffold a kind cluster with OpenShift AI",
      "assertions": [
        "The output contains the text \"kind create cluster\"."
      ]
    }
  ]
}
```

CI validates structure (ids unique, fixture files exist); it never runs model calls (repo policy: no LLM keys in CI). Run evals locally — the recommended loop is the [skill-creator](skills/skill-creator/) paired-with/without-skill benchmark: run each prompt with and without the skill, grade assertions, compare.

## Generated files

The skill table in README.md is generated from frontmatter between `<!-- GENERATED:INDEX:START/END -->` markers. After adding or renaming a skill, run `make index` and commit the result — CI fails on stale indexes. Never hand-edit inside the markers.

## Submitting

1. Branch: `skill/<name>`, `fix/<topic>`, or `docs/<topic>`
2. `make lint` — validator, index check, eval check, tests
3. Open the PR using the template (checkboxes included)
4. Review tiers: skill changes need the skill `owner` + ≥1 maintainer; repo tooling and governance files need ≥1 maintainer (structural changes: two maintainers — see [MAINTAINERS.md](MAINTAINERS.md))
5. Merge: a maintainer comments `/LGTM` and the PR agent squash-merges after re-verifying its guards (`/cancel` abandons the PR — see the [PR workflow](docs/pages/pr-workflow.md))
6. `maturity: experimental` for new skills; promote to `stable` in a follow-up PR once proven in the field

## Automated PR workflow

You don't need to do anything special for a PR to be reviewed — opening it is enough. The repo's PR agent immediately tracks it on a **phase card** (an issue labelled `phase/backlog`) and drives it through **Backlog → Doing → Review → Done**, posting receipts at every step:

- **Triage** — what the change is, its size/risk, which CI jobs matter
- **Checks** — a GREEN/RED/PENDING report from CI (push again and the card re-enters Doing automatically)
- **Review** — an advisory pass against the contribution contract above
- **Merge** — only after a maintainer `/LGTM` **and** five guards re-verified at merge time (right repo, maintainer approval, green checks, reviewed head SHA unchanged, mergeable)

Maintainers steer with two commands, each on its own line: **`/LGTM`** (approve merge) and **`/cancel`** (abandon — closes the PR and the card). The full story, including how to run the agent on your own fork, is the [PR workflow page](docs/pages/pr-workflow.md).

## Local development

```bash
make setup    # install dev deps (pyyaml, pytest, ruff)
make lint     # everything CI runs
make test     # validator/index/evals test suite
make validate # just the skill validator
```

## License & provenance

Everything lands under the repo's [Apache-2.0](LICENSE). Skills ported from elsewhere: state the provenance (source repo + license) in the skill body and drop their bundled license files — the root LICENSE covers them. Bundled third-party code (fonts, libraries) gets attributed in `THIRD_PARTY_NOTICES.md`.

## Deprecation

Set `maturity: deprecated` (plus `metadata.replaced-by` when a successor exists) and note the reason in the description. Deprecated skills ship for at least a quarter, then removal is a routine PR.
