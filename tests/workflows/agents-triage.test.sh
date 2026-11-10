#!/usr/bin/env bash
# tests/workflows/agents-triage.test.sh
# .github/scripts/agent-triage.sh against a stub gh. Pinned, and why:
#   1. Only a Claude Security import counts (label, the import line first, a Severity row, a
#      Recommendation section), parsed line by line: jq's ^ and $ anchor the whole body.
#   2. Low/Medium by a writer -> agent:ready + size: S and the fast-track marker (label first);
#      High/Critical -> agent:candidate. A read-only or bot author, an agent label already, or the
#      bot's earlier marker: nothing. A merged PR naming it: one fixed-on-main comment, no label.
#   3. Failures fail: an unreadable timeline or a comment that did not post reddens the run.
# AGENT_TRUST_CACHE is read by the sourced scripts.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agents-gh-stub.sh"
export AGENT_TRIAGE_NO_MAIN=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-triage.sh"
set +e

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-triage] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-triage] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }
expect_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_pass "$1"; else t_fail "$1: no gh call containing '$2'"; fi; }
expect_no_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_fail "$1: unexpected gh call '$2'"; else t_pass "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export GH_REPO=o/r AGENT_NOW_EPOCH=1793880000
stub_gh_init
labels_all="$(printf '%s\n' "${AGENT_LABELS[@]}" | cut -d'|' -f1)"

# body <severity> [drop]: a Claude Security import's body; drop=import|severity|recommendation
# leaves that part out.
body() {
  local b=""
  [[ "${2:-}" == import ]] || b+=$'> Imported from Claude Security (project `spj_x`). Locations are pinned.\n\n'
  b+=$'| | |\n|---|---|\n'
  [[ "${2:-}" == severity ]] || b+="| **Severity** | $1 |"$'\n'
  b+=$'| **Category** | CWE-345 |\n\n## Description\n\nSomething is wrong.\n\n'
  [[ "${2:-}" == recommendation ]] || b+=$'## Recommendation\n\nFix it.\n'
  printf '%s' "${b}"
}
# ijson <n> <severity> [author] [labels-csv] [drop] [state]
ijson() {
  jq -cn --argjson n "$1" --arg b "$(body "$2" "${5:-}")" --arg a "${3:-owner-login}" --arg l "${4-security,priority: low}" --arg s "${6:-OPEN}" \
    '{number: $n, state: $s, title: "finding", body: $b, author: {login: $a},
      labels: ($l | split(",") | map(select(. != "") | {name: .}))}'
}

# --- 1. what counts as an import -------------------------------------------------------------------
expect "Low" "$(security_severity "$(ijson 1 Low)")" low
expect "Medium" "$(security_severity "$(ijson 1 Medium)")" medium
expect "High" "$(security_severity "$(ijson 1 High)")" high
expect "Critical" "$(security_severity "$(ijson 1 Critical)")" critical
expect "an unknown severity is nothing" "$(security_severity "$(ijson 1 Spicy)")" ""
expect "without the security label: nothing" "$(security_severity "$(ijson 1 Low owner-login 'priority: low')")" ""
expect "without the import line: nothing" "$(security_severity "$(ijson 1 Low owner-login security import)")" ""
expect "without a Severity row: nothing" "$(security_severity "$(ijson 1 Low owner-login security severity)")" ""
expect "without a Recommendation section: nothing" "$(security_severity "$(ijson 1 Low owner-login security recommendation)")" ""
expect "the import line must open the body" \
  "$(security_severity "$(jq -c '.body = "intro\n" + .body' <<<"$(ijson 1 Low)")")" ""
expect "a Severity row quoted mid-line does not count" \
  "$(security_severity "$(jq -c '.body |= sub("\\| \\*\\*Severity\\*\\* \\| Low \\|"; "see | **Severity** | Low |")' <<<"$(ijson 1 Low)")")" ""
expect "a Recommendation heading with text after it does not count" \
  "$(security_severity "$(jq -c '.body |= sub("## Recommendation"; "## Recommendations aside")' <<<"$(ijson 1 Low)")")" ""

# --- 2. what triage does ---------------------------------------------------------------------------
# tri_case <issue-json> [comments-json] [timeline-json]: one issue, #5.
tri_case() {
  stub_gh_reset_calls
  stub_gh_reset_rules
  AGENT_TRUST_CACHE=()
  stub_gh_on 'label list *' "${labels_all}"
  stub_gh_json 'api repos/o/r/collaborators/owner-login/permission*' '{"permission":"admin"}'
  stub_gh_json 'api repos/o/r/collaborators/*/permission*' '{"permission":"read"}'
  stub_gh_json 'api --paginate repos/o/r/issues/5/comments*' "${2:-[]}"
  if [[ -n "${TIMELINE_FAILS:-}" ]]; then stub_gh_on 'api --paginate repos/o/r/issues/5/timeline*' '' 1 'gh: HTTP 502'; fi
  stub_gh_on 'api --paginate repos/o/r/issues/5/timeline*' "${3:-[]}"
  stub_gh_on 'issue view 5 --json labels *' "${VIEW_LABELS:-$(jq -r '.labels[].name' <<<"$1")}"
  if [[ -n "${COMMENT_FAILS:-}" ]]; then stub_gh_on 'issue comment 5 *' '' 1 'gh: HTTP 502'; fi
  triage_one "$1" >"${TMP}/out" 2>"${TMP}/err"
  echo "$?" >"${TMP}/rc"
}
labelled() { stub_gh_calls | grep -Fq "issue edit 5 $1"; }
marker() { stub_gh_any_body "<!-- agent-triage:$1 -->"; }
check() { if "$@"; then t_pass "${label}"; else t_fail "${label}: $(cat "${TMP}/out")"; fi; }
check_not() { if "$@"; then t_fail "${label}: $(cat "${TMP}/out")"; else t_pass "${label}"; fi; }

