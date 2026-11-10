#!/usr/bin/env bash
# .github/scripts/agent-sweep.sh
# The hourly sweep (.github/workflows/agent-sweep.yml): puts right what a run could not, because it
# crashed, was cancelled before its publish job, or because the step after it belongs to a person.
#
#   locks     an `agent:in-progress` issue whose bot lock has EXPIRED and whose run is no longer
#             queued or running is put where its run would have put it. A run that opened its PR
#             makes it `agent:pr-open`; a run that finalized but whose relabel did not land gets
#             the labels of its ledger row's outcome; any other goes back to `agent:ready`, or, on
#             its last attempt, to `agent:blocked` + `agent:needs-human` with an inbox request, and
#             gets the ledger row it never wrote (outcome `failed`), which counts towards the
#             breaker. Nothing is swept while a coder run is in progress: it may be between
#             adding `agent:in-progress` and posting its lock, when the newest lock is still the
#             previous attempt's.
#   prs       an `agent:pr-open` issue whose agent PR MERGED goes to `agent:done-pending-deploy`;
#             one whose agent PR was CLOSED unmerged goes to `agent:blocked` (a person closed it).
#             While any agent PR for it is open, nothing changes.
#   fixes     an agent PR whose `agent:fixing` lock has EXPIRED and whose fixer run has ended goes to
#             the fixer's own finalize, as if the run had failed: unlocked, retried while attempts
#             remain, blocked for a person after the last. A run that wrote its ledger row (its
#             finalize ran, only the unlock failed) is just unlocked. Nothing is swept while a
#             dispatched fixer run is in progress, for the same reason as the locks.
#   breaker   a role whose consecutive failures are at or past its threshold but which never
#             tripped is tripped now, with the inbox request finalize would have filed. Finalize
#             writes the count and the trip in one commit, so this only happens when
#             `breakerThreshold` was lowered in policy.json, or after a hand edit of the ledger.
#
# Only the bot's own lock comments count, and only the bot's own PRs: author: the agent bot,
# label agent:pr, and the outbox's `<!-- agent-run:coder run=R issue=N -->` footer for THIS issue
# in the PR's body. Anyone who can comment could otherwise paste a lock, and a comment that mentions
# an issue on any agent PR adds that PR to the issue's timeline. Issues on `agent:hold` are never
# touched. Each part runs even when another failed; the exit code is 1 when any part failed, so a
# broken sweep shows red.
#
# Usage: agent-sweep.sh run | locks | fixes | prs | breaker
# Env:   GH_TOKEN, GH_REPO, AGENT_BOT_EMAIL, AGENT_INBOX_ISSUE, AGENT_OWNER_LOGIN;
#        AGENT_SWEEP_NO_MAIN=1 loads the functions only (tests/workflows/agents-sweep.test.sh).
#
# Backticks in the single-quoted printf formats are literal markdown.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # read by the sourced agent-state.sh
AGENT_STATE_NO_MAIN=1
# agent-state.sh brings agent-lib.sh, the ledger reader, relabel, mark_merged and the inbox requests.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-state.sh"
unset AGENT_STATE_NO_MAIN

BOT="$(policy '.botLogin')"

# --- locks -------------------------------------------------------------------------------------------

# last_lock <issue>: the newest lock comment the BOT wrote, as "run attempt expires role", or nothing.
last_lock() {
  local bodies m
  bodies="$(gh api --paginate "repos/${GH_REPO}/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"${BOT}\") | .body")" || return 1
  m="$(grep -oE '<!-- agent:lock role=[a-z]+ run=[0-9]+ attempt=[0-9]+ expires=[0-9TZ:-]+ -->' <<<"${bodies}" | tail -1)"
  [[ -n "${m}" ]] || return 0
  sed -E 's/.* role=([a-z]+) run=([0-9]+) attempt=([0-9]+) expires=([0-9TZ:-]+) .*/\2 \3 \4 \1/' <<<"${m}"
}

