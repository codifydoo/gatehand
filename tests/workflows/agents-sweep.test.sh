#!/usr/bin/env bash
# tests/workflows/agents-sweep.test.sh
# .github/scripts/agent-sweep.sh (the hourly sweep) against a stub gh and a local bare ledger repo.
# Pinned, and why:
#   1. A lock is released only when it has EXPIRED and its run has ENDED (or is gone): a long queue
#      or a slow run must never lose its lock to the sweep, and nothing is swept while a coder run is
#      in progress (it may not have posted its own lock yet). Only the bot's lock counts, so a pasted
#      marker cannot free an issue. A failed attempt with attempts left goes back to agent:ready
#      (allow-protected removed, it is one-shot), the last one to agent:blocked + an inbox request.
#      A run that opened its PR makes the issue agent:pr-open; a run that has its ledger row gets
#      that row's outcome, without a second comment or request. agent:hold is never touched.
#   2. A run whose publish job never wrote its ledger row gets one, so it counts against the daily
#      cap and the breaker; a run that has its row does not get a second. Last month's rows are
#      read too, on the 1st of every month as well; an unreadable ledger leaves the issue alone.
#   3. agent:pr-open follows the bot's own agent PR, the one whose footer names the issue: merged ->
#      agent:done-pending-deploy with a marker comment, closed unmerged -> agent:blocked, still
#      open -> untouched. A PR by anyone else, or an agent PR for another issue that a comment
#      mentions this one on, changes nothing.
#   4. A breaker whose count reached the threshold without tripping is tripped once, with a request;
#      a tripped or reset one is left alone.
# ROLE and AGENT_TRUST_CACHE are read by the sourced scripts.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agents-gh-stub.sh"
export AGENT_SWEEP_NO_MAIN=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-sweep.sh"
set +e

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-sweep] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-sweep] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }
expect_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_pass "$1"; else t_fail "$1: no gh call containing '$2'"; fi; }
expect_no_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_fail "$1: unexpected gh call '$2'"; else t_pass "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export GH_REPO=o/r AGENT_NOW_EPOCH=1793880000 # 2026-11-05T12:00:00Z
export AGENT_INBOX_ISSUE=99 AGENT_REQ_ID=REQ-20261105-beef AGENT_LEDGER_BACKOFF=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare "${TMP}/ledger.git"
export LEDGER_REMOTE="${TMP}/ledger.git"
stub_gh_init
labels_all="$(printf '%s\n' "${AGENT_LABELS[@]}" | cut -d'|' -f1)"
ledger_rows() { git --git-dir="${TMP}/ledger.git" show agent-ledger:runs/2026-11.jsonl 2>/dev/null; }
ledger_breaker() { git --git-dir="${TMP}/ledger.git" show agent-ledger:state/breaker.json 2>/dev/null; }

# xpr <n> <state> <merged_at|null> [author] [labels-csv] [repo] [body]: one cross-referenced timeline
# event from a PR; the body defaults to the outbox's footer for run 1 and issue 8.
xpr() {
  jq -cn --argjson n "$1" --arg s "$2" --arg m "$3" --arg u "${4:-repo-agent[bot]}" --arg l "${5-agent:pr}" --arg r "${6:-o/r}" \
    --arg b "${7:-$'## What\nx\n\nRefs #8\n\n<!-- agent-run:coder run=1 issue=8 -->'}" \
    '{event: "cross-referenced", source: {type: "issue", issue: {number: $n, state: $s, body: $b,
      user: {login: $u}, labels: ($l | split(",") | map(select(. != "") | {name: .})),
      repository: {full_name: $r}, pull_request: {merged_at: (if $m == "null" then null else $m end)}}}}'
}

