#!/usr/bin/env bash
# .github/scripts/agent-ledger.sh
# The autonomous agents' run ledger and circuit breaker, kept on the orphan branch `agent-ledger`.
#
# WHY A BRANCH: the ledger must outlive any one run (Actions logs expire and the runners are
# `--rm`), stay readable by a job holding only `contents: read`, and grow past what an issue body
# holds (65,536 characters is a few hundred rows). An orphan branch is append-only history with
# git's integrity for free, readable with
#   git fetch origin agent-ledger && git show origin/agent-ledger:runs/2026-11.jsonl | jq
# The main ruleset targets only the default branch, so the agent App can push here without a bypass.
#
# Layout on the branch:
#   runs/YYYY-MM.jsonl     one JSON object per run (schema in .github/agents/README.md)
#   state/breaker.json     {"<role>": {"consecutive": n, "tripped_at": ISO|null, "reason": …}}
#
# Usage:
#   agent-ledger.sh append <row-json>
#   agent-ledger.sh breaker-record <role> <outcome> <run-id>   prints "tripped" when THIS call trips it
#   agent-ledger.sh breaker-trip <role> <reason>                 /pause <role>
#   agent-ledger.sh breaker-reset <role>                         /resume <role>, /approve on a breaker
#
# Env: GH_TOKEN + GH_REPO        to build the push URL, or
#      LEDGER_REMOTE             any git URL (tests use a local bare repo)
#      AGENT_LEDGER_NO_MAIN=1    load the functions without running (tests)
#
# CONCURRENCY: writers do not share a concurrency group, on purpose (see agent-lib.sh,
# inbox_add_line). Each write is a fresh shallow fetch, an edit and a push; a push that loses a race
# is rejected as non-fast-forward and the whole edit is redone on the new tip, up to five times.
set -uo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/agent-lib.sh"

ledger_remote() {
  if [[ -n "${LEDGER_REMOTE:-}" ]]; then
    printf '%s\n' "${LEDGER_REMOTE}"
  else
    printf 'https://x-access-token:%s@github.com/%s.git\n' "${GH_TOKEN:?GH_TOKEN is required}" "${GH_REPO:?GH_REPO is required}"
  fi
}

# Outcomes that prove the role works: the coder opened a PR, the fixer pushed a fix. Anything else a
# run records counts towards the breaker.
breaker_is_success() { [[ "$1" == "pr-opened" || "$1" == "fix-pushed" ]]; }

# ledger_mutate <commit-message> <function> [args…]: run <function> inside a checkout of the ledger
# branch, then commit and push what it changed. Retries the whole edit when the push loses a race.
# The function may write a result to "${LEDGER_RESULT}", which survives the checkout's removal.
ledger_mutate() {
  local msg="$1" attempt dir remote branch
  shift
  remote="$(ledger_remote)"
  branch="$(policy '.ledgerBranch')"
  for attempt in 1 2 3 4 5; do
    dir="$(mktemp -d)"
    git -C "${dir}" init -q
    git -C "${dir}" config user.name "$(policy '.botLogin')"
    git -C "${dir}" config user.email "${AGENT_BOT_EMAIL:-agent-ledger@users.noreply.github.com}"
    if git -C "${dir}" fetch -q --depth=1 "${remote}" "+refs/heads/${branch}:refs/remotes/ledger/${branch}" 2>/dev/null; then
      git -C "${dir}" checkout -q -B "${branch}" "ledger/${branch}"
    else
      # First write ever: an orphan branch with no shared history with main. A fetch that failed for
      # any OTHER reason lands here too, and is caught below: pushing a fresh root over an existing
      # branch is a non-fast-forward, so it is rejected and retried, never forced.
      git -C "${dir}" symbolic-ref HEAD "refs/heads/${branch}"
    fi
    if ! (cd "${dir}" && "$@"); then
      rm -rf "${dir}"
      return 1
    fi
    git -C "${dir}" add -A
    if git -C "${dir}" diff --cached --quiet; then
      rm -rf "${dir}"
      return 0
    fi
    git -C "${dir}" commit -q -m "${msg}"
    [[ -n "${AGENT_LEDGER_TEST_RACE:-}" && "${attempt}" -eq 1 ]] && "${AGENT_LEDGER_TEST_RACE}"
    if git -C "${dir}" push -q "${remote}" "HEAD:refs/heads/${branch}" 2>/dev/null; then
      rm -rf "${dir}"
      return 0
    fi
    rm -rf "${dir}"
    agent_log "ledger push lost a race (attempt ${attempt}); redoing the edit on the new tip"
    sleep "${AGENT_LEDGER_BACKOFF:-${attempt}}"
  done
  agent_log "ledger: gave up after 5 attempts"
  return 1
}