# run_state <run-id>: "status conclusion started_at" from the Actions API; "gone" for a 404 (the run
# was deleted, so nothing is coming back to release the lock). Exit 1 on any other error.
run_state() {
  local err out
  err="$(mktemp)"
  if out="$(gh api "repos/${GH_REPO}/actions/runs/$1" --jq '"\(.status) \(.conclusion // "none") \(.run_started_at // .created_at // "")"' 2>"${err}")"; then
    rm -f "${err}"
    printf '%s\n' "${out}"
    return 0
  fi
  if grep -q 'HTTP 404' "${err}"; then rm -f "${err}"; echo "gone none "; return 0; fi
  agent_log "could not read run $1: $(head -c 200 "${err}")"
  rm -f "${err}"
  return 1
}

# ledger_row <run-id> [attempt]: the run's row from this month's or last month's ledger, as one JSON
# line; with [attempt], only a row of that attempt ("Re-run all jobs" keeps the run id, so a re-run
# that died must not be taken for its first run, which finalized). Exit 0 found, 1 missing, 2
# unreadable.
ledger_row() {
  local now this last rows row
  now="$(agent_now_epoch)"
  this="$(jq -rn --argjson e "${now}" '$e | strftime("%Y-%m")')"
  # The day before the 1st of this month: always last month, whatever this month's length.
  last="$(jq -rn --argjson e "${now}" '($e | strftime("%Y-%m-01T00:00:00Z") | fromdateiso8601) - 86400 | strftime("%Y-%m")')"
  rows="$(ledger_file "runs/${this}.jsonl")" || return 2
  rows+=$'\n'"$(ledger_file "runs/${last}.jsonl")" || return 2
  row="$(printf '%s\n' "${rows}" | jq -cs --arg r "$1" --arg a "${2:-}" '
    [.[] | select(type == "object" and (.run_id | tostring) == $r and ($a == "" or (.attempt | tostring) == $a))] | last // empty')" \
    || return 2
  [[ -n "${row}" ]] || return 1
  printf '%s\n' "${row}"
}

# write_sweep_row <run> <role> <issue> <attempt> <outcome> <reason> <started> [pr]: the ledger row the
# run's finalize never wrote, plus its breaker step; files the breaker request if that trips it.
write_sweep_row() {
  local run="$1" role="$2" issue="$3" attempt="$4" outcome="$5" reason="$6" started="$7" pr="${8:-}" row tripped
  row="$(jq -cn --arg run "${run}" --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GH_REPO}/actions/runs/${run}" \
    --arg role "${role}" --argjson issue "${issue}" --argjson attempt "${attempt}" --arg outcome "${outcome}" \
    --arg reason "${reason}" --arg pr "${pr}" --arg model "$(policy ".roles[\"${role}\"].model")" \
    --arg started "${started}" --arg ended "$(agent_iso)" '
      {v: 1, run_id: $run, run_url: $url, role: $role, trigger: "sweep", issue: $issue, attempt: $attempt,
       pr: (if $pr == "" then null else ($pr | tonumber) end), outcome: $outcome, reason: $reason,
       model: $model, turns: null, duration_ms: null, cost_usd: null,
       started_at: (if $started == "" then $ended else $started end), ended_at: $ended}')"
  bash "${SCRIPT_DIR}/agent-ledger.sh" append "${row}" >/dev/null || agent_log "sweep: ledger append failed"
  tripped="$(bash "${SCRIPT_DIR}/agent-ledger.sh" breaker-record "${role}" "${outcome}" "${run}")" \
    || agent_log "sweep: breaker update failed"
  if [[ "${tripped}" == tripped ]]; then
    file_request breaker "${issue}" "circuit breaker tripped" \
      "$(policy ".roles[\"${role}\"].breakerThreshold // 3") runs in a row ended without a PR (last: a stale lock)" /dev/null >/dev/null \
      || agent_log "sweep: breaker request failed"
  fi
}

# sweep_one_lock <issue>: prints what it did, one line.
sweep_one_lock() {
  local issue="$1" lock run attempt expires role state status conclusion started max now have \
    plan add remove kind body reason row lrc prs pr outcome counted
  lock="$(last_lock "${issue}")" || { echo "#${issue}: comments unreadable, left alone"; return 1; }
  if [[ -z "${lock}" ]]; then echo "#${issue}: agent:in-progress with no lock by the bot, left alone"; return 0; fi
  read -r run attempt expires role <<<"${lock}"
  now="$(agent_iso)"
  if [[ ! "${expires}" < "${now}" ]]; then echo "#${issue}: lock of run ${run} holds until ${expires}"; return 0; fi
  state="$(run_state "${run}")" || { echo "#${issue}: run ${run} unreadable, left alone"; return 1; }
  read -r status conclusion started <<<"${state}"
  if [[ "${status}" != completed && "${status}" != gone ]]; then
    echo "#${issue}: lock expired but run ${run} is ${status}, left alone"
    return 0
  fi
  # Read the labels again: the run's own publish job may have released it a moment ago.
  have="$(gh issue view "${issue}" --json labels --jq '.labels[].name')" || { echo "#${issue}: labels unreadable"; return 1; }
  grep -Fxq agent:in-progress <<<"${have}" || { echo "#${issue}: released meanwhile"; return 0; }
  if grep -Fxq agent:hold <<<"${have}"; then echo "#${issue}: on agent:hold, left alone"; return 0; fi

  ROLE="${role}"
  max="$(policy ".roles[\"${role}\"].maxAttemptsPerIssue")"
  # What did the run get done before it ended? Its own PR means it got as far as the outbox; a
  # ledger row means its finalize ran too, and only the relabel did not land (finalize logs that and
  # carries on). Either way, re-queueing it would spend a run the outbox then refuses.
  prs="$(agent_prs_for "${issue}" "${run}")" || { echo "#${issue}: timeline unreadable, left alone"; return 1; }
  row="$(ledger_row "${run}" "${attempt}")"
  lrc=$?
  if [[ "${lrc}" -eq 2 ]]; then echo "#${issue}: ledger unreadable, left alone"; return 1; fi
  ensure_labels || agent_log "sweep: could not ensure labels"
  if [[ -n "${prs}" ]]; then
    read -r pr _ <<<"$(sort -n <<<"${prs}" | tail -1)"
    IFS='|' read -r add remove kind <<<"$(finalize_plan pr-opened "" "${attempt}" "${max}")"
    relabel "${issue}" "${add}" "${remove}" || { echo "#${issue}: relabel failed"; return 1; }
    if [[ "${lrc}" -eq 1 ]]; then
      body="$(mktemp)"
      printf '<!-- agent-sweep:stale-lock run=%s -->\nThe %s agent opened #%s in [run %s](%s/%s/actions/runs/%s), which ended before it could say so here. This issue follows #%s from now on.\n' \
        "${run}" "${role}" "${pr}" "${run}" "${GITHUB_SERVER_URL:-https://github.com}" "${GH_REPO}" "${run}" "${pr}" >"${body}"
      gh issue comment "${issue}" --body-file "${body}" >/dev/null || agent_log "sweep: comment on #${issue} failed"
      rm -f "${body}"
      write_sweep_row "${run}" "${role}" "${issue}" "${attempt}" pr-opened "" "${started}" "${pr}"
    fi
    echo "#${issue}: run ${run} opened #${pr} -> ${add}"
    return 0
  fi
  if [[ "${lrc}" -eq 0 ]]; then
    # Finalize already commented, filed any request and recorded the breaker step: only the labels.
    outcome="$(jq -r '.outcome // "failed"' <<<"${row}")"
    reason="$(jq -r '.reason // ""' <<<"${row}")"
    # A row finalize marked `counted: false` (the run never reached the model) goes back to the
    # queue as finalize would have put it; any other value, or none, is a counted run.
    counted="$(jq -r 'if .counted == false then "false" else "true" end' <<<"${row}")"
    IFS='|' read -r add remove kind <<<"$(finalize_plan "${outcome}" "${reason}" "${attempt}" "${max}" "${counted}")"
    relabel "${issue}" "${add}" "${remove}" || { echo "#${issue}: relabel failed"; return 1; }
    echo "#${issue}: run ${run} finalized (${outcome}) but its labels never landed -> ${add}"
    return 0
  fi

  reason="stale lock: run ${run} ended (${status}/${conclusion}) without releasing #${issue}"
  plan="$(finalize_plan failed "${reason}" "${attempt}" "${max}")"
  IFS='|' read -r add remove kind <<<"${plan}"
  relabel "${issue}" "${add}" "${remove}" || { echo "#${issue}: relabel failed"; return 1; }
  body="$(mktemp)"
  {
    printf '<!-- agent-sweep:stale-lock run=%s -->\n' "${run}"
    printf 'The lock of [run %s](%s/%s/actions/runs/%s) (attempt %s of %s) expired at %s, and that run ended (%s, %s) without releasing it. ' \
      "${run}" "${GITHUB_SERVER_URL:-https://github.com}" "${GH_REPO}" "${run}" "${attempt}" "${max}" "${expires}" "${status}" "${conclusion}"
    if [[ "${add}" == agent:ready ]]; then
      printf 'It is back in the queue for another attempt.\n'
    else
      printf 'That was its last attempt, so it is blocked; a request is in the agent inbox.\n'
    fi
  } >"${body}"
  gh issue comment "${issue}" --body-file "${body}" >/dev/null || agent_log "sweep: comment on #${issue} failed"
  rm -f "${body}"
  if [[ -n "${kind}" ]]; then
    file_request "${kind}" "${issue}" "failed: ${reason}" "${reason}" /dev/null >/dev/null || agent_log "sweep: inbox request failed"
  fi

  # The run's own finalize writes its ledger row; it never ran, so without this the run would be
  # missing from the daily cap and the breaker.
  write_sweep_row "${run}" "${role}" "${issue}" "${attempt}" failed "${reason}" "${started}"
  echo "#${issue}: stale lock of run ${run} released -> ${add}"
}

# open_issues <label>: the open issues carrying <label>, minus those on agent:hold.
open_issues() {
  gh issue list --state open --label "$1" --limit 100 --json number,labels \
    --jq '.[] | select([.labels[].name] | index("agent:hold") | not) | .number'
}

sweep_locks() {
  local issues n active rc=0
  # A coder run in progress may be between adding agent:in-progress and posting its lock comment,
  # when its issue's newest bot lock is still the previous attempt's, expired and ended. Locks wait
  # for a sweep with no coder run going (a queued run has not locked anything yet).
  active="$(gh api "repos/${GH_REPO}/actions/workflows/agent-coder.yml/runs?status=in_progress&per_page=1" --jq '.total_count')" \
    || { agent_log "sweep: could not list coder runs"; return 1; }
  [[ "${active}" =~ ^[0-9]+$ ]] || { agent_log "sweep: unexpected coder run count '${active}'"; return 1; }
  if [[ "${active}" != 0 ]]; then echo "a coder run is in progress; locks wait for the next sweep"; return 0; fi
  issues="$(open_issues agent:in-progress)" || { agent_log "sweep: could not list agent:in-progress issues"; return 1; }
  while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    sweep_one_lock "${n}" || rc=1
  done <<<"${issues}"
  return "${rc}"
}

# --- fix locks ---------------------------------------------------------------------------------------

# last_fix_lock <pr>: the newest fix-lock comment the BOT wrote on the PR, as
# "kind n run sha source expires", or nothing.
last_fix_lock() {
  local bodies m
  bodies="$(gh api --paginate "repos/${GH_REPO}/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"${BOT}\") | .body")" || return 1
  m="$(grep -oE '<!-- agent:fix-lock kind=[a-z]+ n=[0-9]+ run=[0-9]+ sha=[0-9a-f]+ source=[a-z0-9-]+ expires=[0-9TZ:-]+ -->' <<<"${bodies}" | tail -1)"
  [[ -n "${m}" ]] || return 0
  sed -E 's/.* kind=([a-z]+) n=([0-9]+) run=([0-9]+) sha=([0-9a-f]+) source=([a-z0-9-]+) expires=([0-9TZ:-]+) .*/\1 \2 \3 \4 \5 \6/' <<<"${m}"
}

