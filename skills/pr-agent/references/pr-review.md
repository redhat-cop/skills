# PR review (Review phase)

## When to use

- A card just entered `phase/review` (checks green).
- Re-reviewing after head moved (card bounced back through Doing).

## Procedure

1. **Fetch the PR review surface**: `gh pr diff <n> --repo
   "${OCLAW_PR_REPO:-redhat-cop/skills}"` and `gh pr view <n> --json
   body,title` (the PR template answers). For skill changes, read the touched
   `SKILL.md` files in full from the diff.

2. **Check against the contribution contract** (from the watched repo's
   CONTRIBUTING / PR template — inspect the PR, do not assume):

   - [ ] Frontmatter contract: `name` kebab == dir name, `description` what+when
         ≤500 chars, `license: Apache-2.0`, `metadata.version` semver bumped in
         the same PR, `maturity` valid, `metadata.owner` = a GitHub handle.
   - [ ] Body: `# Title` H1, `## When to use` present, no `/home/<user>/`
         paths, harness-neutral instructions, ≤500 lines.
   - [ ] One skill per PR; new `skills/<name>/` dir has a matching CODEOWNERS
         line (the validator enforces — confirm it's in the diff).
   - [ ] Generated files updated if needed (`README.md` index table between the
         GENERATED markers — CI drift-checks it).
   - [ ] `evals/evals.json` checked in for skill changes (never run in CI).
   - [ ] No secrets, no provider-token-shaped strings.
   - [ ] PR template checkboxes honest; validation evidence present for skill
         changes.

3. **Post the review on the PR** (the author reads it there):

```bash
gh pr comment <n> --repo "${OCLAW_PR_REPO:-redhat-cop/skills}" --body-file - <<'EOF'
## 🤖 Agent review (automated, advisory)

<findings against the checklist above — facts and contract citations only>

`LGTM` decisions stay with the human maintainers.
EOF
```

4. **Record the digest + SHA marker on the card** (this is what the merge path
   ([pr-done.md](pr-done.md)) and the tick's SHA guard read):

```bash
skills/pr-agent/scripts/pr_card.sh comment <card-issue> <<EOF
## 🤖 Review digest

**Verdict:** <clean | findings noted on PR>
**Contract:** <pass | issues: <count>>
**Summary:** <one paragraph>

LGTM-SHA: <full headRefOid>
_Merging requires maintainer /LGTM, green checks, and this SHA unchanged._
EOF
```

The `LGTM-SHA:` line is load-bearing — always the full 40-char headRefOid.

## Rules

- The agent never grants LGTM itself; `/LGTM` comes only from a maintainer
  (`OCLAW_PR_MAINTAINERS`, default `eformat`, `hultzj`).
- Advisory tone on the PR; hard contract facts on the card.
- If checks were green but the diff looks wrong, say so on the card — Review
  exists precisely so a human looks before merge.
