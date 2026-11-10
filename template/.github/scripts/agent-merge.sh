#!/usr/bin/env bash
# .github/scripts/agent-merge.sh
# The merge gate (.github/workflows/agent-merge.yml): merges an agent PR only when ALL of these hold,
# each checked against the PR's CURRENT head, and otherwise says which one did not:
#   - the agents are on (AGENTS_ENABLED) and no role's breaker is tripped;
#   - the PR is open, not a draft, the agent bot's, labelled agent:pr, against main, from this
#     repository, mergeable, and carries none of agent:hold, agent:blocked, agent:needs-human,
#     agent:fixing or agent:allow-protected (that last one means a person merges it);
#   - every policy.requiredChecks check run, and `agent pr guard`, is `success` on the head SHA,
#     from GitHub Actions, in its latest run (the commit's check runs, not a PR summary);
#   - the newest Claude review (a `<!-- verify-pr-review -->` comment by the review bot or a person
#     with write access) says Approve, is newer than the head reached GitHub, and, for the review
#     bot's, was written by a review job that STARTED after that (a review that began on the old head
#     and posted after a push saw the old diff); and no review of the PR is still queued or running;
#   - no changed file is protected (.github/agents/protected-paths.txt) or in policy.humanPaths;
#   - the head contains main's CURRENT tip (the compare API's behind_by is 0), so the checks and the
#     review saw what main will hold. Decided 2026-11-06 instead of a strict ruleset, which would
#     hold human PRs to it too, and instead of one merge per run, which only narrows the gap: every
#     gate_one reads live, so a second PR in the same run is behind once the first has merged;
#   - AGENT_AUTO_MERGE is `true`. Otherwise this is a dry run: everything is checked and reported,
#     nothing is merged, updated, labelled or dispatched.
# Then `gh pr merge --merge --match-head-commit <sha> --delete-branch` with the App token: never
# --admin (the App is no ruleset bypass actor anyway), never --auto (repo auto-merge is off). The
# issue moves to agent:done-pending-deploy and the ledger gets a row. One window stays open: main
# can move in the seconds between the compare and the merge, which pins only the head. Accepted.
#
# Two things the gate does besides merging, in live runs only:
#   - update: a PR whose ONLY blocker is being behind main (a mergeable of CONFLICTING counts as
#     part of that) gets `PUT pulls/N/update-branch` pinned to its head, so GitHub merges main into
#     it. Any other blocker, a stale review included, and the gate leaves the branch alone, so it
#     never races the fixer. GitHub refuses when main's new commits change workflow files (the App
#     has no Workflows permission) or when the merge conflicts: then the PR gets agent:needs-human
#     and the inbox a `merger` request, once per head.
#   - review: the update is a new head, so the old Approve no longer counts, and nothing carries it
#     across. Once the required checks pass on a head the gate's own update made (its first parent
#     is a head the gate recorded updating, or one it asked a person to update), and nothing but the
#     review and being behind main again is missing, the gate asks for one fresh Claude review of
#     it (request_review, never while a review is queued or running; a request no review answered
#     is made again after 45 minutes, at most twice, then a person is asked in the inbox). If that
#     head conflicts with main as well, a person is asked instead. A head a person pushed on their
#     own still waits for that person. A head whose review the agents already asked for (the fixer,
#     after CI passed on its push) gets the same retries, unless it conflicts with main: a
#     dispatched review can end without posting, and nothing else would ask again.
#
# Usage: agent-merge.sh run [<pr>]   every open agent PR, or the one named
# Env:   GH_TOKEN, GH_REPO, AGENTS_ENABLED, AGENT_AUTO_MERGE, AGENT_BOT_EMAIL;
#        AGENT_MERGE_NO_MAIN=1 loads the functions only (repo-agents' tests/workflows/agents-merge.test.sh).
#
# Every check reads the live state, so a run that starts late, or twice, decides the same, and a PR
# checked after another merged in the same run sees the new main. Runs share one concurrency group,
# so two never merge at once.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # read by the sourced agent-state.sh
AGENT_STATE_NO_MAIN=1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-state.sh"
unset AGENT_STATE_NO_MAIN

