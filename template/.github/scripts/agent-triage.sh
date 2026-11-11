#!/usr/bin/env bash
# .github/scripts/agent-triage.sh
# Triage (.github/workflows/agent-triage.yml): queues Claude Security findings for the coder, without
# a model. Only an open issue that is a Claude Security import is looked at: label `security`, a
# body that starts `> Imported from Claude Security`, a `| **Severity** | X |` row and a
# `## Recommendation` section (the import's own shape, .github/agents/README.md).
#
#   its author lacks write access   left alone (triage vouches for nobody else's text)
#   a merged PR already names it    one `fixed-on-main` comment and no label: it is probably fixed
#                                   and waiting for the owner's prod check (an issue was once
#                                   picked after a merged PR had fixed it)
#   Low or Medium                   agent:ready + size: S, the fast track
#   High or Critical                agent:candidate: a person decides
#
# Never twice: the bot's `<!-- agent-triage:<verdict> -->` comment marks an issue as done, and an issue
# with any agent:* label is a person's or another agent's already. To keep a fast-tracked issue
# away for good, add agent:hold: the marker stays, so a later agent:ready is trusted again.
#
# TRUST. Triage applies agent:ready as the BOT, and the coder's pick trusts only a person's label,
# except here: agent-state.sh triage_fast_tracked takes an issue carrying the bot's fast-track
# comment when its author has write access and nobody without it changed the issue since it was
# opened, which it checks for itself.
#
# Usage: agent-triage.sh run [<issue>]    every open `security` issue, or the one named
# Env:   GH_TOKEN, GH_REPO; AGENT_TRIAGE_NO_MAIN=1 loads the functions only
#        (Gatehand's tests/workflows/agents-triage.test.sh).
#
# Backticks in the single-quoted printf formats are literal markdown.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # read by the sourced agent-state.sh
AGENT_STATE_NO_MAIN=1
# agent-state.sh brings agent-lib.sh (merged_prs_referencing, actor_trusted), relabel and labels.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-state.sh"
unset AGENT_STATE_NO_MAIN

TRIAGE_FIELDS='number,state,title,body,labels,author'

