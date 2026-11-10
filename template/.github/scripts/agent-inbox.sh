#!/usr/bin/env bash
# .github/scripts/agent-inbox.sh
# Applies the owner's answers in the agent inbox: the one place where everything that needs a
# person lands (an issue carrying `<!-- agent-inbox -->`), and the one way to answer (a comment).
#
# Commands, one per line. The comment must START with a command (agent-inbox.yml skips any other);
# further command lines may follow anywhere in it:
#   /approve REQ-YYYYMMDD-xxxx           do what that request proposes
#   /reject  REQ-YYYYMMDD-xxxx [reason]  leave things as they are; the reason is posted on the issue
#   /rerun coder #N                      put #N back in the queue and start the coder on it
#   /pause <role> | /resume <role>       trip or reset a role's circuit breaker (coder, fixer)
#
# WHO MAY ANSWER is decided by the workflow before this runs (the comment author must equal the
# AGENT_OWNER_LOGIN repo variable), and checked again here. A login, not author_association: on this
# org-owned repo the owner's comments carry MEMBER, the same as any other org member's.
#
# What /approve does depends on the request's kind (from its marker, which only the agent bot
# writes; a request comment by anyone else is ignored):
#   protected → #N gets agent:allow-protected (one attempt: finalize removes it when the attempt ends)
#               + agent:ready, and the coder is dispatched on it
#   blocked   → #N gets agent:ready and the coder is dispatched on it, nothing more; granting
#               protected paths for a question the agent asked is a separate, explicit label
#   failed    → the same as blocked
#   breaker   → the role's circuit breaker is reset
#   untrusted → recorded as acknowledged, and nothing else: an inbox answer cannot vouch for issue
#               text a non-writer changed. The reply says to re-apply agent:ready on the issue,
#               which re-anchors trust on a person, then /rerun it
#   fixer     → recorded as seen, and nothing else: the fixer stopped on a PR (a cap, a question),
#               and what is left is a person's change on that PR or closing it
#   merger    → the same: GitHub refused to bring the PR up to date with main (workflow files the
#               App may not push, or a conflict), and a person merges main into it
#   review    → the same: every Claude review requested for the PR's head ended without posting
#               one (agent-state.sh request_review), and a person gets one to run
#   <other>   → (a kind of lowercase letters only, which is what the request marker carries)
#               agent_hook_inbox_<kind> from .github/agents/hooks/lib.sh, when the repo defines one:
#               called as `agent_hook_inbox_<kind> approve|reject <REQ-id> <issue> <reason> <bot-comments>`,
#               it does the work and prints the reply line; exit 0 records the request as answered.
#               This is how a repo's own workflows put requests in the same inbox.
# Nothing is recorded as answered unless every step of it succeeded, so a failed dispatch can be
# retried with the same command.
#
# Usage: agent-inbox.sh apply
# Env:   COMMENT_BODY, COMMENT_ID, COMMENT_AUTHOR, INBOX (issue number), AGENT_OWNER_LOGIN, GH_TOKEN,
#        GH_REPO; AGENT_INBOX_NO_MAIN=1 loads the functions only.
#
# Backticks in single-quoted strings below are literal markdown.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-lib.sh"

KNOWN_ROLES_JQ='.roles | keys[]'

# parse_commands: stdin is the comment body; prints one normalised command per line:
#   approve REQ-… | reject REQ-… <reason> | rerun <role> <N> | pause <role> | resume <role> | unknown <line>
parse_commands() {
  local line roles
  roles="$(policy "${KNOWN_ROLES_JQ}" | paste -sd'|' -)"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "${line}" == /* ]] || continue
    if [[ "${line}" =~ ^/approve[[:space:]]+(REQ-[0-9]{8}-[0-9a-f]{4})[[:space:]]*$ ]]; then
      printf 'approve %s\n' "${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^/reject[[:space:]]+(REQ-[0-9]{8}-[0-9a-f]{4})([[:space:]]+(.*))?$ ]]; then
      printf 'reject %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    elif [[ "${line}" =~ ^/rerun[[:space:]]+(coder)[[:space:]]+#?([0-9]+)[[:space:]]*$ ]]; then
      printf 'rerun %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "${line}" =~ ^/(pause|resume)[[:space:]]+(${roles})[[:space:]]*$ ]]; then
      printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      printf 'unknown %s\n' "${line}"
    fi
  done
}

# bot_comments: the bodies of the agent bot's comments on the inbox issue, captured whole. Matching
# runs on the captured text, never as `gh … | grep -q`: under pipefail an early match kills gh with
# SIGPIPE and the pipeline reads as "no match", which once the inbox is long enough made an answered
# request look unanswered.
bot_comments() {
  gh api --paginate "repos/${GH_REPO}/issues/${INBOX}/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$(policy '.botLogin')\") | .body"
}

# find_request <REQ-id> <bot-comments>: prints "role issue kind" from the request marker, or nothing.
find_request() {
  local m
  m="$(grep -oE "<!-- agent-req:$1 role=[a-z]+ issue=[0-9]+ kind=[a-z]+ -->" <<<"$2")"
  [[ -n "${m}" ]] || return 0
  sed -E 's/.* role=([a-z]+) issue=([0-9]+) kind=([a-z]+) .*/\1 \2 \3/' <<<"${m%%$'\n'*}"
}

