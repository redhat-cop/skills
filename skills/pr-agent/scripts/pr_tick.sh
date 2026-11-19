#!/usr/bin/env bash
# pr_tick.sh — one PR-agent poll tick: reconcile PRs with phase cards.
#
# Read-only GitHub queries ALWAYS execute (this is what makes dry-run useful).
# Mutations (card creation, label swaps, claims, cancels, regression comments)
# only execute with OCLAW_PR_LIVE=1; otherwise the exact gh command is printed.
#
# The tick performs ONLY mechanical state ops. Judgment calls (triage text,
# review content, merge execution) belong to the agent following
# skills/pr-agent/POLL.md and the phase skills.
#
# NOTE: requires ONLY gh (its embedded jq via --jq) — no system jq. Never
# download/install tools to compensate for missing binaries; report instead.
#
# Env:
#   OCLAW_PR_REPO        watched repo          (default redhat-cop/skills)
#   OCLAW_PR_LIVE        1 = perform mutations (default 0 = dry-run)
#   OCLAW_PR_MAINTAINERS comma-separated logins who may /LGTM and /cancel
#                                              (default eformat,hultzj)
#   OCLAW_PR_MAX_CLAIM   backlog cards claimed per tick (default 1)
set -euo pipefail

REPO="${OCLAW_PR_REPO:-redhat-cop/skills}"
LIVE="${OCLAW_PR_LIVE:-0}"
MAINTAINERS="${OCLAW_PR_MAINTAINERS:-eformat,hultzj}"
MAX_CLAIM="${OCLAW_PR_MAX_CLAIM:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || die "gh is required"

mode_label() { [ "$LIVE" = "1" ] && echo "LIVE" || echo "DRY-RUN"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mutate() {
  if [ "$LIVE" = "1" ]; then "$@"; else printf '[DRYRUN] %s\n' "$*"; fi
}
is_maintainer() {
  local login; login="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case ",$(printf '%s' "$MAINTAINERS" | tr '[:upper:]' '[:lower:]')," in
    *,"$login",*) return 0 ;; *) return 1 ;; esac
}

printf '# PR agent tick — %s — repo %s — mode %s\n' "$(now)" "$REPO" "$(mode_label)"

# ---------- gather state (read-only; all filtering inside gh --jq) ----------
prs_tsv="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,url,isDraft,author,createdAt,headRefName,headRefOid \
  --jq '.[] | [.number, .title, .url, .isDraft, .author.login, .createdAt, .headRefOid] | @tsv')" \
  || die "gh pr list failed — check gh auth / egress"