MERGE_PR_FIELDS='number,state,isDraft,author,labels,headRefName,headRefOid,baseRefName,isCrossRepository,mergeable,body,createdAt,reviews'

# pr_blockers <pr-json>: what about the PR itself stops a merge, one reason a line. Pure.
pr_blockers() {
  jq -r --arg slug "${AGENT_BOT_SLUG}" --arg base "$(policy '.baseBranch')" '
    def has($l): ([.labels[]?.name] | index($l)) != null;
    (if .state != "OPEN" then "not open" else empty end),
    (if ((.author.login // "") | IN($slug, "app/" + $slug, $slug + "[bot]")) then empty else "not the agent bot'"'"'s PR" end),
    (if has("agent:pr") then empty else "no agent:pr label" end),
    (if .isDraft then "a draft" else empty end),
    (if .isCrossRepository then "from a fork" else empty end),
    (if .baseRefName != $base then "not against \($base)" else empty end),
    (if .mergeable == "MERGEABLE" then empty else "mergeable is \(.mergeable)" end),
    (["agent:hold", "agent:blocked", "agent:needs-human", "agent:fixing", "agent:allow-protected"][] as $l
      | if has($l) then "labelled \($l)" else empty end)' <<<"$1"
}

# checks_blockers <sha>: each required check (policy.requiredChecks, then `agent pr guard`) whose
# LATEST GitHub Actions check run on <sha> is not `success`, one a line.
checks_blockers() {
  local runs name got
  runs="$(gh api --paginate "repos/${GH_REPO}/commits/$1/check-runs?per_page=100" \
    --jq '.check_runs[] | select(.app.slug == "github-actions") | "\(.id)\t\(.name)\t\(.status)\t\(.conclusion // "none")"')" \
    || { echo "check runs unreadable"; return 0; }
  # No required checks means nothing says CI passed: the gate never takes the review alone.
  [[ "$(policy '(.requiredChecks | type == "array" and length > 0)')" == true ]] \
    || echo "policy.json requiredChecks is empty: list the CI checks that must pass before an agent PR merges"
  while IFS= read -r name; do
    got="$(awk -F '\t' -v n="${name}" '$2 == n' <<<"${runs}" | sort -t$'\t' -k1,1n | tail -1 | cut -f3,4 | tr '\t' '/')"
    [[ "${got}" == completed/success ]] || echo "check '${name}' is ${got:-missing}"
  done < <(policy '.requiredChecks[]'; echo 'agent pr guard')
}

# review_blockers <pr> <head-pushed-at>: why the newest review is not an Approve of this head.
# Which review job wrote a claude[bot] comment comes from agent-state.sh review_attribution.
review_blockers() {
  local pr="$1" pushed="$2" f review at who upd verdict runs seen
  f="$(mktemp)"
  if ! review="$(REVIEW_BODY_FILE="${f}" newest_review "${pr}")"; then rm -f "${f}"; echo "reviews unreadable"; return 0; fi
  if [[ -z "${review}" ]]; then rm -f "${f}"; echo "no review yet"; return 0; fi
  read -r _ at who upd <<<"${review}"
  verdict="$(review_verdict <"${f}")"
  rm -f "${f}"
  [[ "${verdict}" == approve ]] || echo "the newest review says ${verdict}"
  [[ "${at}" > "${pushed}" ]] || echo "the newest review (${at}) is not newer than the head (${pushed})"
  runs="$(review_runs "${pr}" "${pushed}")" || { echo "review runs unreadable"; return 0; }
  if grep -Eq ' (queued|in_progress|waiting|requested|pending)$' <<<"${runs}"; then echo "a review is still running"; fi
  [[ "${who}" == "$(policy '.reviewBotLogin')" ]] || return 0
  # The review bot never edits its review; another PR's review job can edit its comments.
  [[ "${upd:-${at}}" == "${at}" ]] || echo "the newest review was edited after it was posted"
  seen="$(review_attribution "${pr}" "${at}" "${pushed}")" || { echo "review runs unreadable"; return 0; }
  case "${seen}" in
    after) ;;
    before) echo "the newest review was written by a job that started before the head was pushed" ;;
    *) echo "no review job of #${pr} wrote the newest review" ;;
  esac
}

# person_review_blockers <pr-json>: a GitHub review requesting changes, by anyone with write access,
# stops the merge until they approve or it is dismissed, whichever head it was on: the fixer may not
# have answered it yet (a cap, a refusal, or its turn on the one agent slot). Each author's latest
# APPROVED, CHANGES_REQUESTED or DISMISSED review decides; not `latestReviews`, where a later
# COMMENTED review (a reply in a thread) takes the place of a standing Request changes. Pure but
# for the permission lookups; a failed one is a blocker too.
person_review_blockers() {
  local who t
  while IFS= read -r who; do
    [[ -n "${who}" ]] || continue
    is_agent_bot "${who}" && continue
    actor_trusted "${who}"
    t=$?
    case "${t}" in
      0) echo "${who} requested changes" ;;
      2) echo "could not tell whether ${who}, who requested changes, has write access" ;;
    esac
  done < <(jq -r '[.reviews[]? | select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
    | group_by(.author.login) | map(max_by(.submittedAt)) | .[]
    | select(.state == "CHANGES_REQUESTED") | .author.login // empty' <<<"$1")
}

