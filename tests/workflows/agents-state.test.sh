#!/usr/bin/env bash
# tests/workflows/agents-state.test.sh
# .github/scripts/agent-state.sh: the coder's gate, its choice of issue, and the labels it leaves.
# Pinned, and why:
#   1. The gate stops on the kill switch, a missing bot id, an open breaker, the daily cap and the
#      open-PR cap, and FAILS CLOSED when the ledger cannot be read (an outage must not read as
#      "zero runs today").
#   2. Auto-pick takes the highest priority, then the oldest, and skips held, locked, size: L,
#      over-attempted and acceptance-less issues; only the BOT's lock comments count as attempts.
#      It takes an issue only if a writer applied the latest agent:ready and no non-writer renamed
#      or edited it since; only writers' comments are passed on. A named dispatch skips the rest.
#   (1b) The gate refuses a run on the default branch, and one whose runner-ref workflow is stale.
#   3. Finalize leaves exactly one state: a PR → agent:pr-open; a question or a protected path →
#      agent:blocked + agent:needs-human with an inbox request; a failure with attempts left →
#      back to agent:ready; the last failed attempt → blocked with a request. It never closes.
# AGENT_TRUST_CACHE is reset here and read by the sourced agent-state.sh.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agents-gh-stub.sh"
export AGENT_STATE_NO_MAIN=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-state.sh"
set +e

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-state] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-state] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }
expect_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_pass "$1"; else t_fail "$1: no gh call containing '$2'"; fi; }
expect_no_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_fail "$1: unexpected gh call '$2'"; else t_pass "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export GH_REPO=o/r AGENT_NOW_EPOCH=1793880000 # 2026-11-05T12:00:00Z

# --- 1. gate ---------------------------------------------------------------------------------------
expect "gate: all clear" "$(gate_decide true 123 '' 0 2 0 2 ok)" "go"
expect "gate: dispatched on the default branch" "$(gate_decide true 123 '' 0 2 0 2 default | cut -d' ' -f1)" "no-go:wrong-ref"
expect "gate: the runner ref's workflow is stale" "$(gate_decide true 123 '' 0 2 0 2 stale | cut -d' ' -f1)" "no-go:runner-ref-stale"
stub_gh_init
stub_gh_json 'api repos/o/r/contents/.github/workflows/agent-coder.yml?ref=agent-runner *' '{"sha":"aaa"}'
stub_gh_json 'api repos/o/r/contents/.github/workflows/agent-coder.yml?ref=main *' '{"sha":"aaa"}'
expect "ref: agent-runner with main's workflow is ok" "$(RUN_REF=agent-runner DEFAULT_BRANCH=main ref_state)" ok
expect "ref: main is the default branch" "$(RUN_REF=main DEFAULT_BRANCH=main ref_state)" default
expect "ref: any other branch is refused" "$(RUN_REF=feature DEFAULT_BRANCH=main ref_state)" stale
stub_gh_reset_rules
stub_gh_json 'api repos/o/r/contents/.github/workflows/agent-coder.yml?ref=agent-runner *' '{"sha":"aaa"}'
stub_gh_json 'api repos/o/r/contents/.github/workflows/agent-coder.yml?ref=main *' '{"sha":"bbb"}'
expect "ref: a workflow that differs from main's is stale" "$(RUN_REF=agent-runner DEFAULT_BRANCH=main ref_state)" stale
stub_gh_reset_rules
stub_gh_on 'api repos/o/r/contents/*' '' 1 'gh: HTTP 502'
expect "ref: an API failure is unreadable, not stale" "$(RUN_REF=agent-runner DEFAULT_BRANCH=main ref_state)" unreadable
expect "gate: an unreadable ref stops it" "$(gate_decide true 123 '' 0 2 0 2 unreadable | cut -d' ' -f1)" "no-go:ref-unreadable"
expect "gate: kill switch" "$(gate_decide false 123 '' 0 2 0 2 | cut -d' ' -f1)" "no-go:disabled"
expect "gate: unset kill switch" "$(gate_decide '' 123 '' 0 2 0 2 | cut -d' ' -f1)" "no-go:disabled"
expect "gate: bot id missing" "$(gate_decide true '' '' 0 2 0 2 | cut -d' ' -f1)" "no-go:misconfigured"
expect "gate: breaker open" "$(gate_decide true 123 2026-11-05T00:00:00Z 0 2 0 2 | cut -d' ' -f1)" "no-go:breaker-open"
expect "gate: daily cap" "$(gate_decide true 123 '' 2 2 0 2 | cut -d' ' -f1)" "no-go:daily-cap"
expect "gate: open-PR cap" "$(gate_decide true 123 '' 0 2 2 2 | cut -d' ' -f1)" "no-go:open-pr-limit"

# stub_gh_on rules for the ref check, added to every gate case below
ref_ok() {
  stub_gh_json 'api repos/o/r/contents/.github/workflows/agent-coder.yml?ref=*' '{"sha":"aaa"}'
  stub_gh_json 'pr list *' '[]'
}
run_gate() { : >"${TMP}/out"; GITHUB_OUTPUT="${TMP}/out" AGENTS_ENABLED=true AGENT_BOT_ID=123 RUN_REF=agent-runner DEFAULT_BRANCH=main cmd_gate coder >/dev/null 2>&1; }
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/state/breaker.json*' '' 1 'gh: Not Found (HTTP 404)'
stub_gh_on 'api * repos/o/r/contents/runs/2026-11.jsonl*' \
  "$(printf '%s\n%s\n' '{"role":"coder","started_at":"2026-11-05T08:00:00Z"}' '{"role":"coder","started_at":"2026-11-04T08:00:00Z"}')"
