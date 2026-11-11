#!/usr/bin/env bash
# .github/scripts/agent-digest.sh
# The weekly digest: one comment on the agent inbox issue saying what the agents did in the last
# seven days and what waits for the owner. No model runs here: every number comes from the ledger
# branch and the GitHub API, and the only write is that one comment.
#
#   agent-digest.sh render   the digest on stdout, without its marker line and unsanitised
#   agent-digest.sh run      render it, then post it on the inbox, or edit this week's digest in place
#
# Sections, in agenda order. One that cannot be read says so where it would be, the rest still
# render, and `run` posts what it has and then exits 1:
#   Waiting for you   unticked inbox requests, stopped roles (a tripped breaker or `/pause`), blocked
#                     and `agent:candidate` issues, and `agent:done-pending-deploy` issues (to close
#                     once the fix is live)
#   Agent PRs         the agent bot's PRs opened, merged or closed in the window, and those open now:
#                     CI on the first push, the first Claude review's verdict, fix runs
#   Agent runs        the window's ledger rows per role: runs, outcomes, turns, time, cost
#   Queue             open `agent:ready` issues by priority
#   (repo sections)   whatever agent_hook_digest_sections prints, when .github/agents/hooks/lib.sh
#                     defines it: markdown with `### ` headings; exit 1 when part of it was unreadable
#
# Titles, inbox lines and the repo sections go through agent_sanitize, so nothing in them can ping anyone or forge a marker. The marker
# `<!-- agent-digest week=YYYY-Www -->` is added after that, as the first line, and the run edits
# only a github-actions comment whose FIRST line is this week's marker.
#
# Env: GH_TOKEN, GH_REPO; AGENT_INBOX_ISSUE, AGENT_OWNER_LOGIN (finding the inbox); AGENTS_ENABLED,
#      AGENT_AUTO_MERGE (the first line); AGENT_NOW_EPOCH (tests);
#      AGENT_DIGEST_NO_MAIN=1 loads the functions only (Gatehand's tests/workflows/agents-digest.test.sh).
#
# Backticks in the single-quoted printf formats are literal markdown, never meant to expand.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# agent-state.sh brings agent-lib.sh (policy, agent_sanitize, agent_cap, inbox_find) and the ledger
# and review readers the gate uses, so the digest reads both the same way the agents do.
# shellcheck disable=SC2034 # read by the sourced agent-state.sh
AGENT_STATE_NO_MAIN=1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-state.sh"
unset AGENT_STATE_NO_MAIN

MAX_DIGEST_BYTES=60000

NOW="$(agent_now_epoch)"
SINCE_EPOCH=$((NOW - 7 * 86400))
SINCE="$(agent_iso "${SINCE_EPOCH}")"
week_of() { jq -rn --argjson e "$1" '$e | strftime("%G-W%V")'; }
WEEK="$(week_of "${NOW}")"

# gh_or_404 <gh api args…>: the response; nothing on a 404 (a branch or file that does not exist
# yet); exit 1 on any other failure, so "unreadable" never renders as "empty".
gh_or_404() {
  local err out rc
  err="$(mktemp)"
  out="$(gh api "$@" 2>"${err}")"
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if grep -q 'HTTP 404' "${err}"; then rm -f "${err}"; return 0; fi
    agent_log "digest: gh api $*: $(head -c 300 "${err}")"
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  printf '%s\n' "${out}"
}

# human_dur <seconds>: "45 min", "3 h 16 min", "2 d 4 h".
human_dur() {
  local s="$1"
  if ((s < 3600)); then
    printf '%d min' $(((s + 30) / 60))
  elif ((s < 86400)); then
    printf '%d h %d min' $((s / 3600)) $(((s % 3600) / 60))
  else
    printf '%d d %d h' $((s / 86400)) $(((s % 86400) / 3600))
  fi
}

epoch_of() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }

# A title in a table cell: one line, no `|`, no HTML (`<` is escaped, so nothing can hide or fake a
# part of the comment), at most 90 characters.
JQ_CELL='def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|") | gsub("<"; "&lt;") | if length > 90 then .[0:89] + "…" else . end;'

# --- what every section reads ------------------------------------------------------------------------