# path_blockers <pr>: changed files that are protected or human-only.
path_blockers() {
  local files hits human p glob
  files="$(gh api --paginate "repos/${GH_REPO}/pulls/$1/files?per_page=100" --jq '.[] | .filename, (.previous_filename // empty)')" \
    || { echo "files unreadable"; return 0; }
  hits="$(protected_hits <<<"${files}")"
  [[ -z "${hits}" ]] || echo "touches protected paths: $(tr '\n' ' ' <<<"${hits}")"
  human=""
  while IFS= read -r glob; do
    [[ -n "${glob}" ]] || continue
    while IFS= read -r p; do
      [[ -n "${p}" && "${p}" =~ $(glob_to_ere "${glob}") ]] && human+="${p} "
    done <<<"${files}"
  done < <(policy '.humanPaths[]?')
  [[ -z "${human}" ]] || echo "touches policy.humanPaths: ${human}"
}

# breaker_blockers: any role whose breaker is tripped stops every merge.
breaker_blockers() {
  local b
  b="$(ledger_file state/breaker.json)" || { echo "breaker unreadable"; return 0; }
  # Malformed is unreadable, not closed: a merge needs a breaker it can read.
  jq -r 'if type != "object" or (map_values(type == "object") | all | not) then "breaker unreadable"
    else to_entries[] | select(.value.tripped_at != null) | "the \(.key) breaker is tripped" end' <<<"${b:-{\}}" 2>/dev/null \
    || echo "breaker unreadable"
}

# behind_blockers <sha>: how many commits of main's current tip the head lacks, as a blocker.
behind_blockers() {
  local base n
  base="$(policy '.baseBranch')"
  if ! n="$(gh api "repos/${GH_REPO}/compare/${base}...$1" --jq '.behind_by')" || [[ ! "${n}" =~ ^[0-9]+$ ]]; then
    echo "could not compare the head with ${base}"
    return 0
  fi
  [[ "${n}" -eq 0 ]] || echo "behind ${base} by ${n} commits"
}

# The blockers an update or a fresh review can clear; everything else waits for its own owner.
BEHIND_RE='^behind [^ ]+ by [0-9]+ commits$'
CONFLICT_RE='^mergeable is CONFLICTING$'
# A review the gate's own update made stale can also read as one no review job wrote (review_runs
# reads from the day before the push, so an older Approve falls outside it), or as edited.
STALE_RE='^(no review yet|the newest review \(.*\) is not newer than the head \(.*\)|the newest review was written by a job that started before the head was pushed|no review job of #[0-9]+ wrote the newest review|the newest review was edited after it was posted)$'
VERDICT_RE='^the newest review says '