ref_ok
run_gate
expect "gate end to end: a missing ledger and one run today is a go" "$(grep '^go=' "${TMP}/out")" "go=true"
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/state/breaker.json*' '{"coder":{"tripped_at":"2026-11-05T09:00:00Z"}}'
stub_gh_on 'api * repos/o/r/contents/runs/*' '' 1 'gh: Not Found (HTTP 404)'
ref_ok
run_gate
expect "gate end to end: a tripped breaker stops it" "$(grep '^go=' "${TMP}/out")" "go=false"
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/*' '' 1 'gh: HTTP 502: Bad Gateway'
run_gate
expect "gate end to end: an unreadable ledger fails closed" "$(grep '^reason=' "${TMP}/out")" "reason=ledger-unreadable"
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/state/*' '' 1 'gh: Not Found (HTTP 404)'
# The cap is policy.json's, so raising it there does not leave this test behind.
coder_cap="$(jq -r '.roles.coder.runsPerDay' "${REPO_ROOT}/.github/agents/policy.json")"
runs_today() { local i; for ((i = 0; i < $1; i++)); do printf '{"role":"coder","started_at":"2026-11-05T%02d:00:00Z"}\n' "$((i % 24))"; done; }
stub_gh_on 'api * repos/o/r/contents/runs/*' "$(runs_today "$((coder_cap - 1))")"
ref_ok
run_gate
expect "gate end to end: one run under the cap of ${coder_cap} is a go" "$(grep '^go=' "${TMP}/out")" "go=true"
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/state/*' '' 1 'gh: Not Found (HTTP 404)'
stub_gh_on 'api * repos/o/r/contents/runs/*' "$(runs_today "${coder_cap}")"
ref_ok
run_gate
expect "gate end to end: ${coder_cap} runs today hits the cap of ${coder_cap}" "$(grep '^reason=' "${TMP}/out" | cut -d' ' -f1)" "reason=daily-cap"
stub_gh_reset_rules
stub_gh_on 'api * repos/o/r/contents/state/*' '' 1 'gh: Not Found (HTTP 404)'
stub_gh_on 'api * repos/o/r/contents/runs/*' \
  "$(printf '%s\n%s\n%s\n%s\n' '{"role":"coder","started_at":"2026-11-05T08:00:00Z"}' '{"role":"coder","started_at":"2026-11-05T09:00:00Z"}' '{"role":"coder","started_at":"2026-11-05T10:00:00Z","counted":false}' '{"role":"coder","started_at":"2026-11-05T11:00:00Z"}')"
ref_ok
run_gate
expect "gate end to end: a run that never reached the model is not a run for the cap" "$(grep '^go=' "${TMP}/out")" "go=true"

# --- 2. pick ---------------------------------------------------------------------------------------
issue() { # issue <n> <created> <labels-csv> <body> [locks]
  local labels
  labels="$(jq -cn --arg l "$3" '$l | split(",") | map(select(. != "") | {name: .})')"
  jq -cn --argjson n "$1" --arg c "$2" --argjson labels "${labels}" --arg b "$4" --argjson k "${5:-0}" \
    '{number: $n, state: "OPEN", createdAt: $c, labels: $labels, body: $b,
      comments: ([range(0; $k) | {author: {login: "gatehand"}, body: "<!-- agent:lock role=coder run=1 attempt=1 expires=x -->"}]
        + [{author: {login: "outsider"}, body: "<!-- agent:lock role=coder run=9 attempt=9 expires=x -->"},
           {author: {login: "outsider"}, body: "<!-- agent:lock role=coder run=9 attempt=9 expires=x -->"}])}'
}
DONE=$'## What\nx\n\n### Done when\ny'
issues="$(jq -s . <(issue 1 2026-10-01T00:00:00Z 'agent:ready,priority: low' "${DONE}") \
  <(issue 2 2026-11-01T00:00:00Z 'agent:ready,priority: high' "${DONE}") \
  <(issue 3 2026-09-01T00:00:00Z 'agent:ready,priority: critical,agent:hold' "${DONE}") \
  <(issue 4 2026-09-01T00:00:00Z 'agent:ready,priority: critical' 'no acceptance here') \
  <(issue 5 2026-09-01T00:00:00Z 'agent:ready,priority: critical' "${DONE}" 2) \
  <(issue 6 2026-09-01T00:00:00Z 'agent:ready,priority: critical,size: L' "${DONE}") \
  <(issue 7 2026-08-01T00:00:00Z 'agent:ready,priority: high' $'## Recommendation\nz'))"
expect "pick: highest priority, then oldest; skips hold, no acceptance, 2 attempts, size L" \
  "$(pick_auto "${issues}" 2 2>/dev/null)" 7
expect "pick: the skip reasons are logged" "$(pick_auto "${issues}" 2 2>&1 >/dev/null | grep -c '^\[agent\] skip #')" 4
expect "pick: among equal priority the oldest wins" \
  "$(pick_auto "$(jq '[.[] | select(.number != 7)]' <<<"${issues}")" 2 2>/dev/null)" 2
expect "pick: nothing eligible prints nothing" \
  "$(pick_auto "$(jq '[.[] | select(.number == 3 or .number == 4)]' <<<"${issues}")" 2 2>/dev/null)" ""
expect "explicit: a named open issue is fine without acceptance" "$(explicit_ok "$(issue 4 x 'priority: low' 'none')")" ""
expect "explicit: a held issue is refused" "$(explicit_ok "$(issue 4 x 'agent:hold' "${DONE}")")" "held, locked or already has a PR"
expect "explicit: a closed issue is refused" "$(explicit_ok "$(jq '.state = "CLOSED"' <<<"$(issue 4 x '' "${DONE}")")")" "not open"

# The labeler check runs the script's real jq over raw timeline and GraphQL JSON (stub_gh_json).
ev() { jq -cn --arg e "$1" --arg l "$2" --arg a "$3" --arg t "$4" '{event: $e, label: {name: $l}, actor: {login: $a}, created_at: $t}'; }
edits() { # edits "<iso>|<login>" ... -> the GraphQL response; EDITS_TOTAL overrides totalCount
  local e a=() ; for e in "$@"; do a+=("$(jq -cn --arg at "${e%%|*}" --arg ed "${e#*|}" '{editedAt: $at, editor: {login: $ed}}')"); done
  jq -cn --argjson n "$(printf '%s\n' "${a[@]}" | jq -s .)" --argjson t "${EDITS_TOTAL:-null}" \
    '{data: {repository: {issue: {userContentEdits: {totalCount: ($t // ($n | length)), nodes: $n}}}}}'
}
labeler_case() { # labeler_case <timeline-json> <perm-of-everyone-else> [edit…] -> yes/no
  local tl="$1" perm="$2"
  shift 2
  stub_gh_reset_rules
  AGENT_TRUST_CACHE=()
  stub_gh_json 'api --paginate repos/o/r/issues/8/timeline*' "${tl}"
  stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
  stub_gh_json 'api repos/o/r/collaborators/*/permission*' "{\"permission\":\"${perm}\"}"
  if [[ $# -gt 0 ]]; then stub_gh_json 'api graphql *' "$(edits "$@")"; else stub_gh_json 'api graphql *' "$(edits)"; fi
  if [[ -n "${FT_VIEW:-}" ]]; then stub_gh_on 'issue view 8 --json author,createdAt,comments' "${FT_VIEW}"; fi
  if labeler_trusted 8 2>/dev/null; then echo yes; else echo no; fi
}
# ft_view <author> [comment-author] [comment-body]: the issue view triage_fast_tracked reads.
FT_MARK='<!-- agent-triage:fast-track -->
A low-severity Claude Security finding by a writer: queued for the coder agent.'
ft_view() {
  jq -cn --arg a "$1" --arg ca "${2:-app/gatehand}" --arg cb "${3-${FT_MARK}}" \
    '{author: {login: $a}, createdAt: "2026-11-05T08:00:00Z", comments: [{author: {login: $ca}, body: $cb}]}'
}
T0=2026-11-05T10:00:00Z
T1=2026-11-05T11:00:00Z
T2=2026-11-05T12:00:00Z
by() { jq -s . <(ev labeled agent:ready "$1" "${T0}"); }
expect "labeler: a write collaborator is trusted" "$(labeler_case "$(by bob)" write)" yes
expect "labeler: a read-only collaborator is not" "$(labeler_case "$(by outsider)" read)" no
expect "labeler: a triage collaborator is not" "$(labeler_case "$(by outsider)" triage)" no
expect "labeler: no labeled event at all is not" "$(labeler_case '[]' write)" no
expect "labeler: only the bot ever labelled it: not trusted" "$(labeler_case "$(by 'gatehand[bot]')" read)" no
expect "labeler: the LATEST person's agent:ready label counts" \
  "$(labeler_case "$(jq -s . <(ev labeled agent:ready owner-login 2026-11-01T00:00:00Z) <(ev labeled agent:ready outsider "${T0}"))" read)" no
expect "labeler: another label by an untrusted actor does not matter" \
  "$(labeler_case "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev labeled bug outsider "${T1}"))" read)" yes
expect "labeler: a rename by a non-writer after the label is not trusted" \
  "$(labeler_case "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev renamed '' outsider "${T1}"))" read)" no
expect "labeler: the bot's re-label does NOT reset the window over a non-writer's edit" \
  "$(labeler_case "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev renamed '' outsider "${T1}") <(ev labeled agent:ready 'gatehand[bot]' "${T2}"))" read)" no
expect "labeler: a body edit by a non-writer after the label is not trusted" \
  "$(labeler_case "$(by owner-login)" read "${T1}|outsider")" no
expect "labeler: a non-writer's edit hidden behind a writer's later edit is still caught" \
  "$(labeler_case "$(by owner-login)" read "${T1}|outsider" "${T2}|owner-login")" no
expect "labeler: a body edit before the label is fine" \
  "$(labeler_case "$(by owner-login)" read "2026-11-05T09:00:00Z|outsider")" yes
expect "labeler: a body edit by a writer after the label is fine" \
  "$(labeler_case "$(by owner-login)" read "${T1}|owner-login")" yes
expect "labeler: a non-writer's edit in the SAME second as the label counts as after it" \
  "$(labeler_case "$(by owner-login)" read "${T0}|outsider")" no
expect "labeler: a non-writer's rename in the same second as the label counts as after it" \
  "$(labeler_case "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev renamed '' outsider "${T0}"))" read)" no
expect "labeler: more edits than one page holds is not trusted" \
  "$(EDITS_TOTAL=101 labeler_case "$(by owner-login)" read)" no
# Triage's fast track: only the bot labelled it, and its fast-track comment is there.
BOTLABEL="$(jq -s . <(ev labeled agent:ready 'gatehand[bot]' "${T0}"))"
expect "fast track: the bot's label + its triage comment + a writer's own issue is trusted" \
  "$(FT_VIEW="$(ft_view owner-login)" labeler_case "${BOTLABEL}" read)" yes
expect "fast track: the triage comment written by anyone but the bot is not" \
  "$(FT_VIEW="$(ft_view owner-login outsider)" labeler_case "${BOTLABEL}" read)" no
expect "fast track: a bot comment without the fast-track marker is not" \
  "$(FT_VIEW="$(ft_view owner-login app/gatehand 'The coder agent picked this up.')" labeler_case "${BOTLABEL}" read)" no