# answered <REQ-id> <bot-comments>: exit 0 when an answer marker for it already exists.
# Also true for an id answered earlier in the SAME comment, which is not posted yet.
answered() {
  local e
  grep -Fq "<!-- agent-answer:$1 -->" <<<"$2" && return 0
  for e in "${ANSWERED[@]}"; do [[ "${e%%|*}" == "$1" ]] && return 0; done
  return 1
}

requeue() {  # requeue <issue> <extra-label-or-empty>
  local issue="$1" extra="$2" have args=(--add-label agent:ready) l
  [[ -n "${extra}" ]] && args+=(--add-label "${extra}")
  have="$(gh issue view "${issue}" --json labels --jq '.labels[].name')" || return 1
  for l in agent:blocked agent:needs-human; do
    grep -Fxq -- "${l}" <<<"${have}" && args+=(--remove-label "${l}")
  done
  gh issue edit "${issue}" "${args[@]}" >/dev/null
}

# dispatch <role> <issue>: on the runner ref, never the default branch (agent-state.sh ref_state).
dispatch() {
  gh workflow run "agent-$1.yml" --ref "$(policy '.runnerRef')" -f issue="$2" >/dev/null
}

# builtin_kind <kind>: the request kinds this script handles itself; a repo hook never overrides them.
builtin_kind() { case "$1" in protected | blocked | failed | breaker | untrusted | fixer | merger | review) return 0 ;; esac; return 1; }

# apply_one <command line> <bot-comments>: prints one result line for the reply.
apply_one() {
  local verb arg1 arg2 req role issue kind found note have ok=1
  read -r verb arg1 arg2 <<<"$1"
  case "${verb}" in
    approve | reject)
      req="${arg1}"
      found="$(find_request "${req}" "$2")"
      if [[ -z "${found}" ]]; then printf -- '- `%s`: no request by the agent has that id\n' "${req}"; return; fi
      if answered "${req}" "$2"; then printf -- '- `%s`: already answered\n' "${req}"; return; fi
      read -r role issue kind <<<"${found}"
      if [[ "${verb}" == reject ]]; then
        # A breaker request has no issue to tell; a fixer, merger or review request is about the PR,
        # not the issue (which stays agent:pr-open), so a reject only records that it was seen.
        if ! builtin_kind "${kind}" && declare -F "agent_hook_inbox_${kind}" >/dev/null; then
          if "agent_hook_inbox_${kind}" reject "${req}" "${issue}" "$(printf '%s' "${arg2}" | agent_oneline 300)" "$2" </dev/null; then
            mark_answered "${req}" "rejected"
          else
            printf -- '- `%s`: rejecting failed part way; nothing recorded, send it again\n' "${req}"
          fi
          return
        elif [[ "${kind}" != breaker && "${kind}" != fixer && "${kind}" != merger && "${kind}" != review ]]; then
          note="$(mktemp)"
          printf 'The owner rejected %s in the agent inbox%s It stays blocked.\n' "${req}" \
            "$([[ -n "${arg2}" ]] && printf ': %s.' "$(printf '%s' "${arg2}" | agent_oneline 300)" || printf '.')" >"${note}"
          gh issue comment "${issue}" --body-file "${note}" >/dev/null || ok=0
          rm -f "${note}"
          have="$(gh issue view "${issue}" --json labels --jq '.labels[].name')" || ok=0
          if grep -Fxq agent:needs-human <<<"${have}"; then
            gh issue edit "${issue}" --remove-label agent:needs-human >/dev/null || ok=0
          fi
        fi
        if [[ "${ok}" == 1 ]]; then
          mark_answered "${req}" "rejected"
          printf -- '- `%s` rejected; #%s stays as it is\n' "${req}" "${issue}"
        else
          printf -- '- `%s`: rejecting failed part way; nothing recorded, send it again\n' "${req}"
        fi
        return
      fi
      case "${kind}" in
        protected)
          if requeue "${issue}" agent:allow-protected && dispatch "${role}" "${issue}"; then
            mark_answered "${req}" "approved"
            printf -- '- `%s` approved: #%s may touch protected paths for one attempt, and the %s was started\n' "${req}" "${issue}" "${role}"
          else ok=0; fi
          ;;
        blocked | failed)
          if requeue "${issue}" "" && dispatch "${role}" "${issue}"; then
            mark_answered "${req}" "approved"
            printf -- '- `%s` approved: #%s is queued and the %s was started\n' "${req}" "${issue}" "${role}"
          else ok=0; fi
          ;;
        breaker)
          if bash "${SCRIPT_DIR}/agent-ledger.sh" breaker-reset "${role}" >/dev/null; then
            mark_answered "${req}" "approved"
            printf -- '- `%s` approved: the %s circuit breaker is reset\n' "${req}" "${role}"
          else ok=0; fi
          ;;
        fixer)
          mark_answered "${req}" "seen"
          printf -- '- `%s` seen; nothing changed. Fix the PR yourself and remove `agent:blocked` and `agent:needs-human` from it, or close it\n' "${req}"
          return
          ;;
        merger)
          mark_answered "${req}" "seen"
          printf -- '- `%s` seen; nothing changed. Merge `main` into the PR'"'"'s branch yourself and remove `agent:needs-human` from it, or close it. When that merge is the only new commit, the merge gate asks for the fresh review itself; otherwise run `gh workflow run "Claude Code Review" -f pr=<PR>`\n' "${req}"
          return
          ;;
        review)
          mark_answered "${req}" "seen"
          printf -- '- `%s` seen; nothing changed. Once the review can run, ask for it yourself: `gh workflow run "Claude Code Review" -f pr=<PR>`; or close the PR\n' "${req}"
          return
          ;;
        untrusted)
          mark_answered "${req}" "acknowledged"
          printf -- '- `%s` acknowledged; nothing changed on #%s. An answer here cannot vouch for issue text: re-apply `agent:ready` yourself, then `/rerun coder #%s`\n' "${req}" "${issue}" "${issue}"
          return
          ;;
        *)
          if ! declare -F "agent_hook_inbox_${kind}" >/dev/null; then
            printf -- '- `%s`: unknown request kind %s\n' "${req}" "${kind}"
            return
          fi
          if "agent_hook_inbox_${kind}" approve "${req}" "${issue}" "" "$2" </dev/null; then
            mark_answered "${req}" "approved"
          else ok=0; fi
          ;;
      esac
      [[ "${ok}" == 1 ]] || printf -- '- `%s`: applying it failed part way (see the run); nothing recorded, send it again\n' "${req}"
      ;;
    rerun)
      role="${arg1}" issue="${arg2}"
      if requeue "${issue}" "" && dispatch "${role}" "${issue}"; then
        printf -- '- #%s is queued and the %s was started\n' "${issue}" "${role}"
      else
        printf -- '- re-running #%s failed (see the run)\n' "${issue}"
      fi
      ;;
    pause)
      if bash "${SCRIPT_DIR}/agent-ledger.sh" breaker-trip "${arg1}" "paused by the owner" >/dev/null; then
        printf -- '- the %s is paused (`/resume %s` restarts it)\n' "${arg1}" "${arg1}"
      else
        printf -- '- pausing the %s failed (see the run)\n' "${arg1}"
      fi
      ;;
    resume)
      if bash "${SCRIPT_DIR}/agent-ledger.sh" breaker-reset "${arg1}" >/dev/null; then
        printf -- '- the %s is resumed and its circuit breaker reset\n' "${arg1}"
      else
        printf -- '- resuming the %s failed (see the run)\n' "${arg1}"
      fi
      ;;
    unknown)
      printf -- '- not understood: `%s`\n' "$(printf '%s' "${arg1} ${arg2}" | tr -d '`' | agent_oneline 120)"
      ;;
  esac
}

