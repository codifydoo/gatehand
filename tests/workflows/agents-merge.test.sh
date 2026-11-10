#!/usr/bin/env bash
# tests/workflows/agents-merge.test.sh
# .github/scripts/agent-merge.sh (the merge gate) against a stub gh. Every condition is tested by
# starting from an all-green PR and breaking exactly that one thing, so each assertion can fail:
#   - kill switch, a tripped breaker, AGENT_AUTO_MERGE unset (dry run: reported, never merged);
#   - the PR itself: author, agent:pr, draft, fork, base, mergeable, and each blocking label;
#   - each required check, and `agent pr guard`, must be `success` in its LATEST run on the head;
#   - the newest trusted review must say Approve, be newer than the head's push, have been written by
#     a review job that started after it, and no review may still be running;
#   - no protected path and no policy.humanPaths path;
#   - the head contains main's current tip, read live, so a second PR in one run is behind once the
#     first has merged.
# Green: `gh pr merge <n> --merge --match-head-commit <sha> --delete-branch`, never --admin or --auto,
# then the issue moves to agent:done-pending-deploy. Behind main as the only blocker: update-branch
# (live runs only; a refusal asks a person, once per head), and on a head that update made, one
# fresh review once its checks pass.
# AGENT_TRUST_CACHE is reset here and read by the sourced scripts; the ( export …; green ) cases
# change their variables in a subshell on purpose, so each case starts from the all-green PR.
# shellcheck disable=SC2034,SC2030,SC2031
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agents-gh-stub.sh"
export AGENT_MERGE_NO_MAIN=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-merge.sh"
set +e

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-merge] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-merge] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export GH_REPO=o/r AGENT_NOW_EPOCH=1793880000 AGENT_LEDGER_BACKOFF=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare "${TMP}/ledger.git"
export LEDGER_REMOTE="${TMP}/ledger.git"
stub_gh_init
labels_all="$(printf '%s\n' "${AGENT_LABELS[@]}" | cut -d'|' -f1)"
HEAD=cccccccccccccccccccccccccccccccccccccccc
PUSHED=2026-11-05T10:00:00Z

