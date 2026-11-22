#!/usr/bin/env bash
# tests/workflows/agents-ledger.test.sh
# .github/scripts/agent-ledger.sh against a local bare repo standing in for GitHub. Pinned:
#   1. The first write creates the orphan `agent-ledger` branch; rows append, one JSON object a line.
#   2. A row that is not a JSON object is refused rather than written.
#   3. The breaker trips at the policy threshold, says so exactly ONCE (that is what files the inbox
#      request, so saying it twice files two), resets on a PR and on /resume, and /pause trips it.
#   4. A push that loses a race is redone on the new tip: no row is lost, nothing is forced.
#   5. Writers racing for real (roles.coder.parallelism > 1 finalizes at once): every row lands once;
#      concurrent failures all count and the breaker announces its trip exactly once; an attempt that
#      tripped it but lost the race does not report the trip; a row already on the tip is not
#      written twice; a breaker step repeated with the same key (its push landed but reported an
#      error) is not counted twice, and says "tripped" again when it was the one that tripped it.
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

# --- 5. real concurrency ---------------------------------------------------------------------------
for r in c1 c2 c3 c4 c5; do
  (bash "${LEDGER}" append "{\"role\":\"coder\",\"outcome\":\"failed\",\"run_id\":\"${r}\"}" >/dev/null 2>&1) &
done
wait
expect "five appends at once: each row lands exactly once" \
  "$(show "runs/${MONTH}.jsonl" | jq -rs '[.[] | select(.run_id | startswith("c"))] | map(.run_id) | sort | join(",")')" "c1,c2,c3,c4,c5"
bash "${LEDGER}" breaker-reset coder >/dev/null
for r in b1 b2 b3; do (bash "${LEDGER}" breaker-record coder failed "${r}" >"${TMP}/trip.${r}" 2>/dev/null) & done
wait
expect "three failures at once all count" "$(show state/breaker.json | jq -r .coder.consecutive)" 3
expect "and the trip is announced exactly once" "$(cat "${TMP}"/trip.b? | grep -c tripped)" 1
bash "${LEDGER}" breaker-reset coder >/dev/null
bash "${LEDGER}" breaker-record coder failed s1 >/dev/null
bash "${LEDGER}" breaker-record coder failed s2 >/dev/null
# The racer lands the third failure first, so this call's first attempt trips it and loses the push;
# redone on the new tip, the breaker is already open and this call must not say "tripped".
trip_racer() {
  local d
  d="$(mktemp -d)"
  git clone -q --branch agent-ledger "${TMP}/remote.git" "${d}" 2>/dev/null
  jq '.coder.consecutive = 3 | .coder.tripped_at = "2026-11-05T11:59:00Z"' "${d}/state/breaker.json" >"${d}/b" && mv "${d}/b" "${d}/state/breaker.json"
  git -C "${d}" commit -qam "racer trips"
  git -C "${d}" push -q origin agent-ledger
  rm -rf "${d}"
}
export -f trip_racer
out="$(AGENT_LEDGER_TEST_RACE=trip_racer bash "${LEDGER}" breaker-record coder failed s3 2>/dev/null)"
expect "an attempt that tripped it but lost the race does not report the trip" "${out}" ""
expect "and the winning edit counted it on top" "$(show state/breaker.json | jq -r .coder.consecutive)" 4
bash "${LEDGER}" breaker-reset coder >/dev/null
bash "${LEDGER}" breaker-record coder failed k1 key-1 >/dev/null
bash "${LEDGER}" breaker-record coder failed k1 key-1 >/dev/null
expect "a breaker step repeated with its key counts once" "$(show state/breaker.json | jq -r .coder.consecutive)" 1
bash "${LEDGER}" breaker-record coder failed k2 key-2 >/dev/null
first="$(bash "${LEDGER}" breaker-record coder failed k3 key-3)"
again="$(bash "${LEDGER}" breaker-record coder failed k3 key-3)"
expect "the step that tripped it, repeated, says tripped again and counts once" "${first}|${again}|$(show state/breaker.json | jq -r .coder.consecutive)" "tripped|tripped|3"
expect "a later step, a new key, is counted and does not announce" "$(bash "${LEDGER}" breaker-record coder failed k4 key-4)|$(show state/breaker.json | jq -r .coder.consecutive)" "|4"
# Another run's step lands between a step and its retry (a, b, a): still counted once, and the
# step that tripped it still says so.
bash "${LEDGER}" breaker-reset coder >/dev/null
bash "${LEDGER}" breaker-record coder failed x1 key-a >/dev/null
bash "${LEDGER}" breaker-record coder failed x2 key-b >/dev/null
bash "${LEDGER}" breaker-record coder failed x1 key-a >/dev/null
expect "a, b, a: the retried step is not counted again" "$(show state/breaker.json | jq -r .coder.consecutive)" 2
trip="$(bash "${LEDGER}" breaker-record coder failed x3 key-c)"
bash "${LEDGER}" breaker-record coder failed x4 key-d >/dev/null
again="$(bash "${LEDGER}" breaker-record coder failed x3 key-c)"
expect "a, b, a after a trip: the tripping step says tripped again, counted once" "${trip}|${again}|$(show state/breaker.json | jq -r .coder.consecutive)" "tripped|tripped|4"
bash "${LEDGER}" breaker-record coder pr-opened x5 key-e >/dev/null
bash "${LEDGER}" breaker-record coder failed x6 key-f >/dev/null
bash "${LEDGER}" breaker-record coder pr-opened x5 key-e >/dev/null
expect "a success retried after another run's failure does not wipe that failure" "$(show state/breaker.json | jq -r .coder.consecutive)" 1
row='{"role":"coder","outcome":"pr-opened","run_id":"dup"}'
bash "${LEDGER}" append "${row}" >/dev/null
bash "${LEDGER}" append "${row}" >/dev/null
expect "the exact row already on the tip is not written twice" "$(show "runs/${MONTH}.jsonl" | grep -c '"run_id":"dup"')" 1

printf '\n[agents-ledger] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
