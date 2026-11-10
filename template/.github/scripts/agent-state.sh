#!/usr/bin/env bash
# .github/scripts/agent-state.sh
# The coder's issue state machine: whether a run may start, which issue it takes, the lock, and the
# labels it leaves behind. Labels are the state; HTML-comment markers are the evidence.
#
#   agent:ready ──lock──► agent:in-progress ──► agent:pr-open        (a PR with `Refs #N` exists)
#                                          ├──► agent:ready          (a failed attempt, retries left)
#                                          └──► agent:blocked + agent:needs-human  (a request is in the inbox)
#   agent:hold is never touched. The owner closes issues; nothing here ever does.
#
# Usage (all read GH_TOKEN, GH_REPO; outputs go to $GITHUB_OUTPUT):
#   agent-state.sh gate <role>         go=true|false, reason=…
#   agent-state.sh pick [<issue>]      issue=N, attempt=K  (empty issue = nothing eligible)
#   agent-state.sh lock <issue> <attempt>
#   agent-state.sh snapshot <issue> <out> <since|label>   the task file, from one fetch, re-checked
#   agent-state.sh finalize            reads OUTCOME, REASON, ISSUE, ATTEMPT, PR_NUMBER, PR_URL, RUN_ID,
#                                      RUN_URL, FINAL_DIR (summary.md, blocked.md), METRICS_FILE
#
# Env: AGENTS_ENABLED (the repo variable), AGENT_BOT_ID (the App's bot user id), AGENT_STATE_NO_MAIN=1
#      to load the functions only (tests/workflows/agents-state.test.sh).
#
# Backticks and `$` in the single-quoted printf formats and jq programs below are literal markdown
# and jq, never meant to expand, so SC2016 is silenced file-wide.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-lib.sh"

ROLE="${ROLE:-coder}"

# --- gate --------------------------------------------------------------------------------------------

# ledger_file <path>: a file from the ledger branch on stdout; nothing when it does not exist yet.
# FAILS CLOSED: any error other than a 404 returns 1, so an unreadable ledger stops the run instead
# of reading as "zero runs today, breaker closed".
ledger_file() {
  local path="$1" err out rc
  err="$(mktemp)"
  out="$(gh api -H 'Accept: application/vnd.github.raw' \
    "repos/${GH_REPO}/contents/${path}?ref=$(policy '.ledgerBranch')" 2>"${err}")"
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if grep -q 'HTTP 404' "${err}"; then rm -f "${err}"; return 0; fi
    agent_log "ledger read failed for ${path}: $(head -c 300 "${err}")"
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  printf '%s\n' "${out}"
}

# gate_decide <enabled> <bot-id> <tripped-at> <runs-today> <cap> <open-prs> <max-open> <ref-state>: pure.
# <ref-state> is ok, default (dispatched on the default branch) or stale (the runner ref's copy of
# this workflow differs from main's); see ref_state.
gate_decide() {
  local enabled="$1" bot_id="$2" tripped="$3" today="$4" cap="$5" open="$6" max_open="$7" ref="${8:-ok}"
  if [[ "${enabled}" != "true" ]]; then echo "no-go:disabled (AGENTS_ENABLED is not true)"; return; fi
  if [[ "${ref}" == default ]]; then echo "no-go:wrong-ref (dispatch with --ref $(policy '.runnerRef'), never on the default branch)"; return; fi
  if [[ "${ref}" == stale ]]; then echo "no-go:runner-ref-stale (fast-forward $(policy '.runnerRef') to main)"; return; fi
  if [[ "${ref}" == unreadable ]]; then echo "no-go:ref-unreadable (could not compare the workflow on $(policy '.runnerRef') and main)"; return; fi
  if ! [[ "${bot_id}" =~ ^[0-9]+$ ]]; then echo "no-go:misconfigured (AGENT_BOT_ID is not set)"; return; fi
  if [[ -n "${tripped}" ]]; then echo "no-go:breaker-open (since ${tripped}; /resume ${ROLE} in the inbox)"; return; fi
  if [[ "${today}" -ge "${cap}" ]]; then echo "no-go:daily-cap (${today} of ${cap} runs today)"; return; fi
  if [[ "${open}" -ge "${max_open}" ]]; then echo "no-go:open-pr-limit (${open} open agent PRs, max ${max_open})"; return; fi
  echo "go"
}

# ref_state: whether this run is on the runner ref, and that ref's copy of the workflow is main's.
#
# WHY A SEPARATE REF: the code job runs code the agent wrote, so it controls its own job, including
# the JavaScript actions that run after the model and hold the Actions runtime token, which can
# write CACHES in the run's ref scope. A run on the default branch writes caches that every CI job
# on main and on every PR restores, so a poisoned cache entry would run in later CI and release
# jobs with whatever those hold. Dispatched on
# `agent-runner` instead, whatever it writes is visible only to other agent-runner runs, and the
# code job restores no caches at all. Every job checks out the default branch explicitly, so the
# ref only scopes the run; the blob check keeps its workflow definition equal to main's.
# WORKFLOW_FILE names the workflow whose copies are compared (agent-coder.yml by default; the fixer
# runs agent-fixup.yml on the same ref for the same reason).
ref_state() {
  local ref="${RUN_REF:-}" default="${DEFAULT_BRANCH:-main}" wf="${WORKFLOW_FILE:-agent-coder.yml}" a b
  [[ "${ref}" != "${default}" ]] || { echo default; return; }
  [[ "${ref}" == "$(policy '.runnerRef')" ]] || { echo stale; return; }
  if ! a="$(gh api "repos/${GH_REPO}/contents/.github/workflows/${wf}?ref=${ref}" --jq .sha 2>/dev/null)" \
    || ! b="$(gh api "repos/${GH_REPO}/contents/.github/workflows/${wf}?ref=${default}" --jq .sha 2>/dev/null)" \
    || [[ -z "${a}" || -z "${b}" ]]; then
    echo unreadable
    return
  fi
  if [[ "${a}" == "${b}" ]]; then echo ok; else echo stale; fi
}

cmd_gate() {
  local role="${1:-${ROLE}}" breaker runs tripped day month count cap open max_open decision
  month="$(jq -rn --argjson e "$(agent_now_epoch)" '$e | strftime("%Y-%m")')"
  day="$(jq -rn --argjson e "$(agent_now_epoch)" '$e | strftime("%Y-%m-%d")')"
  if ! breaker="$(ledger_file state/breaker.json)" || ! runs="$(ledger_file "runs/${month}.jsonl")"; then
    decision="no-go:ledger-unreadable"
  else
    [[ -n "${breaker}" ]] || breaker='{}'
    tripped="$(jq -r --arg r "${role}" '.[$r].tripped_at // empty' <<<"${breaker}")"
    # A run that never reached the model (`counted: false`, infra_failure) is not a run for the cap.
    count="$(printf '%s\n' "${runs}" | jq -s --arg d "${day}" --arg r "${role}" \
      '[.[] | select(type == "object" and .role == $r and .counted != false and ((.started_at // "") | startswith($d)))] | length')"
    cap="$(policy ".roles[\"${role}\"].runsPerDay")"
    max_open="$(policy ".roles[\"${role}\"].maxOpenPrs")"
    if ! open="$(gh pr list --state open --label agent:pr --limit 100 --json number --jq 'length')"; then
      decision="no-go:github-unreadable"
    else
      decision="$(gate_decide "${AGENTS_ENABLED:-}" "${AGENT_BOT_ID:-}" "${tripped}" "${count}" "${cap}" "${open}" "${max_open}" "$(ref_state)")"
    fi
  fi
  if [[ "${decision}" == "go" ]]; then
    output go true
    output reason ""
  else
    output go false
    output reason "${decision#no-go:}"
    printf '::notice title=agent %s skipped::%s\n' "${role}" "${decision#no-go:}"
  fi
}