sweep_one_fix() {
  local pr="$1" lock kind n run src expires state status conclusion started have issue
  lock="$(last_fix_lock "${pr}")" || { echo "#${pr}: comments unreadable, left alone"; return 1; }
  if [[ -z "${lock}" ]]; then
    # Preflight adds the label before it posts the lock, and a run cancelled in between leaves the
    # label alone with nothing to free it. No dispatched fixer run is in progress (sweep_fixes), so
    # nobody holds it.
    relabel_pr "${pr}" "" agent:fixing || { echo "#${pr}: unlock failed"; return 1; }
    echo "#${pr}: agent:fixing with no fix lock by the bot and no fixer run going: unlocked"
    return 0
  fi
  read -r kind n run _ src expires <<<"${lock}"
  if [[ ! "${expires}" < "$(agent_iso)" ]]; then echo "#${pr}: fix lock of run ${run} holds until ${expires}"; return 0; fi
  state="$(run_state "${run}")" || { echo "#${pr}: run ${run} unreadable, left alone"; return 1; }
  read -r status conclusion started <<<"${state}"
  if [[ "${status}" != completed && "${status}" != gone ]]; then echo "#${pr}: fix lock expired but run ${run} is ${status}, left alone"; return 0; fi
  have="$(gh api "repos/${GH_REPO}/issues/${pr}/labels?per_page=100" --jq '.[].name')" || { echo "#${pr}: labels unreadable"; return 1; }
  grep -Fxq agent:fixing <<<"${have}" || { echo "#${pr}: released meanwhile"; return 0; }
  if grep -Fxq agent:hold <<<"${have}"; then echo "#${pr}: on agent:hold, left alone"; return 0; fi
  ledger_row "${run}" "${n}" >/dev/null
  case $? in
    0)
      relabel_pr "${pr}" "" agent:fixing || { echo "#${pr}: unlock failed"; return 1; }
      echo "#${pr}: fixer run ${run} had finalized; unlocked"
      ;;
    1)
      issue="$(pr_issue "$(gh pr view "${pr}" --json body)")"
      OUTCOME=failed REASON="stale fix lock: run ${run} ended (${status}/${conclusion}) without finalizing" \
        PR="${pr}" ISSUE="${issue:-0}" KIND="${kind}" N="${n}" SOURCE="${src}" RUN_ID="${run}" \
        RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GH_REPO}/actions/runs/${run}" STARTED_AT="${started}" \
        TRIGGER=sweep FINAL_DIR=/nonexistent METRICS_FILE=/nonexistent \
        RUN_CANCELLED="$([[ "${conclusion}" == cancelled ]] && echo true || echo false)" \
        bash "${SCRIPT_DIR}/agent-fixup.sh" finalize >/dev/null || { echo "#${pr}: finalize failed"; return 1; }
      echo "#${pr}: stale fix lock of run ${run} finalized as failed"
      ;;
    *) echo "#${pr}: ledger unreadable, left alone"; return 1 ;;
  esac
}

