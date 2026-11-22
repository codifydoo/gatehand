#!/usr/bin/env bash
# tests/doctor/doctor.test.sh: bin/doctor.sh's check that the sweep runs on its schedule, against a
# stubbed gh. GitHub reports nothing when a cron does not fire, so the doctor is the only place that
# notices; what is pinned is that it warns only when it should:
#   1. The time agent-sweep.yml reached the default branch is the merge time of the PR that brought it
#      (a merge commit keeps the feature branch's older date), else the commit's own date.
#   2. Two hours with no scheduled run warns; under two hours, or any scheduled run, does not.
#   3. A sweep schedule that is not hourly is not checked; an unreadable one, or a failing API, warns.
#   4. With claude.agentAuth set apart from claude.auth, the agents' own secret is checked as well:
#      a dedicated key the coder and fixer need but nobody set is a FAIL, not a silent outage.
#   5. An inbox pinned by AGENT_INBOX_ISSUE is never replaced (agent-lib.sh inbox_issue), so the
#      doctor warns once it has policy.inboxRotateAt comments (2,000 when unset), before GitHub's
#      ~2,500 cap stops it; under the threshold it is ok, and an unreadable count warns.
#   6. roles.coder.parallelism > 1: GitHub-hosted agent runners are ok; a self-hosted pool with
#      fewer online runners carrying runners.agent's labels than slots warns, as do unlistable
#      runners and a maxOpenPrs below the slots. Parallelism 1 says nothing.
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0 fail=0
t_pass() { printf '\033[1;32m[doctor] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[doctor] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/r" && git -C "${TMP}/r" init -q -b main && "${PKG}/bin/render.sh" "${TMP}/r" >/dev/null
ago() { jq -rn --argjson h "$1" '(now - $h * 3600) | todate'; }

# The stub answers only the calls the schedule check makes, from STUB_* variables; every other gh call
# fails, which the doctor already treats as a WARN or FAIL of its own check.
gh() {
  case "$*" in
    "repo view --json nameWithOwner --jq .nameWithOwner") echo o/r ;;
    "repo view --json defaultBranchRef --jq .defaultBranchRef.name") echo main ;;
    "api --paginate repos/o/r/commits?sha=main&path=.github/workflows/agent-sweep.yml&per_page=100 "*)
      [[ "${STUB_COMMITS:-}" == fail ]] && return 1
      printf '%s\n' "${STUB_COMMITS:-}" ;;
    "api repos/o/r/commits/"*"/pulls") [[ "${STUB_PULLS:-}" == fail ]] && return 1; printf '%s\n' "${STUB_PULLS:-[]}" ;;
    "api repos/o/r/actions/workflows/agent-sweep.yml/runs?event=schedule&per_page=1 "*) printf '%s\n' "${STUB_FIRED:-0}" ;;
    "secret list --repo o/r --json name --jq .[].name") printf '%s\n' ${STUB_SECRETS:-} ;;
    "variable list --repo o/r --json name,value") [[ -n "${STUB_PIN:-}" ]] || return 1
      printf '[{"name":"AGENT_INBOX_ISSUE","value":"%s"}]\n' "${STUB_PIN#none}" ;;
    "api --paginate repos/o/r/actions/runners --jq .runners[]") [[ -n "${STUB_RUNNERS:-}" ]] || return 1
      jq -c '.[]' <<<"${STUB_RUNNERS}" ;;
    "api repos/o/r/issues/${STUB_PIN:-x} --jq .comments") [[ "${STUB_COUNT:-}" == fail ]] && return 1; printf '%s\n' "${STUB_COUNT:-0}" ;;
    *) return 1 ;;
  esac
}
export -f gh
sweep_line() { bash "${PKG}/bin/doctor.sh" "${TMP}/r" 2>/dev/null | grep -E '^(ok|WARN|FAIL) .*sweep' | head -1; }
case_is() {
  local label="$1" want="$2" got
  got="$(sweep_line)"
  if [[ "${got}" =~ ${want} ]]; then t_pass "${label}"; else t_fail "${label}: got '${got}'"; fi
}
pr() { printf '[{"number":1,"merged_at":"%s","base":{"ref":"%s"}}]' "$1" "${2:-main}"; }