# --- 1 + 2. locks ----------------------------------------------------------------------------------
lock() { printf '<!-- agent:lock role=coder run=%s attempt=%s expires=%s -->\nThe coder agent picked this up.' "$1" "$2" "$3"; }
comments() { # comments "<login>|<body>" ... -> the REST comments array
  local c a=()
  for c in "$@"; do a+=("$(jq -cn --arg u "${c%%|*}" --arg b "${c#*|}" '{user: {login: $u}, body: $b}')"); done
  printf '%s\n' "${a[@]}" | jq -s .
}
EXPIRED=2026-11-05T11:00:00Z
FRESH=2026-11-05T13:00:00Z
# lock_case <comments-json> <run-json-or-empty> [run-rc] [run-stderr]: one in-progress issue, #7.
# ACTIVE (coder runs in progress), HAVE (its labels), TIMELINE, LEDGER_* vary one thing each.
lock_case() {
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_on 'label list *' "${labels_all}"
  stub_gh_json 'api repos/o/r/actions/workflows/agent-coder.yml/runs*' "{\"total_count\":${ACTIVE:-0}}"
  stub_gh_on 'issue list --state open --label agent:in-progress *' '7'
  stub_gh_on 'issue view 7 --json labels *' "${HAVE:-$'agent:in-progress\nagent:allow-protected'}"
  stub_gh_on 'issue view 99 --json body *' $'intro\n<!-- agent-inbox:open:start -->\n<!-- agent-inbox:open:end -->'
  stub_gh_json 'api --paginate repos/o/r/issues/7/timeline*' "${TIMELINE:-[]}"
  stub_gh_json 'api --paginate repos/o/r/issues/7/comments*' "$1"
  if [[ -n "${2:-}" ]]; then stub_gh_json 'api repos/o/r/actions/runs/*' "$2"; else stub_gh_on 'api repos/o/r/actions/runs/*' '' "${3:-1}" "${4:-gh: HTTP 502}"; fi
  stub_gh_on 'api * repos/o/r/contents/runs/*' "${LEDGER_RUNS:-}" "${LEDGER_RC:-1}" "${LEDGER_ERR:-gh: Not Found (HTTP 404)}"
  : >"${TMP}/sweep.out"
  sweep_locks >"${TMP}/sweep.out" 2>"${TMP}/sweep.err"
}
COMPLETED='{"status":"completed","conclusion":"cancelled","run_started_at":"2026-11-05T09:00:00Z"}'
RUNNING='{"status":"in_progress","conclusion":null,"run_started_at":"2026-11-05T09:00:00Z"}'
QUEUED='{"status":"queued","conclusion":null,"run_started_at":null}'

lock_case "$(comments "repo-agent[bot]|$(lock 555 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "expired + ended, attempts left: back to agent:ready, allow-protected removed" \
  "issue edit 7 --add-label agent:ready --remove-label agent:in-progress --remove-label agent:allow-protected"
if stub_gh_any_body '<!-- agent-sweep:stale-lock run=555 -->'; then t_pass "the issue is told why"; else t_fail "no stale-lock comment"; fi
expect_no_call "attempts left: no inbox request" "issue comment 99"
expect "the run gets the ledger row its publish job never wrote" \
  "$(ledger_rows | jq -r 'select(.run_id == "555") | "\(.outcome) \(.trigger) \(.issue) \(.attempt) \(.started_at)"')" \
  "failed sweep 7 1 2026-11-05T09:00:00Z"
expect "and it counts towards the breaker" "$(ledger_breaker | jq -r .coder.consecutive)" 1

lock_case "$(comments "repo-agent[bot]|$(lock 556 2 "${EXPIRED}")")" "${COMPLETED}"
expect_call "expired + ended on the LAST attempt: blocked + needs-human" \
  "issue edit 7 --add-label agent:blocked --add-label agent:needs-human --remove-label agent:in-progress --remove-label agent:allow-protected"
if stub_gh_any_body 'kind=failed -->'; then t_pass "last attempt: a 'failed' inbox request"; else t_fail "last attempt: no inbox request"; fi

lock_case "$(comments "repo-agent[bot]|$(lock 557 1 "${EXPIRED}")")" "${RUNNING}"
expect_no_call "expired but the run is still in progress: untouched" "issue edit 7"
lock_case "$(comments "repo-agent[bot]|$(lock 557 1 "${EXPIRED}")")" "${QUEUED}"
expect_no_call "expired but the run is still queued: untouched" "issue edit 7"
lock_case "$(comments "repo-agent[bot]|$(lock 558 1 "${FRESH}")")" "${COMPLETED}"
expect_no_call "not expired yet: untouched, even if the run ended" "issue edit 7"
expect_no_call "and its run is not even looked up" "actions/runs/558"
lock_case "$(comments "repo-agent[bot]|$(lock 559 1 "${EXPIRED}")")" '' 1 'gh: HTTP 502'
expect_no_call "a run that cannot be read: untouched" "issue edit 7"
lock_case "$(comments "repo-agent[bot]|$(lock 560 1 "${EXPIRED}")")" '' 1 'gh: Not Found (HTTP 404)'
expect_call "a run that is gone (404) frees the lock" "issue edit 7 --add-label agent:ready"
lock_case "$(comments "outsider|$(lock 561 1 "${EXPIRED}")")" "${COMPLETED}"
expect_no_call "a lock pasted by someone else does not count" "issue edit 7"
lock_case "$(comments "repo-agent[bot]|$(lock 562 1 "${FRESH}")" "outsider|$(lock 563 1 "${EXPIRED}")")" "${COMPLETED}"
expect_no_call "a forged expired lock after the bot's fresh one does not count" "issue edit 7"
lock_case "$(comments "repo-agent[bot]|$(lock 564 1 2026-11-05T08:00:00Z)" "repo-agent[bot]|$(lock 565 2 "${FRESH}")")" "${COMPLETED}"
expect_no_call "the NEWEST bot lock decides (an old expired one does not)" "issue edit 7"

rows_before="$(ledger_rows | wc -l | tr -d ' ')"
LEDGER_RUNS='{"run_id":"566","role":"coder","attempt":1,"outcome":"failed"}' LEDGER_RC=0 \
  lock_case "$(comments "repo-agent[bot]|$(lock 566 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a run that already has its row is still released" "issue edit 7 --add-label agent:ready"
expect "but gets no second row" "$(ledger_rows | wc -l | tr -d ' ')" "${rows_before}"
expect_no_call "and no second comment (its finalize wrote one)" "issue comment 7"
LEDGER_RUNS='{"run_id":"576","role":"coder","attempt":2,"outcome":"failed","counted":false}' LEDGER_RC=0 \
  lock_case "$(comments "repo-agent[bot]|$(lock 576 2 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a finalized run that never reached the model goes back to the queue, even on its last attempt" "issue edit 7 --add-label agent:ready"
if stub_gh_any_body 'kind=failed -->'; then t_fail "an uncounted run filed a last-attempt request"; else t_pass "and files no last-attempt request"; fi
LEDGER_RUNS='{"run_id":"577","role":"coder","attempt":1,"outcome":"failed"}' LEDGER_RC=0 \
  lock_case "$(comments "repo-agent[bot]|$(lock 577 2 "${EXPIRED}")")" "${COMPLETED}"
if stub_gh_any_body 'kind=failed -->'; then t_pass "a re-run (same run id, attempt 2) that died is not its first run's row: the last-attempt request is filed"; else t_fail "a dead re-run was taken for its finalized first run"; fi
expect "and it gets its own row" "$(ledger_rows | jq -r 'select(.run_id == "577" and .attempt == 2) | .outcome')" failed
LEDGER_RUNS='{"run_id":"570","role":"coder","attempt":1,"outcome":"blocked","reason":"needs a decision"}' LEDGER_RC=0 \
  lock_case "$(comments "repo-agent[bot]|$(lock 570 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a finalized run whose relabel never landed gets its row's outcome (blocked), not 'failed'" \
  "issue edit 7 --add-label agent:blocked --add-label agent:needs-human --remove-label agent:in-progress"
expect_no_call "and no second inbox request (its finalize filed one)" "issue comment 99"
LEDGER_RC=1 LEDGER_ERR='gh: HTTP 502' \
  lock_case "$(comments "repo-agent[bot]|$(lock 567 1 "${EXPIRED}")")" "${COMPLETED}"
expect "an unreadable ledger writes no row (it may be there)" "$(ledger_rows | grep -c '"567"')" 0
expect_no_call "and leaves the issue alone until it can be read" "issue edit 7"
if grep -q 'ledger unreadable' "${TMP}/sweep.out"; then t_pass "saying why"; else t_fail "unreadable ledger: $(cat "${TMP}/sweep.out")"; fi

# The run opened its PR (the footer names this run and this issue), then died before finalize.
TIMELINE="$(jq -s . <(xpr 71 open null repo-agent[bot] agent:pr o/r $'Refs #7\n\n<!-- agent-run:coder run=571 issue=7 -->'))" \
  lock_case "$(comments "repo-agent[bot]|$(lock 571 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a run that opened its PR: agent:pr-open, not back in the queue" \
  "issue edit 7 --add-label agent:pr-open --remove-label agent:in-progress --remove-label agent:allow-protected"
if stub_gh_any_body '<!-- agent-sweep:stale-lock run=571 -->' && stub_gh_any_body '#71'; then t_pass "and the issue is told about the PR"; else t_fail "no comment naming #71"; fi
expect "its row says pr-opened, with the PR" "$(ledger_rows | jq -r 'select(.run_id == "571") | "\(.outcome) \(.pr)"')" "pr-opened 71"
expect_no_call "and no inbox request" "issue comment 99"
rows_before="$(ledger_rows | wc -l | tr -d ' ')"
TIMELINE="$(jq -s . <(xpr 76 open null repo-agent[bot] agent:pr o/r $'Refs #7\n\n<!-- agent-run:coder run=576 issue=7 -->'))" \
  LEDGER_RUNS='{"run_id":"576","role":"coder","attempt":1,"outcome":"pr-opened","pr":76}' LEDGER_RC=0 \
  lock_case "$(comments "repo-agent[bot]|$(lock 576 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a run that opened its PR AND finalized: agent:pr-open" "issue edit 7 --add-label agent:pr-open"
expect_no_call "with no second comment (finalize said it)" "issue comment 7"
expect "and no second row" "$(ledger_rows | wc -l | tr -d ' ')" "${rows_before}"
TIMELINE="$(jq -s . <(xpr 72 closed 2026-11-04T10:00:00Z repo-agent[bot] agent:pr o/r $'Refs #7\n\n<!-- agent-run:coder run=400 issue=7 -->'))" \
  lock_case "$(comments "repo-agent[bot]|$(lock 572 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a PR an EARLIER run opened does not count for this one: back to agent:ready" "issue edit 7 --add-label agent:ready"
TIMELINE="$(jq -s . <(xpr 73 open null repo-agent[bot] agent:pr o/r $'Refs #9\n\n<!-- agent-run:coder run=573 issue=9 -->'))" \
  lock_case "$(comments "repo-agent[bot]|$(lock 573 1 "${EXPIRED}")")" "${COMPLETED}"
expect_call "nor does this run's footer for another issue (a comment mention)" "issue edit 7 --add-label agent:ready"

ACTIVE=1 lock_case "$(comments "repo-agent[bot]|$(lock 574 1 "${EXPIRED}")")" "${COMPLETED}"
expect_no_call "while a coder run is in progress, no lock is swept" "issue edit 7"
expect_no_call "and no issue is even read" "issues/7/comments"
stub_gh_reset_rules
stub_gh_on 'api repos/o/r/actions/workflows/agent-coder.yml/runs*' ''
if sweep_locks >/dev/null 2>&1; then t_fail "an empty run count reads as fine"; else t_pass "a run count that is not a number fails the part"; fi
HAVE=$'agent:in-progress\nagent:hold' lock_case "$(comments "repo-agent[bot]|$(lock 575 1 "${EXPIRED}")")" "${COMPLETED}"
expect_no_call "an issue on agent:hold is never touched" "issue edit 7"
expect_no_call "nor commented on" "issue comment 7"
stub_gh_reset_rules
stub_gh_json 'issue list --state open --label agent:in-progress *' '[{"number":7,"labels":[{"name":"agent:in-progress"},{"name":"agent:hold"}]},{"number":6,"labels":[{"name":"agent:in-progress"}]}]'
expect "the lists leave agent:hold out" "$(open_issues agent:in-progress | tr '\n' ' ')" "6 "

# ledger_row reads last month too, including on the 1st and after a short month.
for c in "1796085000 2026-11" "1804118400 2027-02"; do # 2026-12-01T00:30Z, 2027-03-04T00:00Z
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_on 'api * repos/o/r/contents/runs/*' '' 1 'gh: Not Found (HTTP 404)'
  AGENT_NOW_EPOCH="${c% *}" ledger_row 1 >/dev/null 2>&1
  expect_call "on $(jq -rn --argjson e "${c% *}" '$e | todate'), last month is ${c#* }" "contents/runs/${c#* }.jsonl"
done

# released meanwhile: the label list said in-progress, the re-read does not
lock_case "$(comments "repo-agent[bot]|$(lock 568 1 "${EXPIRED}")")" "${COMPLETED}"
stub_gh_reset_calls
stub_gh_reset_rules
stub_gh_on 'issue list --state open --label agent:in-progress *' '7'
stub_gh_on 'issue view 7 --json labels *' 'agent:pr-open'
stub_gh_json 'api --paginate repos/o/r/issues/7/comments*' "$(comments "repo-agent[bot]|$(lock 568 1 "${EXPIRED}")")"
stub_gh_json 'api repos/o/r/actions/runs/*' "${COMPLETED}"
sweep_locks >/dev/null 2>&1
expect_no_call "an issue its run released a moment ago is left alone" "issue edit 7"

# Two failures already on the breaker: one more stale lock without a row is the third, which trips it
# and files a breaker request, as finalize would have.
git init -q --bare "${TMP}/ledger-trip.git"
LEDGER_REMOTE="${TMP}/ledger-trip.git"
bash "${REPO_ROOT}/.github/scripts/agent-ledger.sh" breaker-record coder failed r1 >/dev/null
bash "${REPO_ROOT}/.github/scripts/agent-ledger.sh" breaker-record coder failed r2 >/dev/null
lock_case "$(comments "repo-agent[bot]|$(lock 569 1 "${EXPIRED}")")" "${COMPLETED}"
expect "the stale lock is the third failure in a row" \
  "$(git --git-dir="${TMP}/ledger-trip.git" show agent-ledger:state/breaker.json | jq -r '"\(.coder.consecutive) \(.coder.tripped_at != null)"')" "3 true"
if stub_gh_any_body 'kind=breaker -->'; then t_pass "and files a breaker request"; else t_fail "the breaker tripped with no request"; fi
LEDGER_REMOTE="${TMP}/ledger.git"

# --- 2b. fix locks ---------------------------------------------------------------------------------
fixlock() { printf '<!-- agent:fix-lock kind=%s n=%s run=%s sha=abc123 source=901 expires=%s -->\nThe fixer agent is working on this.' "$1" "$2" "$3" "$4"; }
fix_case() { # fix_case <comments-json> <run-json> [ledger-runs]
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_on 'label list *' "${labels_all}"
  stub_gh_json 'api repos/o/r/actions/workflows/agent-fixup.yml/runs*' "{\"total_count\":${ACTIVE:-0}}"
  stub_gh_json 'pr list --state open --label agent:fixing *' '[{"number":44,"labels":[{"name":"agent:fixing"}]},{"number":45,"labels":[{"name":"agent:fixing"},{"name":"agent:hold"}]}]'
  local have='[{"name":"agent:pr"},{"name":"agent:fixing"}]'
  stub_gh_json 'api repos/o/r/issues/44/labels*' "${HAVE:-${have}}"
  stub_gh_on 'pr view 44 --json body' '{"body":"## What\nx\n\nRefs #7"}'
  stub_gh_on 'issue view 99 --json body *' $'intro\n<!-- agent-inbox:open:start -->\n<!-- agent-inbox:open:end -->'
  stub_gh_json 'api --paginate repos/o/r/issues/44/comments*' "$1"
  # The fix job, as finalize reads it for a cancelled run: by default a person stopped it 5 minutes in.
  local person_cancel='{"jobs":[{"id":502,"name":"fix (agent)","conclusion":"cancelled","started_at":"2026-11-05T09:01:00Z","completed_at":"2026-11-05T09:06:00Z","steps":[{"name":"Set up job","started_at":"2026-11-05T09:01:00Z"}]}]}'
  local by_person='[{"annotation_level":"failure","message":"The run was canceled by @owner-login."}]'
  stub_gh_json 'api repos/o/r/actions/runs/*/jobs*' "${JOBS:-${person_cancel}}"
  stub_gh_json 'api --paginate repos/o/r/check-runs/*/annotations*' "${NOTES:-${by_person}}"
  stub_gh_json 'api repos/o/r/actions/runs/*' "$2"
  stub_gh_on 'api * repos/o/r/contents/runs/*' "${3:-}" "$([[ -n "${3:-}" ]] && echo 0 || echo 1)" 'gh: Not Found (HTTP 404)'
  sweep_fixes >"${TMP}/sweep.out" 2>"${TMP}/sweep.err"
}
unlocked() { stub_gh_calls | grep -Fxq 'api -X DELETE repos/o/r/issues/44/labels/agent%3Afixing'; }
FAILED='{"status":"completed","conclusion":"failure","run_started_at":"2026-11-05T09:00:00Z"}'
fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7001 "${EXPIRED}")")" "${FAILED}"
if unlocked; then t_pass "a dead fix run's lock: the PR is unlocked"; else t_fail "a dead fix run's lock stayed: $(cat "${TMP}/sweep.out")"; fi
expect_call "and, with a CI attempt left, the fix is retried on the runner ref" "workflow run agent-fixup.yml --ref agent-runner -f pr=44 -f kind=ci -f source=901"
expect "and it gets a fixer ledger row" "$(ledger_rows | jq -r 'select(.run_id == "7001") | "\(.role) \(.outcome) \(.trigger)"')" "fixer failed sweep"
fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7002 "${EXPIRED}")")" "${COMPLETED}" '{"run_id":"7002","role":"fixer","attempt":1,"outcome":"refused"}'
if unlocked; then t_pass "a run that finalized but kept its lock is just unlocked"; else t_fail "the finalized run's lock stayed"; fi
expect_no_call "and not retried" "workflow run"
fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7009 "${EXPIRED}")")" "${COMPLETED}"
if unlocked; then t_pass "a dead fix run that was CANCELLED: unlocked"; else t_fail "a cancelled dead fix stayed locked"; fi
expect_no_call "and, cancelled by a person, not retried" "workflow run"
JOBS='{"jobs":[{"id":502,"name":"fix (agent)","conclusion":"cancelled","started_at":"2026-11-05T09:01:00Z","completed_at":"2026-11-05T09:31:00Z","steps":[{"name":"Set up job","started_at":"2026-11-05T09:01:00Z"}]}]}' \
  NOTES='[{"annotation_level":"failure","message":"The job has exceeded the maximum execution time of 30m0s"}]' fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7010 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a dead fix run CANCELLED by its fix job's 30-minute timeout is retried" "workflow run agent-fixup.yml --ref agent-runner -f pr=44 -f kind=ci"
JOBS='{"jobs":[{"id":501,"name":"preflight","conclusion":"cancelled","started_at":"2026-11-05T09:00:00Z","completed_at":"2026-11-05T09:01:00Z","steps":[{"name":"Set up job","started_at":"2026-11-05T09:00:00Z"}]},{"id":502,"name":"fix (agent)","conclusion":"skipped","started_at":"2026-11-05T09:01:00Z","completed_at":"2026-11-05T09:01:00Z","steps":[]}]}' \
  fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7011 "${EXPIRED}")")" "${COMPLETED}"
expect_no_call "a dead run cancelled in preflight (its fix job skipped) is not retried" "workflow run"
JOBS='{"jobs":[{"id":502,"name":"fix (agent)","conclusion":"success","started_at":"2026-11-05T09:01:00Z","completed_at":"2026-11-05T09:20:00Z","steps":[{"name":"Set up job","started_at":"2026-11-05T09:01:00Z"}]},{"id":503,"name":"publish and finalize","conclusion":"cancelled","started_at":"2026-11-05T09:21:00Z","completed_at":"2026-11-05T09:31:00Z","steps":[{"name":"Set up job","started_at":"2026-11-05T09:21:00Z"}]}]}' \
  NOTES='[{"annotation_level":"failure","message":"The job has exceeded the maximum execution time of 10m0s"}]' \
  fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7012 "${EXPIRED}")")" "${COMPLETED}"
expect_call "a dead run whose publish job hit its 10-minute limit is a failure: retried" "workflow run agent-fixup.yml --ref agent-runner -f pr=44 -f kind=ci"
fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7003 "${FRESH}")")" "${COMPLETED}"
if unlocked; then t_fail "a fresh fix lock was freed"; else t_pass "a fix lock that has not expired stays"; fi
fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7004 "${EXPIRED}")")" "${RUNNING}"
if unlocked; then t_fail "a running fix lost its lock"; else t_pass "an expired fix lock whose run still runs stays"; fi
fix_case "$(comments "outsider|$(fixlock ci 1 7005 "${EXPIRED}")")" "${COMPLETED}"
if unlocked; then t_pass "a PR whose only fix lock was pasted by someone else holds no bot lock: unlocked"; else t_fail "a lockless agent:fixing PR stayed locked"; fi
expect_no_call "and the pasted lock does not count as a run to finalize or retry" "workflow run"
fix_case '[]' "${COMPLETED}"
if unlocked; then t_pass "agent:fixing with no fix lock at all (preflight cancelled between label and comment): unlocked"; else t_fail "a lockless fix stayed locked"; fi
ACTIVE=1 fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7006 "${EXPIRED}")")" "${COMPLETED}"
if unlocked; then t_fail "a fix lock was freed while a fixer run was in progress"; else t_pass "no fix lock is swept while a dispatched fixer run is in progress"; fi
expect_call "and the count asked for dispatched runs only (routing runs never lock)" "agent-fixup.yml/runs?event=workflow_dispatch&status=in_progress"
fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7007 "${EXPIRED}")")" "${COMPLETED}"
expect_no_call "a PR on agent:hold is left out of the list" "issues/45/comments"
HAVE='[{"name":"agent:pr"},{"name":"agent:fixing"},{"name":"agent:hold"}]' \
  fix_case "$(comments "repo-agent[bot]|$(fixlock ci 1 7008 "${EXPIRED}")")" "${COMPLETED}"