sweep_fixes() {
  local prs pr active rc=0
  # As with the coder's locks: a fixer run adds agent:fixing before it posts its fix lock. Only
  # dispatched runs lock; the routing runs (workflow_run, review events) never do.
  active="$(gh api "repos/${GH_REPO}/actions/workflows/agent-fixup.yml/runs?event=workflow_dispatch&status=in_progress&per_page=1" --jq '.total_count')" \
    || { agent_log "sweep: could not list fixer runs"; return 1; }
  [[ "${active}" =~ ^[0-9]+$ ]] || { agent_log "sweep: unexpected fixer run count '${active}'"; return 1; }
  if [[ "${active}" != 0 ]]; then echo "a fixer run is in progress; fix locks wait for the next sweep"; return 0; fi
  prs="$(gh pr list --state open --label agent:fixing --limit 100 --json number,labels \
    --jq '.[] | select([.labels[].name] | index("agent:hold") | not) | .number')" \
    || { agent_log "sweep: could not list agent:fixing PRs"; return 1; }
  while IFS= read -r pr; do
    [[ -n "${pr}" ]] || continue
    sweep_one_fix "${pr}" || rc=1
  done <<<"${prs}"
  return "${rc}"
}

# --- PRs ---------------------------------------------------------------------------------------------

# agent_prs_for <issue> [run]: the BOT's agent PRs in this repository for <issue> (opened by run
# [run], when given), from its timeline, as "number state merged_at" lines (merged_at is `none`
# when unmerged). A PR counts only when its body carries the outbox's footer naming this issue:
# GitHub adds a PR to an issue's timeline when any comment on that PR mentions the issue, too.
# Only the outbox writes the footer; agent_sanitize escapes `<!--` in everything the model wrote.
agent_prs_for() {
  local issue="$1" run='[0-9]+'
  [[ "${issue}" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "${2:-}" ]]; then [[ "$2" =~ ^[0-9]+$ ]] || return 1; run="$2"; fi
  gh api --paginate "repos/${GH_REPO}/issues/${issue}/timeline?per_page=100" \
    --jq ".[] | select(.event == \"cross-referenced\" and .source.type == \"issue\"
      and .source.issue.pull_request != null and .source.issue.user.login == \"${BOT}\"
      and ([.source.issue.labels[]?.name] | index(\"agent:pr\")) != null
      and ((.source.issue.repository.full_name // \"\") | ascii_downcase) == (\"${GH_REPO}\" | ascii_downcase)
      and ((.source.issue.body // \"\") | test(\"<!-- agent-run:coder run=${run} issue=${issue} -->\")))
      | \"\(.source.issue.number) \(.source.issue.state) \(.source.issue.pull_request.merged_at // \"none\")\""
}

sweep_one_pr() {
  local issue="$1" prs pr state merged body
  prs="$(agent_prs_for "${issue}")" || { echo "#${issue}: timeline unreadable, left alone"; return 1; }
  if [[ -z "${prs}" ]]; then echo "#${issue}: agent:pr-open but no agent PR references it, left alone"; return 0; fi
  if grep -q ' open ' <<<"${prs}"; then echo "#${issue}: an agent PR is still open"; return 0; fi
  read -r pr state merged <<<"$(sort -n <<<"${prs}" | tail -1)"
  if [[ "${merged}" != none ]]; then
    mark_merged "${issue}" "${pr}" || { echo "#${issue}: could not mark #${pr} merged"; return 1; }
    echo "#${issue}: #${pr} merged -> agent:done-pending-deploy"
    return 0
  fi
  relabel "${issue}" agent:blocked agent:pr-open || { echo "#${issue}: relabel failed"; return 1; }
  body="$(mktemp)"
  printf '<!-- agent-sweep:pr-closed pr=%s -->\n#%s was closed without being merged, so the agent stops here. To try again, re-apply `agent:ready` (edit the issue first if the PR missed the point).\n' \
    "${pr}" "${pr}" >"${body}"
  gh issue comment "${issue}" --body-file "${body}" >/dev/null || agent_log "sweep: comment on #${issue} failed"
  rm -f "${body}"
  echo "#${issue}: #${pr} closed unmerged -> agent:blocked"
}

sweep_prs() {
  local issues n rc=0
  issues="$(open_issues agent:pr-open)" || { agent_log "sweep: could not list agent:pr-open issues"; return 1; }
  while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    sweep_one_pr "${n}" || rc=1
  done <<<"${issues}"
  return "${rc}"
}

# --- breaker -----------------------------------------------------------------------------------------

# sweep_breaker: a role whose consecutive failures are at or past the threshold but whose breaker is
# not tripped is tripped now. Finalize writes the count and the trip in one commit, so this is for a
# threshold lowered in policy.json, or a hand edit of the ledger. A reset sets `consecutive` to 0,
# so this never re-trips a breaker the owner reset.
sweep_breaker() {
  local breaker role n threshold tripped
  breaker="$(ledger_file state/breaker.json)" || { agent_log "sweep: breaker unreadable"; return 1; }
  [[ -n "${breaker}" ]] || { echo "breaker: none recorded yet"; return 0; }
  while IFS= read -r role; do
    [[ -n "${role}" ]] || continue
    n="$(jq -r --arg r "${role}" '.[$r].consecutive // 0' <<<"${breaker}")"
    tripped="$(jq -r --arg r "${role}" '.[$r].tripped_at // empty' <<<"${breaker}")"
    threshold="$(policy ".roles[\"${role}\"].breakerThreshold // 3")"
    if [[ -n "${tripped}" || "${n}" -lt "${threshold}" ]]; then
      echo "breaker ${role}: ${n} of ${threshold}${tripped:+, tripped since ${tripped}}"
      continue
    fi
    # shellcheck disable=SC2034 # file_request (agent-state.sh) reads ROLE
    ROLE="${role}"
    bash "${SCRIPT_DIR}/agent-ledger.sh" breaker-trip "${role}" "${n} runs in a row ended without a PR (tripped by the sweep)" >/dev/null \
      || { agent_log "sweep: could not trip the ${role} breaker"; return 1; }
    file_request breaker 0 "circuit breaker tripped" "${n} runs in a row ended without a PR" /dev/null >/dev/null \
      || agent_log "sweep: breaker request failed"
    echo "breaker ${role}: ${n} of ${threshold}, tripped now"
  done < <(policy '.roles | keys[]')
}

cmd_run() {
  local rc=0 part out
  for part in locks fixes prs breaker; do
    out="$("sweep_${part}")" || { rc=1; printf '::warning title=agent sweep::the %s part failed (see the log)\n' "${part}"; }
    printf '%s\n' "${out}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -n "${out}" ]]; then
      { printf '### %s\n\n' "${part}"; awk '{ print "- " $0 }' <<<"${out}"; printf '\n'; } >>"${GITHUB_STEP_SUMMARY}"
    fi
  done
  return "${rc}"
}

main() {
  case "${1:-}" in
    run) cmd_run ;;
    locks | fixes | prs | breaker) "sweep_$1" ;;
    *) agent_log "usage: agent-sweep.sh run|locks|fixes|prs|breaker"; return 2 ;;
  esac
}

if [[ "${AGENT_SWEEP_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