# green: one all-green PR; each variable below breaks one condition when set.
prjson() { # prjson [pr] [head]
  jq -cn --argjson n "${1:-44}" --arg l "${LABELS-agent:pr}" --arg a "${AUTHOR:-app/repo-agent}" --arg m "${MERGEABLE:-MERGEABLE}" \
    --argjson d "${DRAFT:-false}" --arg base "${BASE:-main}" --arg h "${2:-${HEAD}}" --arg st "${STATE:-OPEN}" --argjson fork "${FORK:-false}" '
    {number: $n, state: $st, isDraft: $d, author: {login: $a}, mergeable: $m,
     labels: ($l | split(",") | map(select(. != "") | {name: .})), headRefName: "fix/agent-x\($n)", headRefOid: $h,
     baseRefName: $base, isCrossRepository: $fork, createdAt: "2026-11-05T09:00:00Z",
     reviews: ($ENV.REVIEWS // "[]" | fromjson),
     body: ($ENV.PR_BODY // "## What\nx\n\nRefs #7\n\n<!-- agent-run:coder run=900 issue=7 -->")}'
}
checks() { # every required check and the guard, success; CHECK_OVERRIDE="<name>|<status>|<conclusion>" adds a later run
  local name i=100 rows=()
  while IFS= read -r name; do
    i=$((i + 1))
    rows+=("$(jq -cn --argjson id "${i}" --arg n "${name}" '{id: $id, name: $n, status: "completed", conclusion: "success", app: {slug: "github-actions"}}')")
  done < <(policy '.requiredChecks[]' | grep -vxF "${CHECKS_DROP:-__none__}"; echo 'agent pr guard')
  if [[ -n "${CHECK_OVERRIDE:-}" ]]; then
    IFS='|' read -r n s c a <<<"${CHECK_OVERRIDE}"
    rows+=("$(jq -cn --arg n "${n}" --arg s "${s}" --arg c "${c}" --arg a "${a:-github-actions}" '{id: 999, name: $n, status: $s, conclusion: (if $c == "" then null else $c end), app: {slug: $a}}')")
  fi
  if [[ -n "${CHECK_EXTRA:-}" ]]; then rows+=("${CHECK_EXTRA}"); fi
  printf '%s\n' "${rows[@]}" | jq -s '{check_runs: .}'
}
REVIEW_OK=$'<!-- verify-pr-review -->\n\n### Blocking problems\nNone.\n\n### Verdict\nApprove'
# stub_pr <pr> <head>: everything about one PR: the PR, its comments (the review, then BOT_COMMENTS:
# a JSON array of the agent bot's bodies), its files, how far its head is behind main (BEHIND), the
# head's first parent (PARENT), and the branch update (UPDATE_RC/UPDATE_ERR).
stub_pr() {
  local pr="$1" head="$2" cid=$(($1 * 10))
  stub_gh_on "pr view ${pr} --json mergeCommit *" 'mmmmmmm'
  stub_gh_on "pr view ${pr} --json *" "$(prjson "${pr}" "${head}")"
  stub_gh_json "api --paginate repos/o/r/issues/${pr}/comments*" \
    "$(jq -cn --argjson id "${cid}" --arg b "${REVIEW_BODY:-${REVIEW_OK}}" --arg u "${REVIEWER:-claude[bot]}" --arg t "${REVIEW_AT:-2026-11-05T10:30:00Z}" --arg e "${REVIEW_EDITED:-}" \
      --argjson bot "${BOT_COMMENTS:-[]}" '
      [{id: $id, user: {login: $u}, created_at: $t, updated_at: (if $e == "" then $t else $e end), body: $b}]
      + ($bot | map({id: 1, user: {login: "repo-agent[bot]"}, created_at: "2026-11-05T09:10:00Z", updated_at: "2026-11-05T09:10:00Z", body: .}))')"
  stub_gh_json "api repos/o/r/issues/comments/${cid} *" "$(jq -cn --arg b "${REVIEW_BODY:-${REVIEW_OK}}" '{body: $b}')"
  stub_gh_json "api --paginate repos/o/r/pulls/${pr}/files*" "$(jq -cn --arg f "${FILES:-cli/table.go}" --arg p "${RENAMED_FROM:-}" \
    '$f | split(",") | map({filename: .}) | if $p == "" then . else .[0].previous_filename = $p end')"
  if [[ -n "${COMPARE_FAIL:-}" ]]; then stub_gh_on "api repos/o/r/compare/main...${head} *" '' 1 'gh: HTTP 502'; fi
  stub_gh_json "api repos/o/r/compare/main...${head} *" "{\"behind_by\": ${BEHIND:-0}, \"ahead_by\": 1}"
  stub_gh_json "api repos/o/r/commits/${head} *" "$(jq -cn --arg h "${head}" --arg p "${PARENT:-pppppppppppppppppppppppppppppppppppppppp}" \
    '{sha: $h, parents: ([{sha: $p}] + (if env.ONE_PARENT == "1" then [] else [{sha: "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm"}] end))}')"
  stub_gh_on "api -X PUT repos/o/r/pulls/${pr}/update-branch *" '' "${UPDATE_RC:-0}" "${UPDATE_ERR:-}"
}
green() {
  stub_gh_reset_calls
  stub_gh_reset_rules
  AGENT_TRUST_CACHE=()
  stub_gh_on 'pr list --state open --label agent:pr *' "${PR_LIST:-44}"
  if [[ -n "${EXTRA_STUBS:-}" ]]; then "${EXTRA_STUBS}"; fi
  stub_pr 44 "${HEAD}"
  if [[ -n "${CHECKS_FAIL:-}" ]]; then stub_gh_on 'api --paginate repos/o/r/commits/*/check-runs*' '' 1 'gh: HTTP 502'; fi
  stub_gh_json 'api --paginate repos/o/r/commits/*/check-runs*' "$(checks)"
  stub_gh_json 'api repos/o/r/commits/*/check-suites*' "{\"check_suites\":[{\"created_at\":\"${PUSHED}\"}]}"
  stub_gh_json 'api --paginate repos/o/r/actions/workflows/claude-code-review.yml/runs*' \
    "$(jq -cn --arg s "${REVIEW_RUN_STATUS:-completed}" '{workflow_runs: [
      {id: 70, display_title: "Claude review of PR #44", created_at: "2026-11-05T10:20:00Z", status: $s},
      {id: 71, display_title: "Claude review of PR #45", created_at: "2026-11-05T10:20:00Z", status: "completed"}]}')"
  stub_gh_json 'api repos/o/r/actions/runs/7*/jobs*' \
    "$(jq -cn --arg st "${JOB_START:-2026-11-05T10:25:00Z}" '{jobs: [{name: "claude-review", started_at: $st, completed_at: "2026-11-05T10:31:00Z"}]}')"
  stub_gh_on 'api * repos/o/r/contents/state/breaker.json*' "${BREAKER:-}" "${BREAKER_RC:-1}" "${BREAKER_ERR:-gh: Not Found (HTTP 404)}"
  if [[ -n "${PERM_FAIL:-}" ]]; then stub_gh_on 'api repos/o/r/collaborators/owner-login/permission*' '' 1 'gh: HTTP 502'; fi
  stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
  stub_gh_json 'api repos/o/r/collaborators/*/permission*' '{"permission":"read"}'
  stub_gh_json 'api repos/o/r/issues/*/labels*' "$(jq -cn --arg l "${LABELS-agent:pr}" '$l | split(",") | map(select(. != "") | {name: .})')"
  stub_gh_on 'issue view 7 --json labels *' 'agent:pr-open'
  stub_gh_on 'issue view 99 --json body *' $'intro\n<!-- agent-inbox:open:start -->\n<!-- agent-inbox:open:end -->'
  stub_gh_on 'label list *' "${labels_all}"
  if [[ -n "${FORCED_AT:-}" ]]; then
    stub_gh_json 'api graphql *' "$(jq -cn --arg t "${FORCED_AT}" --arg o "${HEAD}" '{data: {repository: {pullRequest: {timelineItems: {nodes: [{createdAt: $t, afterCommit: {oid: $o}}]}}}}}')"
  fi
  if [[ -n "${MERGE_FAILS:-}" ]]; then stub_gh_on 'pr merge 44 *' '' 1 'GraphQL: Base branch was modified'; fi
  if [[ -n "${COMMENT_FAIL:-}" ]]; then stub_gh_on 'issue comment 44 *' '' 1 'gh: HTTP 502'; fi
  if [[ -n "${INBOX_FAIL:-}" ]]; then stub_gh_on 'issue comment 99 *' '' 1 'gh: HTTP 502'; fi
  if [[ -n "${LABEL_FAIL:-}" ]]; then stub_gh_on 'api -X POST repos/o/r/issues/44/labels*' '' 1 'gh: HTTP 502'; fi
  stub_gh_json 'api --paginate repos/o/r/issues/99/comments*' "$(jq -cn --argjson b "${INBOX_COMMENTS:-[]}" '$b | map({user: {login: "repo-agent[bot]"}, body: .})')"
  : >"${TMP}/run.out"
  AGENT_INBOX_ISSUE=99 AGENTS_ENABLED="${ENABLED:-true}" AGENT_AUTO_MERGE="${AUTO-true}" cmd_run "${WANT_PR:-}" >"${TMP}/run.out" 2>"${TMP}/run.err"
  echo "$?" >"${TMP}/run.rc"
}
merged() { stub_gh_calls | grep -q '^pr merge 44 '; }

green
if merged; then t_pass "all green: merged"; else t_fail "all green but not merged: $(cat "${TMP}/run.out")"; fi
expect "with --merge, pinned to the checked head, deleting the branch" \
  "$(stub_gh_calls | grep '^pr merge 44 ')" "pr merge 44 --merge --match-head-commit ${HEAD} --delete-branch"
if stub_gh_calls | grep -q -- '--admin\|--auto'; then t_fail "--admin or --auto was used"; else t_pass "never --admin, never --auto"; fi
if stub_gh_calls | grep -q '^issue edit 7 --add-label agent:done-pending-deploy'; then t_pass "the issue moves to agent:done-pending-deploy"; else t_fail "the issue was not moved on"; fi
expect "and the ledger gets a merger row" \
  "$(git --git-dir="${TMP}/ledger.git" show agent-ledger:runs/2026-11.jsonl 2>/dev/null | jq -r 'select(.role == "merger") | "\(.pr) \(.issue) \(.head) \(.outcome)"' | tail -1)" "44 7 ${HEAD} merged"
expect "the run succeeds" "$(cat "${TMP}/run.rc")" 0

# not_merged <label> <VAR=value…>: break one condition, expect no merge and the reason in the output.
not_merged() {
  local label="$1" want="$2"
  shift 2
  # shellcheck disable=SC2163 # "$@" is VAR=value pairs
  ( export "$@"; green )
  if merged; then t_fail "${label}: merged anyway"; elif grep -Fq -- "${want}" "${TMP}/run.out"; then t_pass "${label}"; else t_fail "${label}: reason '${want}' missing from: $(cat "${TMP}/run.out")"; fi
}

not_merged "AGENT_AUTO_MERGE unset: a dry run that says it would merge" "would merge ${HEAD}" AUTO=
not_merged "AGENT_AUTO_MERGE anything but 'true' is a dry run too" "would merge ${HEAD}" AUTO=yes
not_merged "the kill switch" "AGENTS_ENABLED is not true" ENABLED=false
not_merged "a tripped breaker" "the coder breaker is tripped" BREAKER='{"coder":{"tripped_at":"2026-11-05T09:00:00Z"}}' BREAKER_RC=0
not_merged "a person's PR" "not the agent bot's PR" AUTHOR=owner-login
# No required checks configured (the package default) must never mean "nothing to wait for".
jq '.requiredChecks = []' "${REPO_ROOT}/.github/agents/policy.json" >"${TMP}/policy-nochecks.json"
not_merged "no requiredChecks: never merged on the review alone" "policy.json requiredChecks is empty" AGENT_POLICY="${TMP}/policy-nochecks.json"
jq '.requiredChecks = "CI"' "${REPO_ROOT}/.github/agents/policy.json" >"${TMP}/policy-strchecks.json"
not_merged "requiredChecks as a string is not a list of checks" "policy.json requiredChecks is empty" AGENT_POLICY="${TMP}/policy-strchecks.json"
not_merged "no agent:pr" "no agent:pr label" LABELS=
not_merged "a draft" "a draft" DRAFT=true
not_merged "a closed PR" "not open" STATE=CLOSED
not_merged "a PR from a fork" "from a fork" FORK=true
not_merged "check runs that cannot be read" "check runs unreadable" CHECKS_FAIL=1
not_merged "not against main" "not against main" BASE=release
not_merged "not mergeable" "mergeable is CONFLICTING" MERGEABLE=CONFLICTING
for l in agent:hold agent:blocked agent:needs-human agent:fixing agent:allow-protected; do
  not_merged "labelled ${l}" "labelled ${l}" LABELS="agent:pr,${l}"
done
while IFS= read -r name; do
  not_merged "required check '${name}' failed in its latest run" "check '${name}' is completed/failure" CHECK_OVERRIDE="${name}|completed|failure"
done < <(policy '.requiredChecks[]'; echo 'agent pr guard')
not_merged "a required check still running" "check 'test (unit)' is in_progress/none" CHECK_OVERRIDE="test (unit)|in_progress|"
not_merged "the review asks for changes" "the newest review says request-changes" REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Verdict\nRequest changes'
not_merged "no verdict at all" "the newest review says unknown" REVIEW_BODY=$'<!-- verify-pr-review -->\n\nlooks ok'
# Seen on 2026-11-07: a review approved under HTML headings, and the gate read it as unknown.
( export REVIEW_BODY=$'<!-- verify-pr-review -->\n\n<h3>Blocking problems</h3>\n\nNone.\n\n<h3>Verdict</h3>\n\nApprove'; green )
if merged; then t_pass "an Approve under an HTML <h3>Verdict</h3> heading: merged"; else t_fail "an HTML-headed Approve did not merge: $(cat "${TMP}/run.out")"; fi
( export REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Verdict\nApprove\n\nThe template line is:\n```\n### Verdict\nRequest changes\n```'; green )
if merged; then t_pass "a Verdict heading quoted in a code fence after the real Approve does not win: merged"; else t_fail "a fenced quote of the template blocked an Approve: $(cat "${TMP}/run.out")"; fi
not_merged "an Approve inside an HTML comment after a real Request changes" "the newest review says request-changes" REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Verdict\nRequest changes\n\n<!--\n### Verdict\nApprove\n-->'
not_merged "an Approve in a code fence with no real verdict" "the newest review says unknown" REVIEW_BODY=$'<!-- verify-pr-review -->\n\n```\n### Verdict\nApprove\n```'
not_merged "a review that copied /verify-pr's template line has approved nothing" "the newest review says unknown" \
  REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Blocking problems\nNone.\n\n### Verdict\nApprove / Request changes'
not_merged "the review predates the head's push" "is not newer than the head" REVIEW_AT=2026-11-05T09:59:00Z JOB_START=2026-11-05T09:50:00Z
not_merged "a review job that started before the push wrote it" "started before the head was pushed" JOB_START=2026-11-05T09:55:00Z
not_merged "a review still running" "a review is still running" REVIEW_RUN_STATUS=in_progress
not_merged "a claude[bot] review that no review job's window holds" "no review job of #44 wrote the newest review" REVIEW_AT=2026-11-05T10:40:00Z
not_merged "a review marker by a read-only account is no review" "no review yet" REVIEWER=outsider
not_merged "a protected path" "touches protected paths: deploy/Makefile" FILES=cli/table.go,deploy/Makefile
not_merged "a rename FROM a protected path" "touches protected paths: deploy/Makefile" FILES=cli/x.go RENAMED_FROM=deploy/Makefile
jq '.humanPaths = ["docs/legal/**"]' "${AGENT_POLICY}" >"${TMP}/policy-human.json"
not_merged "a policy.humanPaths path" "touches policy.humanPaths: docs/legal/terms.md" AGENT_POLICY="${TMP}/policy-human.json" FILES=cli/x.go,docs/legal/terms.md
not_merged "an unreadable breaker" "breaker unreadable" BREAKER_RC=1 BREAKER_ERR='gh: HTTP 502'
not_merged "a fixer breaker tripped stops merges too" "the fixer breaker is tripped" BREAKER='{"fixer":{"tripped_at":"2026-11-05T09:00:00Z"}}' BREAKER_RC=0
not_merged "a required check's success from another app does not count" "check 'build' is completed/failure" \
  CHECK_OVERRIDE="build|completed|failure" CHECK_EXTRA='{"id":1000,"name":"build","status":"completed","conclusion":"success","app":{"slug":"evil"}}'
not_merged "a required check that never ran" "check 'lint' is missing" CHECK_OVERRIDE="lint|completed|success|evil" \
  CHECKS_DROP='lint'

# A GitHub review requesting changes by a writer stops the merge, on any head, until it is answered.
not_merged "a writer's Request changes review" "owner-login requested changes" \
  REVIEWS='[{"author":{"login":"owner-login"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-05T09:30:00Z"}]'
not_merged "a writer's Request changes, when their access cannot be read" "could not tell whether owner-login" PERM_FAIL=1 \
  REVIEWS='[{"author":{"login":"owner-login"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-05T09:30:00Z"}]'
( export REVIEWS='[{"author":{"login":"outsider"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-05T09:30:00Z"},{"author":{"login":"owner-login"},"state":"APPROVED","submittedAt":"2026-11-05T09:40:00Z"}]'; green )
if merged; then t_pass "a read-only account's Request changes does not stop it"; else t_fail "a reader's review blocked the merge: $(cat "${TMP}/run.out")"; fi
not_merged "a writer's Request changes followed by a mere comment review still stands" "owner-login requested changes" \
  REVIEWS='[{"author":{"login":"owner-login"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-05T09:30:00Z"},{"author":{"login":"owner-login"},"state":"COMMENTED","submittedAt":"2026-11-05T09:45:00Z"}]'
for later in APPROVED DISMISSED; do
  ( export REVIEWS="[{\"author\":{\"login\":\"owner-login\"},\"state\":\"CHANGES_REQUESTED\",\"submittedAt\":\"2026-11-05T09:30:00Z\"},{\"author\":{\"login\":\"owner-login\"},\"state\":\"${later}\",\"submittedAt\":\"2026-11-05T09:45:00Z\"}]"; green )
  if merged; then t_pass "a Request changes the writer later ${later,,}: merged"; else t_fail "a ${later,,} Request changes still blocked: $(cat "${TMP}/run.out")"; fi
done
# A force-push back to this head after the review: the review saw another head.
not_merged "a force-push back to the head after the review" "is not newer than the head (2026-11-05T10:40:00Z)" FORCED_AT=2026-11-05T10:40:00Z
# The review bot never edits its review; another PR's review job could have.
not_merged "an edited Claude review" "the newest review was edited after it was posted" REVIEW_EDITED=2026-11-05T10:50:00Z
# A writer's newer verdict must not be skipped for the bot's older Approve when the lookup fails.
not_merged "a writer's marker comment whose access cannot be read" "reviews unreadable" REVIEWER=owner-login PERM_FAIL=1
# A breaker file that is not what finalize writes is unreadable, never closed.
for b in '[]' '[1]' '{"coder":"tripped"}' 'not json'; do
  not_merged "a malformed breaker (${b})" "breaker unreadable" BREAKER="${b}" BREAKER_RC=0
done
# An older failed or cancelled run of a check is history: the latest one decides.
( export CHECK_OVERRIDE='agent pr guard|completed|success' CHECK_EXTRA='{"id":50,"name":"agent pr guard","status":"completed","conclusion":"cancelled","app":{"slug":"github-actions"}}'; green )
if merged; then t_pass "an older cancelled run before a newer success: merged"; else t_fail "an older cancelled run blocked it: $(cat "${TMP}/run.out")"; fi
# The issue comes from the outbox footer, never the first Refs #N the model wrote.
( export PR_BODY=$'Follows Refs #12 for context.\n\nRefs #7\n\n<!-- agent-run:coder run=900 issue=7 -->'; green )
if stub_gh_calls | grep -q '^issue edit 12 '; then t_fail "the merge moved #12, which the model named first"; else t_pass "the model's first Refs does not decide the issue"; fi
if stub_gh_calls | grep -q '^issue edit 7 --add-label agent:done-pending-deploy'; then t_pass "the footer's issue moves on"; else t_fail "the footer's issue was not moved"; fi

# A person with write access may give the Approve; no review job window applies to it.
( export REVIEWER=owner-login JOB_START=2026-11-05T09:00:00Z; green )
if merged; then t_pass "an Approve by a person with write access counts"; else t_fail "a writer's Approve did not merge: $(cat "${TMP}/run.out")"; fi
# A dispatch naming a PR checks that one; anything but a number is refused before any call.
( export WANT_PR='44;x'; green )
expect "a dispatch with a non-number is refused" "$(cat "${TMP}/run.rc")" 2
if merged; then t_fail "a bad dispatch merged"; else t_pass "and nothing is merged"; fi
( export MERGE_FAILS=1; green )
expect "a failed merge fails the run" "$(cat "${TMP}/run.rc")" 1
if stub_gh_calls | grep -q '^issue edit 7 '; then t_fail "the issue moved although the merge failed"; else t_pass "and the issue stays where it is"; fi

# --- up to date with main (decided 2026-11-06) -----------------------------------------------------
called() { stub_gh_calls | grep -Fq -- "$1"; }
check() { if "$@"; then t_pass "${label}"; else t_fail "${label}: $(cat "${TMP}/run.out")"; fi; }
check_not() { if "$@"; then t_fail "${label}: $(cat "${TMP}/run.out")"; else t_pass "${label}"; fi; }
UPDATE="api -X PUT repos/o/r/pulls/44/update-branch -f expected_head_sha=${HEAD}"
REVIEW_CALL='workflow run Claude Code Review -f pr=44'
green
label="the gate compares the head with main"; check called "api repos/o/r/compare/main...${HEAD} "
label="and an up-to-date head is not updated"; check_not called "update-branch"
( export BEHIND=3; green )
label="behind main: not merged"; check_not merged
label="the reason says how far behind"; check grep -Fq "behind main by 3 commits" "${TMP}/run.out"
label="a live run asks GitHub to merge main into the branch, pinned to the checked head"; check called "${UPDATE}"
label="and records that it did, for the review that follows"; check stub_gh_any_body "<!-- agent-merge-updated from=${HEAD} -->"
expect "and the run is fine" "$(cat "${TMP}/run.rc")" 0
( export BEHIND=3 AUTO=; green )
label="a dry run says it would update"; check grep -Fq "would update the branch (behind main by 3)" "${TMP}/run.out"
label="and changes nothing"; check_not called "update-branch"
label="not even a comment"; check_not called "issue comment 44"
( export BEHIND=3 COMPARE_FAIL=1; green )
label="a compare that cannot be read"; check grep -Fq "could not compare the head with main" "${TMP}/run.out"
label="is a blocker, and no update"; check_not called "update-branch"
( export COMPARE_FAIL=1; green )
label="an up-to-date PR whose compare fails is not merged"; check_not merged
# Any other blocker, and the branch is left alone: the gate never races the fixer.
behind_and() { # behind_and <label> <VAR=value…>
  local l="$1"
  shift
  # shellcheck disable=SC2163
  ( export BEHIND=2 "$@"; green )
  label="behind plus ${l}: no update"; check_not called "update-branch"
  label="behind plus ${l}: not merged"; check_not merged
}
behind_and "a red check" CHECK_OVERRIDE="test (unit)|completed|failure"
behind_and "a check still running" CHECK_OVERRIDE="test (unit)|in_progress|"
behind_and "agent:fixing" LABELS=agent:pr,agent:fixing
behind_and "a stale review" REVIEW_AT=2026-11-05T09:59:00Z JOB_START=2026-11-05T09:50:00Z
behind_and "no review" REVIEWER=outsider
behind_and "a review still running" REVIEW_RUN_STATUS=in_progress
behind_and "a Request changes review" REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Verdict\nRequest changes'
behind_and "a protected path" FILES=cli/x.go,deploy/Makefile
behind_and "a mergeable GitHub has not computed yet" MERGEABLE=UNKNOWN
behind_and "the kill switch" ENABLED=false
# A conflict with main is part of being behind: the update is what tells.
( export BEHIND=2 MERGEABLE=CONFLICTING; green )
label="behind and CONFLICTING: the update is tried"; check called "${UPDATE}"

# GitHub refuses: workflow files (the App has no Workflows permission), or a merge conflict.
WF_ERR="gh: refusing to allow a GitHub App to create or update workflow \`.github/workflows/ci.yml\` without \`workflows\` permission (HTTP 422)"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}"; green )
label="a refused update for workflow files: agent:needs-human"; check grep -q '"agent:needs-human"' <<<"$(stub_gh_last_body 'api -X POST repos/o/r/issues/44/labels*')"
label="and a merger request in the inbox"; check stub_gh_any_body 'role=merger issue=7 kind=merger -->'
label="naming the reason"; check stub_gh_any_body "change workflow files"
label="and a marker on the PR for that head"; check stub_gh_any_body "<!-- agent-merge-needs-human sha=${HEAD} -->"
label="the report names it"; check grep -Fq "cannot be brought up to date (main's new commits change workflow files" "${TMP}/run.out"
label="nothing merged"; check_not merged
label="no updated-marker for an update that did not happen"; check_not stub_gh_any_body "agent-merge-updated"
expect "and the run is fine" "$(cat "${TMP}/run.rc")" 0
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}" LABELS=agent:pr,agent:needs-human; green )
label="the next run: agent:needs-human, so no second try"; check_not called "update-branch"
label="and no second request"; check_not called "issue comment 99"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}" BOT_COMMENTS="[\"<!-- agent-merge-needs-human sha=${HEAD} -->\"]"; green )
label="the label taken off without an update: asked once already"; check grep -Fq "a person was already asked" "${TMP}/run.out"
label="so no second inbox request"; check_not called "issue comment 99"
label="and no second label"; check_not called "api -X POST repos/o/r/issues/44/labels"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR='gh: merge conflict between base and head (HTTP 422)'; green )
label="a conflict: agent:needs-human too"; check grep -q '"agent:needs-human"' <<<"$(stub_gh_last_body 'api -X POST repos/o/r/issues/44/labels*')"
label="naming the conflict"; check grep -Fq "merging main into the branch conflicts" "${TMP}/run.out"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="gh: expected head sha didn't match current head ref. (HTTP 422)"; green )
label="a head that moved meanwhile: left for the next run"; check grep -Fq "the head moved" "${TMP}/run.out"
label="without asking anyone"; check_not called "issue comment 99"
expect "and the run is fine" "$(cat "${TMP}/run.rc")" 0
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR='gh: HTTP 502'; green )
expect "any other failure fails the run" "$(cat "${TMP}/run.rc")" 1
label="and asks nobody (it may pass next time)"; check_not called "issue comment 99"
( export BEHIND=2 COMMENT_FAIL=1; green )
expect "an update it could not record fails the run (its review would never be asked for)" "$(cat "${TMP}/run.rc")" 1