issues_tsv="$(gh issue list --repo "$REPO" --state all --limit 300 \
  --json number,title,body,state,url,labels,createdAt \
  --jq '.[]
    | select(any(.labels[]?; (.name // "") | startswith("phase/")))
    | [(.number | tostring), .state, (.createdAt // ""), (.body // "")] | @tsv')" \
  || die "gh issue list failed — check gh auth / egress"

open_pr_urls="$(printf '%s\n' "$prs_tsv" | awk -F'\t' '{print $3}')"

# index: pr_url -> "issue<TAB>state"  (marker line in card body: "PR: <url>";
# @tsv bodies are single-line with \n escapes, so grep works per line)
declare -A CARD_NUM CARD_STATE CARD_CREATED
while IFS=$'\t' read -r cnum cstate ccreated cbody; do
  [ -n "${cnum:-}" ] || continue
  url="$(printf '%s' "${cbody:-}" | grep -oE 'https://github\.com/[^ )"]+/pull/[0-9]+' | head -1 || true)"
  [ -n "$url" ] || continue
  CARD_NUM["$url"]="$cnum"; CARD_STATE["$url"]="$cstate"; CARD_CREATED["$url"]="$ccreated"
done < <(printf '%s\n' "$issues_tsv")

# ---------- 1. reconcile: missing cards for open PRs ----------
printf '\n## Reconcile — open PRs\n'
created=0
while IFS=$'\t' read -r num title url draft author; do
  [ -n "${url:-}" ] || continue
  if [ "${CARD_NUM[$url]+set}" != "set" ]; then
    if [ "$draft" = "true" ]; then
      printf '  skip  PR #%s (draft, no card until marked ready) %s\n' "$num" "$title"
      continue
    fi
    printf '  missing card for PR #%s %s (%s)\n' "$num" "$title" "$author"
    mutate "$SCRIPT_DIR/pr_card.sh" create "$url"
    created=$((created + 1))
  else
    printf '  ok    PR #%s ↔ card #%s\n' "$num" "${CARD_NUM[$url]}"
  fi
done < <(printf '%s\n' "$prs_tsv" | awk -F'\t' '{print $1"\t"$2"\t"$3"\t"$4"\t"$5}')

# ---------- 2. orphan cards: open card whose PR is closed ----------
printf '\n## Cancel sweep — open cards whose PR closed\n'
cancelled=0; done_ext=0
while IFS=$'\t' read -r num state url; do
  [ -n "${num:-}" ] || continue
  [ "$state" = "open" ] || continue
  [ -n "$url" ] || continue
  if grep -qxF "$url" <<< "$open_pr_urls"; then continue; fi
  prn="${url##*/}"
  pr_state="$(gh pr view "$prn" --repo "$REPO" --json state,merged \
    --jq '[.state, .merged] | @tsv')" \
    || { printf '  warn  card #%s: PR #%s lookup failed\n' "$num" "$prn"; continue; }
  if [ "$(cut -f2 <<< "$pr_state")" = "true" ]; then
    printf '  merged-externally  card #%s / PR #%s -> phase/done\n' "$num" "$prn"
    mutate "$SCRIPT_DIR/pr_card.sh" set-phase "$num" done
    mutate "$SCRIPT_DIR/pr_card.sh" comment "$num" \
      < <(printf '_🤖 PR #%s was merged externally — closing card as Done._\n' "$prn")
    mutate "$SCRIPT_DIR/pr_card.sh" close "$num"
    done_ext=$((done_ext + 1))
  else
    printf '  closed-unmerged    card #%s / PR #%s -> phase/cancelled\n' "$num" "$prn"
    mutate "$SCRIPT_DIR/pr_card.sh" set-phase "$num" cancelled
    mutate "$SCRIPT_DIR/pr_card.sh" comment "$num" \
      < <(printf '_🤖 PR #%s was closed without merging — card cancelled._\n' "$prn")
    mutate "$SCRIPT_DIR/pr_card.sh" close "$num"
    cancelled=$((cancelled + 1))
  fi
done < <(printf '%s\n' "$issues_tsv" | awk -F'\t' '{print $1"\t"$2"\t"$4}')

# ---------- 3. claim oldest backlog card ----------
printf '\n## Claim\n'
claimed=""
claimed_count=0
# backlog cards: state open + label phase/backlog, oldest first.
backlog_tsv="$(gh issue list --repo "$REPO" --state open --limit 100 \
  --label phase/backlog --json number,createdAt,body \
  --jq 'sort_by(.createdAt) | .[] | [(.number | tostring), .createdAt, (.body // "")] | @tsv')"
while IFS=$'\t' read -r bnum bcreated bbody; do
  [ -n "${bnum:-}" ] || continue
  [ "$claimed_count" -lt "$MAX_CLAIM" ] || break
  url="$(printf '%s' "${bbody:-}" | grep -oE 'https://github\.com/[^ )"]+/pull/[0-9]+' | head -1 || true)"
  [ -n "$url" ] || { printf '  warn  backlog card #%s has no PR marker\n' "$bnum"; continue; }
  prn="${url##*/}"
  printf '  claim card #%s (PR #%s)\n' "$bnum" "$prn"
  mutate "$SCRIPT_DIR/pr_card.sh" set-phase "$bnum" doing
  mutate "$SCRIPT_DIR/pr_card.sh" comment "$bnum" \
    < <(printf '_🤖 claimed by pr-agent tick %s — moving to Doing (checks)._\n' "$(now)")
  claimed="$claimed PR#$prn"
  claimed_count=$((claimed_count + 1))
done <<< "$backlog_tsv"

# ---------- 4. LGTM / cancel scan on Review cards ----------
printf '\n## Review scan (/LGTM, /cancel, SHA guard)\n'
review_tsv="$(gh issue list --repo "$REPO" --state open --limit 100 \
  --label phase/review --json number,body \
  --jq '.[] | [(.number | tostring), (.body // "")] | @tsv')"
while IFS=$'\t' read -r num body; do
  [ -n "${num:-}" ] || continue
  url="$(printf '%s' "${body:-}" | grep -oE 'https://github\.com/[^ )"]+/pull/[0-9]+' | head -1 || true)"
  [ -n "$url" ] || { printf '  warn  review card #%s has no PR marker\n' "$num"; continue; }
  prn="${url##*/}"
  head_oid="$(gh pr view "$prn" --repo "$REPO" --json headRefOid --jq .headRefOid)" \
    || { printf '  warn  PR #%s lookup failed\n' "$prn"; continue; }
  mergeable="$(gh pr view "$prn" --repo "$REPO" --json mergeable --jq .mergeable)"

  # (login, body) pairs: PR issue comments + card comments + PR reviews
  comments="$(
    {
      gh pr view "$prn" --repo "$REPO" --json comments \
        --jq '.comments[] | [.author.login, .body] | @tsv' || true
      gh issue view "$num" --repo "$REPO" --json comments \
        --jq '.comments[] | [.author.login, .body] | @tsv' || true
      gh api "repos/$REPO/pulls/$prn/reviews" --jq \
        '.[] | select(.body != "") | [.user.login, .body] | @tsv' || true
    } 2>/dev/null || true
  )"

  # /LGTM and /cancel must be on their own line (line-anchored; in @tsv bodies
  # real newlines appear as literal "\n"). This prevents the agent's own
  # receipts (which mention the tokens mid-sentence) from counting as votes.
  lgtm_by="$(printf '%s' "$comments" | awk -F'\t' '$2 ~ /(^|\\n)\/LGTM/ {print $1}' | tail -1)"
  cancel_by="$(printf '%s' "$comments" | awk -F'\t' '$2 ~ /(^|\\n)\/cancel/ {print $1}' | tail -1)"
  recorded_sha="$(printf '%s' "$comments" | grep -oE 'LGTM-SHA: [0-9a-f]{7,40}' | tail -1 | cut -d' ' -f2)"

  if [ -n "$cancel_by" ] && is_maintainer "$cancel_by"; then
    printf '  /cancel by @%s on card #%s (PR #%s) -> phase/cancelled\n' "$cancel_by" "$num" "$prn"
    mutate "$SCRIPT_DIR/pr_card.sh" set-phase "$num" cancelled
    mutate "$SCRIPT_DIR/pr_card.sh" comment "$num" \
      < <(printf '_🤖 /cancel by @%s — card cancelled._\n' "$cancel_by")
    mutate "$SCRIPT_DIR/pr_card.sh" close "$num"
    continue
  fi

  if [ -n "$lgtm_by" ] && is_maintainer "$lgtm_by"; then
    if [ -n "$recorded_sha" ] && [ "$recorded_sha" != "$head_oid" ]; then
      printf '  head moved since LGTM on PR #%s (recorded %s, now %s) -> back to Doing\n' \
        "$prn" "${recorded_sha:0:12}" "${head_oid:0:12}"
      mutate "$SCRIPT_DIR/pr_card.sh" set-phase "$num" doing
      mutate "$SCRIPT_DIR/pr_card.sh" comment "$num" \
        < <(printf '_🤖 head moved since /LGTM (recorded `%s`, now `%s`) — re-running checks._\n' \
             "$recorded_sha" "$head_oid")
    else
      printf '  READY-TO-MERGE PR #%s card #%s: /LGTM by @%s, head %s, mergeable %s\n' \
        "$prn" "$num" "$lgtm_by" "${head_oid:0:12}" "$mergeable"
      printf '        -> run skills/pr-agent/references/pr-done.md merge path for PR #%s\n' "$prn"
    fi
  else
    printf '  waiting PR #%s card #%s: no maintainer /LGTM yet (head %s)\n' \
      "$prn" "$num" "${head_oid:0:12}"
  fi
done <<< "$review_tsv"

# ---------- 4b. re-check scan on Doing cards (mechanical) ----------
# A Doing card needs re-checks when its last `checks @ <sha>` report predates
# the current head SHA (author pushed) — emitted mechanically so the agent
# doesn't have to judge. The agent runs skills/pr-agent/references/pr-checks.md inline for
# each RECHECK finding (and posts a fresh report).
printf '\n## Re-check scan (Doing cards, head-SHA comparison)\n'
doing_tsv="$(gh issue list --repo "$REPO" --state open --limit 100 \
  --label phase/doing --json number,body \
  --jq '.[] | [(.number | tostring), (.body // "")] | @tsv')"
while IFS=$'\t' read -r dnum dbody; do
  [ -n "${dnum:-}" ] || continue
  url="$(printf '%s' "${dbody:-}" | grep -oE 'https://github\.com/[^ )"]+/pull/[0-9]+' | head -1 || true)"
  [ -n "$url" ] || continue
  prn="${url##*/}"
  head_oid="$(gh pr view "$prn" --repo "$REPO" --json headRefOid --jq .headRefOid)" \
    || { printf '  warn  PR #%s lookup failed\n' "$prn"; continue; }
  last_report_sha="$(gh issue view "$dnum" --repo "$REPO" --json comments \
    --jq '.comments | map(.body) | join("\n")' 2>/dev/null \
    | grep -oE 'checks @ .[0-9a-f]{7,40}.' | tail -1 | grep -oE '[0-9a-f]{7,40}' || true)"
  if [ -z "$last_report_sha" ]; then
    printf '  RECHECK  card #%s (PR #%s): no checks report yet — run pr-checks inline\n' "$dnum" "$prn"
  elif [ "$head_oid" != "$last_report_sha" ] && [[ "$head_oid" != "$last_report_sha"* ]]; then
    printf '  RECHECK  card #%s (PR #%s): report %s predates head %s — run pr-checks inline\n' \
      "$dnum" "$prn" "${last_report_sha:0:12}" "${head_oid:0:12}"
  else
    printf '  ok       card #%s (PR #%s): report matches head %s\n' "$dnum" "$prn" "${head_oid:0:12}"
  fi
done <<< "$doing_tsv"

# ---------- summary ----------
printf '\n## Summary\n'
printf -- '- cards created: %s\n' "$created"
printf -- '- cancelled: %s, done-externally: %s\n' "$cancelled" "$done_ext"
printf -- '- claimed: %s\n' "$([ -n "$claimed" ] && echo "$claimed" || echo "none")"
if [ "$LIVE" != "1" ]; then
  printf -- '- mode: DRY-RUN (no mutations performed; set OCLAW_PR_LIVE=1 to apply)\n'
fi
