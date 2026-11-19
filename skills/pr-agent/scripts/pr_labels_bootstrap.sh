#!/usr/bin/env bash
# pr_labels_bootstrap.sh — one-time creation of the phase/* labels on the
# watched repo. Idempotent: creates missing labels, fixes colors/descriptions.
# Safe to run live (label management only, no card/PR changes).
#
# Env:
#   OCLAW_PR_REPO   watched repo (default eformat/redhat-cop-skills)
#   OCLAW_PR_LIVE   1 = perform mutations (default 0 = dry-run)
set -euo pipefail

REPO="${OCLAW_PR_REPO:-eformat/redhat-cop-skills}"
LIVE="${OCLAW_PR_LIVE:-0}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || die "gh is required"

mutate() {
  if [ "$LIVE" = "1" ]; then "$@"; else printf '[DRYRUN] %s\n' "$*"; fi
}

# name color description
specs=(
  "phase/backlog|BFD4F2|PR agent: card available for work"
  "phase/doing|FBCA04|PR agent: agent is running checks"
  "phase/review|D4C5F9|PR agent: awaiting maintainer /LGTM to merge"
  "phase/done|0E8A16|PR agent: merged / complete"
  "phase/cancelled|E99695|PR agent: abandoned or cancelled"
)

printf '# PR agent labels — repo %s — mode %s\n' "$REPO" \
  "$([ "$LIVE" = "1" ] && echo LIVE || echo DRY-RUN)"

for spec in "${specs[@]}"; do
  IFS='|' read -r name color desc <<< "$spec"
  if gh label list --repo "$REPO" --search "$name" --json name \
       --jq '.[] | select(.name == "'"$name"'")' | grep -q "$name"; then
    mutate gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc"
    printf '  exists  %s\n' "$name"
  else
    mutate gh label create "$name" --repo "$REPO" --color "$color" --description "$desc"
    printf '  create  %s\n' "$name"
  fi
done

printf 'done. reminder: run with OCLAW_PR_LIVE=1 to apply.\n'
