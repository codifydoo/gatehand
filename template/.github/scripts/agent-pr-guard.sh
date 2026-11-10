#!/usr/bin/env bash
# .github/scripts/agent-pr-guard.sh
# The `agent pr guard` check: rules an agent PR must meet, enforced by CI rather than by trusting
# the outbox that opened it. It passes every PR not opened by the agent bot, so it can be a required
# check on main without touching human PRs.
#
# For a PR whose author is policy.botLogin it fails when:
#   - a changed path is a `!` line of .github/agents/protected-paths.txt, whatever the labels;
#   - a changed path is protected and the PR does not carry `agent:allow-protected` applied by the
#     agent bot itself (the outbox sets it at creation, and only when a writer put it on the issue;
#     a triage collaborator adding it to the PR later does not count);
#   - the body lacks `Refs #N`, or the title, body or any commit uses a closing keyword;
#   - the repo's own rule says so: agent_hook_pr_guard <labels> <files-file>, when
#     .github/agents/hooks/lib.sh defines it, prints its own "FAIL: …" lines (a label-scoped path
#     rule, say: the fixer may push to any agent PR, so a scope has to be checked here).
#
# RUNS FROM THE BASE BRANCH. The workflow checks out the PR's BASE commit, not its head, so this
# script and the protected list are main's copies. An agent PR that edits either cannot use that
# edit to pass. The PR's files and commits come from the API, never from its checkout.
#
# Usage: agent-pr-guard.sh
# Env:   PR_NUMBER, PR_AUTHOR, PR_TITLE, PR_BODY, PR_LABELS_JSON (a JSON array of names), GH_TOKEN,
#        GH_REPO;
#        AGENT_PR_GUARD_NO_MAIN=1 loads the functions only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-lib.sh"

# guard_decide <author> <title> <body-file> <labels> <files-file> <messages-file>: prints one
# "FAIL: …" line per broken rule; nothing when the PR passes.
guard_decide() {
  local author="$1" title="$2" body="$3" labels="$4" files="$5" msgs="$6" hits
  [[ "${author}" == "$(policy '.botLogin')" ]] || return 0
  hits="$(never_hits <"${files}")"
  if [[ -n "${hits}" ]]; then
    printf 'FAIL: touches paths no label unlocks (a person makes these changes): %s\n' "$(tr '\n' ' ' <<<"${hits}")"
  fi
  hits="$(protected_hits <"${files}")"
  if [[ -n "${hits}" ]] && ! grep -Fxq 'agent:allow-protected' <<<"${labels}"; then
    printf 'FAIL: touches protected paths without agent:allow-protected: %s\n' "$(tr '\n' ' ' <<<"${hits}")"
  fi
  if declare -F agent_hook_pr_guard >/dev/null; then
    local out rc=0
    out="$(agent_hook_pr_guard "${labels}" "${files}" </dev/null)" || rc=$?
    grep '^FAIL: ' <<<"${out}"
    # A hook that errors (an unset variable, a failed API call) has not said the PR is fine.
    [[ "${rc}" -eq 0 ]] || printf 'FAIL: the repo'"'"'s guard hook (agent_hook_pr_guard) failed with exit %s\n' "${rc}"
  fi
  grep -Eq '(^|[^[:alnum:]_])Refs #[0-9]+' "${body}" || printf 'FAIL: the body has no Refs #N\n'
  if printf '%s\n' "${title}" | has_closing_keyword || has_closing_keyword <"${body}"; then
    printf 'FAIL: the title or body uses a closing keyword; agent PRs say Refs #N\n'
  fi
  if has_closing_keyword <"${msgs}"; then
    printf 'FAIL: a commit message uses a closing keyword\n'
  fi
}

main() {
  local body files msgs verdict line labels
  if [[ "${PR_AUTHOR:-}" != "$(policy '.botLogin')" ]]; then
    echo "Not an agent PR (author ${PR_AUTHOR:-unknown}): nothing to check."
    return 0
  fi
  body="$(mktemp)"; files="$(mktemp)"; msgs="$(mktemp)"
  printf '%s\n' "${PR_BODY:-}" >"${body}"
  gh api --paginate "repos/${GH_REPO}/pulls/${PR_NUMBER:?}/files?per_page=100" \
    --jq '.[] | .filename, (.previous_filename // empty)' >"${files}" || { echo "::error::could not list the PR's files"; return 1; }
  gh api --paginate "repos/${GH_REPO}/pulls/${PR_NUMBER}/commits?per_page=100" \
    --jq '.[].commit.message' >"${msgs}" || { echo "::error::could not list the PR's commits"; return 1; }
  labels="$(jq -r '.[]' <<<"${PR_LABELS_JSON:-[]}")"
  if grep -Fxq 'agent:allow-protected' <<<"${labels}" && ! is_agent_bot "$(label_applier "${PR_NUMBER}" agent:allow-protected)"; then
    echo "::warning::agent:allow-protected on this PR was not applied by the agent bot; ignoring it"
    labels="$(grep -Fxv 'agent:allow-protected' <<<"${labels}")"
  fi
  verdict="$(guard_decide "${PR_AUTHOR}" "${PR_TITLE:-}" "${body}" "${labels}" "${files}" "${msgs}")"
  rm -f "${body}" "${files}" "${msgs}"
  if [[ -n "${verdict}" ]]; then
    while IFS= read -r line; do printf '::error::%s\n' "${line#FAIL: }"; done <<<"${verdict}"
    return 1
  fi
  echo "Agent PR #${PR_NUMBER} meets the agent rules."
}

if [[ "${AGENT_PR_GUARD_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