expect "fast track: the bot's candidate marker is not a fast track" \
  "$(FT_VIEW="$(ft_view owner-login app/gatehand '<!-- agent-triage:candidate -->
A high-severity Claude Security finding: marked agent:candidate.')" labeler_case "${BOTLABEL}" read)" no
expect "fast track: an issue a read-only collaborator opened is not" \
  "$(FT_VIEW="$(ft_view outsider)" labeler_case "${BOTLABEL}" read)" no
expect "fast track: an issue the bot itself opened is not" \
  "$(FT_VIEW="$(ft_view app/gatehand)" labeler_case "${BOTLABEL}" read)" no
expect "fast track: a non-writer's edit since it was opened (even before the label) is not" \
  "$(FT_VIEW="$(ft_view owner-login)" labeler_case "${BOTLABEL}" read "2026-11-05T09:00:00Z|outsider")" no
expect "fast track: a non-writer's rename since it was opened is not" \
  "$(FT_VIEW="$(ft_view owner-login)" labeler_case "$(jq -s . <(ev renamed '' outsider 2026-11-05T09:00:00Z) <(ev labeled agent:ready 'gatehand[bot]' "${T0}"))" read)" no
expect "fast track: a writer's later edit is fine" \
  "$(FT_VIEW="$(ft_view owner-login)" labeler_case "${BOTLABEL}" read "${T1}|owner-login")" yes
# The repo's own rule (agent_hook_labeler_trusted, .github/agents/hooks/lib.sh): asked only when no
# writer's label and no fast track vouches, and its answer stands.
agent_hook_labeler_trusted() { echo "hook asked for $1" >>"${TMP}/hook-calls"; [[ "${HOOK_VOUCH:-}" == yes ]]; }
: >"${TMP}/hook-calls"
expect "labeler hook: no hook answer, only the bot labelled it: not trusted" "$(labeler_case "${BOTLABEL}" read)" no
expect "labeler hook: the hook vouches for an issue only the bot labelled" "$(HOOK_VOUCH=yes labeler_case "${BOTLABEL}" read)" yes
expect "labeler hook: it was asked about that issue" "$(sort -u "${TMP}/hook-calls")" "hook asked for 8"
: >"${TMP}/hook-calls"
expect "labeler hook: a writer's own label never asks it" "$(labeler_case "$(by owner-login)" read)" yes
expect "labeler hook: not asked when a writer's label vouches" "$(cat "${TMP}/hook-calls")" ""
# A person without write access labelled it: the hook is never the way around that, so a bot-filed
# issue (a coder follow-up) cannot be queued by a triage collaborator through a repo's rule.
expect "labeler hook: a non-writer's label is not trusted even if the hook would vouch" \
  "$(HOOK_VOUCH=yes labeler_case "$(by outsider)" triage)" no
expect "labeler hook: ...and it was not asked" "$(cat "${TMP}/hook-calls")" ""
# An unreadable timeline: no answer from the repo's rule either.
stub_gh_reset_rules
AGENT_TRUST_CACHE=()
stub_gh_on 'api --paginate repos/o/r/issues/8/timeline*' '' 1 'HTTP 502'
if HOOK_VOUCH=yes labeler_trusted 8 2>/dev/null; then t_fail "labeler hook: an unreadable timeline was trusted"; else t_pass "labeler hook: an unreadable timeline is not trusted"; fi
expect "labeler hook: ...and it was not asked" "$(cat "${TMP}/hook-calls")" ""
unset -f agent_hook_labeler_trusted
expect "fast track: a read-only collaborator's later agent:ready does not undo it" \
  "$(FT_VIEW="$(ft_view owner-login)" labeler_case "$(jq -s . <(ev labeled agent:ready 'gatehand[bot]' "${T0}") <(ev labeled agent:ready outsider "${T1}"))" read)" yes
# end to end: the higher-priority issue was labelled by a read-only collaborator, so the next one wins
stub_gh_reset_rules
AGENT_TRUST_CACHE=()
stub_gh_on 'issue list *' "$(jq -s . <(issue 2 2026-11-01T00:00:00Z 'agent:ready,priority: high' "${DONE}") <(issue 1 2026-10-01T00:00:00Z 'agent:ready,priority: low' "${DONE}"))"
stub_gh_json 'api --paginate repos/o/r/issues/2/timeline*' "$(by outsider)"
stub_gh_json 'api --paginate repos/o/r/issues/1/timeline*' "$(by owner-login)"
stub_gh_json 'api repos/o/r/collaborators/outsider/permission*' '{"permission":"read"}'
stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
stub_gh_json 'api graphql *' "$(edits)"
: >"${TMP}/out"
GITHUB_OUTPUT="${TMP}/out" cmd_pick "" 2>/dev/null
expect "pick: an issue queued by a read-only collaborator is passed over" "$(grep '^issue=' "${TMP}/out")" "issue=1"
# A merged PR that references the issue means it is already fixed on main (an issue was once
# picked after a merged PR had fixed it). Same two issues, both labelled by the owner; #2 ranks first.
XREF_BODY=$'## What\nx\n\nRefs #2'
xref() { # xref <pr> <merged_at|null> [repo] [body]
  jq -cn --argjson n "$1" --arg m "$2" --arg r "${3:-o/r}" --arg b "${4:-${XREF_BODY}}" \
    '{event: "cross-referenced", created_at: "2026-11-01T00:00:00Z",
      source: {type: "issue", issue: {number: $n, repository: {full_name: $r}, body: $b,
        pull_request: {url: "x", merged_at: (if $m == "null" then null else $m end)}}}}'
}
pick_with_xref() { # pick_with_xref <timeline-json-for-#2> [extra rule glob for #2's merged lookup] -> issue=N
  stub_gh_reset_rules
  AGENT_TRUST_CACHE=()
  stub_gh_on 'issue list *' "$(jq -s . <(issue 2 2026-11-01T00:00:00Z 'agent:ready,priority: high' "${DONE}") <(issue 1 2026-10-01T00:00:00Z 'agent:ready,priority: low' "${DONE}"))"
  [[ -n "${2:-}" ]] && stub_gh_on "$2" '' 1 'gh: HTTP 502'
  stub_gh_json 'api --paginate repos/o/r/issues/2/timeline*' "$1"
  stub_gh_json 'api --paginate repos/o/r/issues/1/timeline*' "$(by owner-login)"
  stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
  stub_gh_json 'api graphql *' "$(edits)"
  : >"${TMP}/out"
  GITHUB_OUTPUT="${TMP}/out" cmd_pick "" 2>"${TMP}/err"
  grep '^issue=' "${TMP}/out"
}
expect "pick: an issue a merged PR references is passed over" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 850 2026-10-27T20:51:00Z))")" "issue=1"
expect "pick: and the log names the PR" "$(grep -c 'skip #2: merged PR #850 already references it' "${TMP}/err")" 1
expect "pick: an open or closed-unmerged PR that references it does not count" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 851 null))")" "issue=2"
expect "pick: a merged PR in another repository does not count" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 9 2026-10-27T20:51:00Z other/repo))")" "issue=2"
expect "pick: a cross-reference from a plain issue does not count" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(jq -c '.source.issue |= del(.pull_request)' <<<"$(xref 1045 x)"))")" "issue=2"
expect "pick: a merged PR that only mentions the issue (a review comment's follow-up) does not count" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 851 2026-10-27T20:51:00Z o/r 'Follow-up in #2, not done here.'))")" "issue=2"
expect "pick: one whose body says Fixes o/r#2 counts" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 852 2026-10-27T20:51:00Z o/r 'Fixes o/r#2'))")" "issue=1"
expect "pick: one whose body says resolves the issue URL counts" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 853 2026-10-27T20:51:00Z o/r 'resolves https://github.com/o/r/issues/2'))")" "issue=1"
expect "pick: a batch PR's list counts (Fixes o/r#5, o/r#2.)" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 857 2026-10-27T20:51:00Z o/r 'Fixes o/r#5, o/r#2.'))")" "issue=1"
expect "pick: so does Refs #5 and #2" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 858 2026-10-27T20:51:00Z o/r 'Refs #5 and #2'))")" "issue=1"
expect "pick: a list that breaks off does not reach #2" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 859 2026-10-27T20:51:00Z o/r 'Refs #5, see #2 later'))")" "issue=2"
expect "pick: a bare number is not a reference" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 856 2026-10-27T20:51:00Z o/r 'Fixes 2 flaky tests'))")" "issue=2"
expect "pick: Refs #20 is not Refs #2" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 854 2026-10-27T20:51:00Z o/r 'Refs #20'))")" "issue=2"
expect "pick: another repo's #2 is not this one" \
  "$(pick_with_xref "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(xref 855 2026-10-27T20:51:00Z o/r 'Fixes other/r#2'))")" "issue=2"
expect "pick: a timeline the merged-PR check cannot read skips the issue (fails closed)" \
  "$(pick_with_xref "$(by owner-login)" 'api --paginate repos/o/r/issues/2/timeline?per_page=100')" "issue=1"
stub_gh_reset_rules
AGENT_TRUST_CACHE=()
stub_gh_on 'issue view 2 *' "$(issue 2 2026-11-01T00:00:00Z 'agent:ready' "${DONE}")"
stub_gh_json 'api --paginate repos/o/r/issues/2/timeline*' "$(jq -s . <(xref 850 2026-10-27T20:51:00Z))"
: >"${TMP}/out"
GITHUB_OUTPUT="${TMP}/out" cmd_pick 2 2>/dev/null
expect "pick: a dispatch that names the issue still takes it" "$(grep '^issue=' "${TMP}/out")" "issue=2"
# snapshot: writers' comments only, from one fetch, re-checked after it
stub_gh_reset_rules
AGENT_TRUST_CACHE=()
stub_gh_on 'issue view 7 --json number,title,body,labels,author,comments,createdAt' \
  '{"number":7,"title":"t","body":"b","labels":[],"comments":[{"author":{"login":"owner-login"},"body":"writer says"},{"author":{"login":"outsider"},"body":"reader says"}]}'