# load: the ledger (the window's rows, from the months it touches, and the breaker), the open
# issues' labels, and the inbox issue. A part that cannot be read leaves its *_OK at 0.
load() {
  local m part
  LEDGER_OK=1 LEDGER_ROWS="" BREAKER_OK=1 BREAKER="{}"
  for m in $(jq -rn --argjson a "${SINCE_EPOCH}" --argjson b "${NOW}" '[$a, $b] | map(strftime("%Y-%m")) | unique | .[]'); do
    if ! part="$(ledger_file "runs/${m}.jsonl")"; then LEDGER_OK=0; break; fi
    LEDGER_ROWS+="${part}"$'\n'
  done
  # One malformed line costs that line, not the ledger.
  [[ "${LEDGER_OK}" == 1 ]] && LEDGER_ROWS="$(jq -cR --arg s "${SINCE}" 'fromjson? | objects
    | select(((.started_at // .ended_at // "") | tostring) >= $s)' <<<"${LEDGER_ROWS}")"
  if ! part="$(ledger_file state/breaker.json)"; then
    BREAKER_OK=0
  elif [[ -n "${part//[[:space:]]/}" ]]; then
    BREAKER="$(jq -ce 'objects' <<<"${part}" 2>/dev/null)" || { BREAKER_OK=0; BREAKER="{}"; }
  fi

  ISSUES_OK=1
  ISSUES="$(gh issue list --state open --limit 500 --json number,title,labels \
    --jq '[.[] | {number, title, labels: [.labels[].name]}]')" || { ISSUES_OK=0; ISSUES="[]"; }

  INBOX_OK=1
  INBOX="${INBOX:-}"
  if [[ -z "${INBOX}" ]]; then INBOX="$(inbox_find)" || INBOX_OK=0; fi
  [[ "${INBOX}" =~ ^[0-9]+$ ]] || { INBOX_OK=0; INBOX=""; }
}

# --- sections ----------------------------------------------------------------------------------------

header() {
  local on merge
  [[ "${AGENTS_ENABLED:-}" == true ]] && on="on" || on="**off** (\`AGENTS_ENABLED\` is not \`true\`)"
  [[ "${AGENT_AUTO_MERGE:-}" == true ]] && merge="on" || merge="**off** (\`AGENT_AUTO_MERGE\` is not \`true\`)"
  printf '## Weekly digest: %s to %s\n\n' "${SINCE:0:10}" "$(agent_iso "${NOW}" | cut -c1-10)"
  printf 'The seven days to %s UTC. Agents: %s. Auto-merge: %s. Written by `.github/workflows/agent-digest.yml`, which edits this comment if it runs again this week.\n\n' \
    "$(agent_iso "${NOW}" | cut -c1-16 | tr T ' ')" "${on}" "${merge}"
}

section_waiting() {
  local rc=0 lines=() body l dpd row n title pr
  printf '### Waiting for you\n\n'

  if [[ "${INBOX_OK}" != 1 ]]; then
    lines+=("- Could not find the inbox issue, so its open requests are not listed.")
    rc=1
  elif ! body="$(gh issue view "${INBOX}" --json body --jq '.body')"; then
    lines+=("- Could not read the inbox issue #${INBOX}, so its open requests are not listed.")
    rc=1
  else
    while IFS= read -r l; do
      # The summary carries the agent's own reason: `<` is escaped, so no HTML in it renders.
      [[ -n "${l}" ]] && lines+=("- Inbox request $(sed -e 's/^- \[ \] //' -e 's/</\&lt;/g' <<<"${l}"): answer it on #${INBOX}.")
    done < <(tr -d '\r' <<<"${body}" | awk '/<!-- agent-inbox:open:start -->/ {on = 1; next}
      /<!-- agent-inbox:open:end -->/ {on = 0} on && /^- \[ \] REQ-/')
  fi

  if [[ "${BREAKER_OK}" != 1 ]]; then
    lines+=("- Could not read the breaker state on the ledger branch, so a stopped role would not show here.")
    rc=1
  else
    while IFS= read -r l; do [[ -n "${l}" ]] && lines+=("${l}"); done < <(jq -r '
      to_entries[] | select((.value | type) == "object" and .value.tripped_at != null)
      | "- The \(.key) is stopped since \(.value.tripped_at | tostring | .[0:16] | sub("T"; " ")) UTC: \(.value.reason // "no reason recorded"). `/resume \(.key)` on the inbox starts it again."' <<<"${BREAKER}")
  fi

  if [[ "${ISSUES_OK}" != 1 ]]; then
    lines+=("- Could not list the open issues, so blocked ones are not listed.")
    rc=1
  else
    while IFS= read -r l; do [[ -n "${l}" ]] && lines+=("${l}"); done < <(jq -r "${JQ_CELL}"'
      .[] | select(.labels | index("agent:blocked") or index("agent:needs-human"))
      | "- #\(.number) \(.title | cell): \([.labels[] | select(. == "agent:blocked" or . == "agent:needs-human")] | join(", "))."' <<<"${ISSUES}")
    # Triage's High and Critical findings, the coder's follow-ups and anything else filed as a
    # candidate: the coder takes only a person's agent:ready, so these wait for you to queue or close.
    l="$(jq -r '[.[] | select(.labels | index("agent:candidate")) | "#\(.number)"]
      | if length == 0 then empty
        else "- \(length) `agent:candidate` issue(s) to queue (add `agent:ready`) or close: \(.[0:10] | join(", "))\(if length > 10 then ", …" else "" end)." end' <<<"${ISSUES}")"
    [[ -n "${l}" ]] && lines+=("${l}")
  fi

  if ! dpd="$(gh issue list --state open --label agent:done-pending-deploy --limit 100 --json number,title,comments)"; then
    lines+=("- Could not list the \`agent:done-pending-deploy\` issues.")
    rc=1
  else
    while IFS= read -r row; do
      [[ -n "${row}" ]] || continue
      n="$(jq -r '.number' <<<"${row}")"
      title="$(jq -r "${JQ_CELL}"' .title | cell' <<<"${row}")"
      # The PR is the one in the agent bot's last `agent-merged` note on the issue.
      pr="$(jq -r --arg b "$(policy '.botLogin')" '($b | rtrimstr("[bot]")) as $s
        | [.comments[] | select(.author.login as $a | $a == $s or $a == "app/\($s)" or $a == "\($s)[bot]")
           | (.body // "") | capture("<!-- agent-merged pr=(?<pr>[0-9]+) -->") | .pr] | last // empty' <<<"${row}")"
      # A repo that knows when a merge is live (a deploy record) says so in its own line:
      # agent_hook_digest_done_pending <issue> <title> <pr or empty> <issue-json>, when
      # .github/agents/hooks/lib.sh defines it; no output, or a failure, keeps the line below.
      l=""
      if declare -F agent_hook_digest_done_pending >/dev/null; then
        l="$(agent_hook_digest_done_pending "${n}" "${title}" "${pr}" "${row}" 2>/dev/null </dev/null)" || l=""
        l="${l%%$'\n'*}"
      fi
      if [[ -n "${l}" ]]; then
        lines+=("${l}")
      elif [[ -z "${pr}" ]]; then
        lines+=("- #${n} ${title}: merged, but with no merge note. Check it is live, then close it.")
      else
        lines+=("- #${n} ${title}: #${pr} is merged. Close it once the fix is live.")
      fi
    done < <(jq -c 'sort_by(.number) | .[]' <<<"${dpd}")
  fi

  if [[ "${#lines[@]}" -eq 0 ]]; then printf 'Nothing.\n\n'; else printf '%s\n' "${lines[@]}"; printf '\n'; fi
  return "${rc}"
}

# first_ci <branch> <pr-created-at>: the conclusion of the first CI run the PR's opening started.
first_ci() {
  local b
  b="$(jq -rn --arg b "$1" '$b | @uri')"
  gh api "repos/${GH_REPO}/actions/workflows/$(policy '.ci.workflowFile // "ci.yml"')/runs?event=pull_request&branch=${b}&per_page=100" \
    --jq "[.workflow_runs[] | select(.created_at >= \"$2\")] | sort_by(.created_at) | .[0] // empty | (.conclusion // .status)"
}

# first_review <pr>: the verdict of the first Claude review (approve, request-changes, unknown), or
# none. Only the review bot's comments count; anyone could paste the marker.
first_review() {
  local bodies
  bodies="$(gh api --paginate "repos/${GH_REPO}/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$(policy '.reviewBotLogin')\" and ((.body // \"\") | contains(\"$(policy '.reviewMarker')\"))) | .body | @json")" || return 1
  if [[ -z "${bodies}" ]]; then echo none; return 0; fi
  jq -r . <<<"${bodies%%$'\n'*}" | review_verdict
}

section_prs() {
  local rc=0 bot list sel row n title state created merged branch now l ci rev fixes opened=0 merged_n=0 closed=0 open=0 pass=0 approve=0 table=()
  printf '### Agent PRs\n\n'
  bot="$(policy '.botLogin')"
  if ! list="$(gh pr list --state all --author "app/${bot%\[bot\]}" --limit 200 \
    --json number,title,state,createdAt,mergedAt,closedAt,headRefName,labels)"; then
    printf 'Could not list the agent PRs.\n\n'
    return 1
  fi
  sel="$(jq -c --arg s "${SINCE}" '[.[] | select(.state == "OPEN" or .createdAt >= $s or (.mergedAt // "") >= $s or (.closedAt // "") >= $s)]
    | sort_by(.number) | .[]' <<<"${list}")" || { printf 'Could not read the agent PR list.\n\n'; return 1; }
  if [[ -z "${sel}" ]]; then printf 'None opened, merged or open in these seven days.\n\n'; return 0; fi

  while IFS= read -r row; do
    n="$(jq -r '.number' <<<"${row}")"
    title="$(jq -r "${JQ_CELL}"' .title | cell' <<<"${row}")"
    state="$(jq -r '.state' <<<"${row}")"
    created="$(jq -r '.createdAt' <<<"${row}")"
    merged="$(jq -r '.mergedAt // ""' <<<"${row}")"
    branch="$(jq -r '.headRefName' <<<"${row}")"
    case "${state}" in
      MERGED)
        now="merged after $(human_dur $(($(epoch_of "${merged}") - $(epoch_of "${created}"))))"
        [[ ! "${merged}" < "${SINCE}" ]] && merged_n=$((merged_n + 1))
        ;;
      CLOSED)
        now="closed unmerged"
        [[ ! "$(jq -r '.closedAt // ""' <<<"${row}")" < "${SINCE}" ]] && closed=$((closed + 1))
        ;;
      *)
        now="open"
        open=$((open + 1))
        l="$(jq -r '[.labels[].name | select(startswith("agent:") and . != "agent:pr")] | join(", ")' <<<"${row}")"
        [[ -n "${l}" ]] && now+=" (${l})"
        ;;
    esac
    if ci="$(first_ci "${branch}" "${created}")"; then
      case "${ci}" in success) ci=passed ;; failure) ci=failed ;; "") ci=none ;; esac
    else
      ci="?"
      rc=1
    fi
    rev="$(first_review "${n}")" || { rev="?"; rc=1; }
    if [[ "${LEDGER_OK}" == 1 ]]; then
      fixes="$(jq -s --argjson p "${n}" '[.[] | select(.role == "fixer" and .pr == $p)] | length' <<<"${LEDGER_ROWS}")"
    else
      fixes="?"
    fi
    if [[ ! "${created}" < "${SINCE}" ]]; then
      opened=$((opened + 1))
      [[ "${ci}" == passed ]] && pass=$((pass + 1))
      [[ "${rev}" == approve ]] && approve=$((approve + 1))
    fi
    table+=("| #${n} ${title} | ${now} | ${ci} | ${rev} | ${fixes} |")
  done <<<"${sel}"

  printf 'Opened %d, merged %d, closed unmerged %d; %d open now.' "${opened}" "${merged_n}" "${closed}" "${open}"
  if [[ "${opened}" -gt 0 ]]; then
    printf ' Of the %d opened, CI passed on the first push for %d and the first Claude review approved %d.' "${opened}" "${pass}" "${approve}"
  fi
  printf '\n\n| PR | Now | CI, first push | First review | Fix runs this week |\n|---|---|---|---|---:|\n'
  printf '%s\n' "${table[@]}"
  printf '\n'
  return "${rc}"
}

section_runs() {
  local win
  printf '### Agent runs\n\n'
  if [[ "${LEDGER_OK}" != 1 ]]; then printf 'Could not read the ledger.\n\n'; return 1; fi
  win="${LEDGER_ROWS}"
  if [[ -z "${win}" ]]; then printf 'No runs in these seven days.\n\n'; return 0; fi
  printf '| Role | Runs | Outcomes | Turns | Time | Cost |\n|---|---:|---|---:|---:|---:|\n'
  jq -rs '
    def total(f): [.[] | f | numbers] | if length == 0 then null else add end;
    def usd: (. * 100 | round) as $c | "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
    group_by(.role)[]
    | ([.[] | select(.counted == false)] | length) as $nc
    | ([group_by(.outcome)[] | {o: (.[0].outcome // "none"), n: length}] | sort_by(-.n, .o) | map("\(.n) \(.o)") | join(", ")
       + (if $nc > 0 then " (\($nc) never reached the agent, not counted)" else "" end)) as $out
    | total(.turns) as $t | total(.duration_ms) as $ms | total(.cost_usd) as $c
    | "| \(.[0].role // "?") | \(length) | \($out) | \($t // "–") | \(if $ms then "\($ms / 60000 | round) min" else "–" end) | \(if $c then ($c | usd) else "–" end) |"' <<<"${win}"
  printf '\n'
}

section_queue() {
  local n per
  printf '### Queue\n\n'
  if [[ "${ISSUES_OK}" != 1 ]]; then printf 'Could not list the open issues.\n\n'; return 1; fi
  n="$(jq '[.[] | select(.labels | index("agent:ready"))] | length' <<<"${ISSUES}")"
  if [[ "${n}" == 0 ]]; then printf 'Nothing is queued for the coder.\n\n'; return 0; fi
  per="$(policy '.roles.coder.runsPerDay')"
  printf '%s issue(s) queued for the coder: %s. At %s coder runs a day, that is about %s day(s).\n\n' "${n}" \
    "$(jq -r '[.[] | select(.labels | index("agent:ready"))
      | ([.labels[] | select(startswith("priority: ")) | ltrimstr("priority: ")][0] // "no priority")]
      | group_by(.) | map({p: .[0], n: length})
      | sort_by({"critical": 0, "high": 1, "medium": 2, "low": 3}[.p] // 4)
      | map("\(.n) \(.p)") | join(", ")' <<<"${ISSUES}")" \
    "${per}" "$(((n + per - 1) / per))"
}

render() {
  local rc=0
  load
  header
  section_waiting || rc=1
  section_prs || rc=1
  section_runs || rc=1
  section_queue || rc=1
  if declare -F agent_hook_digest_sections >/dev/null; then
    agent_hook_digest_sections </dev/null || rc=1
  fi
  return "${rc}"
}

# --- posting -----------------------------------------------------------------------------------------

cmd_run() {
  local rc=0 work marker existing id old
  INBOX="$(inbox_find)" || { agent_log "digest: could not look up the inbox issue"; return 1; }
  if [[ ! "${INBOX}" =~ ^[0-9]+$ ]]; then
    agent_log "digest: no inbox issue (an open issue carrying $(policy '.inboxMarker'), opened by the agent bot or AGENT_OWNER_LOGIN)"
    return 1
  fi
  work="$(mktemp -d)"
  render >"${work}/raw" || rc=1
  marker="<!-- agent-digest week=${WEEK} -->"
  # Cap first, then sanitise (agent-lib.sh): a cut inside a code span must not leave a mention live.
  # No test pins the order: the runs table's `$` already makes the sanitiser rewrite every mention.
  { printf '%s\n' "${marker}"; agent_cap "${MAX_DIGEST_BYTES}" <"${work}/raw" | agent_sanitize; } >"${work}/body"

  # This week's digest, if one is posted: the newest github-actions comment whose first line is the
  # marker. A listing that fails stops here, so a bad read never posts a second digest.
  if ! existing="$(gh api --paginate "repos/${GH_REPO}/issues/${INBOX}/comments?per_page=100" --jq "
      .[] | select((.user.login == \"github-actions[bot]\")
        and (((.body // \"\") | split(\"\n\")[0] | rtrimstr(\"\r\")) == \"${marker}\")) | {id, body} | @json")"; then
    agent_log "digest: could not read the inbox comments; nothing posted"
    rm -rf "${work}"
    return 1
  fi
  existing="$(tail -1 <<<"${existing}")"
  if [[ -n "${existing}" ]]; then
    id="$(jq -r '.id' <<<"${existing}")"
    old="$(jq -r '.body | gsub("\r\n"; "\n")' <<<"${existing}")"
    if [[ "${old}" == "$(cat "${work}/body")" ]]; then
      echo "digest: ${WEEK} on #${INBOX} is up to date"
    elif jq -Rs '{body: .}' <"${work}/body" | gh api -X PATCH "repos/${GH_REPO}/issues/comments/${id}" --input - >/dev/null; then
      echo "digest: ${WEEK} on #${INBOX} updated"
    else
      agent_log "digest: could not edit comment ${id}"
      rc=1
    fi
  elif gh issue comment "${INBOX}" --body-file "${work}/body" >/dev/null; then
    echo "digest: ${WEEK} posted on #${INBOX}"
  else
    agent_log "digest: could not comment on #${INBOX}"
    rc=1
  fi
  rm -rf "${work}"
  [[ "${rc}" == 0 ]] || agent_log "digest: a section could not be read or the comment not written; see above"
  return "${rc}"
}

main() {
  case "${1:-}" in
    render) render ;;
    run) cmd_run ;;
    *) echo "usage: agent-digest.sh render|run" >&2; return 2 ;;
  esac
}

if [[ "${AGENT_DIGEST_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
