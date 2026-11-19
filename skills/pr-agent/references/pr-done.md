# PR done (merge path)

## When to use

- The tick printed `READY-TO-MERGE` for a Review card.
- Never speculatively: this procedure is only entered after `/LGTM` was
  detected.

## The five guards (re-verify ALL, right now — do not trust the tick's cache)

```bash
repo="${OCLAW_PR_REPO:-redhat-cop/skills}"
# 0. REPO IDENTITY — the PR lives in the watched repo, nowhere else
url="$(gh pr view <n> --repo "$repo" --json url --jq .url)"
case "$url" in
  "https://github.com/$repo/pull/"*) : ;;                     # ok
  *) die-or-abort ;;                                          # wrong repo → never merge
esac
# 1. maintainer /LGTM present (scan PR comments + reviews + card comments)
#    author login ∈ OCLAW_PR_MAINTAINERS (default eformat,hultzj)
# 2. checks green RIGHT NOW
gh pr checks <n> --repo "$repo"
# 3. head SHA unchanged since the review that recorded LGTM-SHA:
current="$(gh pr view <n> --repo "$repo" --json headRefOid --jq .headRefOid)"
recorded="<LGTM-SHA from the card>"          # grep the card comments
[ "$current" = "$recorded" ]                 # mismatch → abort, back to Doing
# 4. mergeable
gh pr view <n> --repo "$repo" --json mergeable --jq .mergeable
#    must be MERGEABLE (CONFLICTING/UNKNOWN → abort with a card note)
```

**If any guard fails:** do not merge. Comment the failure on the card and move
the card accordingly (`phase/doing` for head-moved/pending checks; stay in
`phase/review` for missing LGTM).

## Merge (all five guards green, live mode)

```bash
gh pr merge <n> --repo "$repo" --squash
```

- The agent merges ONLY in live mode (`OCLAW_PR_LIVE=1`), ONLY after the guards.
- No force-push, no direct pushes to `main`, no merge-commit strategy.

## Receipt + Done

```bash
sha="$(gh pr view <n> --repo "$repo" --json mergeCommit --jq .mergeCommit.oid)"
skills/pr-agent/scripts/pr_card.sh comment <card-issue> <<EOF
## 🤖 Merged (Done)

- squash-merged by the pr-agent on maintainer /LGTM (@<login>)
- merge commit: <sha>
- guards at merge time: /LGTM ✅ checks ✅ SHA ✅ mergeable ✅

Thanks @<author>!
EOF
skills/pr-agent/scripts/pr_card.sh set-phase <card-issue> done
skills/pr-agent/scripts/pr_card.sh close <card-issue>
```

If the PR was already merged externally, post the "merged externally" receipt
instead and close the card as `phase/done` (the tick also handles this case).