stub_gh_json 'api repos/o/r/collaborators/outsider/permission*' '{"permission":"read"}'
stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
stub_gh_json 'api --paginate repos/o/r/issues/7/timeline*' '[]'
stub_gh_json 'api graphql *' "$(edits)"
cmd_snapshot 7 "${TMP}/task.md" "${T0}" 2>/dev/null
expect "snapshot: a writer's comment is in the task" "$(grep -c 'writer says' "${TMP}/task.md")" 1
expect "snapshot: a read-only commenter's is not" "$(grep -c 'reader says' "${TMP}/task.md")" 0
stub_gh_reset_rules
stub_gh_on 'issue view 7 --json number,title,body,labels,author,comments,createdAt' '{"number":7,"title":"t","body":"b","labels":[],"comments":[]}'
stub_gh_json 'api repos/o/r/collaborators/outsider/permission*' '{"permission":"read"}'
stub_gh_json 'api --paginate repos/o/r/issues/7/timeline*' '[]'
stub_gh_json 'api graphql *' "$(edits "${T1}|outsider")"
AGENT_TRUST_CACHE=()
if cmd_snapshot 7 "${TMP}/task2.md" "${T0}" 2>/dev/null; then t_fail "snapshot: an outsider's edit since the run started was not caught"; else t_pass "snapshot: an outsider's edit since the run started fails it"; fi
# The read-back runs AFTER the fetch, or it checks the issue as it was before the read.
stub_gh_reset_rules
stub_gh_reset_calls
stub_gh_on 'issue view 7 --json number,title,body,labels,author,comments,createdAt' '{"number":7,"title":"t","body":"b","labels":[],"comments":[]}'
stub_gh_json 'api --paginate repos/o/r/issues/7/timeline*' '[]'
stub_gh_json 'api graphql *' "$(edits)"
cmd_snapshot 7 "${TMP}/task3.md" "${T0}" 2>/dev/null
view_at="$(stub_gh_calls | grep -n '^issue view 7 ' | head -1 | cut -d: -f1)"
gql_at="$(stub_gh_calls | grep -n '^api graphql ' | tail -1 | cut -d: -f1)"
if [[ -n "${view_at}" && -n "${gql_at}" && "${gql_at}" -gt "${view_at}" ]]; then
  t_pass "snapshot: the edit check runs after the fetch"
else
  t_fail "snapshot: the edit check (call ${gql_at:-none}) does not follow the fetch (call ${view_at:-none})"
fi
# A failed sanitize leaves no copy of the issue behind: the fixer's task file is a mktemp.
stub_gh_reset_rules
AGENT_TRUST_CACHE=()
stub_gh_on 'issue view 7 --json number,title,body,labels,author,comments,createdAt' '{"number":7,"title":"t","body":"b","labels":[],"comments":[]}'
mkdir -p "${TMP}/failing" && printf '#!/usr/bin/env bash\nexit 1\n' >"${TMP}/failing/agent-sanitize-input.sh"
saved_script_dir="${SCRIPT_DIR}"
SCRIPT_DIR="${TMP}/failing"
if cmd_snapshot 7 "${TMP}/task4.md" "${T0}" 2>/dev/null; then t_fail "snapshot: a failed sanitize passed"; else t_pass "snapshot: a failed sanitize fails it"; fi
SCRIPT_DIR="${saved_script_dir}"
expect "snapshot: a failed sanitize leaves no issue JSON behind" "$([[ -e "${TMP}/task4.md.json" ]] && echo left || echo gone)" gone
# snap_case <since> <timeline-json> [edit…] -> yes/no: which window the read-back checks.
snap_case() {
  local since="$1" tl="$2"
  shift 2
  stub_gh_reset_rules
  AGENT_TRUST_CACHE=()
  stub_gh_on 'issue view 7 --json number,title,body,labels,author,comments,createdAt' '{"number":7,"title":"t","body":"b","labels":[],"comments":[],"createdAt":"2026-11-01T00:00:00Z"}'
  stub_gh_json 'api --paginate repos/o/r/issues/7/timeline*' "${tl}"
  stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
  stub_gh_json 'api repos/o/r/collaborators/*/permission*' '{"permission":"read"}'
  if [[ $# -gt 0 ]]; then stub_gh_json 'api graphql *' "$(edits "$@")"; else stub_gh_json 'api graphql *' "$(edits)"; fi
  if cmd_snapshot 7 "${TMP}/snap.md" "${since}" 2>/dev/null; then echo yes; else echo no; fi
}
expect "snapshot (auto-pick): an outsider's edit after the trusted label fails it" \
  "$(snap_case label "$(by owner-login)" "${T1}|outsider")" no
expect "snapshot (auto-pick): untouched since the trusted label passes" "$(snap_case label "$(by owner-login)")" yes
expect "snapshot (named): an outsider's edit after the owner's label fails it, though it predates the run" \
  "$(snap_case "${T2}" "$(by owner-login)" "${T1}|outsider")" no
expect "snapshot (named): with only the bot's label, an outsider's edit at any time refuses (window from creation)" \
  "$(snap_case "${T2}" "$(by 'gatehand[bot]')" "${T1}|outsider")" no
expect "snapshot (named): with no label at all, the same" "$(snap_case "${T2}" '[]' "${T1}|outsider")" no
expect "snapshot (named): with no label and only writers' edits, it passes" "$(snap_case "${T2}" '[]' "${T1}|owner-login")" yes
expect "snapshot (named): a person's label after the run started does not shrink the window" \
  "$(snap_case "${T0}" "$(jq -s . <(ev labeled agent:ready owner-login "${T2}"))" "${T1}|outsider")" no
T3=2026-11-05T13:00:00Z
expect "snapshot (named): a later label by a non-writer does not move the window past an outsider's edit" \
  "$(snap_case "${T3}" "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev labeled agent:ready outsider "${T2}"))" "${T1}|outsider")" no
expect "snapshot (named): nor does a later label by a workflow token" \
  "$(snap_case "${T3}" "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev labeled agent:ready 'github-actions[bot]' "${T2}"))" "${T1}|outsider")" no
expect "snapshot (named): with no writer's label, the oldest person's label anchors it, not the run's start" \
  "$(snap_case "${T3}" "$(jq -s . <(ev labeled agent:ready outsider "${T0}"))" "${T2}|outsider")" no
expect "snapshot (named): an outsider re-labelling after their own edit does not move the fallback" \
  "$(snap_case "${T3}" "$(jq -s . <(ev labeled agent:ready outsider "${T0}") <(ev labeled agent:ready outsider "${T2}"))" "${T1}|outsider")" no
# A failed permission lookup must not read as "no writer labelled it" and widen the window.
stub_gh_reset_rules
AGENT_TRUST_CACHE=()
stub_gh_on 'issue view 7 --json number,title,body,labels,author,comments,createdAt' '{"number":7,"title":"t","body":"b","labels":[],"comments":[]}'
stub_gh_json 'api --paginate repos/o/r/issues/7/timeline*' "$(by owner-login)"
stub_gh_on 'api repos/o/r/collaborators/*/permission*' '' 1 'gh: HTTP 502'
stub_gh_json 'api graphql *' "$(edits "${T1}|outsider")"
if cmd_snapshot 7 "${TMP}/snap.md" "${T3}" 2>/dev/null; then
  t_fail "snapshot (named): a failed permission lookup let an outsider's edit through"
else
  t_pass "snapshot (named): a failed permission lookup still checks from the owner's label"
fi
expect "snapshot (named): the owner re-applying the label after an edit vouches for it" \
  "$(snap_case "${T3}" "$(jq -s . <(ev labeled agent:ready owner-login "${T0}") <(ev labeled agent:ready owner-login "${T2}"))" "${T1}|outsider")" yes
expect "snapshot (named): a later label by a writer does move it" \
  "$(snap_case "${T3}" "$(jq -s . <(ev labeled agent:ready outsider "${T0}") <(ev labeled agent:ready owner-login "${T2}"))" "${T1}|outsider")" yes

# --- 3. finalize -----------------------------------------------------------------------------------
expect "plan: pr-opened (allow-protected is one-shot)" "$(finalize_plan pr-opened '' 1 2)" "agent:pr-open|agent:in-progress,agent:allow-protected|"
expect "plan: blocked" "$(finalize_plan blocked '' 1 2)" "agent:blocked,agent:needs-human|agent:in-progress,agent:allow-protected|blocked"
expect "plan: refused on a protected path files a 'protected' request" "$(finalize_plan refused 'protected:scripts/x.sh' 1 2)" "agent:blocked,agent:needs-human|agent:in-progress,agent:allow-protected|protected"
expect "plan: refused on a never path stops and asks" "$(finalize_plan refused 'never:.github/actions/x' 1 2)" "agent:blocked,agent:needs-human|agent:in-progress,agent:allow-protected|blocked"
expect "plan: refused otherwise retries" "$(finalize_plan refused 'bad title' 1 2)" "agent:ready|agent:in-progress,agent:allow-protected|"
expect "plan: failed with attempts left retries" "$(finalize_plan failed 'x' 1 2)" "agent:ready|agent:in-progress,agent:allow-protected|"
expect "plan: the last failed attempt asks" "$(finalize_plan failed 'x' 2 2)" "agent:blocked,agent:needs-human|agent:in-progress,agent:allow-protected|failed"
expect "plan: an untrusted change is never re-queued by the bot" "$(finalize_plan refused 'untrusted-change: x' 1 2)" "agent:blocked,agent:needs-human|agent:in-progress,agent:allow-protected|untrusted"
expect "plan: an untrusted change on the last attempt is the same" "$(finalize_plan refused 'untrusted-change: x' 2 2)" "agent:blocked,agent:needs-human|agent:in-progress,agent:allow-protected|untrusted"
expect "plan: a run that never reached the model is re-queued and keeps allow-protected" "$(finalize_plan failed 'x' 2 2 false)" "agent:ready|agent:in-progress|"