# Two PRs in one live run: the second is checked after the first merged, against the new main.
HEAD45=dddddddddddddddddddddddddddddddddddddddd
second_pr() {
  STUB_AFTER='pr merge 44 *' STUB_MODE=json stub_gh_on "api repos/o/r/compare/main...${HEAD45} *" '{"behind_by": 1, "ahead_by": 1}'
  stub_pr 45 "${HEAD45}"
}
( export PR_LIST=$'44\n45' EXTRA_STUBS=second_pr; green )
label="two eligible PRs: the first merges"; check merged
label="the second, behind once the first merged, is not merged"; check_not called "pr merge 45 "
label="it is updated instead"; check called "api -X PUT repos/o/r/pulls/45/update-branch -f expected_head_sha=${HEAD45}"
label="and the report says why"; check grep -Fq "#45: behind main by 1 commits" "${TMP}/run.out"
( export PR_LIST=$'44\n45' EXTRA_STUBS=second_pr AUTO=; green )
label="in a dry run nothing merges, so the second is still up to date (the stub's main moves only on a merge)"; check grep -Fq "#45: would merge ${HEAD45}" "${TMP}/run.out"

# After an update: the old Approve does not count, and the gate asks for one fresh review.
OLD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
UPDATED="[\"<!-- agent-merge-updated from=${OLD} -->\"]"
after_update() { # the gate's own update made HEAD; the Approve saw the old head
  export PARENT="${PARENT:-${OLD}}" BOT_COMMENTS="${BOT_COMMENTS:-${UPDATED}}" REVIEW_AT="${REVIEW_AT:-2026-11-05T09:50:00Z}" JOB_START=2026-11-05T09:45:00Z
  green
}
( after_update )
label="after an update, the old Approve does not merge it"; check_not merged
label="green checks on the gate's update: a fresh review is requested"; check called "${REVIEW_CALL}"
label="and recorded for that head"; check stub_gh_any_body "<!-- agent-review-dispatched sha=${HEAD} -->"
expect "once" "$(stub_gh_calls | grep -c "^${REVIEW_CALL}")" 1
( export BOT_COMMENTS="[\"<!-- agent-merge-updated from=${OLD} -->\", \"<!-- agent-review-dispatched sha=${HEAD} -->\"]"; after_update )
label="a head whose review was requested already: not again"; check_not called "${REVIEW_CALL}"
( export REVIEW_RUN_STATUS=in_progress; after_update )
label="never while a review is running"; check_not called "${REVIEW_CALL}"
( export CHECK_OVERRIDE="test (unit)|completed|failure"; after_update )
label="never while a check is red"; check_not called "${REVIEW_CALL}"
( export CHECK_OVERRIDE="test (unit)|in_progress|"; after_update )
label="nor while one is still running"; check_not called "${REVIEW_CALL}"
( export LABELS=agent:pr,agent:fixing; after_update )
label="nor while the fixer has it"; check_not called "${REVIEW_CALL}"
( export BOT_COMMENTS='[]'; after_update )
label="a head a person pushed (no update of the gate's under it) waits for that person"; check_not called "${REVIEW_CALL}"
( export PARENT=ffffffffffffffffffffffffffffffffffffffff; after_update )
label="nor one whose parent is not a head the gate updated"; check_not called "${REVIEW_CALL}"
( export AUTO=; after_update )
label="a dry run says it would request one"; check grep -Fq "would request a review of ${HEAD:0:9}" "${TMP}/run.out"
label="and requests none"; check_not called "${REVIEW_CALL}"
( export BEHIND=1; after_update )
label="behind main again as well: the review is still requested (the update waits for its Approve)"; check called "${REVIEW_CALL}"
label="and the branch is not updated meanwhile"; check_not called "update-branch"
( export REVIEWER=outsider; after_update )
label="no review at all on the gate's update: one is requested"; check called "${REVIEW_CALL}"
( export REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Verdict\nRequest changes'; after_update )
label="a stale review's own verdict does not matter: requested"; check called "${REVIEW_CALL}"
( export MERGEABLE=CONFLICTING; after_update )
label="a conflict on the updated head: no review"; check_not called "${REVIEW_CALL}"
label="and, not behind (GitHub's mergeable can lag), nobody is asked yet"; check_not called "issue comment 99"
( export PARENT="${OLD}" BOT_COMMENTS="${UPDATED}" REVIEW_BODY=$'<!-- verify-pr-review -->\n\n### Verdict\nRequest changes'; green )
label="a Request changes review of the updated head itself: no second review (the fixer's turn)"; check_not called "${REVIEW_CALL}"

# An Approve older than review_runs' window reads as one no review job wrote: still stale.
( export REVIEW_AT=2026-11-03T09:50:00Z; after_update )
label="an old Approve outside the review-run window on the gate's update: a review is requested"; check called "${REVIEW_CALL}"
( export REVIEW_EDITED=2026-11-05T09:55:00Z; after_update )
label="an edited old Approve on the gate's update: a review is requested too"; check called "${REVIEW_CALL}"
# The gate's update, behind again AND conflicting: neither a review nor an update can move it.
( export BEHIND=2 MERGEABLE=CONFLICTING; after_update )
label="the gate's update, now behind and conflicting: a person is asked"; check stub_gh_any_body 'role=merger issue=7 kind=merger -->'
label="labelled agent:needs-human"; check grep -q '"agent:needs-human"' <<<"$(stub_gh_last_body 'api -X POST repos/o/r/issues/44/labels*')"
label="with no update tried"; check_not called "update-branch"
label="and no review"; check_not called "${REVIEW_CALL}"
( export BEHIND=2 MERGEABLE=CONFLICTING AUTO=; after_update )
label="a dry run says it would ask a person"; check grep -Fq "would ask a person" "${TMP}/run.out"
label="and asks nobody"; check_not called "issue comment 99"
( export BEHIND=2 MERGEABLE=CONFLICTING BOT_COMMENTS='[]'; after_update )
label="the same on a head a person pushed: left to that person"; check_not called "issue comment 99"
# A person did what the needs-human request asked: the gate takes it from there.
( export PARENT="${OLD}" BOT_COMMENTS="[\"<!-- agent-merge-needs-human sha=${OLD} -->\"]"; after_update )
label="a person merged main into a head the gate could not update: a review is requested"; check called "${REVIEW_CALL}"
# The person is asked first; the label, which stops every retry, comes last.
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}" INBOX_FAIL=1; green )
expect "an inbox request that failed fails the run" "$(cat "${TMP}/run.rc")" 1
label="and leaves no label, so the next run asks again"; check_not called "api -X POST repos/o/r/issues/44/labels"
label="nor a marker that says it asked"; check_not stub_gh_any_body "<!-- agent-merge-needs-human sha=${HEAD} -->"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR='gh: Resource not accessible: this would change a workflow file (HTTP 403)'; green )
label="other wording that names a workflow is the same refusal"; check stub_gh_any_body 'role=merger issue=7 kind=merger -->'
# A 202 that left the head where it was: ask again, record once.
( export BEHIND=2 BOT_COMMENTS="[\"<!-- agent-merge-updated from=${HEAD} -->\"]"; green )
label="a head the gate asked to update before: asked again"; check called "${UPDATE}"
label="without a second comment"; check_not called "issue comment 44"
# The owner's rule holds for every stale line, the two that also read as stale on an update included.
behind_and "an edited review" REVIEW_EDITED=2026-11-05T10:50:00Z
behind_and "a review no job of the PR wrote" REVIEW_AT=2026-11-05T10:40:00Z
# A conflicting head of the gate's own is asked of a person only when nothing else is in the way.
( export BEHIND=2 MERGEABLE=CONFLICTING CHECK_OVERRIDE="test (unit)|completed|failure"; after_update )
label="the gate's conflicting head with a red check: nobody is asked (the fixer's turn)"; check_not called "issue comment 99"
label="and no label"; check_not called "api -X POST repos/o/r/issues/44/labels"
( export BEHIND=2 MERGEABLE=CONFLICTING LABELS=agent:pr,agent:fixing; after_update )
label="the gate's conflicting head the fixer holds: nobody is asked"; check_not called "issue comment 99"
label="and no label either"; check_not called "api -X POST repos/o/r/issues/44/labels"
# Only a merge commit on a recorded head is the gate's update, and only its own markers record one.
( export ONE_PARENT=1; after_update )
label="a person's own commit on a head the gate updated is theirs: no review"; check_not called "${REVIEW_CALL}"
( export BOT_COMMENTS="[\"<!-- agent-review-dispatched sha=${OLD} -->\"]"; after_update )
label="a parent the gate only asked a review for is no update of its own: no review"; check_not called "${REVIEW_CALL}"
# Each step of asking a person is retried until it holds, and never doubled.
ASKED="[\"<!-- agent-merge-ask pr=44 sha=${HEAD} -->\"]"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}" INBOX_COMMENTS="${ASKED}"; green )
label="the inbox already holds this head's request: no second one"; check_not called "issue comment 99"
label="but the label goes on"; check grep -q '"agent:needs-human"' <<<"$(stub_gh_last_body 'api -X POST repos/o/r/issues/44/labels*')"
label="and the PR's marker"; check stub_gh_any_body "<!-- agent-merge-needs-human sha=${HEAD} -->"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}" LABEL_FAIL=1; green )
expect "a label that failed fails the run" "$(cat "${TMP}/run.rc")" 1
label="after the inbox request"; check stub_gh_any_body "<!-- agent-merge-ask pr=44 sha=${HEAD} -->"
label="and leaves no PR marker, so the next run tries the label again"; check_not stub_gh_any_body "<!-- agent-merge-needs-human sha=${HEAD} -->"
( export BEHIND=2 UPDATE_RC=1 UPDATE_ERR="${WF_ERR}" COMMENT_FAIL=1; green )
expect "a PR comment that failed fails the run" "$(cat "${TMP}/run.rc")" 1
label="with the label already on, which stops the next run"; check grep -q '"agent:needs-human"' <<<"$(stub_gh_last_body 'api -X POST repos/o/r/issues/44/labels*')"
printf '\n[agents-merge] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