# gate_updated_head <pr> <sha>: exit 0 when <sha> is a branch update the gate made or asked for: a
# merge commit whose first parent is a head the gate recorded updating on this PR, or one it could
# not update and asked a person to (what the needs-human request asks of them).
gate_updated_head() {
  local bodies parent
  bodies="$(pr_bot_comments "$1")" || return 1
  # A merge only (update-branch and `git merge main` both make one): a person's own commit on top of
  # a recorded head is theirs, not an update.
  parent="$(gh api "repos/${GH_REPO}/commits/$2" --jq 'if (.parents | length) == 2 then .parents[0].sha else "" end')" || return 1
  [[ -n "${parent}" ]] || return 1
  grep -Fq -e "<!-- agent-merge-updated from=${parent} -->" -e "<!-- agent-merge-needs-human sha=${parent} -->" <<<"${bodies}"
}

# review_requested_head <pr> <sha>: exit 0 when the agents already asked for a review of <sha> (the
# fixer after CI passed on its push, or this gate): the review of that head is theirs to ask again.
review_requested_head() {
  local bodies
  bodies="$(pr_bot_comments "$1")" || return 1
  grep -Fq "<!-- agent-review-dispatched sha=$2 -->" <<<"${bodies}"
}

# gate_one <pr>: prints one of
#   merge <sha>                    every condition holds
#   update <sha> <n>               behind main by <n> is the only blocker: update the branch
#   review <sha> wait: <reasons>   the head is the gate's own update, and a review of it is all
#                                  that is missing (being behind again too, so the two cannot wait
#                                  on each other); or the same on a head whose review the agents
#                                  already asked for, unless it conflicts with main
#   conflict <sha> <n>             the same, but it now conflicts with main as well: neither a
#                                  review nor an update can move it, so a person merges main in
#   wait: <reasons>                anything else; the reasons are each blocker found
gate_one() {
  local pr="$1" json sha pushed blockers others n reasons
  json="$(gh pr view "${pr}" --json "${MERGE_PR_FIELDS}")" || { echo "wait: #${pr} unreadable"; return 0; }
  sha="$(jq -r .headRefOid <<<"${json}")"
  blockers="$(pr_blockers "${json}")"
  blockers+=$'\n'"$(person_review_blockers "${json}")"
  [[ "${AGENTS_ENABLED:-}" == true ]] || blockers+=$'\nAGENTS_ENABLED is not true'
  blockers+=$'\n'"$(breaker_blockers)"
  blockers+=$'\n'"$(checks_blockers "${sha}")"
  if pushed="$(head_pushed_at "${sha}" "${pr}")"; then
    blockers+=$'\n'"$(review_blockers "${pr}" "${pushed}")"
  else
    blockers+=$'\nthe head'"'"'s push time is unreadable'
  fi
  blockers+=$'\n'"$(path_blockers "${pr}")"
  blockers+=$'\n'"$(behind_blockers "${sha}")"
  blockers="$(grep -v '^$' <<<"${blockers}")"
  if [[ -z "${blockers}" ]]; then
    printf 'merge %s\n' "${sha}"
    return 0
  fi
  reasons="$(paste -sd';' - <<<"${blockers}" | sed 's/;/; /g')"
  others="$(grep -Ev "${BEHIND_RE}|${CONFLICT_RE}|${STALE_RE}|${VERDICT_RE}" <<<"${blockers}")"
  if [[ -z "${others}" ]] && grep -Eq "${BEHIND_RE}" <<<"${blockers}" \
    && ! grep -Eq "${STALE_RE}|${VERDICT_RE}" <<<"${blockers}"; then
    n="$(grep -E "${BEHIND_RE}" <<<"${blockers}" | grep -oE '[0-9]+ commits$' | cut -d' ' -f1)"
    printf 'update %s %s\n' "${sha}" "${n}"
  elif [[ -z "${others}" ]] && grep -Eq "${STALE_RE}" <<<"${blockers}" && gate_updated_head "${pr}" "${sha}"; then
    if ! grep -Eq "${CONFLICT_RE}" <<<"${blockers}"; then
      printf 'review %s wait: %s\n' "${sha}" "${reasons}"
    elif grep -Eq "${BEHIND_RE}" <<<"${blockers}"; then
      n="$(grep -E "${BEHIND_RE}" <<<"${blockers}" | grep -oE '[0-9]+ commits$' | cut -d' ' -f1)"
      printf 'conflict %s %s\n' "${sha}" "${n}"
    else
      printf 'wait: %s\n' "${reasons}"
    fi
  elif [[ -z "${others}" ]] && grep -Eq "${STALE_RE}" <<<"${blockers}" \
    && ! grep -Eq "${CONFLICT_RE}" <<<"${blockers}" && review_requested_head "${pr}" "${sha}"; then
    printf 'review %s wait: %s\n' "${sha}" "${reasons}"
  else
    printf 'wait: %s\n' "${reasons}"
  fi
}