git init -q --bare "${TMP}/ledger.git"
export LEDGER_REMOTE="${TMP}/ledger.git" AGENT_LEDGER_BACKOFF=0 AGENT_INBOX_ISSUE=99 AGENT_REQ_ID=REQ-20261105-abcd
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
labels_all="$(printf '%s\n' "${AGENT_LABELS[@]}" | cut -d'|' -f1)"
finalize_with() { # finalize_with <outcome> <attempt> [reason]
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_on 'label list *' "${labels_all}"
  stub_gh_on 'issue view 7 --json labels *' "${ISSUE_LABELS:-agent:in-progress}"
  stub_gh_on 'issue view 99 --json body *' $'intro\n<!-- agent-inbox:open:start -->\n<!-- agent-inbox:open:end -->'
  if [[ -n "${FIN_EXTRA:-}" ]]; then "${FIN_EXTRA}"; fi
  if [[ -n "${JOBS_FAIL:-}" ]]; then stub_gh_on 'api repos/o/r/actions/runs/*/jobs*' '' 1 'gh: HTTP 502'; fi
  if [[ -n "${JOBS:-}" ]]; then stub_gh_json 'api repos/o/r/actions/runs/*/jobs*' "${JOBS}"; fi
  OUTCOME="$1" ATTEMPT="$2" REASON="${3:-}" ISSUE=7 RUN_ID=555 FINAL_DIR="${TMP}/final" \
    PR_URL=https://github.com/o/r/pull/42 PR_NUMBER=42 cmd_finalize >/dev/null 2>&1
}
mkdir -p "${TMP}/final"
finalize_with pr-opened 1
expect_call "pr-opened: agent:pr-open replaces agent:in-progress" "issue edit 7 --add-label agent:pr-open --remove-label agent:in-progress"
expect_no_call "pr-opened: no inbox request" "issue comment 99"
expect "pr-opened: a ledger row was written" \
  "$(git --git-dir="${TMP}/ledger.git" show agent-ledger:runs/2026-11.jsonl | jq -r 'select(.run_id=="555") | "\(.outcome) \(.issue) \(.pr)"')" "pr-opened 7 42"
finalize_with failed 1 "the code job ended as failure"
expect_call "failed with attempts left: back to agent:ready" "issue edit 7 --add-label agent:ready --remove-label agent:in-progress"
expect_no_call "failed with attempts left: no inbox request" "issue comment 99"
printf 'Fixing this needs scripts/runner-bootstrap.sh.\n' >"${TMP}/final/blocked.md"
finalize_with blocked 1
expect_call "blocked: agent:blocked + agent:needs-human" "issue edit 7 --add-label agent:blocked --add-label agent:needs-human --remove-label agent:in-progress"
req="$(stub_gh_last_body 'issue comment 99 *')"
expect "blocked: the inbox request carries the marker agent-inbox.sh looks up" \
  "$(head -1 <<<"${req}")" "<!-- agent-req:REQ-20261105-abcd role=coder issue=7 kind=blocked -->"
expect "blocked: the request names its own id in the commands" "$(grep -c '/approve REQ-20261105-abcd' <<<"${req}")" 1
expect "blocked: the agent's note is quoted" "$(grep -c '^> Fixing this needs' <<<"${req}")" 1
expect_call "blocked: the request is listed in the inbox body" "issue edit 99 --body-file"
rm -f "${TMP}/final/blocked.md"
finalize_with failed 2 "x"
expect_call "last attempt failed: blocked" "issue edit 7 --add-label agent:blocked --add-label agent:needs-human --remove-label agent:in-progress"
if stub_gh_any_body "<!-- agent-req:REQ-20261105-abcd role=coder issue=7 kind=failed -->"; then
  t_pass "last attempt failed: a 'failed' request"
else
  t_fail "last attempt failed: no 'failed' request was posted"
fi
# failed, blocked, failed: three runs in a row without a PR, the policy threshold.
if stub_gh_any_body "kind=breaker -->"; then
  t_pass "the third run in a row without a PR trips the breaker and files a breaker request"
else
  t_fail "three runs without a PR filed no breaker request"
fi
expect_no_call "finalize never closes an issue" "issue close"
finalize_with failed 1 $'two\nlines @claude'
if stub_gh_any_body "two lines @-claude"; then t_pass "finalize: the reason is posted as one sanitised line"; else t_fail "finalize: the reason was posted raw"; fi
finalize_with refused 1 "untrusted-change: someone without write access changed the issue"
expect_call "untrusted change: blocked, not re-queued" "issue edit 7 --add-label agent:blocked --add-label agent:needs-human --remove-label agent:in-progress"
note="$(stub_gh_last_body 'issue comment 7 *')"
# shellcheck disable=SC2016 # the backticks are literal markdown in the comment text
if grep -Fq 're-apply `agent:ready` yourself' <<<"${note}" && grep -Fq '/rerun coder #7' <<<"${note}" && ! grep -q 'back in the queue\|No attempts left' <<<"${note}"; then
  t_pass "untrusted change: the issue comment says to re-apply the label yourself"
else
  t_fail "untrusted change: the issue comment was '${note}'"
fi
if stub_gh_any_body "kind=untrusted -->"; then t_pass "untrusted change: an 'untrusted' inbox note is filed"; else t_fail "untrusted change: no inbox note"; fi

# --- 3b. a run that failed before the model step costs nothing (agent-lib.sh infra_failure) ---------
# The code job's steps as agent-coder.yml names them; the jobs API reports a composite action as one
# step under its `name:`. A 504 on a toolchain download fails 'project toolchain'. codesteps moves
# the one failure to another step.
CODE_STEPS=('Set up job' 'Run actions/checkout@v7' 'agent directory' 'project system packages' 'project toolchain'
  'project dependencies' 'Run actions/download-artifact@v4' 'prepare the work branch' 'drop sudo' 'implement'
  'package the work' 'Run actions/upload-artifact@v4')
codesteps() { # codesteps <failed-step> [job-name]
  printf '%s\n' "${CODE_STEPS[@]}" | jq -R . | jq -sc --arg f "$1" --arg j "${2:-implement (agent)}" '
    (index($f)) as $i | to_entries
    | map({number: (.key + 1), name: .value,
           conclusion: (if .key < $i then "success" elif .key == $i then "failure" else "skipped" end)})
    + [{number: 30, name: "Post Run actions/checkout@v7", conclusion: "success"}, {number: 33, name: "Complete job", conclusion: "success"}]
    | {jobs: [{name: "preflight (gate, pick, lock)", conclusion: "success", steps: []},
              {name: $j, conclusion: "failure", steps: .}]}'
}
expect "pre-agent: a toolchain download failure qualifies" "$(pre_agent_failure "$(codesteps 'project toolchain')" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}")" "project toolchain"
expect "pre-agent: so does a pinned action's step name" "$(CODE_STEPS[1]='Run actions/checkout@b906affcce14559ad1aafd4ab0e942779e9f58b1'; pre_agent_failure "$(codesteps 'Run actions/checkout@b906affcce14559ad1aafd4ab0e942779e9f58b1')" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}")" "Run actions/checkout@b906affcce14559ad1aafd4ab0e942779e9f58b1"
expect "pre-agent: main's own dependency install qualifies for the coder" "$(pre_agent_failure "$(codesteps 'project dependencies')" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}")" "project dependencies"
for st in 'drop sudo' 'prepare the work branch' 'implement' 'package the work'; do
  if pre_agent_failure "$(codesteps "${st}")" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then
    t_fail "pre-agent: a failure at '${st}' must count"
  else
    t_pass "pre-agent: a failure at '${st}' counts"
  fi