ANSWERED=()
mark_answered() { ANSWERED+=("$1|$2"); }

cmd_apply() {
  local cmds line reply entry req note comments
  [[ -n "${AGENT_OWNER_LOGIN:-}" && "${COMMENT_AUTHOR:-}" == "${AGENT_OWNER_LOGIN}" ]] \
    || { agent_log "comment author is not AGENT_OWNER_LOGIN; nothing applied"; return 0; }
  cmds="$(printf '%s\n' "${COMMENT_BODY:-}" | parse_commands)"
  [[ -n "${cmds}" ]] || { agent_log "no commands in the comment"; return 0; }
  reply="$(mktemp)"
  comments="$(bot_comments)" || { agent_log "could not read the inbox comments"; comments=""; }
  while IFS= read -r line; do
    apply_one "${line}" "${comments}" >>"${reply}"
  done <<<"${cmds}"
  for entry in "${ANSWERED[@]}"; do
    IFS='|' read -r req note <<<"${entry}"
    printf '<!-- agent-answer:%s -->\n' "${req}" >>"${reply}"
    inbox_tick_line "${INBOX}" "${req}" "${note}" || agent_log "could not tick ${req} in the inbox list"
  done
  gh issue comment "${INBOX}" --body-file "${reply}" >/dev/null
  if [[ -n "${COMMENT_ID:-}" ]]; then
    gh api -X POST "repos/${GH_REPO}/issues/comments/${COMMENT_ID}/reactions" -f content='+1' >/dev/null \
      || agent_log "could not react to the command"
  fi
  rm -f "${reply}"
}

main() {
  case "${1:-}" in
    apply) cmd_apply ;;
    *) agent_log "usage: agent-inbox.sh apply"; return 2 ;;
  esac
}

if [[ "${AGENT_INBOX_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