# --- edits (run inside the checkout) -----------------------------------------------------------------

_append_row() {
  local row="$1" month
  month="$(jq -rn --argjson e "$(agent_now_epoch)" '$e | strftime("%Y-%m")')"
  mkdir -p runs
  printf '%s\n' "${row}" >>"runs/${month}.jsonl"
}

_breaker_load() { if [[ -s state/breaker.json ]]; then cat state/breaker.json; else echo '{}'; fi; }
_breaker_save() { mkdir -p state && jq -S . >state/breaker.json.new && mv state/breaker.json.new state/breaker.json; }

_breaker_record() {
  local role="$1" outcome="$2" run="$3" threshold now state
  threshold="$(policy ".roles[\"${role}\"].breakerThreshold // 3")"
  now="$(agent_iso)"
  if breaker_is_success "${outcome}"; then
    state="$(_breaker_load | jq --arg r "${role}" --arg o "${outcome}" --arg run "${run}" --arg now "${now}" \
      '.[$r] = ((.[$r] // {}) + {consecutive: 0, last_run: $run, last_outcome: $o, updated_at: $now})')"
    printf '%s\n' "${state}" | _breaker_save
    return 0
  fi
  state="$(_breaker_load | jq --arg r "${role}" --arg o "${outcome}" --arg run "${run}" --arg now "${now}" \
    --argjson t "${threshold}" '
      (.[$r] // {consecutive: 0, tripped_at: null}) as $b
      | ($b.consecutive + 1) as $n
      | .[$r] = ($b + {consecutive: $n, last_run: $run, last_outcome: $o, updated_at: $now})
      | if $n >= $t and ($b.tripped_at // null) == null
        then .[$r].tripped_at = $now
             | .[$r].reason = "\($n) runs in a row ended without a PR (last: \($o))"
             | .[$r].newly_tripped = true
        else .[$r].newly_tripped = false end')"
  if [[ "$(jq -r --arg r "${role}" '.[$r].newly_tripped' <<<"${state}")" == "true" ]]; then
    printf 'tripped\n' >"${LEDGER_RESULT}"
  fi
  jq --arg r "${role}" 'del(.[$r].newly_tripped)' <<<"${state}" | _breaker_save
}

_breaker_trip() {
  local role="$1" reason="$2"
  _breaker_load | jq --arg r "${role}" --arg why "${reason}" --arg now "$(agent_iso)" \
    '.[$r] = ((.[$r] // {consecutive: 0}) + {tripped_at: $now, reason: $why, updated_at: $now})' | _breaker_save
}

_breaker_reset() {
  local role="$1"
  _breaker_load | jq --arg r "${role}" --arg now "$(agent_iso)" \
    '.[$r] = ((.[$r] // {}) + {consecutive: 0, tripped_at: null, reason: null, updated_at: $now})' | _breaker_save
}

main() {
  local cmd="${1:-}" rc
  shift || true
  LEDGER_RESULT="$(mktemp)"
  export LEDGER_RESULT
  case "${cmd}" in
    append)
      local row
      row="$(jq -ce 'if type == "object" then . else error("not an object") end' <<<"${1:-}")" \
        || { agent_log "append: the row is not a JSON object"; return 2; }
      ledger_mutate "ledger: $(jq -r '"\(.role // "?") \(.outcome // "?") run \(.run_id // "?")"' <<<"${row}")" _append_row "${row}"
      ;;
    breaker-record)
      [[ $# -eq 3 ]] || { agent_log "usage: breaker-record <role> <outcome> <run-id>"; return 2; }
      ledger_mutate "breaker: $1 $2" _breaker_record "$1" "$2" "$3"
      ;;
    breaker-trip)
      [[ $# -eq 2 ]] || { agent_log "usage: breaker-trip <role> <reason>"; return 2; }
      ledger_mutate "breaker: trip $1" _breaker_trip "$1" "$2"
      ;;
    breaker-reset)
      [[ $# -eq 1 ]] || { agent_log "usage: breaker-reset <role>"; return 2; }
      ledger_mutate "breaker: reset $1" _breaker_reset "$1"
      ;;
    *)
      agent_log "usage: agent-ledger.sh append|breaker-record|breaker-trip|breaker-reset …"
      return 2
      ;;
  esac
  rc=$?
  [[ -s "${LEDGER_RESULT}" ]] && cat "${LEDGER_RESULT}"
  rm -f "${LEDGER_RESULT}"
  return "${rc}"
}

if [[ "${AGENT_LEDGER_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