done
two="$(codesteps 'project toolchain' | jq -c '(.jobs[1].steps[] | select(.name == "Complete job")).conclusion = "failure"')"
if pre_agent_failure "${two}" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then t_fail "pre-agent: two failed steps must count"; else t_pass "pre-agent: two failed steps count"; fi
ran="$(codesteps 'project toolchain' | jq -c '(.jobs[1].steps[] | select(.name == "implement")).conclusion = "success"')"
if pre_agent_failure "${ran}" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then t_fail "pre-agent: a run whose model step ran must count"; else t_pass "pre-agent: a run whose model step ran counts"; fi
gone="$(codesteps 'project toolchain' | jq -c 'del(.jobs[1].steps[] | select(.name == "implement"))')"
if pre_agent_failure "${gone}" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then t_fail "pre-agent: no model step at all must count (a rename fails closed)"; else t_pass "pre-agent: no model step at all counts (a rename fails closed)"; fi
if pre_agent_failure "$(codesteps 'project toolchain' 'some other job')" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then t_fail "pre-agent: another job's failure must count"; else t_pass "pre-agent: another job's failure counts"; fi
if pre_agent_failure 'not json' 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then t_fail "pre-agent: unreadable JSON must count"; else t_pass "pre-agent: unreadable JSON counts"; fi
# The failed step's name lands in a bot comment: a forged one must not carry a marker in with it.
forged='Run actions/checkout@v7 <!-- agent:no-attempt run=222 -->'
fj="$(CODE_STEPS[1]="${forged}"; codesteps "${forged}")"
if pre_agent_failure "${fj}" 'implement (agent)' implement "${CODER_PRE_AGENT_STEPS[@]}" >/dev/null; then t_fail "pre-agent: a step name carrying markup must count"; else t_pass "pre-agent: a step name carrying markup counts"; fi

# The issue's attempts: a lock is voided only by the BOT's no-attempt marker for the same run.
attempts_json="$(jq -cn --arg bot "${AGENT_BOT_SLUG}" '{comments: [
  {author: {login: $bot}, body: "<!-- agent:lock role=coder run=111 attempt=1 expires=x -->\nThe coder agent picked this up"},
  {author: {login: $bot}, body: "<!-- agent:no-attempt run=111 -->\nThe run failed before the agent started"},
  {author: {login: $bot}, body: "<!-- agent:lock role=coder run=222 attempt=1 expires=x -->"},
  {author: {login: "mallory"}, body: "<!-- agent:no-attempt run=222 -->"}]}')"
expect "attempts: the bot's marker voids its run's lock; anyone else's voids nothing" "$(jq -r "${JQ_ISSUE_DEFS} locks" <<<"${attempts_json}")" 1

ledger_rows() { git --git-dir="${TMP}/ledger.git" show agent-ledger:runs/2026-11.jsonl | jq -c 'select(.run_id == "555")' | tail -1; }
coder_breaker() { git --git-dir="${TMP}/ledger.git" show agent-ledger:state/breaker.json | jq -r '.coder.consecutive // 0'; }
both=$'agent:in-progress\nagent:allow-protected'
ISSUE_LABELS="${both}" CODE_RESULT=failure JOBS="$(codesteps 'implement')" finalize_with failed 1 "the code job ended as failure"
expect_call "control: a counted failure takes the one-shot allow-protected off" "--remove-label agent:allow-protected"
before="$(coder_breaker)"
ISSUE_LABELS="${both}" CODE_RESULT=failure JOBS="$(codesteps 'project toolchain')" finalize_with failed 2 "the code job ended as failure"
expect_call "infra: back to agent:ready even on the last attempt" "issue edit 7 --add-label agent:ready --remove-label agent:in-progress"
expect_no_call "infra: and allow-protected stays, since its attempt never happened" "--remove-label agent:allow-protected"
note="$(stub_gh_last_body 'issue comment 7 *')"
expect "infra: the issue comment starts with the bot's no-attempt marker" "$(head -1 <<<"${note}")" "<!-- agent:no-attempt run=555 -->"
if grep -Fq '**project toolchain**' <<<"${note}"; then t_pass "infra: and names the failed step"; else t_fail "infra: the comment was '${note}'"; fi
expect_no_call "infra: no inbox request" "issue comment 99"
expect "infra: the ledger row is not counted and names the step" "$(ledger_rows | jq -r '"\(.counted) \(.infra_step) \(.outcome)"')" "false project toolchain failed"
expect "infra: no breaker step" "$(coder_breaker)" "${before}"
CODE_RESULT=failure JOBS="$(codesteps 'implement')" finalize_with failed 1 "the code job ended as failure"
expect "infra: a failure of the model step itself is counted" "$(ledger_rows | jq -r '"\(.counted) \(.infra_step)"')" "true null"
CODE_RESULT=failure JOBS_FAIL=1 finalize_with failed 1 "the code job ended as failure"
expect "infra: unreadable jobs are counted (fails closed)" "$(ledger_rows | jq -r .counted)" true
PREFLIGHT_RESULT=failure CODE_RESULT=skipped finalize_with failed 1 "the code job ended as skipped"
expect "infra: a preflight failure is not counted, with no budget" "$(ledger_rows | jq -r '"\(.counted) \(.infra_step)"')" "false preflight"
expect_no_call "infra: and needs no jobs API" "actions/runs/"
SNAPSHOT_RESULT=failure PREFLIGHT_RESULT=failure CODE_RESULT=skipped finalize_with failed 1 "the code job ended as skipped"
expect "infra: a preflight whose snapshot failed is never a free run" "$(ledger_rows | jq -r .counted)" true
CODE_RESULT=failure JOBS="$(codesteps 'project toolchain')" finalize_with refused 1 "untrusted-change: someone without write access changed the issue"
expect_call "infra: an untrusted change is still blocked, never reclassified" "issue edit 7 --add-label agent:blocked --add-label agent:needs-human --remove-label agent:in-progress"
expect_no_call "infra: and its jobs are not read" "actions/runs/"
grace_used() { stub_gh_on 'api * repos/o/r/contents/runs/*' '{"run_id":"9","role":"coder","started_at":"2026-11-05T08:00:00Z","counted":false}'; }
FIN_EXTRA=grace_used CODE_RESULT=failure JOBS="$(codesteps 'project toolchain')" finalize_with failed 1 "the code job ended as failure"
expect "infra: past the day's grace the run is counted, and the reason says why" "$(ledger_rows | jq -r '"\(.counted) \(.reason)"')" "true infrastructure (project toolchain); today's grace is used, so it counts"
expect "infra: the coder's daily grace is one" "$(policy '.roles.coder.infraGracePerDay')" 1

# A breaker request names the role that tripped, so its /resume resets the right breaker.
if ROLE=fixer request_body breaker 0 "3 fixer runs in a row ended without a push" /dev/null | grep -Fq '/resume fixer'; then
  t_pass "breaker request: the fixer's names /resume fixer"
else
  t_fail "breaker request: the fixer's does not name /resume fixer"
fi
if ROLE=fixer request_body breaker 0 "x" /dev/null | grep -q 'coder'; then t_fail "breaker request: the fixer's mentions the coder"; else t_pass "breaker request: and never the coder"; fi

# head_pushed_at: the head's first check suite, unless the PR was force-pushed back to it later.
SHA=cccccccccccccccccccccccccccccccccccccccc
pushed_case() { # pushed_case <graphql-json|FAIL>
  stub_gh_reset_rules
  stub_gh_json 'api repos/o/r/commits/*/check-suites*' '{"check_suites":[{"created_at":"2026-11-05T10:05:00Z"},{"created_at":"2026-11-05T10:00:00Z"}]}'
  if [[ "$1" == FAIL ]]; then stub_gh_on 'api graphql *' '' 1 'gh: HTTP 502'; else stub_gh_json 'api graphql *' "$1"; fi
}
fp() { jq -cn --arg t "$1" --arg o "$2" '{data: {repository: {pullRequest: {timelineItems: {nodes: [{createdAt: $t, afterCommit: {oid: $o}}]}}}}}'; }
pushed_case "$(fp 2026-11-05T11:10:00Z "${SHA}")"
expect "head_pushed_at: without a PR, the first check suite" "$(head_pushed_at "${SHA}")" 2026-11-05T10:00:00Z
expect "head_pushed_at: a later force-push back to this SHA is when it came back" "$(head_pushed_at "${SHA}" 44)" 2026-11-05T11:10:00Z
pushed_case "$(fp 2026-11-05T11:10:00Z dddddddddddddddddddddddddddddddddddddddd)"
expect "head_pushed_at: a force-push to another SHA does not count" "$(head_pushed_at "${SHA}" 44)" 2026-11-05T10:00:00Z
pushed_case FAIL
if head_pushed_at "${SHA}" 44 >/dev/null 2>&1; then t_fail "head_pushed_at: an unreadable timeline reads as fine"; else t_pass "head_pushed_at: an unreadable timeline fails"; fi
# review_runs reads every page, from the day before the push on.
stub_gh_reset_calls
stub_gh_reset_rules
review_runs 44 2026-11-05T10:00:00Z >/dev/null 2>&1
expect_call "review_runs: every page, from the day before the push" \
  "api --paginate repos/o/r/actions/workflows/claude-code-review.yml/runs?per_page=100&created=%3E%3D2026-11-04"
