#!/usr/bin/env bash
# tests/doctor/doctor.test.sh: bin/doctor.sh's check that the sweep runs on its schedule, against a
# stubbed gh. GitHub reports nothing when a cron does not fire, so the doctor is the only place that
# notices; what is pinned is that it warns only when it should:
#   1. The time agent-sweep.yml reached the default branch is the merge time of the PR that brought it
#      (a merge commit keeps the feature branch's older date), else the commit's own date.
#   2. Two hours with no scheduled run warns; under two hours, or any scheduled run, does not.
#   3. A sweep schedule that is not hourly is not checked; an unreadable one, or a failing API, warns.
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

printf '\n[doctor] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