# --- pick --------------------------------------------------------------------------------------------

# The jq definitions every eligibility check shares. Input: one issue from `gh issue view/list
# --json number,state,title,body,labels,createdAt,comments`.
# Only the bot's lock comments count as attempts; anyone who can comment could otherwise use up an
# issue's attempts by pasting the marker. gh spells an App author `app/<slug>` or `<slug>`
# (AGENT_BOT_SLUG comes from agent-lib.sh). A lock whose run never reached the model is voided by
# the bot's own `<!-- agent:no-attempt run=R -->` (finalize, infra_failure); a person's copy of that
# marker voids nothing.
JQ_ISSUE_DEFS='
  def names: [.labels[]?.name];
  def has($l): (names | index($l)) != null;
  def by_bot: ((.author.login // "") as $a | ($a == "'"${AGENT_BOT_SLUG}"'" or $a == "app/'"${AGENT_BOT_SLUG}"'" or $a == "'"${AGENT_BOT_SLUG}"'[bot]"));
  def voided: [.comments[]? | select(by_bot) | (.body // "") | capture("<!-- agent:no-attempt run=(?<r>[0-9A-Za-z]+) -->") | .r];
  def locks: voided as $v
    | [.comments[]? | select(by_bot and ((.body // "") | contains("<!-- agent:lock ")))
       | select((((.body // "") | capture("<!-- agent:lock [^>]*run=(?<r>[0-9A-Za-z]+)") | .r) // "") as $r | ($v | any(. == $r)) | not)]
    | length;
  def acceptance:
    (.body // "") | test("(?im)^#{2,3} +(recommendation|done when|acceptance( criteria)?|suggested fix|expected( behaviou?r)?)\\b|^\\*\\*(done when|acceptance)");
  def prio:
    if has("priority: critical") then 0 elif has("priority: high") then 1
    elif has("priority: medium") then 2 elif has("priority: low") then 3 else 4 end;
  def busy: has("agent:hold") or has("agent:in-progress") or has("agent:pr-open");
  def skip_reason($max):
    if (.state // "OPEN") != "OPEN" then "not open"
    elif busy then "held, locked or already has a PR"
    elif has("question") then "labelled question"
    elif has("size: L") then "size: L"
    elif (acceptance | not) then "no acceptance section (Done when / Acceptance / Recommendation / Suggested fix)"
    elif locks >= $max then "already attempted \(locks) times"
    else null end;
'

# log_skips <issues-json-array> <max-attempts>: one log line per ineligible issue and why, so the
# run log says why nothing was taken.
log_skips() {
  local line
  while IFS= read -r line; do
    agent_log "${line}"
  done < <(jq -r --argjson max "$2" "${JQ_ISSUE_DEFS}"'
    .[] | skip_reason($max) as $why | select($why != null) | "skip #\(.number): \($why)"
  ' <<<"$1")
}

# pick_auto <issues-json-array> <max-attempts>: the first eligible issue by priority then age,
# before the labeler check (cmd_pick applies that, because it needs the API).
pick_auto() {
  log_skips "$1" "$2"
  pick_ranked "$1" "$2" | head -1
}

# pick_ranked <issues-json-array> <max-attempts>: every eligible issue number, in pick order.
pick_ranked() {
  jq -r --argjson max "$2" "${JQ_ISSUE_DEFS}"'
    [.[] | select(skip_reason($max) == null)] | sort_by(prio, .createdAt) | .[].number
  ' <<<"$1"
}

# content_untouched_since <issue> <iso>: exit 0 when nobody without write access renamed the issue
# or edited its body at or after <iso>. Every body edit counts (GraphQL userContentEdits), not just
# the last one, so an outsider's edit cannot hide behind a writer's later typo fix. `>=`, not `>`:
# the timestamps have one-second resolution, so an edit in the same second as the label could be
# either side of it, and it is treated as after. More edits than one page holds fails closed
# rather than trusting the order GitHub returns them in.
content_untouched_since() {
  local issue="$1" since="$2" who owner="${GH_REPO%%/*}" repo="${GH_REPO#*/}" renamers editors
  renamers="$(gh api --paginate "repos/${GH_REPO}/issues/${issue}/timeline?per_page=100" \
    --jq ".[] | select(.event == \"renamed\" and .created_at >= \"${since}\") | .actor.login")" || return 1
  editors="$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){userContentEdits(first:100){totalCount nodes{editedAt editor{login}}}}}}' \
    -f o="${owner}" -f r="${repo}" -F n="${issue}" \
    --jq ".data.repository.issue.userContentEdits | if .totalCount > (.nodes | length) then \"!too-many\"
      else (.nodes[] | select(.editedAt >= \"${since}\") | (.editor.login // \"ghost\")) end")" || return 1
  while IFS= read -r who; do
    [[ -n "${who}" ]] || continue
    [[ "${who}" != '!too-many' ]] || { agent_log "#${issue}: more body edits than one page holds; not trusted"; return 1; }
    actor_trusted "${who}" || { agent_log "#${issue}: changed by ${who}, who has no write access, at or after ${since}"; return 1; }
  done < <(printf '%s\n%s\n' "${renamers}" "${editors}")
}

# person_labels <issue>: one "login|iso" line per `agent:ready` a PERSON applied, oldest first (the
# bot's own re-labels after a failed attempt or an inbox answer do not count, or they would reset
# the window). Exit 1 when the timeline cannot be read.
person_labels() {
  local who at events
  events="$(gh api --paginate "repos/${GH_REPO}/issues/$1/timeline?per_page=100" \
    --jq '.[] | select(.event == "labeled" and .label.name == "agent:ready") | "\(.actor.login // "")|\(.created_at)"')" || return 1
  while IFS='|' read -r who at; do
    [[ -n "${at}" ]] || continue
    is_agent_bot "${who}" || printf '%s|%s\n' "${who}" "${at}"
  done <<<"${events}"
}

# person_label_at <issue>: the latest of those, or nothing when only the bot ever applied it.
person_label_at() {
  local all
  all="$(person_labels "$1")" || return 1
  tail -1 <<<"${all}"
}

# named_anchor <issue>: where a named dispatch's read-back starts (before the min with the run's
# start). The latest `agent:ready` applied by someone with write access, newest first, so a later
# label by a triage account or a workflow token cannot move the window past an outsider's edit.
# Failing that (no writer ever labelled it, or the permission lookup failed) the OLDEST label any
# person applied, which is stricter, never looser. Nothing when no person ever labelled it (only the
# bot, or nobody); cmd_snapshot then checks from the issue's creation.
named_anchor() {
  local all who at
  all="$(person_labels "$1")" || return 1
  [[ -n "${all}" ]] || return 0
  while IFS='|' read -r who at; do
    [[ -n "${at}" ]] || continue
    if actor_trusted "${who}"; then printf '%s\n' "${at}"; return 0; fi
  done < <(awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' <<<"${all}")
  at="${all%%$'\n'*}"
  printf '%s\n' "${at#*|}"
}

# labeler_trusted <issue>: exit 0 when the latest `agent:ready` applied by a person came from someone
# with write access, and nobody without write access changed the title or body since.
#
# The label is what turns issue text into an agent PR, and on a private repo a read-only
# collaborator can open issues; with auto-merge (Phase 2) that would be a path from read access to
# code on main. The agent-task issue template applies the label too, so this also decides whether a
# template-filed issue is taken: the owner's are, a read-only collaborator's wait for someone with
# write access to re-apply the label. An inbox /approve or /rerun re-labels as the bot and
# dispatches the issue by name; cmd_snapshot checks that case from named_anchor.
#
# Or the issue was fast-tracked by triage (triage_fast_tracked): then the bot applied the label, and
# what vouches for the text is that a writer wrote it and only writers changed it since.
#
# Or the repo's own rule vouches for it: agent_hook_labeler_trusted <issue>, when
# .github/agents/hooks/lib.sh defines it, for issues the repo's own workflows file and queue as the
# bot. It is asked only when NO person ever applied agent:ready (a label by someone without write
# access never reaches it), after a first readable timeline; a later read inside triage's check can
# still fail before it is asked, so the hook checks the content itself. It must exit 0 only when it can vouch for
# the issue's CURRENT title and body (content_untouched_since is here for that), since its text
# becomes an agent PR. The coder's follow-ups (`<!-- agent-followup:` marker) are bot-filed too,
# with model-written text: a hook must never vouch for those.
labeler_trusted() {
  local issue="$1" anchor
  anchor="$(person_label_at "${issue}")" || return 1
  if [[ -n "${anchor}" ]] && actor_trusted "${anchor%%|*}" && content_untouched_since "${issue}" "${anchor#*|}"; then
    return 0
  fi
  triage_fast_tracked "${issue}" && return 0
  [[ -z "${anchor}" ]] && declare -F agent_hook_labeler_trusted >/dev/null \
    && agent_hook_labeler_trusted "${issue}" </dev/null
}

# triage_fast_tracked <issue>: exit 0 when the bot's triage put its `<!-- agent-triage:fast-track -->`
# comment on the issue (agent-triage.sh: a Low or Medium Claude Security import), the issue's AUTHOR
# has write access (and is not the bot), and nobody without write access renamed it or edited its
# body since it was opened. A writer's label vouches for the text from the label on; here the text
# is a writer's own from the start, which is at least as strong. Triage never fast-tracks an issue
# whose author lacks write access, and this checks again rather than trusting the comment.
triage_fast_tracked() {
  local issue="$1" json author created
  json="$(gh issue view "${issue}" --json author,createdAt,comments)" || return 1
  jq -e "${JQ_ISSUE_DEFS}"'[.comments[]? | select(by_bot and ((.body // "") | contains("<!-- agent-triage:fast-track -->")))] | length > 0' \
    <<<"${json}" >/dev/null || return 1
  author="$(jq -r '.author.login // ""' <<<"${json}")"
  created="$(jq -r '.createdAt // ""' <<<"${json}")"
  [[ -n "${author}" && -n "${created}" ]] || return 1
  if is_agent_bot "${author}" || ! actor_trusted "${author}"; then return 1; fi
  content_untouched_since "${issue}" "${created}"
}

# cmd_snapshot <issue> <out-file> <since-iso|label>: the task file the model will read, built ONCE,
# here, after the trust checks, from one fetch of the issue. The code job reads this file instead of
# fetching the issue again minutes later, so an edit made while it installs toolchains never reaches
# the model. Only writers' comments are kept (TRUSTED_COMMENTERS). The content is checked again
# AFTER the fetch, which closes the gap between the check and the read:
#   label (auto-pick)        from the trusted person's label, as the pick did;
#   <iso> (named dispatch)   from named_anchor (or, when no person ever labelled the issue, its
#                            creation), or the run's start when that is earlier. An inbox /approve
#                            answers a request about the issue as it was; an outsider's edit since
#                            the owner's label must not ride along with it, and with a `protected`
#                            request widen its reach.
cmd_snapshot() {
  local issue="$1" out="$2" since="$3" json who list="" at
  json="$(gh issue view "${issue}" --json number,title,body,labels,author,comments,createdAt)" || return 1
  while IFS= read -r who; do
    [[ -n "${who}" ]] || continue
    if actor_trusted "${who}"; then list+="${list:+,}${who}"; fi
  done < <(jq -r '.comments[].author.login' <<<"${json}" | sort -u)
  printf '%s\n' "${json}" >"${out}.json"
  TRUSTED_COMMENTERS="${list}" bash "${SCRIPT_DIR}/agent-sanitize-input.sh" --from-json "${out}.json" >"${out}" || return 1
  rm -f "${out}.json"
  if [[ "${since}" == label ]]; then
    labeler_trusted "${issue}" || { agent_log "#${issue}: no longer trusted after the snapshot"; return 1; }
  else
    at="$(named_anchor "${issue}")" || return 1
    [[ -n "${at}" ]] || at="$(jq -r '.createdAt // empty' <<<"${json}")"
    [[ -n "${at}" && "${at}" < "${since}" ]] && since="${at}"
    content_untouched_since "${issue}" "${since}" || return 1
  fi
}

# explicit_ok <issue-json>: a dispatch that names an issue is the owner's choice, so only hard
# stops apply (closed, held, locked, already has a PR). No attempt cap, no acceptance check.
explicit_ok() {
  jq -r "${JQ_ISSUE_DEFS}"'
    if (.state // "OPEN") != "OPEN" then "not open" elif busy then "held, locked or already has a PR" else "" end
  ' <<<"$1"
}

cmd_pick() {
  local want="${1:-}" json why max n attempt
  max="$(policy ".roles[\"${ROLE}\"].maxAttemptsPerIssue")"
  if [[ -n "${want}" ]]; then
    [[ "${want}" =~ ^[0-9]+$ ]] || { agent_log "pick: '${want}' is not an issue number"; output issue ""; return 0; }
    json="$(gh issue view "${want}" --json number,state,title,body,labels,createdAt,comments)" || return 1
    why="$(explicit_ok "${json}")"
    if [[ -n "${why}" ]]; then
      agent_log "pick: #${want} cannot be taken: ${why}"
      printf '::notice title=agent coder::#%s not taken: %s\n' "${want}" "${why}"
      output issue ""
      return 0
    fi
    n="${want}"
  else
    json="$(gh issue list --state open --label agent:ready --limit 100 \
      --json number,state,title,body,labels,createdAt,comments)" || return 1
    # Candidates in pick order; the first that no merged PR already references and whose label
    # came from a trusted hand wins. A merged PR naming the issue usually means it is fixed on main
    # and waiting for a prod check (an issue was once picked after a merged PR had fixed it); a dispatch that
    # names the issue still takes it.
    log_skips "${json}" "${max}"
    n=""
    local cand merged
    while IFS= read -r cand; do
      [[ -n "${cand}" ]] || continue
      if ! merged="$(merged_prs_referencing "${cand}")"; then
        agent_log "skip #${cand}: could not read its timeline for merged PRs"
        continue
      fi
      if [[ -n "${merged}" ]]; then
        agent_log "skip #${cand}: merged PR #$(paste -sd' ' - <<<"${merged}" | sed 's/ / #/g') already references it (dispatch it by name to take it anyway)"
        continue
      fi
      if labeler_trusted "${cand}"; then n="${cand}"; break; fi
      agent_log "skip #${cand}: agent:ready was applied by someone without write access"
    done < <(pick_ranked "${json}" "${max}")
    if [[ -z "${n}" ]]; then
      printf '::notice title=agent coder::no eligible agent:ready issue\n'
      output issue ""
      return 0
    fi
    json="$(jq --argjson n "${n}" '.[] | select(.number == $n)' <<<"${json}")"
  fi
  attempt="$(jq -r "${JQ_ISSUE_DEFS}"' locks + 1' <<<"${json}")"
  output issue "${n}"
  output attempt "${attempt}"
}

# cmd_kick: the coder's schedule. A scheduled run is on the default branch, where the gate refuses to
# run (ref_state), so it only dispatches an auto-pick run on the runner ref, unless a coder run is
# already queued or running: GitHub keeps one pending run per concurrency group and cancels the
# older, and a kick must never cancel a person's named dispatch. The day's cap is the gate's.
cmd_kick() {
  local busy
  busy="$(gh api "repos/${GH_REPO}/actions/workflows/agent-coder.yml/runs?event=workflow_dispatch&per_page=30" \
    --jq '[.workflow_runs[] | select(.status != "completed")] | length')" || { agent_log "kick: could not list coder runs"; return 1; }
  [[ "${busy}" =~ ^[0-9]+$ ]] || { agent_log "kick: unexpected run count '${busy}'"; return 1; }
  if [[ "${busy}" != 0 ]]; then echo "a coder run is already queued or running; no kick"; return 0; fi
  gh workflow run agent-coder.yml --ref "$(policy '.runnerRef')" >/dev/null || { agent_log "kick: the dispatch failed"; return 1; }
  echo "dispatched an auto-pick coder run on $(policy '.runnerRef')"
}

# --- labels ------------------------------------------------------------------------------------------

# relabel <issue> <add,comma,list> <remove,comma,list>: only removes labels the issue has, because
# `gh issue edit --remove-label` on an absent label is an error on some gh versions.
relabel() {
  local issue="$1" add="$2" remove="$3" have args=() l _add _rm
  have="$(gh issue view "${issue}" --json labels --jq '.labels[].name')" || return 1
  IFS=',' read -r -a _add <<<"${add}"
  IFS=',' read -r -a _rm <<<"${remove}"
  for l in "${_add[@]}"; do [[ -n "${l}" ]] && args+=(--add-label "${l}"); done
  for l in "${_rm[@]}"; do
    [[ -n "${l}" ]] && grep -Fxq -- "${l}" <<<"${have}" && args+=(--remove-label "${l}")
  done
  [[ ${#args[@]} -gt 0 ]] || return 0
  gh issue edit "${issue}" "${args[@]}" >/dev/null
}

cmd_lock() {
  local issue="$1" attempt="$2" max ttl expires body
  max="$(policy ".roles[\"${ROLE}\"].maxAttemptsPerIssue")"
  ttl="$(policy ".roles[\"${ROLE}\"].lockTtlMinutes")"
  expires="$(agent_iso $(($(agent_now_epoch) + ttl * 60)))"
  ensure_labels || return 1
  relabel "${issue}" "agent:in-progress" "agent:ready,agent:blocked,agent:needs-human" || return 1
  body="$(mktemp)"
  {
    printf '<!-- agent:lock role=%s run=%s attempt=%s expires=%s -->\n' "${ROLE}" "${RUN_ID:-local}" "${attempt}" "${expires}"
    printf 'The %s agent picked this up (attempt %s of %s): [run](%s). ' "${ROLE}" "${attempt}" "${max}" "${RUN_URL:-}"
    printf 'It may open a PR that says `Refs #%s`. It never closes this issue; that stays with a person after the fix is live.\n' "${issue}"
  } >"${body}"
  # The lock comment is how the sweep tells this run's lock from the last attempt's, so a lock that
  # could not post it fails: preflight stops, and the publish job's finalize releases the issue.
  local rc=0
  gh issue comment "${issue}" --body-file "${body}" >/dev/null || rc=1
  rm -f "${body}"
  return "${rc}"
}

# mark_merged <issue> <pr>: the issue's agent PR merged. agent:pr-open (and any agent:blocked or
# agent:needs-human a person resolved by merging) becomes agent:done-pending-deploy, with one
# `<!-- agent-merged pr=N -->` comment naming the merge commit. The owner closes the issue after
# checking production; nothing here closes it. Idempotent: an issue without agent:pr-open is left
# alone, so the sweep and the merge gate can both call it.
mark_merged() {
  local issue="$1" pr="$2" have sha body
  have="$(gh issue view "${issue}" --json labels --jq '.labels[].name')" || return 1
  grep -Fxq agent:pr-open <<<"${have}" || return 0
  ensure_labels || agent_log "mark_merged: could not ensure labels"
  relabel "${issue}" agent:done-pending-deploy agent:pr-open,agent:blocked,agent:needs-human || return 1
  sha="$(gh pr view "${pr}" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)"
  body="$(mktemp)"
  {
    printf '<!-- agent-merged pr=%s -->\n' "${pr}"
    printf '#%s is merged%s. It is not deployed yet: close this issue once you have checked the fix in production.\n' \
      "${pr}" "${sha:+ as \`${sha:0:12}\`}"
  } >"${body}"
  gh issue comment "${issue}" --body-file "${body}" >/dev/null || agent_log "mark_merged: comment on #${issue} failed"
  rm -f "${body}"
}

# --- pull requests (shared by the sweep, the fixer and the merge gate) -------------------------------

# relabel_pr <pr> <add,csv> <remove,csv>: relabel a PR through the issues REST API, which takes a PR
# number too; only removes labels it has.
relabel_pr() {
  local pr="$1" have l _add _rm
  have="$(gh api "repos/${GH_REPO}/issues/${pr}/labels?per_page=100" --jq '.[].name')" || return 1
  IFS=',' read -r -a _add <<<"$2"
  IFS=',' read -r -a _rm <<<"$3"
  for l in "${_add[@]}"; do
    [[ -n "${l}" ]] || continue
    grep -Fxq -- "${l}" <<<"${have}" && continue
    jq -n --arg l "${l}" '{labels: [$l]}' | gh api -X POST "repos/${GH_REPO}/issues/${pr}/labels" --input - >/dev/null || return 1
  done
  for l in "${_rm[@]}"; do
    if [[ -z "${l}" ]] || ! grep -Fxq -- "${l}" <<<"${have}"; then continue; fi
    gh api -X DELETE "repos/${GH_REPO}/issues/${pr}/labels/$(jq -rn --arg l "${l}" '$l | @uri')" >/dev/null || return 1
  done
}

# pr_issue <pr-json>: the issue named by the outbox's `<!-- agent-run:coder run=R issue=N -->` footer
# in the PR body. Not the first `Refs #N`: the rest of the body is the model's, and could name any
# issue first. Only the outbox writes the footer (agent_sanitize escapes `<!--` in model text).
pr_issue() {
  { jq -r '.body // ""' <<<"$1" | grep -oE '<!-- agent-run:coder run=[0-9a-z]+ issue=[0-9]+ -->' || true; } \
    | tail -1 | grep -oE 'issue=[0-9]+' | cut -d= -f2
}

# pr_bot_comments <pr>: the bodies of the agent bot's own comments on a PR. Only the bot's count as
# markers: anyone who can comment could paste one.
pr_bot_comments() {
  gh api --paginate "repos/${GH_REPO}/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$(policy '.botLogin')\") | .body"
}

# request_review <pr> <sha> <why>: dispatch "Claude Code Review" for the PR, once per head; <why>
# opens the PR comment that records it. The fixer asks for the heads it pushes, the merge gate for
# the heads its branch updates made, and the shared marker keeps them to one between them. The
# review's own dedup skips a PR that already has a review on its automatic trigger; a dispatch is
# exempt on purpose (claude-code-review.yml), which is what makes this the way to get a second one.
request_review() {
  local pr="$1" sha="$2" why="$3" bodies body
  bodies="$(pr_bot_comments "${pr}")" || return 1
  if grep -Fq "<!-- agent-review-dispatched sha=${sha} -->" <<<"${bodies}"; then
    echo "#${pr}: a review of ${sha:0:9} was already requested"
    return 0
  fi
  gh workflow run "Claude Code Review" -f pr="${pr}" >/dev/null || { agent_log "review: dispatching the review of #${pr} failed"; return 1; }
  body="$(mktemp)"
  printf '<!-- agent-review-dispatched sha=%s -->\n%s, so a fresh Claude review was requested.\n' "${sha}" "${why}" >"${body}"
  gh issue comment "${pr}" --body-file "${body}" >/dev/null || agent_log "review: could not record the review request on #${pr}"
  rm -f "${body}"
  echo "#${pr}: review requested for ${sha:0:9}"
}

# --- reviews (shared by the fixer and the merge gate) -----------------------------------------------

# newest_review <pr>: the newest comment carrying policy.reviewMarker that the review bot
# (policy.reviewBotLogin) or someone with write access wrote, as "id created_at login", or nothing.
# Anyone who can comment could paste the marker, so nobody else's counts. Its body goes to
# "${REVIEW_BODY_FILE}" when that is set.
newest_review() {
  local marker rows id at who upd t
  marker="$(policy '.reviewMarker')"
  rows="$(gh api --paginate "repos/${GH_REPO}/issues/$1/comments?per_page=100" \
    --jq ".[] | select((.body // \"\") | contains(\"${marker}\")) | \"\(.id) \(.created_at) \(.user.login) \(.updated_at // .created_at)\"")" || return 1
  while read -r id at who upd; do
    [[ -n "${id}" ]] || continue
    if [[ "${who}" != "$(policy '.reviewBotLogin')" ]]; then
      is_agent_bot "${who}" && continue
      actor_trusted "${who}"
      t=$?
      # A failed lookup must not skip a writer's newer verdict for an older one: unreadable.
      [[ "${t}" -ne 2 ]] || return 1
      [[ "${t}" -eq 0 ]] || continue
    fi
    if [[ -n "${REVIEW_BODY_FILE:-}" ]]; then
      gh api "repos/${GH_REPO}/issues/comments/${id}" --jq '.body' >"${REVIEW_BODY_FILE}" || return 1
    fi
    printf '%s %s %s %s\n' "${id}" "${at}" "${who}" "${upd:-${at}}"
    return 0
  done < <(sort -k2,2r -k1,1nr <<<"${rows}")
}

# review_runs <pr> [since-iso]: the Claude review runs of the PR (claude-code-review.yml's run-name is
# "Claude review of PR #N" on both of its triggers), as "run-id created_at status" lines; with
# [since-iso], only runs created on or after the day before it. Every page: the repo runs a few
# dozen reviews a day, so one page reaches back only days, and a PR that waited longer would wedge.
review_runs() {
  local q="per_page=100"
  if [[ -n "${2:-}" ]]; then
    q+="&created=%3E%3D$(jq -rn --arg t "$2" '($t | fromdateiso8601) - 86400 | strftime("%Y-%m-%d")')"
  fi
  gh api --paginate "repos/${GH_REPO}/actions/workflows/claude-code-review.yml/runs?${q}" \
    --jq ".workflow_runs[] | select(.display_title == \"Claude review of PR #$1\") | \"\(.id) \(.created_at) \(.status)\""
}

# review_attribution <pr> <comment-at> <pushed-at>: which Claude review job wrote the review comment
# posted at <comment-at>, by the window its `claude-review` job ran in: "after" when it started after
# the head reached GitHub (<pushed-at>), "before" when it (or, with several candidates, any of them)
# started earlier, so it read the previous diff, "none" when no job's window holds the comment.
# The review pool has one slot, so one window holds it. Exit 1 when the runs cannot be read.
review_attribution() {
  local pr="$1" at="$2" pushed="$3" runs run status w js je inside=0 early=0
  runs="$(review_runs "${pr}" "${pushed}")" || return 1
  while read -r run _ status; do
    [[ -n "${run}" && "${status}" == completed ]] || continue
    # Every attempt (filter=all): a re-run's attempt 2 may skip the review, and its comment then
    # sits in attempt 1's window.
    w="$(gh api "repos/${GH_REPO}/actions/runs/${run}/jobs?filter=all&per_page=100" \
      --jq '.jobs[] | select(.name == "claude-review") | "\(.started_at // "") \(.completed_at // "")"')" || return 1
    while read -r js je; do
      [[ -n "${js}" && -n "${je}" ]] || continue
      if [[ ! "${at}" < "${js}" && ! "${at}" > "${je}" ]]; then
        inside=1
        [[ "${js}" > "${pushed}" ]] || early=1
      fi
    done <<<"${w}"
  done <<<"${runs}"
  if [[ "${early}" == 1 ]]; then echo before; elif [[ "${inside}" == 1 ]]; then echo after; else echo none; fi
}

# review_verdict: stdin is a review comment; prints approve, request-changes or unknown, from the
# first non-empty line under the LAST Verdict heading (a finding may quote an earlier one), with
# fenced code blocks and HTML comments skipped: a review that quotes the template AFTER its verdict
# would otherwise have the quote win, and a comment could hide a second heading. The
# heading is `### Verdict`, `<h3>Verdict</h3>`, `**Verdict**` or `__Verdict__`, alone on its line:
# on 2026-11-07 one review in eight wrote its headings as HTML, an Approve read as unknown, and the
# gate stranded the PR (one review per head); on 2026-11-09 a review wrote them in bold, with the
# same result. Only plain wrapper tags (p, b, i, em, strong) are dropped from the verdict line,
# and a line of them alone is skipped: any other tag can change what a reader sees (<s>Approve</s>,
# <del>, a comment or <details> that hides the line), so it stays literal and the verdict unknown.
# The line must be the verdict alone, give or take emphasis and punctuation: /verify-pr's template
# line is `Approve / Request changes`, and a review that copies it, or hedges, has approved nothing.
review_verdict() {
  local line approve='^approve[[:space:][:punct:]]*$' changes='^request changes[[:space:][:punct:]]*$'
  # Text inside a fenced code block or an HTML comment is quoted, not said: a review that shows the
  # template there after its real verdict must not have that copy win (the last heading counts).
  # Both follow CommonMark: a fence closes only on the same character, at least as long, with
  # nothing after it (so a 4-backtick fence can quote a 3-backtick one), and a backtick opener
  # followed by another backtick on its line is a code span, not a fence; `<!--` opens a comment
  # that may span lines only at the start of a line, while a mid-line `<!--` with no `-->` is
  # literal text (a review about this very parser writes it in a code span). `<!-->` and `<!--->`
  # are complete, empty comments. A fence or comment still open at the end makes the verdict
  # unknown: the rendering is then anyone's guess, and unknown is the safe answer (the gate waits).
  # A line that reads as a Verdict heading only once a comment is stripped makes the whole verdict
  # unknown: `<!-- x -->### Verdict` is raw HTML that renders as text, while `### Verdict <!-- x -->`
  # is a real heading, and telling them apart is not worth a wrong approve.
  # A bold `**Verdict**` is no heading but paragraph text, so unlike ### or <h3> it cannot break out
  # of what the line above opened (an inline comment, a code span, ~~strikethrough~~, a quote or list
  # item by lazy continuation), and its Approve could render hidden or quoted. So it counts only at
  # the start of a paragraph: the first line, or right after a raw blank line (wb).
  # A processing instruction (`<?`), a declaration (`<!X`) or CDATA (`<![CDATA[`) at the start of a
  # line (after indentation, `>` or a list marker; a lone CR ends a line for CommonMark, not for awk,
  # so it counts as a line start too) opens a raw HTML block that runs across blank
  # lines too. Mid-line they are inline HTML, which a blank line ends, so a review that mentions
  # `<?php` or `<?xml` in its text still has a verdict; one on a line of its own (fenced or not)
  # does not.
  # A <details>, <pre>, <script>, <style> or <textarea> tag can put what follows it out of a
  # reader's sight (collapsed, hidden or quoted) across blank lines, and where it ends depends on
  # HTML parsing no regex reproduces. So it fails closed: any of them in the raw text
  # before the verdict line (above the heading or between it and the line) makes the whole verdict
  # unknown, whatever surrounds the tag (a fence, a comment, even backticks) and whether or not it
  # is closed. A NUL would end an awk record early, so it becomes ? first, as CommonMark replaces
  # it too, byte-wise (macOS tr in a UTF-8 locale drops all input after an invalid byte). Every
  # attempt to let a tag through where it looked quoted (counting closers, skipping blocks,
  # stripping code spans) was beaten in review by CommonMark the regexes did not reproduce.
  # The cost: a review that only names one of the tags before its verdict strands its PR; 2 of 449
  # reviews from 2026-08 to 2026-11 did, both of PRs about this parser.
  line="$(LC_ALL=C tr '\000' '?' | awk '
    function hides(s,  t) { t = tolower(s)
      return t ~ /<(details|pre|script|style|textarea)([^a-z0-9-]|$)/ ||
        t ~ /(^|\r)([[:space:]>]|[-*+][[:space:]]|[0-9]+[.)][[:space:]])*<(\?|!\[cdata\[|![a-z])/ }
    { wb = pb; pb = ($0 ~ /^[[:space:]]*$/); if (hides($0)) seen = 1; l = $0
      if (comment) { e = index(l, "-->"); if (!e) next; l = substr(l, e + 3); comment = 0 }
      else if (fence) {
        if (match(l, /^ ? ? ?(```+|~~~+)[[:space:]]*$/)) { t = l; sub(/^ */, "", t); sub(/[[:space:]]*$/, "", t)
          if (substr(t, 1, 1) == fc && length(t) >= fl) fence = 0 }
        next }
      else if (match(l, /^ ? ? ?(```+|~~~+)/)) { t = substr(l, RSTART, RLENGTH); sub(/^ */, "", t)
        fc = substr(t, 1, 1); rest = substr(l, RSTART + RLENGTH)
        if (!(fc == "`" && index(rest, "`"))) { fl = length(t); fence = 1; next } }
      first = (l ~ /^ ? ? ?<!--/)
      while ((b = index(l, "<!--"))) { pre = substr(l, 1, b - 1); rest = substr(l, b + 4)
        if (substr(rest, 1, 1) == ">") k = 2; else if (substr(rest, 1, 2) == "->") k = 3; else { e = index(rest, "-->"); k = e ? e + 3 : 0 }
        if (k) l = pre substr(rest, k); else if (first) { l = pre; comment = 1; break } else break
        first = 0 }
      if (l ~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*$/) next
      stripped = (l != $0); $0 = l }
    /^###[[:space:]]+Verdict[[:space:]]*$/ || /^<[hH]3>[[:space:]]*Verdict[[:space:]]*<\/[hH]3>[[:space:]]*$/ ||
    ((NR == 1 || wb) && (/^[*][*]Verdict[*][*][[:space:]]*$/ || /^__Verdict__[[:space:]]*$/)) { if (stripped || seen) ambiguous = 1; on = 1; v = ""; next }
    on { if (seen) ambiguous = 1; l = $0; gsub(/<\/?([pP]|[bB]|[iI]|[eE][mM]|[sS][tT][rR][oO][nN][gG])>/, "", l); if (l ~ /^[[:space:]]*$/) next; v = l; on = 0 }
    END { if (!fence && !comment && !ambiguous) print v }' | tr -d '*_`' | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//')"
  if [[ "${line}" =~ ${approve} ]]; then
    echo approve
  elif [[ "${line}" =~ ${changes} ]]; then
    echo request-changes
  else
    echo unknown
  fi
}

# head_pushed_at <sha>: when the commit reached GitHub: the earliest check suite created for it,
# which a commit's own dates (set by whoever made it, the agent included) cannot move. The
# committer date when no suite exists yet.
head_pushed_at() {
  local at forced owner="${GH_REPO%%/*}" repo="${GH_REPO#*/}"
  at="$(gh api "repos/${GH_REPO}/commits/$1/check-suites?per_page=100" --jq '[.check_suites[].created_at] | min // empty')" || return 1
  # A force-push back to an older SHA makes it the head again without a new check suite, so its
  # first suite's time is long before it came back: the PR's latest force-push TO this SHA counts.
  if [[ -n "${2:-}" ]]; then
    forced="$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){timelineItems(itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT],last:100){nodes{... on HeadRefForcePushedEvent{createdAt afterCommit{oid}}}}}}}' \
      -f o="${owner}" -f r="${repo}" -F n="$2" \
      --jq "[.data.repository.pullRequest.timelineItems.nodes[]? | select(.afterCommit.oid == \"$1\") | .createdAt] | max // empty")" || return 1
    if [[ -n "${forced}" && ( -z "${at}" || "${forced}" > "${at}" ) ]]; then at="${forced}"; fi
  fi
  [[ -n "${at}" ]] || at="$(gh api "repos/${GH_REPO}/commits/$1" --jq '.commit.committer.date')" || return 1
  [[ -n "${at}" ]] || return 1
  printf '%s\n' "${at}"
}

# --- finalize ----------------------------------------------------------------------------------------

# finalize_plan <outcome> <reason> <attempt> <max> [counted]: pure. Prints "add|remove|kind" where
# kind is the inbox request to file (empty for none). counted=false is a run that never reached the
# model: straight back to the queue, keeping agent:allow-protected, whose attempt never happened.
finalize_plan() {
  local outcome="$1" reason="$2" attempt="$3" max="$4" counted="${5:-true}"
  if [[ "${counted}" == false ]]; then
    echo "agent:ready|agent:in-progress|"
    return
  fi
  # agent:allow-protected is ONE-SHOT: every outcome removes it from the issue (an opened PR keeps
  # its own copy for the guard), so each attempt has to be allowed again.
  local rm="agent:in-progress,agent:allow-protected"
  case "${outcome}" in
    pr-opened) echo "agent:pr-open|${rm}|" ;;
    blocked) echo "agent:blocked,agent:needs-human|${rm}|blocked" ;;
    refused)
      if [[ "${reason}" == protected:* ]]; then
        echo "agent:blocked,agent:needs-human|${rm}|protected"
      elif [[ "${reason}" == never:* ]]; then
        echo "agent:blocked,agent:needs-human|${rm}|blocked"
      elif [[ "${reason}" == untrusted-change:* ]]; then
        # Never back to agent:ready: the bot's label would not re-anchor trust, so auto-pick would
        # skip it forever and a named run would be refused again. A person re-applies the label.
        echo "agent:blocked,agent:needs-human|${rm}|untrusted"
      elif [[ "${attempt}" -lt "${max}" ]]; then
        echo "agent:ready|${rm}|"
      else
        echo "agent:blocked,agent:needs-human|${rm}|failed"
      fi
      ;;
    *)
      if [[ "${attempt}" -lt "${max}" ]]; then
        echo "agent:ready|${rm}|"
      else
        echo "agent:blocked,agent:needs-human|${rm}|failed"
      fi
      ;;
  esac
}

# request_body <kind> <issue> <reason> <blocked-file>: the inbox request text. The REQ id is not known
# yet, so commands name it as REQ-ID and the caller substitutes it.
request_body() {
  local kind="$1" issue="$2" reason="$3" note="$4"
  case "${kind}" in
    blocked)
      printf '**What:** the coder stopped on #%s and needs a decision.\n\n' "${issue}"
      if [[ -s "${note}" ]]; then
        printf '**Its note:**\n\n'
        sed 's/^/> /' "${note}"
        printf '\n\n'
      else
        printf '**Why:** %s\n\n' "${reason}"
      fi
      printf '**Answer with one of:**\n'
      printf -- '- `/approve REQ-ID` put #%s back in the queue as it is and start the coder on it (edit the issue first if the agent misread it)\n' "${issue}"
      printf -- '- to let it touch protected paths, add `agent:allow-protected` to #%s, then `/rerun coder #%s`. Everything under `.github/` and `.claude/`, `.mcp.json` and the agents'"'"' own tests stay closed even then\n' "${issue}" "${issue}"
      printf -- '- `/reject REQ-ID <reason>` leave it blocked\n\n'
      ;;
    protected)
      printf '**What:** the coder'"'"'s change for #%s touches protected paths, so it was not pushed.\n\n' "${issue}"
      printf '**Paths:** %s\n\n' "${reason#protected:}"
      printf '**Answer with one of:**\n'
      printf -- '- `/approve REQ-ID` allow protected paths for ONE more attempt on #%s and start it. The PR will say so, and a person merges it\n' "${issue}"
      printf -- '- `/reject REQ-ID <reason>` leave it blocked\n\n'
      ;;
    failed)
      printf '**What:** the coder failed #%s on its last allowed attempt.\n\n**Last failure:** %s\n\n' "${issue}" "${reason}"
      printf '**Answer with one of:**\n'
      printf -- '- `/approve REQ-ID` try once more as it is\n'
      printf -- '- `/rerun coder #%s` the same, after you edit the issue to make it clearer\n' "${issue}"
      printf -- '- `/reject REQ-ID <reason>` leave it blocked\n\n'
      ;;
    untrusted)
      printf '**What:** someone without write access changed #%s after the label this run trusts, or its trust check failed, so nothing reached the agent.\n\n' "${issue}"
      printf '**Answer with one of:**\n'
      printf -- '- read the change; if it is fine, re-apply `agent:ready` on #%s yourself, then `/rerun coder #%s`. Only your own label vouches for issue text; the bot'"'"'s does not\n' "${issue}" "${issue}"
      printf -- '- `/approve REQ-ID` acknowledge it and change nothing\n'
      printf -- '- `/reject REQ-ID <reason>` leave it blocked\n\n'
      ;;
    breaker)
      printf '**What:** the %s'"'"'s circuit breaker tripped: %s. No %s run starts until it is reset.\n\n' "${ROLE}" "${reason}" "${ROLE}"
      printf '**Answer with one of:**\n'
      printf -- '- `/approve REQ-ID` or `/resume %s` reset it\n' "${ROLE}"
      printf -- '- `/reject REQ-ID` keep the %s paused\n\n' "${ROLE}"
      ;;
  esac
  printf '**If nobody answers:** nothing happens on its own.\n'
}

# file_request <kind> <issue> <summary> <reason> <note-file>: prints the request id.
file_request() {
  local kind="$1" issue="$2" summary="$3" reason="$4" note="$5" body req_id
  req_id="${AGENT_REQ_ID:-$(new_req_id)}"
  body="$(mktemp)"
  request_body "${kind}" "${issue}" "${reason}" "${note}" | sed "s/REQ-ID/${req_id}/g" >"${body}"
  AGENT_REQ_ID="${req_id}" inbox_request "${kind}" "${ROLE}" "${issue}" "${summary}" "${body}"
  rm -f "${body}"
}

cmd_finalize() {
  local outcome="${OUTCOME:-failed}" issue="${ISSUE:?}" attempt="${ATTEMPT:-1}" reason
  # Sanitised again here, not only in the outbox: this text reaches the issue, the inbox request
  # and the inbox checklist, whichever step produced it.
  reason="$(printf '%s' "${REASON:-}" | agent_oneline 300)"
  case "${outcome}" in pr-opened | blocked | refused | no-op | failed) ;; *) outcome=failed ;; esac
  local max plan add remove kind body note="${FINAL_DIR:-/nonexistent}/blocked.md" tripped row metrics
  local counted=true infra="" infra_step="" irc
  max="$(policy ".roles[\"${ROLE}\"].maxAttemptsPerIssue")"
  # Only a plain failure is ever reclassified: refusals (an untrusted change, a path rule) and
  # everything else keep their meaning.
  if [[ "${outcome}" == failed && "${ROLE}" == coder ]]; then
    infra="$(infra_failure coder "implement (agent)" implement "${CODER_PRE_AGENT_STEPS[@]}")"
    irc=$?
    infra_step="${infra#*|}"
    if [[ "${irc}" -eq 0 ]]; then
      counted=false
      reason="$(printf 'infrastructure: %s failed before the agent started (not counted)' "${infra_step}" | agent_oneline 300)"
    elif [[ "${irc}" -eq 2 ]]; then
      reason="$(printf 'infrastructure (%s); today'"'"'s grace is used, so it counts' "${infra_step}" | agent_oneline 300)"
    else
      infra_step=""
    fi
  fi
  plan="$(finalize_plan "${outcome}" "${reason}" "${attempt}" "${max}" "${counted}")"
  IFS='|' read -r add remove kind <<<"${plan}"
  ensure_labels || agent_log "finalize: could not ensure labels"
  relabel "${issue}" "${add}" "${remove}" || agent_log "finalize: relabel failed"

  body="$(mktemp)"
  case "${outcome}" in
    pr-opened)
      printf 'The %s agent opened %s (attempt %s, [run](%s)).\n\n' "${ROLE}" "${PR_URL:-a PR}" "${attempt}" "${RUN_URL:-}" >"${body}"
      if [[ -s "${FINAL_DIR:-}/summary.md" ]]; then cat "${FINAL_DIR}/summary.md" >>"${body}"; fi
      ;;
    blocked)
      printf 'The %s agent stopped and asked for a decision (attempt %s, [run](%s)). The request is in the agent inbox.\n\n' "${ROLE}" "${attempt}" "${RUN_URL:-}" >"${body}"
      if [[ -s "${note}" ]]; then sed 's/^/> /' "${note}" >>"${body}"; fi
      ;;
    *)
      if [[ "${counted}" == false ]]; then
        # The marker is what voids this run's lock in the attempt count (JQ_ISSUE_DEFS `locks`).
        printf '<!-- agent:no-attempt run=%s -->\n' "${RUN_ID:-local}" >"${body}"
        printf 'The %s agent'"'"'s [run](%s) failed before the agent started, at the step **%s**. It did no work, so it does not count as attempt %s, as a run today or towards the breaker. It is back in the queue.\n' \
          "${ROLE}" "${RUN_URL:-}" "${infra_step}" "${attempt}" >>"${body}"
      else
        printf 'Attempt %s of %s by the %s agent ended without a PR: **%s**%s ([run](%s)).\n' \
          "${attempt}" "${max}" "${ROLE}" "${outcome}" "${reason:+ (${reason})}" "${RUN_URL:-}" >"${body}"
        if [[ "${add}" == agent:ready ]]; then
          printf '\nIt is back in the queue for another attempt.\n' >>"${body}"
        elif [[ "${kind}" == untrusted ]]; then
          printf '\nNothing reached the agent. Read the change; to run it again, re-apply `agent:ready` yourself (the bot'"'"'s re-label does not count), then `/rerun coder #%s` in the agent inbox, where a note is waiting.\n' "${issue}" >>"${body}"
        else
          printf '\nNo attempts left. A request is in the agent inbox.\n' >>"${body}"
        fi
      fi
      ;;
  esac
  gh issue comment "${issue}" --body-file "${body}" >/dev/null || agent_log "finalize: issue comment failed"
  rm -f "${body}"

  if [[ -n "${kind}" ]]; then
    file_request "${kind}" "${issue}" "${outcome}${reason:+: ${reason}}" "${reason}" "${note}" >/dev/null \
      || agent_log "finalize: inbox request failed"
  fi

  metrics='{}'
  if [[ -s "${METRICS_FILE:-}" ]] && jq -e 'type == "object"' "${METRICS_FILE}" >/dev/null 2>&1; then
    metrics="$(jq -c . "${METRICS_FILE}")"
  fi
  row="$(jq -cn --arg run "${RUN_ID:-local}" --arg url "${RUN_URL:-}" --arg role "${ROLE}" \
    --arg trigger "${TRIGGER:-workflow_dispatch}" --argjson issue "${issue}" --argjson attempt "${attempt}" \
    --arg pr "${PR_NUMBER:-}" --arg outcome "${outcome}" --arg reason "${reason}" \
    --arg model "$(policy ".roles[\"${ROLE}\"].model")" --arg started "${STARTED_AT:-}" \
    --arg ended "$(agent_iso)" --argjson m "${metrics}" --argjson counted "${counted}" --arg infra "${infra_step}" '
      {v: 1, run_id: $run, run_url: $url, role: $role, trigger: $trigger, issue: $issue,
       attempt: $attempt, pr: (if $pr == "" then null else ($pr | tonumber) end),
       outcome: $outcome, reason: $reason, model: $model, counted: $counted,
       infra_step: (if $infra == "" then null else $infra end),
       turns: ($m.turns // null), duration_ms: ($m.duration_ms // null), cost_usd: ($m.cost_usd // null),
       started_at: (if $started == "" then $ended else $started end), ended_at: $ended}')"
  bash "${SCRIPT_DIR}/agent-ledger.sh" append "${row}" || agent_log "finalize: ledger append failed"
  tripped=""
  if [[ "${counted}" == false ]]; then
    agent_log "finalize: the run never reached the model; no breaker step"
  else
    tripped="$(bash "${SCRIPT_DIR}/agent-ledger.sh" breaker-record "${ROLE}" "${outcome}" "${RUN_ID:-local}")" \
      || agent_log "finalize: breaker update failed"
  fi
  if [[ "${tripped}" == "tripped" ]]; then
    file_request breaker "${issue}" "circuit breaker tripped" \
      "$(policy ".roles[\"${ROLE}\"].breakerThreshold // 3") runs in a row ended without a PR (last: ${outcome})" /dev/null >/dev/null \
      || agent_log "finalize: breaker request failed"
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### Agent %s: %s\n\n' "${ROLE}" "${outcome}"
      printf '| issue | attempt | PR | reason |\n|---|---|---|---|\n'
      printf '| #%s | %s | %s | %s |\n' "${issue}" "${attempt}" "${PR_URL:-}" "${reason}"
    } >>"${GITHUB_STEP_SUMMARY}"
  fi
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    gate) cmd_gate "$@" ;;
    pick) cmd_pick "$@" ;;
    lock) cmd_lock "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    finalize) cmd_finalize ;;
    kick) cmd_kick ;;
    *) agent_log "usage: agent-state.sh gate|pick|lock|snapshot|finalize|kick"; return 2 ;;
  esac
}

if [[ "${AGENT_STATE_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