# update_one <pr> <sha> <n>: ask GitHub to merge main into the PR's branch, pinned to <sha>. 202
# means it does so asynchronously, as a new head the next run sees. A head still here on the next run
# is asked for again (the earlier update may have failed after its 202), but recorded only once.
update_one() {
  local pr="$1" sha="$2" n="$3" base out why body bodies
  base="$(policy '.baseBranch')"
  bodies="$(pr_bot_comments "${pr}")" || { echo "#${pr}: behind ${base} by ${n} commits, and its comments are unreadable, so no update"; return 1; }
  if out="$(gh api -X PUT "repos/${GH_REPO}/pulls/${pr}/update-branch" -f expected_head_sha="${sha}" 2>&1)"; then
    if grep -Fq "<!-- agent-merge-updated from=${sha} -->" <<<"${bodies}"; then
      echo "#${pr}: behind ${base} by ${n} commits: asked GitHub again to merge ${base} into the branch (the earlier request left the head where it was)"
      return 0
    fi
    body="$(mktemp)"
    printf '<!-- agent-merge-updated from=%s -->\nThis branch was %s commits behind `%s`, so the merge gate asked GitHub to merge `%s` into it. That is a new head, which the last review did not see: CI runs on it, and once the required checks pass the gate asks for a fresh Claude review.\n' \
      "${sha}" "${n}" "${base}" "${base}" >"${body}"
    if ! gh issue comment "${pr}" --body-file "${body}" >/dev/null; then
      rm -f "${body}"
      # Without the marker the gate cannot tell its update from a person's push, and never asks for
      # the review: say so, loudly.
      echo "#${pr}: behind ${base} by ${n} commits: the branch update was requested, but not recorded on the PR, so its review must be requested by hand"
      return 1
    fi
    rm -f "${body}"
    echo "#${pr}: behind ${base} by ${n} commits: asked GitHub to merge ${base} into the branch (the next run sees the new head)"
    return 0
  fi
  case "$(tr '[:upper:]' '[:lower:]' <<<"${out}")" in
    # GitHub's wording is not documented; the owner saw "refusing to allow a GitHub App to create or
    # update workflow". Any mention of a workflow is that refusal: no retry can change it.
    *workflow*) why="${base}'s new commits change workflow files, which the agent App may not push" ;;
    *"merge conflict"*) why="merging ${base} into the branch conflicts" ;;
    *"expected head sha"*)
      echo "#${pr}: the head moved while the gate checked it; the next run sees the new one"
      return 0
      ;;
    *)
      echo "#${pr}: behind ${base} by ${n} commits, and the branch update failed: $(printf '%s' "${out}" | agent_oneline 200)"
      return 1
      ;;
  esac
  ask_person_update "${pr}" "${sha}" "${n}" "${why}"
}