# actor_trusted: a failed lookup is neither yes nor no, and is not cached.
AGENT_TRUST_CACHE=()
stub_gh_reset_rules
stub_gh_on 'api repos/o/r/collaborators/bob/permission*' '' 1 'gh: HTTP 502'
actor_trusted bob 2>/dev/null
expect "actor_trusted: a failed lookup says so (2)" "$?" 2
stub_gh_reset_rules
stub_gh_json 'api repos/o/r/collaborators/bob/permission*' '{"permission":"write"}'
if actor_trusted bob; then t_pass "actor_trusted: and is asked again, not cached as no"; else t_fail "actor_trusted: a failed lookup was cached"; fi
stub_gh_reset_rules
stub_gh_on 'api repos/o/r/collaborators/nobody/permission*' '' 1 'gh: Not Found (HTTP 404)'
actor_trusted nobody 2>/dev/null
expect "actor_trusted: a 404 is a no (1)" "$?" 1
# cmd_kick: the schedule's dispatch, never on top of a queued or running coder run.
kick_case() { # kick_case <runs-json> [rc]
  stub_gh_reset_calls
  stub_gh_reset_rules
  if [[ "${2:-0}" != 0 ]]; then stub_gh_on 'api repos/o/r/actions/workflows/agent-coder.yml/runs*' '' "$2" 'gh: HTTP 502'
  else stub_gh_json 'api repos/o/r/actions/workflows/agent-coder.yml/runs*' "$1"; fi
  cmd_kick >/dev/null 2>&1
  echo "$?" >"${TMP}/kick.rc"
}
kick_case '{"workflow_runs":[{"status":"completed"},{"status":"completed"}]}'
expect_call "kick: nothing queued or running: an auto-pick run is dispatched on the runner ref" "workflow run agent-coder.yml --ref agent-runner"
expect_call "kick: counting dispatched runs only" "agent-coder.yml/runs?event=workflow_dispatch"
for st in queued in_progress waiting pending requested; do
  kick_case "{\"workflow_runs\":[{\"status\":\"completed\"},{\"status\":\"${st}\"}]}"
  expect_no_call "kick: a coder run ${st}: no dispatch (it would cancel a pending one)" "workflow run"
done
kick_case '' 1
expect "kick: an unreadable run list fails" "$(cat "${TMP}/kick.rc")" 1
stub_gh_reset_calls
stub_gh_reset_rules
stub_gh_on 'api repos/o/r/actions/workflows/agent-coder.yml/runs*' ''
cmd_kick >/dev/null 2>&1
expect "kick: an answer that is not a count fails too" "$?" 1
expect_no_call "kick: and dispatches nothing" "workflow run"

# cmd_lock: the lock comment is what the sweep tells this run's lock from the last one's by, so a
# comment that cannot be posted fails the lock (and with it preflight; finalize then releases it).
stub_gh_reset_calls
stub_gh_reset_rules
stub_gh_on 'label list *' "${labels_all}"
stub_gh_on 'issue comment 7 *' '' 1 'gh: HTTP 502'
if ROLE=coder RUN_ID=555 cmd_lock 7 1 >/dev/null 2>&1; then t_fail "a lock whose comment failed reads as taken"; else t_pass "a lock whose comment failed fails"; fi
stub_gh_reset_rules
stub_gh_on 'label list *' "${labels_all}"
if ROLE=coder RUN_ID=555 cmd_lock 7 1 >/dev/null 2>&1; then t_pass "a lock whose comment posted succeeds"; else t_fail "a posted lock failed"; fi