export STUB_COMMITS STUB_PULLS STUB_FIRED
STUB_COMMITS="aaa $(ago 5)" STUB_PULLS="$(pr "$(ago 1)")" STUB_FIRED=0
case_is "a PR merged 1 h ago counts from the merge, not the commit 5 h ago" '^ok +agent-sweep.yml reached main under 2 h ago'
STUB_PULLS='[]'
case_is "a direct push 5 h ago with no scheduled run warns" '^WARN +the sweep has never run on its schedule in the 5 h'
STUB_PULLS="$(pr "$(ago 1)" develop)"
case_is "a PR into another branch does not count as reaching main" '^WARN +.* in the 5 h'
STUB_PULLS=fail
case_is "a failing pulls call falls back to the commit's date" '^WARN +.* in the 5 h'
STUB_COMMITS="newer $(ago 1)"$'\n'"oldest $(ago 9)" STUB_PULLS='[]'
case_is "the oldest commit is the one that counts" '^WARN +.* in the 9 h'
STUB_FIRED=3
case_is "any scheduled run is fine" '^ok +the sweep has run on its schedule'
STUB_FIRED=0 STUB_COMMITS=fail
case_is "a failing commits call cannot tell" '^WARN +cannot tell whether the sweep runs on its schedule'
STUB_COMMITS=""
case_is "no agent-sweep.yml on main cannot tell" '^WARN +cannot tell'

P="${TMP}/r/.github/agents/policy.json"
cp "${P}" "${TMP}/policy"
jq '.schedules.sweep = "41 9 * * 1-5"' "${TMP}/policy" >"${P}"
STUB_COMMITS="aaa $(ago 5)"
case_is "a schedule that is not hourly is not checked" '^ok +the sweep.s schedule \(41 9 \* \* 1-5\) is not hourly'
jq '.schedules.sweep = null' "${TMP}/policy" >"${P}"
case_is "an unreadable sweep schedule warns" '^WARN +cannot read schedules.sweep'
cp "${TMP}/policy" "${P}"

# --- 4 ---------------------------------------------------------------------------------------------
cred_lines() { bash "${PKG}/bin/doctor.sh" "${TMP}/r" 2>/dev/null | grep -E '^(ok|WARN|FAIL) +secret (CLAUDE|ANTHROPIC)'; }
cred_is() {
  local label="$1" want="$2" got
  got="$(cred_lines | tr '\n' '|')"
  if [[ "${got}" == "${want}" ]]; then t_pass "${label}"; else t_fail "${label}: got '${got}'"; fi
}
export STUB_SECRETS
STUB_SECRETS="CLAUDE_CODE_OAUTH_TOKEN"
cred_is "no agentAuth: one credential, checked once" 'ok    secret CLAUDE_CODE_OAUTH_TOKEN is set|'
jq '.claude.agentAuth = "oauth"' "${TMP}/policy" >"${P}" && "${PKG}/bin/render.sh" "${TMP}/r" >/dev/null
cred_is "agentAuth equal to auth: still checked once" 'ok    secret CLAUDE_CODE_OAUTH_TOKEN is set|'
jq '.claude.agentAuth = "api-key"' "${TMP}/policy" >"${P}" && "${PKG}/bin/render.sh" "${TMP}/r" >/dev/null
cred_is "agentAuth api-key without its secret fails" 'ok    secret CLAUDE_CODE_OAUTH_TOKEN is set|FAIL  secret ANTHROPIC_API_KEY_AGENTS is not set (policy.json claude.agentAuth)|'
STUB_SECRETS="CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY_AGENTS"
cred_is "...and passes once it is set" 'ok    secret CLAUDE_CODE_OAUTH_TOKEN is set|ok    secret ANTHROPIC_API_KEY_AGENTS is set|'
STUB_SECRETS="ANTHROPIC_API_KEY_AGENTS"
cred_is "...and the review's own credential is still required" 'FAIL  secret CLAUDE_CODE_OAUTH_TOKEN is not set (policy.json claude.auth)|ok    secret ANTHROPIC_API_KEY_AGENTS is set|'
cp "${TMP}/policy" "${P}" && "${PKG}/bin/render.sh" "${TMP}/r" >/dev/null