tri_case "$(ijson 5 Low)"
label="Low by a writer: agent:ready + size: S"; check labelled '--add-label agent:ready --add-label size: S'
label="with the fast-track marker"; check marker fast-track
first_edit="$(stub_gh_calls | grep -n '^issue edit 5 ' | head -1 | cut -d: -f1)"
first_comment="$(stub_gh_calls | grep -n '^issue comment 5 ' | head -1 | cut -d: -f1)"
if [[ -n "${first_edit}" && -n "${first_comment}" && "${first_edit}" -lt "${first_comment}" ]]; then
  t_pass "the label goes on before the marker"
else
  t_fail "label (${first_edit:-none}) not before marker (${first_comment:-none})"
fi
expect "and the run is fine" "$(cat "${TMP}/rc")" 0
tri_case "$(ijson 5 Medium)"
label="Medium: fast-tracked too"; check marker fast-track
for sev in High Critical; do
  tri_case "$(ijson 5 "${sev}")"
  label="${sev}: agent:candidate"; check labelled '--add-label agent:candidate'
  label="${sev}: not agent:ready"; check_not labelled '--add-label agent:ready'
  label="${sev}: with the candidate marker"; check marker candidate
done
tri_case "$(ijson 5 Low outsider)"
expect_no_call "an issue a read-only collaborator opened is left alone" "issue edit 5"
expect_no_call "and gets no comment" "issue comment 5"
tri_case "$(ijson 5 Low app/repo-agent)"
expect_no_call "an issue the bot opened is left alone" "issue edit 5"
tri_case "$(ijson 5 Low owner-login 'security,agent:hold')"
expect_no_call "an issue with an agent label already is left alone" "issue edit 5"
tri_case "$(ijson 5 Low owner-login 'security' '' CLOSED)"
expect_no_call "a closed issue is left alone" "issue edit 5"
tri_case "$(ijson 5 Low owner-login 'priority: low')"
expect_no_call "a non-security issue is left alone" "issue edit 5"
expect_no_call "without reading its comments" "issues/5/comments"
tri_case "$(ijson 5 Low)" '[{"user":{"login":"repo-agent[bot]"},"body":"<!-- agent-triage:fast-track -->\nqueued"}]'
expect_no_call "triaged before (the bot's marker): never again" "issue edit 5"
tri_case "$(ijson 5 Low)" '[{"user":{"login":"outsider"},"body":"<!-- agent-triage:fast-track -->\nforged"}]'
label="a marker pasted by someone else does not stop triage"; check marker fast-track

XREF='{"event":"cross-referenced","source":{"type":"issue","issue":{"number":850,"repository":{"full_name":"o/r"},"body":"Refs #5","pull_request":{"merged_at":"2026-11-01T00:00:00Z"}}}}'
tri_case "$(ijson 5 Low)" '[]' "[${XREF}]"
label="a merged PR names it: one fixed-on-main comment"; check marker fixed-on-main
expect_no_call "and no label" "issue edit 5"
if stub_gh_any_body '#850'; then t_pass "naming the PR"; else t_fail "the comment does not name #850"; fi
# The scheduled pick skips an issue a merged PR names, so only a dispatch by name can start it.
if stub_gh_any_body 'gh workflow run agent-coder.yml --repo o/r --ref agent-runner -f issue=5'; then
  t_pass "and telling a person to dispatch it by name, the only way it can run"
else
  t_fail "the fixed-on-main comment does not give the dispatch-by-name command"
fi
if stub_gh_any_body "add \`agent:ready\` yourself"; then t_fail "it still says to add agent:ready, which the pick skips"; else t_pass "not to add agent:ready, which the pick skips"; fi
TIMELINE_FAILS=1 tri_case "$(ijson 5 Low)"
expect "an unreadable timeline fails" "$(cat "${TMP}/rc")" 1
expect_no_call "and changes nothing" "issue edit 5"
COMMENT_FAILS=1 VIEW_LABELS=$'security\nagent:ready\nsize: S' tri_case "$(ijson 5 Low)"
expect "a marker that did not post fails the run" "$(cat "${TMP}/rc")" 1
expect_call "and the labels come off again, so the next run retries (the coder never trusts them without it)" \
  "issue edit 5 --remove-label agent:ready --remove-label size: S"
COMMENT_FAILS=1 VIEW_LABELS=$'security\nagent:candidate' tri_case "$(ijson 5 High)"
expect_call "a candidate whose marker did not post loses the label again too" "issue edit 5 --remove-label agent:candidate"

# --- cmd_run ---------------------------------------------------------------------------------------
stub_gh_reset_calls
stub_gh_reset_rules
cmd_run '5;x' >/dev/null 2>&1
expect "a dispatch with a non-number is refused" "$?" 2
expect_no_call "before any call" "issue"
stub_gh_reset_calls
stub_gh_on 'issue list *' ''
cmd_run >/dev/null 2>&1
expect_call "with no issue named, every open security issue is listed" "issue list --state open --label security"

printf '\n[agents-triage] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