# request_review: once per head, again when that request went nowhere (a dispatched review that
# ended without posting, 2026-11-10), at most twice, then once in the inbox. Now is 12:00; a request
# is stale after 45 minutes, so 11:30 is recent and 11:00 is not.
RR_SHA=1111111111111111111111111111111111111111
RR_CALL='workflow run Claude Code Review -f pr=44'
rr_marker() { printf '<!-- agent-review-dispatched sha=%s -->\nwhy' "${2:-${RR_SHA}}"; }
rr_comments() { # rr_comments "<login>|<created_at>|<body>" ... -> the REST comments array
  local c rest a=() i=0
  for c in "$@"; do
    i=$((i + 1)); rest="${c#*|}"
    a+=("$(jq -cn --argjson id "${i}" --arg u "${c%%|*}" --arg t "${rest%%|*}" --arg b "${rest#*|}" '{id: $id, user: {login: $u}, created_at: $t, updated_at: $t, body: $b}')")
  done
  if [[ ${#a[@]} -eq 0 ]]; then echo '[]'; else printf '%s\n' "${a[@]}" | jq -s .; fi
}
RR_RUNS_NONE='{"workflow_runs":[]}'
# rr_case <comments-json>: request_review as the merge gate calls it (RR_AGAIN= for the fixer's call).
# RR_RUNS: the review runs; RR_JOB: "<started> <completed>" of run 70's claude-review job; RR_INBOX:
# the inbox's comments; RR_FAIL: a glob that fails.
rr_case() {
  stub_gh_reset_calls
  stub_gh_reset_rules
  AGENT_TRUST_CACHE=()
  if [[ -n "${RR_FAIL:-}" ]]; then stub_gh_on "${RR_FAIL}" '' 1 'gh: HTTP 502'; fi
  stub_gh_json 'api --paginate repos/o/r/issues/44/comments*' "$1"
  stub_gh_json 'api --paginate repos/o/r/actions/workflows/claude-code-review.yml/runs*' "${RR_RUNS:-${RR_RUNS_NONE}}"
  # RR_POST: "<started> <completed>" of the same attempt's post-review job, which posts the comment.
  # RR_JOBS: the jobs list as it stands, in place of RR_JOB and RR_POST.
  [[ -z "${RR_JOBS:-}" ]] || stub_gh_json 'api repos/o/r/actions/runs/70/jobs*' "{\"jobs\":${RR_JOBS}}"
  stub_gh_json 'api repos/o/r/actions/runs/70/jobs*' "$(jq -cn --arg w "${RR_JOB:-}" --arg p "${RR_POST:-}" '($w | split(" ")) as $j | ($p | split(" ")) as $q
    | {jobs: ((if $w == "" then [] else [{name: "claude-review", run_attempt: 1, started_at: $j[0], completed_at: $j[1]}] end)
      + (if $p == "" then [] else [{name: "post-review", run_attempt: 1, started_at: $q[0], completed_at: $q[1]}] end))}')"
  stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
  stub_gh_json 'api repos/o/r/collaborators/*/permission*' '{"permission":"read"}'
  stub_gh_json 'api --paginate repos/o/r/issues/99/comments*' "${RR_INBOX:-[]}"
  stub_gh_on 'pr view 44 --json body*' '{"body":"x\n\nRefs #7\n\n<!-- agent-run:coder run=900 issue=7 -->"}'
  stub_gh_on 'issue view 99 --json body *' $'intro\n<!-- agent-inbox:open:start -->\n<!-- agent-inbox:open:end -->'
  AGENT_INBOX_ISSUE=99 request_review 44 "${RR_SHA}" "CI passed on the fixer's ${RR_SHA:0:9}" ${RR_AGAIN-again} >"${TMP}/rr.out" 2>"${TMP}/rr.err"
  echo "$?" >"${TMP}/rr.rc"
}
rr_dispatches() { stub_gh_calls | grep -c "^${RR_CALL}"; }

rr_case '[]'
expect "request_review: the first request for a head dispatches the review" "$(rr_dispatches)" 1
if stub_gh_last_body 'issue comment 44 *' | grep -Fq "<!-- agent-review-dispatched sha=${RR_SHA} -->"$'\n'"CI passed on the fixer's ${RR_SHA:0:9}, so a fresh Claude review was requested."; then
  t_pass "request_review: and records it on the PR with the caller's reason"
else
  t_fail "request_review: recorded '$(stub_gh_last_body 'issue comment 44 *')'"
fi
rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:30:00Z|$(rr_marker)")"
expect "request_review: a request 30 minutes old is not repeated" "$(rr_dispatches)" 0
expect_no_call "request_review: nor recorded again" "issue comment 44"
if grep -Fq "a review of ${RR_SHA:0:9} was already requested" "${TMP}/rr.out"; then t_pass "request_review: and says it was already requested"; else t_fail "request_review: said '$(cat "${TMP}/rr.out")'"; fi
rr_case "$(rr_comments "claude[bot]|2026-11-05T09:00:00Z|<!-- verify-pr-review -->" "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
expect "request_review: a request an hour old with no review since: requested again" "$(rr_dispatches)" 1
if stub_gh_last_body 'issue comment 44 *' | grep -Fq "<!-- agent-review-dispatched sha=${RR_SHA} -->" \
  && stub_gh_last_body 'issue comment 44 *' | grep -Fq "requested at 2026-11-05T11:00:00Z posted nothing" \
  && stub_gh_last_body 'issue comment 44 *' | grep -Fq "(request 2 of 3)"; then
  t_pass "request_review: recorded as the second request for the head, naming the one that went nowhere"
else
  t_fail "request_review: recorded '$(stub_gh_last_body 'issue comment 44 *')'"
fi
expect "request_review: and the retry succeeds" "$(cat "${TMP}/rr.rc")" 0
rr_case "$(rr_comments "gatehand[bot]|2026-11-05T10:00:00Z|$(rr_marker)" "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
expect "request_review: two stale requests: a third, the last allowed" "$(rr_dispatches)" 1
if stub_gh_last_body 'issue comment 44 *' | grep -Fq "(request 3 of 3)"; then t_pass "request_review: recorded as 3 of 3"; else t_fail "request_review: recorded '$(stub_gh_last_body 'issue comment 44 *')'"; fi
RR_STALE="$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
RR_AGAIN= rr_case "${RR_STALE}"
expect "request_review: the fixer's call never repeats a request, however old" "$(rr_dispatches)" 0
# Whether a review posted after the request answers it: the review bot's must come from a job that
# started after the request (review_attribution) and be unedited; a writer's counts as it is.
RR_RUN70='{"workflow_runs":[{"id":70,"display_title":"Claude review of PR #44","created_at":"2026-11-05T11:00:01Z","status":"completed"}]}'
RR_ANSWER="$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)" "claude[bot]|2026-11-05T11:10:00Z|<!-- verify-pr-review -->")"
RR_RUNS="${RR_RUN70}" RR_JOB="2026-11-05T11:01:00Z 2026-11-05T11:12:00Z" rr_case "${RR_ANSWER}"
expect "request_review: a review its own job posted after the request: answered, not requested again" "$(rr_dispatches)" 0
RR_RUNS="${RR_RUN70}" RR_JOB="2026-11-05T10:50:00Z 2026-11-05T11:12:00Z" rr_case "${RR_ANSWER}"
expect "request_review: a review posted after the request by a job that started before it: no answer, requested again" "$(rr_dispatches)" 1
RR_RUNS="${RR_RUN70}" rr_case "${RR_ANSWER}"
expect "request_review: a review no job of the PR wrote: no answer, requested again" "$(rr_dispatches)" 1
# #1147: the post-review job posts the comment after the claude-review job has ended.
RR_RUNS="${RR_RUN70}" RR_JOB="2026-11-05T11:01:00Z 2026-11-05T11:05:00Z" RR_POST="2026-11-05T11:06:00Z 2026-11-05T11:12:00Z" rr_case "${RR_ANSWER}"
expect "request_review: a review the post job posted, after a review job that started after the request: answered" "$(rr_dispatches)" 0
RR_RUNS="${RR_RUN70}" RR_JOB="2026-11-05T10:50:00Z 2026-11-05T10:58:00Z" RR_POST="2026-11-05T10:59:00Z 2026-11-05T11:12:00Z" rr_case "${RR_ANSWER}"
expect "request_review: a review the post job posted, whose review job started before the request: requested again" "$(rr_dispatches)" 1
# "Re-run failed jobs" on a failed post-review: attempt 2 has only post-review, and posts attempt 1's
# review of the old head. Its window starts where attempt 1's review did, so it is stale even while
# a later full attempt's window also holds the comment.
RR_RUNS="${RR_RUN70}" RR_JOBS='[{"name":"claude-review","run_attempt":1,"started_at":"2026-11-05T10:50:00Z","completed_at":"2026-11-05T10:58:00Z"},
  {"name":"post-review","run_attempt":2,"started_at":"2026-11-05T11:09:00Z","completed_at":"2026-11-05T11:11:00Z"},
  {"name":"claude-review","run_attempt":3,"started_at":"2026-11-05T11:01:00Z","completed_at":"2026-11-05T11:20:00Z"}]' rr_case "${RR_ANSWER}"
expect "request_review: a re-run post job's comment is as old as the review it posts: requested again" "$(rr_dispatches)" 1
RR_RUNS="${RR_RUN70}" RR_JOB="2026-11-05T11:01:00Z 2026-11-05T11:12:00Z" \
  rr_case "$(jq -c '(.[] | select(.user.login == "claude[bot]") | .updated_at) = "2026-11-05T11:20:00Z"' <<<"${RR_ANSWER}")"
expect "request_review: the review bot's review edited after it posted: no answer, requested again" "$(rr_dispatches)" 1
rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)" "owner-login|2026-11-05T11:10:00Z|<!-- verify-pr-review -->")"
expect "request_review: a writer's review after the request: answered" "$(rr_dispatches)" 0
rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)" "outsider|2026-11-05T11:10:00Z|<!-- verify-pr-review -->")"
expect "request_review: an outsider's review after the request: no answer, requested again" "$(rr_dispatches)" 1
RR_RUNS='{"workflow_runs":[{"id":70,"display_title":"Claude review of PR #44","created_at":"2026-11-05T11:00:01Z","status":"queued"}]}' \
  rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
expect "request_review: a stale request whose run is still queued: not requested again" "$(rr_dispatches)" 0
RR_RUNS='{"workflow_runs":[{"id":70,"display_title":"Claude review of PR #45","created_at":"2026-11-05T11:00:01Z","status":"in_progress"}]}' \
  rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
expect "request_review: another PR's running review does not hold this one back" "$(rr_dispatches)" 1
rr_case "$(rr_comments "outsider|2026-11-05T11:30:00Z|$(rr_marker)")"
expect "request_review: a marker someone else pasted is no request" "$(rr_dispatches)" 1
rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:30:00Z|$(rr_marker x 2222222222222222222222222222222222222222)")"
expect "request_review: a request for another head is no request for this one" "$(rr_dispatches)" 1
# The cap: three requests that all went nowhere, and the head goes to a person, once.
RR_THREE="$(rr_comments "gatehand[bot]|2026-11-05T10:00:00Z|$(rr_marker)" "gatehand[bot]|2026-11-05T10:30:00Z|$(rr_marker)" "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
rr_case "${RR_THREE}"
expect "request_review: the cap reached: no fourth request" "$(rr_dispatches)" 0
if stub_gh_last_body 'issue comment 99 *' | grep -Fq "<!-- agent-review-ask pr=44 sha=${RR_SHA} -->" \
  && stub_gh_last_body 'issue comment 99 *' | grep -Eq "<!-- agent-req:REQ-[0-9]{8}-[0-9a-f]{4} role=merger issue=7 kind=review -->" \
  && stub_gh_last_body 'issue comment 99 *' | grep -Fq 'gh workflow run "Claude Code Review" -f pr=44'; then
  t_pass "request_review: the cap reached: a review request in the agent inbox, with what to do"
else
  t_fail "request_review: inbox got '$(stub_gh_last_body 'issue comment 99 *')'"
fi
expect_no_call "request_review: and nothing on the PR" "issue comment 44"
expect_no_call "request_review: nor a label" "issues/44/labels"
expect "request_review: the inbox request succeeds" "$(cat "${TMP}/rr.rc")" 0
RR_RUNS="${RR_RUN70}" RR_JOB="2026-11-05T10:50:00Z 2026-11-05T11:12:00Z" \
  rr_case "$(jq -c '. + [{id: 9, user: {login: "claude[bot]"}, created_at: "2026-11-05T11:10:00Z", updated_at: "2026-11-05T11:10:00Z", body: "<!-- verify-pr-review -->"}]' <<<"${RR_THREE}")"
if stub_gh_calls | grep -q '^issue comment 99 ' && [[ "$(rr_dispatches)" == 0 ]]; then
  t_pass "request_review: the cap reached with only an older job's review since: still the inbox, no fourth request"
else
  t_fail "request_review: cap with an older job's review: $(cat "${TMP}/rr.out")"
fi
RR_INBOX="$(jq -cn --arg b "<!-- agent-review-ask pr=44 sha=${RR_SHA} -->" '[{user: {login: "gatehand[bot]"}, body: $b}]')" rr_case "${RR_THREE}"
expect_no_call "request_review: a head already in the inbox: not asked twice" "issue comment 99"
expect "request_review: nor requested" "$(rr_dispatches)" 0
RR_INBOX="$(jq -cn --arg b "<!-- agent-review-ask pr=44 sha=${RR_SHA} -->" '[{user: {login: "outsider"}, body: $b}]')" rr_case "${RR_THREE}"
if stub_gh_calls | grep -q '^issue comment 99 '; then t_pass "request_review: an ask marker someone else pasted does not count"; else t_fail "request_review: a pasted ask marker suppressed the inbox request"; fi
RR_FAIL='issue comment 99 *' rr_case "${RR_THREE}"
expect "request_review: an inbox request that failed fails, so the next run asks again" "$(cat "${TMP}/rr.rc")" 1
rr_case "$(rr_comments "gatehand[bot]|2026-11-05T10:00:00Z|$(rr_marker)" "gatehand[bot]|2026-11-05T10:30:00Z|$(rr_marker)" "gatehand[bot]|2026-11-05T11:30:00Z|$(rr_marker)")"
expect "request_review: three requests, the last one recent: it still has time" "$(rr_dispatches)" 0
expect_no_call "request_review: and nobody is asked yet" "issue comment 99"
RR_FAIL='api --paginate repos/o/r/issues/44/comments*' rr_case '[]'
expect "request_review: unreadable comments fail" "$(cat "${TMP}/rr.rc")" 1
expect "request_review: and request nothing" "$(rr_dispatches)" 0
RR_FAIL='api --paginate repos/o/r/actions/workflows/claude-code-review.yml/runs*' rr_case "$(rr_comments "gatehand[bot]|2026-11-05T11:00:00Z|$(rr_marker)")"
expect "request_review: unreadable review runs on a stale request fail" "$(cat "${TMP}/rr.rc")" 1
expect "request_review: and request nothing" "$(rr_dispatches)" 0

printf '\n[agents-state] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
