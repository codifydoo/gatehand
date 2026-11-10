#!/usr/bin/env bash
# tests/workflows/agents-ledger.test.sh
# .github/scripts/agent-ledger.sh against a local bare repo standing in for GitHub. Pinned:
#   1. The first write creates the orphan `agent-ledger` branch; rows append, one JSON object a line.
#   2. A row that is not a JSON object is refused rather than written.
#   3. The breaker trips at the policy threshold, says so exactly ONCE (that is what files the inbox
#      request, so saying it twice files two), resets on a PR and on /resume, and /pause trips it.
#   4. A push that loses a race is redone on the new tip: no row is lost, nothing is forced.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
LEDGER="${REPO_ROOT}/.github/scripts/agent-ledger.sh"

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-ledger] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-ledger] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare "${TMP}/remote.git"
export LEDGER_REMOTE="${TMP}/remote.git" AGENT_LEDGER_BACKOFF=0
export AGENT_NOW_EPOCH=1793880000 # 2026-11-05T12:00:00Z
MONTH=2026-11

show() { git --git-dir="${TMP}/remote.git" show "agent-ledger:$1" 2>/dev/null; }

# --- 1. append -------------------------------------------------------------------------------------
bash "${LEDGER}" append '{"role":"coder","outcome":"pr-opened","run_id":"1"}' >/dev/null
bash "${LEDGER}" append '{"role":"coder","outcome":"failed","run_id":"2"}' >/dev/null
expect "two rows appended to runs/${MONTH}.jsonl" "$(show "runs/${MONTH}.jsonl" | wc -l | tr -d ' ')" 2
expect "rows are JSON objects in order" "$(show "runs/${MONTH}.jsonl" | jq -rs 'map(.run_id) | join(",")')" "1,2"
expect "the ledger branch shares no history with anything (one root)" \
  "$(git --git-dir="${TMP}/remote.git" rev-list --max-parents=0 agent-ledger | wc -l | tr -d ' ')" 1

# --- 2. refusal ------------------------------------------------------------------------------------
bash "${LEDGER}" append '["not","an","object"]' >/dev/null 2>&1
expect "a non-object row is refused (exit 2)" "$?" 2
expect "and nothing was written" "$(show "runs/${MONTH}.jsonl" | wc -l | tr -d ' ')" 2

# --- 3. breaker ------------------------------------------------------------------------------------
out1="$(bash "${LEDGER}" breaker-record coder failed r1)"
out2="$(bash "${LEDGER}" breaker-record coder no-op r2)"
expect "two failures do not trip a threshold of 3" "${out1}${out2}" ""
expect "consecutive failures counted" "$(show state/breaker.json | jq -r .coder.consecutive)" 2
out3="$(bash "${LEDGER}" breaker-record coder refused r3)"
expect "the third failure trips it and says so" "${out3}" "tripped"
expect "tripped_at is set" "$(show state/breaker.json | jq -r '.coder.tripped_at != null')" true
out4="$(bash "${LEDGER}" breaker-record coder failed r4)"
expect "an already-open breaker does not announce again" "${out4}" ""
bash "${LEDGER}" breaker-reset coder >/dev/null
expect "reset clears tripped_at" "$(show state/breaker.json | jq -r .coder.tripped_at)" null
expect "reset zeroes the count" "$(show state/breaker.json | jq -r .coder.consecutive)" 0
bash "${LEDGER}" breaker-record coder failed r5 >/dev/null
bash "${LEDGER}" breaker-record coder pr-opened r6 >/dev/null
expect "a PR resets the count" "$(show state/breaker.json | jq -r .coder.consecutive)" 0
bash "${LEDGER}" breaker-record fixer failed f1 >/dev/null
bash "${LEDGER}" breaker-record fixer fix-pushed f2 >/dev/null
expect "a pushed fix resets the fixer's count" "$(show state/breaker.json | jq -r '"\(.fixer.consecutive) \(.fixer.last_outcome)"')" "0 fix-pushed"
bash "${LEDGER}" breaker-trip coder "paused by the owner" >/dev/null
expect "/pause trips it with the reason" "$(show state/breaker.json | jq -r .coder.reason)" "paused by the owner"
expect "breaker state stays per role (the fixer's above is its own)" "$(show state/breaker.json | jq -r 'keys | join(",")')" "coder,fixer"

# --- 4. a lost race is redone, never forced -------------------------------------------------------
race() {
  local d
  d="$(mktemp -d)"
  git clone -q --branch agent-ledger "${TMP}/remote.git" "${d}" 2>/dev/null
  printf '%s\n' '{"role":"other","run_id":"racer"}' >>"${d}/runs/${MONTH}.jsonl"
  git -C "${d}" commit -qam "racer"
  git -C "${d}" push -q origin agent-ledger
  rm -rf "${d}"
}
export -f race
export TMP MONTH
AGENT_LEDGER_TEST_RACE=race bash "${LEDGER}" append '{"role":"coder","outcome":"failed","run_id":"3"}' >/dev/null 2>&1
expect "after a lost race both writes are on the branch" \
  "$(show "runs/${MONTH}.jsonl" | jq -rs 'map(.run_id) | join(",")')" "1,2,racer,3"

printf '\n[agents-ledger] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
