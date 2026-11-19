#!/usr/bin/env bash
# pr_card.sh — card operations for the PR agent (find/create/phase/comment/close).
#
# Dry-run by default: mutations print the gh command instead of running it.
# Set OCLAW_PR_LIVE=1 to perform mutations. Read-only commands always run.
#
# NOTE: requires ONLY gh (embedded jq via --jq) — no system jq. Never
# download/install tools to compensate for missing binaries; report instead.
#
# Usage:
#   pr_card.sh find <pr-url>              -> "<issue-number> <state>" or nothing
#   pr_card.sh show <issue-number>        -> card JSON (read-only)
#   pr_card.sh create <pr-number-or-url>  -> create card w/ phase/backlog (live)
#   pr_card.sh set-phase <issue> <phase>  -> exactly-one phase label swap (live)
#   pr_card.sh comment <issue> [file|-]   -> append comment (live)
#   pr_card.sh close <issue>              -> close card (live)
#
# Env:
#   OCLAW_PR_REPO   watched repo (default eformat/redhat-cop-skills)
#   OCLAW_PR_LIVE   1 = perform mutations (default 0 = dry-run)
set -euo pipefail

REPO="${OCLAW_PR_REPO:-eformat/redhat-cop-skills}"
LIVE="${OCLAW_PR_LIVE:-0}"
PHASES=(backlog doing review done cancelled)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OCE credential delivery is per-destination (see pr_tick.sh): gh REST wants
# $GITHUB_TOKEN_API; local fallbacks keep keyring/single-token setups working.
export GH_TOKEN="${GITHUB_TOKEN_API:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || die "gh is required"

cmd="${1:-}"; shift || true
[ -n "$cmd" ] || die "usage: pr_card.sh <find|show|create|set-phase|comment|close> [args]"

mutate() {
  if [ "$LIVE" = "1" ]; then "$@"; else printf '[DRYRUN] %s\n' "$*"; fi
}

pr_num() { printf '%s' "$1" | grep -oE '[0-9]+$'; }

# list all phase-labelled issues (open+closed) as TSV: number state body
list_cards() {
  gh issue list --repo "$REPO" --state all --limit 300 \
    --json number,state,body \
    --jq '.[] | select(any(.labels[]?; (.name // "") | startswith("phase/")))
          | [.number, .state, (.body // "")] | @tsv'
}

# extract first PR url from a body on stdin
first_pr_url() { grep -oE 'https://github\.com/[^ )"]+/pull/[0-9]+' | head -1; }

case "$cmd" in
  find)
    url="${1:?usage: pr_card.sh find <pr-url>}"
    while IFS=$'\t' read -r num state body; do
      [ -n "${num:-}" ] || continue
      card_url="$(printf '%s' "$body" | first_pr_url || true)"
      if [ "$card_url" = "$url" ]; then printf '%s %s\n' "$num" "$state"; fi
    done < <(list_cards)
    ;;

  show)
    n="${1:?usage: pr_card.sh show <issue-number>}"
    gh issue view "$n" --repo "$REPO" --json number,title,state,url,labels,body,comments
    ;;

  create)
    pr="${1:?usage: pr_card.sh create <pr-number-or-url>}"
    n="$(pr_num "$pr")"
    existing="$("$SCRIPT_DIR/pr_card.sh" find "$(gh pr view "$n" --repo "$REPO" --json url --jq .url)")" || existing=""
    if [ -n "$existing" ]; then printf 'card exists: %s\n' "$existing"; exit 0; fi
    # title + body built entirely inside gh --jq (no system jq)
    title="$(gh pr view "$n" --repo "$REPO" --json number,title \
      --jq '"PR agent: #" + (.number | tostring) + " " + .title')"
    body="$(gh pr view "$n" --repo "$REPO" \
      --json url,author,createdAt,headRefName,baseRefName,isDraft \
      --jq '("PR: " + .url + "\n"
              + "Author: @" + .author.login + "\n"
              + "Opened: " + .createdAt + "\n"
              + "Branch: `" + .headRefName + "` → `" + .baseRefName + "`"
              + (if .isDraft then "\n**Draft PR**" else "" end) + "\n\n"
              + "## Phase checklist\n"
              + "- [ ] Backlog — triage\n- [ ] Doing — checks\n"
              + "- [ ] Review — /LGTM\n- [ ] Done — merged\n\n"
              + "_Managed by the oclaw-pr-agent automation. Maintainers: comment `/LGTM` to "
              + "approve merge, `/cancel` to abandon._')"
    mutate gh issue create --repo "$REPO" --label phase/backlog \
      --title "$title" --body-file - <<< "$body"
    ;;

  set-phase)
    issue="${1:?usage: pr_card.sh set-phase <issue> <phase>}"
    phase="${2:?usage: pr_card.sh set-phase <issue> <phase>}"
    valid=0; for p in "${PHASES[@]}"; do [ "$p" = "$phase" ] && valid=1; done
    [ "$valid" = "1" ] || die "phase must be one of: ${PHASES[*]}"
    args=()
    for p in "${PHASES[@]}"; do
      [ "$p" = "$phase" ] || args+=(--remove-label "phase/$p")
    done
    mutate gh issue edit "$issue" --repo "$REPO" "${args[@]}" --add-label "phase/$phase"
    ;;

  comment)
    issue="${1:?usage: pr_card.sh comment <issue> [file|-]}"
    file="${2:--}"
    mutate gh issue comment "$issue" --repo "$REPO" --body-file "$file"
    ;;

  close)
    issue="${1:?usage: pr_card.sh close <issue>}"
    mutate gh issue close "$issue" --repo "$REPO"
    ;;

  *) die "unknown command: $cmd" ;;
esac