# ask_person_update <pr> <sha> <n> <why>: the branch cannot be brought up to date by the gate, so a
# person does it, once per head, in three steps that each fail the run when they fail and are each
# retried by the next run until they hold: an inbox request (its own marker, so a retry never files
# a second), then agent:needs-human (which every agent leaves alone, so the next run stops here), then
# a PR comment whose marker says all three are done. A person who takes the label off without
# updating the branch meets that marker, and is not asked again.
ask_person_update() {
  local pr="$1" sha="$2" n="$3" why="$4" base bodies inbox asked issue body req ask_marker
  base="$(policy '.baseBranch')"
  bodies="$(pr_bot_comments "${pr}")" || { echo "#${pr}: cannot be brought up to date (${why}), and the PR's comments are unreadable"; return 1; }
  if grep -Fq "<!-- agent-merge-needs-human sha=${sha} -->" <<<"${bodies}"; then
    echo "#${pr}: behind ${base} by ${n} commits, and it cannot be brought up to date (${why}); a person was already asked"
    return 0
  fi
  ask_marker="<!-- agent-merge-ask pr=${pr} sha=${sha} -->"
  inbox="$(inbox_issue)" || { echo "#${pr}: cannot be brought up to date (${why}), and the agent inbox cannot be found"; return 1; }
  asked="$(pr_bot_comments "${inbox}")" || { echo "#${pr}: cannot be brought up to date (${why}), and the agent inbox is unreadable"; return 1; }
  if ! grep -Fq "${ask_marker}" <<<"${asked}"; then
    issue="$(pr_issue "$(gh pr view "${pr}" --json body)")"
    body="$(mktemp)"
    {
      printf '%s\n' "${ask_marker}"
      printf '**What:** #%s is %s commits behind `%s`, and the merge gate cannot bring it up to date: %s.\n\n' "${pr}" "${n}" "${base}" "${why}"
      printf '**What you can do:**\n'
      printf -- '- merge `%s` into the branch yourself (`gh pr update-branch %s`, or locally), resolving any conflict, then remove `agent:needs-human` from #%s. When that merge is the only new commit, the gate asks for a fresh Claude review once CI passes, and merges after its Approve; with other commits on top, ask for one yourself: `gh workflow run "Claude Code Review" -f pr=%s`\n' "${base}" "${pr}" "${pr}" "${pr}"
      printf -- '- or close #%s\n' "${pr}"
      printf -- '- `/approve REQ-ID` or `/reject REQ-ID` only record that you saw this; neither changes #%s\n\n' "${pr}"
      printf '**If nobody answers:** #%s waits.\n' "${pr}"
    } >"${body}.req"
    req="$(new_req_id)"
    sed "s/REQ-ID/${req}/g" "${body}.req" >"${body}"
    rm -f "${body}.req"
    if ! AGENT_REQ_ID="${req}" AGENT_INBOX_ISSUE="${inbox}" inbox_request merger merger "${issue:-0}" "#${pr}: cannot be brought up to date with ${base}" "${body}" >/dev/null; then
      rm -f "${body}"
      echo "#${pr}: cannot be brought up to date (${why}), and the inbox request failed; the next run asks again"
      return 1
    fi
    rm -f "${body}"
  fi
  ensure_labels || agent_log "merge: could not ensure labels"
  relabel_pr "${pr}" agent:needs-human "" \
    || { echo "#${pr}: cannot be brought up to date (${why}); asked in the agent inbox, but labelling it agent:needs-human failed"; return 1; }
  body="$(mktemp)"
  printf '<!-- agent-merge-needs-human sha=%s -->\nThe merge gate cannot bring this branch up to date with `%s` (%s), so it needs a person. The request is in the agent inbox.\n' \
    "${sha}" "${base}" "${why}" >"${body}"
  if ! gh issue comment "${pr}" --body-file "${body}" >/dev/null; then
    rm -f "${body}"
    echo "#${pr}: cannot be brought up to date (${why}); asked in the agent inbox and labelled agent:needs-human, but the PR comment failed"
    return 1
  fi
  rm -f "${body}"
  echo "#${pr}: behind ${base} by ${n} commits, and it cannot be brought up to date (${why}): asked in the agent inbox and labelled agent:needs-human"
}