if unlocked; then t_fail "a PR put on agent:hold meanwhile was unlocked"; else t_pass "a PR put on agent:hold after the list is left alone too"; fi

# --- 3. PRs ----------------------------------------------------------------------------------------
pr_case() { # pr_case <timeline-json>
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_on 'label list *' "${labels_all}"
  stub_gh_on 'issue list --state open --label agent:pr-open *' '8'
  stub_gh_on 'issue view 8 --json labels *' $'agent:pr-open\npriority: low'
  stub_gh_json 'api --paginate repos/o/r/issues/8/timeline*' "$1"
  stub_gh_on 'pr view * --json mergeCommit *' 'abc1234def'
  sweep_prs >"${TMP}/sweep.out" 2>"${TMP}/sweep.err"
}
pr_case "$(jq -s . <(xpr 44 closed 2026-11-05T10:00:00Z))"
expect_call "a merged agent PR: agent:done-pending-deploy replaces agent:pr-open" \
  "issue edit 8 --add-label agent:done-pending-deploy --remove-label agent:pr-open"
body="$(stub_gh_last_body 'issue comment 8 *')"
expect "with the merged marker" "$(head -1 <<<"${body}")" "<!-- agent-merged pr=44 -->"
if grep -Fq 'abc1234def' <<<"${body}" && grep -qi 'prod' <<<"${body}"; then t_pass "naming the merge commit and the prod check"; else t_fail "merged comment was '${body}'"; fi
expect_no_call "the sweep never closes an issue" "issue close"
pr_case "$(jq -s . <(xpr 45 closed null))"
expect_call "an agent PR closed unmerged: agent:blocked" "issue edit 8 --add-label agent:blocked --remove-label agent:pr-open"
if stub_gh_any_body '<!-- agent-sweep:pr-closed pr=45 -->'; then t_pass "and says so on the issue"; else t_fail "no pr-closed comment"; fi
pr_case "$(jq -s . <(xpr 45 closed null) <(xpr 46 open null))"
expect_no_call "while any agent PR is open: untouched" "issue edit 8"
pr_case "$(jq -s . <(xpr 45 closed null) <(xpr 47 closed 2026-11-05T10:00:00Z))"
expect_call "the newest agent PR decides: a later merged one wins over an earlier closed one" \
  "issue edit 8 --add-label agent:done-pending-deploy"