# --- 5. a pinned inbox near GitHub's comment cap ---------------------------------------------------
pin_line() { bash "${PKG}/bin/doctor.sh" "${TMP}/r" 2>/dev/null | grep -E '^(ok|WARN|FAIL) .*AGENT_INBOX_ISSUE' | head -1; }
pin_is() {
  local got
  got="$(pin_line)"
  if [[ "${got}" =~ $2 ]]; then t_pass "$1"; else t_fail "$1: got '${got}'"; fi
}
export STUB_PIN STUB_COUNT
STUB_PIN=7 STUB_COUNT=1999
pin_is "a pinned inbox under 2,000 comments is ok" '^ok +AGENT_INBOX_ISSUE pins inbox #7 \(1999 comments\)'
STUB_COUNT=2000
pin_is "a pinned inbox at 2,000 comments warns" '^WARN +AGENT_INBOX_ISSUE pins inbox #7, which has 2000 comments'
jq '.inboxRotateAt = 3000' "${TMP}/policy" >"${P}"
pin_is "policy.inboxRotateAt moves the threshold" '^ok +AGENT_INBOX_ISSUE pins inbox #7'
jq 'del(.inboxRotateAt)' "${TMP}/policy" >"${P}"
pin_is "without inboxRotateAt in policy.json the threshold is 2,000" '^WARN +AGENT_INBOX_ISSUE pins inbox #7, which has 2000 comments \(inboxRotateAt is 2000\)'
cp "${TMP}/policy" "${P}"
STUB_COUNT=fail
pin_is "an unreadable count warns" '^WARN +cannot read the comment count of the inbox AGENT_INBOX_ISSUE pins \(#7\)'
STUB_PIN=none
if [[ -z "$(pin_line)" ]]; then t_pass "a readable variable list without the pin: no inbox line"; else t_fail "no pin, no inbox line: got '$(pin_line)'"; fi
STUB_PIN=""

# --- 6. parallel coder runs ------------------------------------------------------------------------
par_lines() { bash "${PKG}/bin/doctor.sh" "${TMP}/r" 2>/dev/null | grep -E '^(ok|WARN|FAIL) .*(parallelism|runners.agent)'; }
par_is() {
  local got
  got="$(par_lines)"
  if [[ "${got}" =~ $2 ]]; then t_pass "$1"; else t_fail "$1: got '${got}'"; fi
}
export STUB_RUNNERS
if [[ -z "$(par_lines)" ]]; then t_pass "parallelism 1: no parallelism line"; else t_fail "parallelism 1 said: $(par_lines)"; fi
jq '.roles.coder.parallelism = 3 | .roles.coder.maxOpenPrs = 8' "${TMP}/policy" >"${P}"
par_is "GitHub-hosted agent runners are ok" '^ok +roles.coder.parallelism is 3; runners.agent is GitHub-hosted'
jq '.roles.coder.parallelism = 3 | .roles.coder.maxOpenPrs = 2' "${TMP}/policy" >"${P}"
par_is "maxOpenPrs below the slots warns" '^WARN +roles.coder.parallelism is 3 but maxOpenPrs is 2'
jq '.roles.coder.parallelism = 3 | .roles.coder.maxOpenPrs = 8 | .runners.agent = ["self-hosted", "x-agent"]' "${TMP}/policy" >"${P}"
run() { jq -n --argjson id "$1" --arg s "$2" --argjson l "$3" '{id: $id, status: $s, labels: ($l | map({name: .}))}'; }
STUB_RUNNERS="$(jq -s . <<<"$(run 1 online '["self-hosted","x-agent"]') $(run 2 online '["self-hosted","x-agent","linux"]') $(run 3 offline '["self-hosted","x-agent"]') $(run 4 online '["self-hosted","x-ci"]')")"
par_is "two of the agent pool online for three slots warns" '^WARN +roles.coder.parallelism is 3, but only 2 runners with runners.agent.s labels self-hosted, x-agent are online'
STUB_RUNNERS="$(jq -s . <<<"$(run 1 online '["self-hosted","x-agent"]') $(run 2 online '["self-hosted","x-agent"]') $(run 3 online '["self-hosted","x-agent"]')")"
par_is "three online for three slots is ok" '^ok +roles.coder.parallelism is 3; 3 runners with runners.agent.s labels are online'
STUB_RUNNERS=""
par_is "runners that cannot be listed warn" '^WARN +roles.coder.parallelism is 3, and the self-hosted runners for runners.agent cannot be listed'
cp "${TMP}/policy" "${P}"

printf '\n[doctor] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