# merge_one <pr> <sha>: the merge, pinned to the head the gate checked, then the issue and ledger.
merge_one() {
  local pr="$1" sha="$2" json issue row
  json="$(gh pr view "${pr}" --json "${MERGE_PR_FIELDS}")" || return 1
  # From the outbox's footer, never the first Refs #N in text the model wrote.
  issue="$(pr_issue "${json}")"
  gh pr merge "${pr}" --merge --match-head-commit "${sha}" --delete-branch >/dev/null \
    || { agent_log "merge: gh pr merge #${pr} failed"; return 1; }
  if [[ -n "${issue}" ]]; then mark_merged "${issue}" "${pr}" || agent_log "merge: could not move #${issue} on"; fi
  row="$(jq -cn --arg run "${RUN_ID:-local}" --arg url "${RUN_URL:-}" --arg trigger "${TRIGGER:-}" \
    --argjson pr "${pr}" --arg issue "${issue}" --arg sha "${sha}" --arg now "$(agent_iso)" '
      {v: 1, run_id: $run, run_url: $url, role: "merger", trigger: $trigger,
       issue: (if $issue == "" then null else ($issue | tonumber) end), pr: $pr, head: $sha,
       outcome: "merged", reason: "", started_at: $now, ended_at: $now}')"
  bash "${SCRIPT_DIR}/agent-ledger.sh" append "${row}" >/dev/null || agent_log "merge: ledger append failed"
}

cmd_run() {
  local want="${1:-}" prs pr verdict rc=0 live=0 report sha n rest
  [[ "${AGENT_AUTO_MERGE:-}" == true ]] && live=1
  if [[ -n "${want}" ]]; then
    [[ "${want}" =~ ^[0-9]+$ ]] || { agent_log "merge: not a PR number: ${want}"; return 2; }
    prs="${want}"
  else
    prs="$(gh pr list --state open --label agent:pr --limit 100 --json number --jq '.[].number')" \
      || { agent_log "merge: could not list agent PRs"; return 1; }
  fi
  report="$(mktemp)"
  while IFS= read -r pr; do
    [[ -n "${pr}" ]] || continue
    verdict="$(gate_one "${pr}")"
    case "${verdict}" in
      merge\ *)
        if [[ "${live}" == 1 ]]; then
          if merge_one "${pr}" "${verdict#merge }"; then echo "#${pr}: merged ${verdict#merge }"; else echo "#${pr}: the merge failed"; rc=1; fi
        else
          echo "#${pr}: would merge ${verdict#merge } (dry run: AGENT_AUTO_MERGE is not true)"
        fi
        ;;
      update\ *)
        read -r _ sha n <<<"${verdict}"
        if [[ "${live}" == 1 ]]; then
          update_one "${pr}" "${sha}" "${n}" || rc=1
        else
          echo "#${pr}: would update the branch (behind $(policy '.baseBranch') by ${n}) (dry run: AGENT_AUTO_MERGE is not true)"
        fi
        ;;
      review\ *)
        rest="${verdict#review }"
        sha="${rest%% *}"
        if [[ "${live}" == 1 ]]; then
          echo "#${pr}: ${rest#* }"
          request_review "${pr}" "${sha}" "The required checks pass on ${sha:0:9}, the head the merge gate's branch update made" again || rc=1
        else
          echo "#${pr}: ${rest#* }; would request a review of ${sha:0:9} (dry run: AGENT_AUTO_MERGE is not true)"
        fi
        ;;
      conflict\ *)
        read -r _ sha n <<<"${verdict}"
        if [[ "${live}" == 1 ]]; then
          ask_person_update "${pr}" "${sha}" "${n}" "it conflicts with $(policy '.baseBranch') after the gate's own update" || rc=1
        else
          echo "#${pr}: behind $(policy '.baseBranch') by ${n} and conflicting after the gate's own update: would ask a person (dry run: AGENT_AUTO_MERGE is not true)"
        fi
        ;;
      *) echo "#${pr}: ${verdict}" ;;
    esac
  done <<<"${prs}" >"${report}"
  cat "${report}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -s "${report}" ]]; then
    { printf '### Agent merge gate%s\n\n' "$([[ "${live}" == 1 ]] || echo ' (dry run)')"; awk '{ print "- " $0 }' "${report}"; } >>"${GITHUB_STEP_SUMMARY}"
  fi
  rm -f "${report}"
  return "${rc}"
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    *) agent_log "usage: agent-merge.sh run [<pr>]"; return 2 ;;
  esac
}

if [[ "${AGENT_MERGE_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