pr_case "$(jq -s . <(xpr 48 closed 2026-11-05T10:00:00Z owner-login))"
expect_no_call "a merged PR by a person, even labelled agent:pr, is not the agent's PR: untouched" "issue edit 8"
pr_case "$(jq -s . <(xpr 49 closed 2026-11-05T10:00:00Z repo-agent[bot] 'agent:pr' other/repo))"
expect_no_call "an agent PR in another repository: untouched" "issue edit 8"
pr_case "$(jq -s . <(xpr 50 closed 2026-11-05T10:00:00Z repo-agent[bot] ''))"
expect_no_call "a bot PR without agent:pr is not an agent PR: untouched" "issue edit 8"
pr_case "$(jq -s . <(xpr 51 closed 2026-11-05T10:00:00Z repo-agent[bot] agent:pr o/r $'Refs #9\n\n<!-- agent-run:coder run=1 issue=9 -->'))"
expect_no_call "a merged agent PR for ANOTHER issue (a comment on it mentions this one): untouched" "issue edit 8"
pr_case "$(jq -s . <(xpr 52 closed 2026-11-05T10:00:00Z repo-agent[bot] agent:pr o/r $'Refs #8'))"
expect_no_call "an agent-labelled bot PR without the outbox footer: untouched" "issue edit 8"
pr_case '[]'
expect_no_call "pr-open with no agent PR at all: untouched" "issue edit 8"
stub_gh_reset_calls
stub_gh_reset_rules
stub_gh_on 'issue view 8 --json labels *' 'agent:done-pending-deploy'
mark_merged 8 44 >/dev/null 2>&1
expect_no_call "mark_merged is idempotent: an issue no longer pr-open is left alone" "issue edit 8"
expect_no_call "and gets no second comment" "issue comment 8"

