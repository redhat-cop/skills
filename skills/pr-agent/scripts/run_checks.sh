#!/usr/bin/env bash
# run_checks.sh — PR checks runner (Doing phase). Emits a markdown report.
#
# Read-only except the throwaway scratch checkout. Never comments, never
# merges, never transitions cards — the caller (pr-checks skill) owns those.
#
# Env:
#   OCLAW_PR_REPO         watched repo (default eformat/redhat-cop-skills)
#   OCLAW_PR_LOCAL_LINT   1 = also run the repo's local `make lint` in the
#                         scratch checkout (needs python3/pytest/ruff; skipped
#                         gracefully when absent)
#   OCLAW_PR_WORKDIR      scratch root (default ${TMPDIR:-/tmp}/oclaw-pr-agent)
set -euo pipefail

REPO="${OCLAW_PR_REPO:-eformat/redhat-cop-skills}"
LOCAL_LINT="${OCLAW_PR_LOCAL_LINT:-0}"
WORKDIR="${OCLAW_PR_WORKDIR:-${TMPDIR:-/tmp}/oclaw-pr-agent}"

# OCE credential delivery is per-destination (see scripts/pr_tick.sh):
# gh REST wants $GITHUB_TOKEN_API; git-over-https to github.com wants
# $GITHUB_TOKEN_WEB via a credential helper. Local fallbacks: keyring/gh auth.
export GH_TOKEN="${GITHUB_TOKEN_API:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
for bin in gh git; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done
# NOTE: requires ONLY gh (embedded jq via --jq) — no system jq. Never
# download/install tools to compensate for missing binaries; report instead.

pr="${1:?usage: run_checks.sh <pr-number>}"
pr="$(printf '%s' "$pr" | grep -oE '[0-9]+$')"

head_oid="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
short_oid="${head_oid:0:12}"

printf '### 🤖 pr-agent checks @ `%s`\n\n' "$short_oid"
printf '| field | value |\n|---|---|\n'
gh pr view "$pr" --repo "$REPO" \
  --json title,author,headRefName,baseRefName,additions,deletions,changedFiles,isDraft \
  --jq '[["PR", "#'"$pr"'"],
        ["Title", .title],
        ["Author", "@" + .author.login],
        ["Branch", "`" + .headRefName + "` → `" + .baseRefName + "`"],
        ["Diff", (.changedFiles | tostring) + " files, +" + (.additions | tostring) + "/-" + (.deletions | tostring)],
        ["Draft", (.isDraft | tostring)]] | .[] | @tsv' |
while IFS=$'\t' read -r k v; do printf '| %s | %s |\n' "$k" "$v"; done

# ---------- CI checks (remote, always) ----------
printf '\n#### CI\n\n'
checks_out="$(mktemp)"
checks_rc=0
gh pr checks "$pr" --repo "$REPO" > "$checks_out" 2>&1 || checks_rc=$?
# gh exit codes: 0 = all passed, 1 = failure, 8 = pending
if grep -q "no checks reported" "$checks_out"; then
  ci_verdict="PENDING"
  printf '_No CI checks reported yet (workflows may not have started)._\n'
elif [ ! -s "$checks_out" ]; then
  ci_verdict="PENDING"
  printf '_No CI checks reported._\n'
else
  printf '| check | result | elapsed | log |\n|---|---|---|---|\n'
  while IFS=$'\t' read -r name status elapsed url _; do
    [ -n "${name:-}" ] || continue
    icon="⚪"
    case "$status" in
      pass) icon="✅" ;;
      fail) icon="❌" ;;
      pending*) icon="⏳" ;;
      skipping) icon="⏭" ;;
    esac
    logcell="-"
    [ -n "${url:-}" ] && logcell="[job]($url)"
    printf '| %s | %s %s | %s | %s |\n' "$name" "$icon" "$status" "${elapsed:--}" "$logcell"
  done < "$checks_out"
  if [ "$checks_rc" = "8" ]; then ci_verdict="PENDING"; elif [ "$checks_rc" = "0" ]; then ci_verdict="GREEN"; else ci_verdict="RED"; fi
fi
rm -f "$checks_out"

# ---------- local gate (optional) ----------
local_verdict="skipped (set OCLAW_PR_LOCAL_LINT=1)"
if [ "$LOCAL_LINT" = "1" ]; then
  scratch="$WORKDIR/pr-$pr"
  # git-over-https needs the WEB destination token when running in the OCE
  # sandbox; locally fall back to gh's keyring auth.
  git_credential_args=()
  if [ -n "${GITHUB_TOKEN_WEB:-}" ]; then
    git_credential_args=(
      -c credential.helper='!f() { printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN_WEB"; }; f'
    )
  fi
  if [ -d "$scratch/.git" ]; then
    git -C "$scratch" fetch --force origin "pull/$pr/head" >/dev/null 2>&1
  else
    mkdir -p "$(dirname "$scratch")"
    if [ ${#git_credential_args[@]} -gt 0 ]; then
      git "${git_credential_args[@]}" clone --depth 50 "https://github.com/$REPO.git" "$scratch" >/dev/null 2>&1
      git -C "$scratch" fetch origin "pull/$pr/head" >/dev/null 2>&1
    else
      gh repo clone "$REPO" "$scratch" -- --depth 50 >/dev/null 2>&1
      git -C "$scratch" fetch origin "pull/$pr/head" >/dev/null 2>&1
    fi
  fi
  git -C "$scratch" checkout --force --detach FETCH_HEAD >/dev/null 2>&1
  lint_log="$(mktemp)"
  if command -v make >/dev/null 2>&1 && [ -f "$scratch/Makefile" ]; then
    if ( cd "$scratch" && timeout 900 make lint ) > "$lint_log" 2>&1; then
      local_verdict="GREEN"
    else
      local_verdict="RED"
    fi
  else
    local_verdict="skipped (make/Makefile unavailable)"
  fi
  printf '\n#### Local gate (make lint @ %s)\n\n' "$short_oid"
  printf '| gate | result |\n|---|---|\n| local make lint | %s |\n\n' "$local_verdict"
  printf '<details><summary>local lint output (last 40 lines)</summary>\n\n```\n%s\n```\n\n</details>\n' "$(tail -40 "$lint_log")"
  rm -f "$lint_log"
fi

# ---------- findings placeholder (agent fills this in) ----------
printf '\n#### Findings\n\n_(pr-agent: replace this line with factual observations as bullets — contract/layout/frontmatter/PR-template items; delete the section if there are none)_\n'

# ---------- verdict ----------
printf '\n#### Verdict\n\n'
if [ "$ci_verdict" = "GREEN" ] && { [ "$local_verdict" = "GREEN" ] || [[ "$local_verdict" == skipped* ]]; }; then
  printf '**✅ GREEN** — checks pass. Card moves to `phase/review`; maintainer `/LGTM` required to merge.\n'
elif [ "$ci_verdict" = "PENDING" ]; then
  printf '**⏳ PENDING** — CI still running; the next tick re-checks. Card stays in `phase/doing`.\n'
else
  printf '**❌ RED** (ci=%s, local=%s) — changes requested from the author; card stays in `phase/doing` until checks go green.\n' \
    "$ci_verdict" "$local_verdict"
fi