# security_severity <issue-json>: low|medium|high|critical for a Claude Security import, else
# nothing. Pure. jq's `^` and `$` match only at the ends of the whole body, hence the explicit
# line anchors.
security_severity() {
  jq -r '
    (.body // "") as $b
    | if ([.labels[]?.name] | index("security")) == null then empty
      elif ($b | test("^> Imported from Claude Security") | not) then empty
      elif ($b | test("(^|\n)## Recommendation[ \t]*(\r?\n|$)") | not) then empty
      else ([$b | capture("(^|\n)\\| \\*\\*Severity\\*\\* \\| *(?<s>[A-Za-z]+) *\\|").s][0] // "" | ascii_downcase)
           | select(IN("low", "medium", "high", "critical"))
      end' <<<"$1"
}

# triage_marker <issue>: the verdict of the bot's newest triage comment on it, or nothing.
triage_marker() {
  local bodies
  bodies="$(gh api --paginate "repos/${GH_REPO}/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$(policy '.botLogin')\") | .body")" || return 1
  # No marker is not an error: `|| true`, or pipefail would read it as an unreadable thread.
  { grep -oE '<!-- agent-triage:[a-z-]+ -->' <<<"${bodies}" || true; } | tail -1 | sed -E 's/<!-- agent-triage:([a-z-]+) -->/\1/'
}

# triage_comment <issue> <file>: posts it; exit 1 when that failed.
triage_comment() { gh issue comment "$1" --body-file "$2" >/dev/null; }

# triage_one <issue-json>: prints what it did, one line.
triage_one() {
  local json="$1" n sev author merged done_ body rc=0
  n="$(jq -r .number <<<"${json}")"
  [[ "$(jq -r .state <<<"${json}")" == OPEN ]] || { echo "#${n}: not open"; return 0; }
  if jq -e '[.labels[]?.name | select(startswith("agent:"))] | length > 0' <<<"${json}" >/dev/null; then
    echo "#${n}: already has an agent label"
    return 0
  fi
  sev="$(security_severity "${json}")"
  if [[ -z "${sev}" ]]; then echo "#${n}: not a Claude Security import"; return 0; fi
  author="$(jq -r '.author.login // ""' <<<"${json}")"
  if is_agent_bot "${author}" || ! actor_trusted "${author}"; then
    echo "#${n}: its author (${author}) has no write access; left alone"
    return 0
  fi
  done_="$(triage_marker "${n}")" || { echo "#${n}: comments unreadable"; return 1; }
  if [[ -n "${done_}" ]]; then echo "#${n}: triaged before (${done_})"; return 0; fi
  merged="$(merged_prs_referencing "${n}")" || { echo "#${n}: timeline unreadable"; return 1; }
  body="$(mktemp)"
  if [[ -n "${merged}" ]]; then
    # Not "add agent:ready": the scheduled pick skips any issue a merged PR names, so the label alone
    # would never start it. A dispatch that names the issue skips that check.
    printf '<!-- agent-triage:fixed-on-main -->\nMerged %s already names this finding, so triage did not queue it: it is probably fixed and waiting for a prod check. If it is not fixed, start the coder on it by name (the scheduled pick skips an issue a merged PR names, so `agent:ready` alone would never start it):\n\n```bash\ngh workflow run agent-coder.yml --repo %s --ref agent-runner -f issue=%s\n```\n' \
      "$(awk '{ printf "%s#%s", (NR > 1 ? ", " : ""), $0 }' <<<"${merged}")" "${GH_REPO}" "${n}" >"${body}"
    if triage_comment "${n}" "${body}"; then echo "#${n}: fixed on main ($(paste -sd' ' - <<<"${merged}"))"; else echo "#${n}: comment failed"; rc=1; fi
    rm -f "${body}"
    return "${rc}"
  fi
  ensure_labels || { rm -f "${body}"; echo "#${n}: could not ensure labels"; return 1; }
  case "${sev}" in
    low | medium)
      # Label, then the marker; if the marker does not post, the label comes off again, or the next
      # run would skip the issue for its agent label while the coder never trusts it without the
      # marker. (Marker first would fail the same way the other round: triage skips a marked issue.)
      relabel "${n}" "agent:ready,size: S" "" || { rm -f "${body}"; echo "#${n}: relabel failed"; return 1; }
      printf '<!-- agent-triage:fast-track -->\nA %s-severity Claude Security finding by a writer: queued for the coder agent (`agent:ready`, `size: S`). To keep it away from the agents, add `agent:hold` (removing `agent:ready` lasts only until someone adds it back).\n' "${sev}" >"${body}"
      if triage_comment "${n}" "${body}"; then
        echo "#${n}: ${sev} -> agent:ready"
      else
        relabel "${n}" "" "agent:ready,size: S" || agent_log "triage: could not take the labels off #${n} again"
        echo "#${n}: comment failed; labels taken off again, so the next run retries"
        rc=1
      fi
      ;;
    *)
      relabel "${n}" agent:candidate "" || { rm -f "${body}"; echo "#${n}: relabel failed"; return 1; }
      printf '<!-- agent-triage:candidate -->\nA %s-severity Claude Security finding: marked `agent:candidate`. A person decides whether an agent takes it: add `agent:ready`.\n' "${sev}" >"${body}"
      if triage_comment "${n}" "${body}"; then
        echo "#${n}: ${sev} -> agent:candidate"
      else
        relabel "${n}" "" agent:candidate || agent_log "triage: could not take agent:candidate off #${n} again"
        echo "#${n}: comment failed; label taken off again, so the next run retries"
        rc=1
      fi
      ;;
  esac
  rm -f "${body}"
  return "${rc}"
}

cmd_run() {
  local want="${1:-}" issues line rc=0
  if [[ -n "${want}" ]]; then
    [[ "${want}" =~ ^[0-9]+$ ]] || { agent_log "triage: not an issue number: ${want}"; return 2; }
    issues="$(gh issue view "${want}" --json "${TRIAGE_FIELDS}" --jq 'tojson')" || { agent_log "triage: #${want} unreadable"; return 1; }
  else
    issues="$(gh issue list --state open --label security --limit 300 --json "${TRIAGE_FIELDS}" --jq '.[] | tojson')" \
      || { agent_log "triage: could not list security issues"; return 1; }
  fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    triage_one "${line}" || rc=1
  done <<<"${issues}"
  return "${rc}"
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    *) agent_log "usage: agent-triage.sh run [<issue>]"; return 2 ;;
  esac
}

if [[ "${AGENT_TRIAGE_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