# --- 4. breaker ------------------------------------------------------------------------------------
breaker_case() { # breaker_case <breaker-json>
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_on 'issue view 99 --json body *' $'intro\n<!-- agent-inbox:open:start -->\n<!-- agent-inbox:open:end -->'
  stub_gh_on 'api * repos/o/r/contents/state/breaker.json*' "$1"
  sweep_breaker >"${TMP}/sweep.out" 2>"${TMP}/sweep.err"
}
git init -q --bare "${TMP}/ledger2.git"
LEDGER_REMOTE="${TMP}/ledger2.git"
breaker_case '{"coder":{"consecutive":3,"tripped_at":null}}'
expect "a count at the threshold that never tripped is tripped now" \
  "$(git --git-dir="${TMP}/ledger2.git" show agent-ledger:state/breaker.json | jq -r '.coder.tripped_at != null')" true
if stub_gh_any_body 'kind=breaker -->'; then t_pass "with a breaker request"; else t_fail "no breaker request"; fi
git init -q --bare "${TMP}/ledger3.git"
LEDGER_REMOTE="${TMP}/ledger3.git"
breaker_case '{"coder":{"consecutive":3,"tripped_at":"2026-11-05T09:00:00Z"}}'
expect "an already-tripped breaker is not tripped again" "$(git --git-dir="${TMP}/ledger3.git" show agent-ledger:state/breaker.json 2>/dev/null)" ""
expect_no_call "and files no second request" "issue comment 99"
breaker_case '{"coder":{"consecutive":2,"tripped_at":null}}'
expect "below the threshold: nothing" "$(git --git-dir="${TMP}/ledger3.git" show agent-ledger:state/breaker.json 2>/dev/null)" ""
breaker_case '{"coder":{"consecutive":0,"tripped_at":null}}'
expect "a reset breaker stays reset" "$(git --git-dir="${TMP}/ledger3.git" show agent-ledger:state/breaker.json 2>/dev/null)" ""
jq 'del(.roles.coder.breakerThreshold)' "${AGENT_POLICY}" >"${TMP}/policy-nothreshold.json"
(AGENT_POLICY="${TMP}/policy-nothreshold.json" breaker_case '{"coder":{"consecutive":2,"tripped_at":null}}')
expect "a role with no breakerThreshold: the part still works" "$?" 0
expect "and uses 3, as finalize does (2 does not trip)" \
  "$(git --git-dir="${TMP}/ledger3.git" show agent-ledger:state/breaker.json 2>/dev/null)" ""
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/state/breaker.json*' '' 1 'gh: HTTP 502'
if sweep_breaker >/dev/null 2>&1; then t_fail "an unreadable breaker reads as fine"; else t_pass "an unreadable breaker fails the part"; fi

# --- the whole run ---------------------------------------------------------------------------------
stub_gh_reset_rules
stub_gh_json 'api repos/o/r/actions/workflows/agent-coder.yml/runs*' '{"total_count":0}'
stub_gh_on 'issue list --state open --label agent:in-progress *' '' 1 'gh: HTTP 502'
stub_gh_on 'issue list --state open --label agent:pr-open *' ''
stub_gh_on 'api * repos/o/r/contents/state/breaker.json*' '{}'
cmd_run >"${TMP}/run.out" 2>&1
expect "one failed part fails the run" "$?" 1
expect "but the other parts still ran" "$(grep -c '^breaker: \|^breaker coder' "${TMP}/run.out")" 1

printf '\n[agents-sweep] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
