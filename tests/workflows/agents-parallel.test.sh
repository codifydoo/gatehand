#!/usr/bin/env bash
# tests/workflows/agents-parallel.test.sh
# roles.coder.parallelism > 1 (agent-state.sh claims and kick, agent-lib.sh coder slots, the sweep's
# claims part), against a small STATEFUL fake GitHub: unlike agents-gh-stub.sh it keeps refs, so
# concurrent processes really race. Creating a ref is a `mkdir`, atomic like GitHub's ref create.
# Pinned:
#   1. Two runs claiming one issue at once: exactly one wins, every time; the loser is told "taken"
#      (exit 1), and a re-run of the winner (same run id) still holds it.
#   2. Only "already exists" means taken: a 403 on the ref create stops the pick, rather than
#      walking the queue as if every issue were taken.
#   3. Three picks at once over five eligible issues take three DIFFERENT issues, one claim each; a
#      pick that finds the first issue claimed moves to the next.
#   4. Caps after the claim: other runs' claims count towards maxOpenPrs and runsPerDay; a run over
#      either releases its claim and takes nothing. Five picks at once never start more runs than
#      maxOpenPrs leaves room for.
#   5. Release: only the holder's claim is deleted when a run is named; a missing claim is fine.
#   6. The kick with N = 3 and five eligible issues dispatches three runs, into slots 1, 2, 3; it
#      skips busy slots, counts a run without a slot against the room, and stops at the queue and
#      maxOpenPrs; a run GitHub stranded (queued an hour or more, no jobs) holds no slot and no room.
#      coder_pick_slot prefers a free slot, then one with nothing waiting, and the
#      inbox's /approve and /rerun dispatch the coder into it (the fixer gets no slot).
#   7. The sweep deletes the claim of an ended run, keeps one whose run is going, deletes a claim
#      naming no run only once it is older than lockTtlMinutes, and leaves an agent:in-progress issue
#      alone while its claim's run is going.
#   8. Review fixes: the kick counts only issues the pick would not skip (an import whose every
#      location is closed to the coder included); two inbox dispatches in
#      one comment take different slots; of three runs taking a one-unit infra grace at once,
#      exactly one gets it, and the sweep deletes only past days' grace refs.
#   9. End to end with the real ledger script: three runs finalizing at once each land one row,
#      none lost or doubled, and the day's count is three.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-parallel] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-parallel] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export GH_REPO=o/r AGENT_NOW_EPOCH=1793880000 # 2026-11-05T12:00:00Z
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export FAKE="${TMP}/gh-state"
mkdir -p "${FAKE}/refs" "${FAKE}/commits" "${TMP}/bin"
jq '.roles.coder.parallelism = 3 | .roles.coder.maxOpenPrs = 8 | .roles.coder.runsPerDay = 20' \
  "${REPO_ROOT}/.github/agents/policy.json" >"${TMP}/policy.json"
export AGENT_POLICY="${TMP}/policy.json"

# --- the fake gh ---------------------------------------------------------------------------------
cat >"${TMP}/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Answers the calls the claim, the pick's re-read, the caps, the kick and the sweep make. Applies a
# call's --jq to the JSON it would get, as gh does.
S="${FAKE}"
jqx="" prev=""
for a in "$@"; do [[ "${prev}" == --jq ]] && jqx="${a}"; prev="${a}"; done
out() { if [[ -n "${jqx}" ]]; then jq -r "${jqx}"; else cat; fi; }
nf() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
printf '%s\n' "$*" >>"${S}/calls"
case "$*" in
  "api repos/o/r/commits/main --jq "*) echo '{"sha":"base1","commit":{"tree":{"sha":"tree1"}}}' | out ;;
  "api -X POST repos/o/r/git/commits --input - --jq "*)
    # A unique sha from mktemp: "c<pid><random>" could repeat across processes (pid 12 with 345,
    # pid 123 with 45), and a second commit under one sha made the run that lost read its own run id
    # as the claim's owner.
    tmp="$(mktemp "${S}/commits/.cXXXXXXXXXX")"
    sha="${tmp##*/.}"
    body="$(cat)"
    printf '%s\n' "${body}" >"${S}/last-commit-body"
    # Written whole, then renamed: a reader never sees half a file.
    printf '%s\n' "${body}" | jq -c --arg d "${FAKE_DATE:-2026-11-05T11:59:00Z}" '{message, committer: {date: $d}}' >"${tmp}"
    mv "${tmp}" "${S}/commits/${sha}"
    echo "{\"sha\":\"${sha}\"}" | out ;;
  "api -X POST repos/o/r/git/refs --input -")
    [[ -z "${FAKE_REFS_403:-}" ]] || { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
    body="$(cat)"; name="$(jq -r '.ref | sub("^refs/"; "") | gsub("/"; "%")' <<<"${body}")"
    if mkdir "${S}/refs/${name}" 2>/dev/null; then
      jq -r .sha <<<"${body}" >"${S}/refs/${name}/.sha.$$" && mv "${S}/refs/${name}/.sha.$$" "${S}/refs/${name}/sha"; echo '{}'
    else echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; fi ;;
  "api repos/o/r/git/ref/"*)
    name="$(sed 's#^api repos/o/r/git/ref/##; s# .*##; s#/#%#g' <<<"$*")"
    [[ -s "${S}/refs/${name}/sha" ]] || nf
    jq -n --arg s "$(cat "${S}/refs/${name}/sha")" '{object: {sha: $s}}' | out ;;
  "api repos/o/r/git/commits/"*)
    sha="$(sed 's#^api repos/o/r/git/commits/##; s# .*##' <<<"$*")"
    [[ -f "${S}/commits/${sha}" ]] || nf
    out <"${S}/commits/${sha}" ;;
  "api -X DELETE repos/o/r/git/refs/"*)
    name="$(sed 's#^api -X DELETE repos/o/r/git/refs/##; s#/#%#g' <<<"$*")"
    rm -rf "${S}/refs/${name}.gone"
    mv "${S}/refs/${name}" "${S}/refs/${name}.gone" 2>/dev/null || { echo "gh: Reference does not exist (HTTP 422)" >&2; exit 1; }
    rm -rf "${S}/refs/${name}.gone" ;;
  "api --paginate repos/o/r/git/matching-refs/agent-locks/grace/ --jq "*)
    (cd "${S}/refs" && for d in agent-locks%grace%*; do [[ -d "${d}" && "${d}" != *.gone ]] && printf 'refs/%s\n' "${d//%//}"; done) \
      | jq -R '{ref: .}' | jq -s . | out ;;
  "api --paginate repos/o/r/git/matching-refs/agent-locks/issue- --jq "*)
    (cd "${S}/refs" && for d in agent-locks%issue-*; do [[ -d "${d}" && "${d}" != *.gone ]] && printf 'refs/%s\n' "${d//%//}"; done) \
      | jq -R '{ref: .}' | jq -s . | out ;;
  "issue list --state open --label agent:ready "*)
    jq '[.[] | select(.state == "OPEN" and ([.labels[].name] | index("agent:ready")))]' "${S}/issues.json" | out ;;
  "issue view "*)
    n="$(awk '{print $3}' <<<"$*")"
    jq --argjson n "${n}" '.[] | select(.number == $n)' "${S}/issues.json" | out ;;
  "pr list --state open --label agent:pr "*) out <"${S}/prs.json" ;;
  "api -H Accept: application/vnd.github.raw repos/o/r/contents/runs/"*)
    [[ -f "${S}/runs.jsonl" ]] || nf
    cat "${S}/runs.jsonl" ;;
  "api repos/o/r/actions/workflows/agent-coder.yml/runs?event=workflow_dispatch&per_page=100 --jq "*) out <"${S}/workflow-runs.json" ;;
  "workflow run agent-coder.yml "*) printf '%s\n' "$*" >>"${S}/dispatches" ;;
  "api repos/o/r/actions/runs/"*"/jobs?per_page=1 --jq "*)
    id="$(sed 's#^api repos/o/r/actions/runs/##; s#/jobs.*##' <<<"$*")"
    [[ -f "${S}/jobs-${id}.json" ]] || nf
    out <"${S}/jobs-${id}.json" ;;
  "api repos/o/r/actions/runs/"*)
    id="$(sed 's#^api repos/o/r/actions/runs/##; s# .*##' <<<"$*")"
    [[ -f "${S}/run-${id}.json" ]] || nf
    out <"${S}/run-${id}.json" ;;
  *) echo "fake gh: no answer for: $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"

export AGENT_STATE_NO_MAIN=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-state.sh"
set +e
# The trust checks before the claim are agents-state.test.sh's; here every candidate passes them.
labeler_trusted() { return 0; }
merged_prs_referencing() { return 0; }
stop_blockers() { return 0; }

issue_json() { # issue_json <n>...: open agent:ready issues with an acceptance section
  local n
  for n in "$@"; do
    jq -n --argjson n "${n}" '{number: $n, state: "OPEN", title: "t\($n)", body: "x\n\n## Done when\n\n- y",
      labels: [{name: "agent:ready"}], createdAt: "2026-11-0\($n % 9 + 1)T00:00:00Z", comments: []}'
  done | jq -s .
}
reset_fake() { # reset_fake <open-prs> <ledger-rows-today> <issue>...
  rm -rf "${FAKE}/refs" "${FAKE}/calls" "${FAKE}/dispatches" "${FAKE}/runs.jsonl"
  mkdir -p "${FAKE}/refs"
  jq -n --argjson k "$1" '[range(0; $k) | {number: (100 + .)}]' >"${FAKE}/prs.json"
  local i
  for ((i = 0; i < $2; i++)); do
    printf '{"role":"coder","started_at":"2026-11-05T0%s:00:00Z"}\n' "$((i % 9))" >>"${FAKE}/runs.jsonl"
  done
  shift 2
  issue_json "$@" >"${FAKE}/issues.json"
  echo '{"workflow_runs":[]}' >"${FAKE}/workflow-runs.json"
}
claims() { (cd "${FAKE}/refs" && for d in agent-locks%issue-*; do [[ -d "${d}" ]] && echo "${d##*-}"; done) | sort -n | paste -sd' ' -; }
# pick_as <run-id> [issue]: a pick in its own process, as its own run; prints the issue it took.
pick_as() {
  local o="${TMP}/out.$1"
  : >"${o}"
  (RUN_ID="$1" GITHUB_OUTPUT="${o}" cmd_pick "${2:-}" >/dev/null 2>&1)
  sed -n 's/^issue=//p' "${o}" | tail -1
}

# --- 1. one claim, two runs -----------------------------------------------------------------------
reset_fake 0 0 5
wins=0 losses=0 other=0 bad=""
for round in $(seq 1 "${CLAIM_ROUNDS:-8}"); do
  rm -rf "${FAKE}/refs" && mkdir -p "${FAKE}/refs"
  (RUN_ID="a${round}" claim_issue 5 2>/dev/null; echo $? >"${TMP}/rc.a") &
  (RUN_ID="b${round}" claim_issue 5 2>/dev/null; echo $? >"${TMP}/rc.b") &
  wait
  case "$(cat "${TMP}/rc.a")$(cat "${TMP}/rc.b")" in
    01 | 10) wins=$((wins + 1)) ;;
    *) other=$((other + 1)); bad+=" (round ${round}: rc $(cat "${TMP}/rc.a")$(cat "${TMP}/rc.b"))" ;;
  esac
done
expect "claim race: in every round exactly one of two runs wins and the other is told taken" "${wins}/${other}${bad}" "${CLAIM_ROUNDS:-8}/0"
rm -rf "${FAKE}/refs" && mkdir -p "${FAKE}/refs"
RUN_ID=77 claim_issue 5 2>/dev/null
RUN_ID=77 claim_issue 5 2>/dev/null
expect "claim: a re-run of the holder (same run id) still holds it" "$?" 0
RUN_ID=78 claim_issue 5 2>/dev/null
expect "claim: another run is told taken" "$?" 1
expect "claim_owner names the holder" "$(claim_owner 5 | cut -d' ' -f1)" 77
expect "the claim commit is a child of the base tip with its tree, so it changes no file" \
  "$(jq -c '[.parents, .tree]' "${FAKE}/last-commit-body")" '[["base1"],"tree1"]'

# --- 2. a 403 is not "taken" ----------------------------------------------------------------------
reset_fake 0 0 1 2 3
got="$(FAKE_REFS_403=1 pick_as 300)"
expect "403: the pick takes nothing" "${got}" ""
FAKE_REFS_403=1 RUN_ID=300 GITHUB_OUTPUT=/dev/null cmd_pick >/dev/null 2>&1
expect "403: and fails, so preflight stops red" "$?" 1
expect "403: it tried the first issue only, not the whole queue" "$(grep -c 'git/refs --input' "${FAKE}/calls")" 2

# --- 3. three picks at once -----------------------------------------------------------------------
reset_fake 0 0 1 2 3 4 5
for r in 401 402 403; do (pick_as "${r}" >"${TMP}/took.${r}") & done
wait
took="$(cat "${TMP}/took.401" "${TMP}/took.402" "${TMP}/took.403" | sort -n | paste -sd' ' -)"
expect "three picks at once take three issues" "$(wc -w <<<"${took}" | tr -d ' ')" 3
expect "and three different ones" "$(tr ' ' '\n' <<<"${took}" | sort -u | grep -c .)" 3
expect "one claim per issue taken, no other" "$(claims)" "${took}"
reset_fake 0 0 1 2
RUN_ID=999 claim_issue 1 2>/dev/null
expect "a pick that finds the first issue claimed moves to the next" "$(pick_as 410)" 2
expect "and the attempt comes from the issue read after the claim" "$(sed -n 's/^attempt=//p' "${TMP}/out.410")" 1

# --- 4. caps after the claim ----------------------------------------------------------------------
reset_fake 6 0 1 2 3
RUN_ID=901 claim_issue 2 2>/dev/null
RUN_ID=902 claim_issue 3 2>/dev/null
expect "maxOpenPrs: 6 open PRs and 2 other claims of 8 leave no room" "$(pick_as 420)" ""
expect "and the run released its claim" "$(claims)" "2 3"
reset_fake 0 19 1 2
RUN_ID=903 claim_issue 2 2>/dev/null
expect "runsPerDay: 19 runs today and 1 other claim of 20 leave no room" "$(pick_as 421)" ""
expect "and the run released its claim" "$(claims)" "2"
reset_fake 0 18 1 2
RUN_ID=904 claim_issue 2 2>/dev/null
expect "runsPerDay: 18 today and 1 other claim of 20 leave room for this one" "$(pick_as 422)" 1
jq '.roles.coder.maxOpenPrs = 3' "${TMP}/policy.json" >"${TMP}/policy3.json"
reset_fake 1 0 1 2 3 4 5
for r in 431 432 433 434 435; do (AGENT_POLICY="${TMP}/policy3.json" pick_as "${r}" >"${TMP}/took.${r}") & done
wait
started="$(cat "${TMP}"/took.43? | grep -c .)"
if [[ "${started}" -le 2 ]]; then t_pass "five picks at once with room for 2 (1 open PR of 3) start ${started}, never more"
else t_fail "five picks at once with room for 2 started ${started}"; fi
expect "and only the runs that went on still hold claims" "$(claims | wc -w | tr -d ' ')" "${started}"

# --- 5. release -------------------------------------------------------------------------------------
reset_fake 0 0 5
RUN_ID=501 claim_issue 5 2>/dev/null
release_claim 5 502 2>/dev/null
expect "release naming another run leaves the claim" "$(claims)" 5
release_claim 5 501 2>/dev/null
expect "release by the holder deletes it" "$(claims)" ""
release_claim 5 501 2>/dev/null
expect "releasing a claim already gone is fine" "$?" 0

# --- 6. the kick and the slots -----------------------------------------------------------------------
runs_json() { jq -n --argjson r "$1" '{workflow_runs: $r}' >"${FAKE}/workflow-runs.json"; }
reset_fake 0 0 1 2 3 4 5
cmd_kick >/dev/null 2>&1
expect "kick: N = 3 and five queued issues dispatch three runs" "$(grep -c . "${FAKE}/dispatches")" 3
expect "kick: into slots 1, 2 and 3" "$(grep -oE 'slot=[0-9]+' "${FAKE}/dispatches" | paste -sd' ' -)" "slot=1 slot=2 slot=3"
reset_fake 0 0 1 2 3 4 5
runs_json '[{"status":"in_progress","display_title":"Agent coder: auto pick (slot 2)"}]'
cmd_kick >/dev/null 2>&1
expect "kick: a busy slot is skipped" "$(grep -oE 'slot=[0-9]+' "${FAKE}/dispatches" | paste -sd' ' -)" "slot=1 slot=3"
reset_fake 0 0 1 2 3 4 5
runs_json '[{"status":"in_progress","display_title":"Agent coder: issue 9"}]'
cmd_kick >/dev/null 2>&1
expect "kick: a run without a slot holds no slot but counts against the room" "$(grep -c . "${FAKE}/dispatches")" 2
stranded_slot2='[{"id":61,"status":"queued","created_at":"2026-11-05T10:00:00Z","display_title":"Agent coder: auto pick (slot 2)"}]'
reset_fake 0 0 1 2 3 4 5
runs_json "${stranded_slot2}"
echo '{"total_count":0}' >"${FAKE}/jobs-61.json"
cmd_kick >/dev/null 2>&1
expect "kick: a run GitHub stranded in slot 2 (queued 2 h, no jobs) holds no slot and no room" \
  "$(grep -oE 'slot=[0-9]+' "${FAKE}/dispatches" | paste -sd' ' -)" "slot=1 slot=2 slot=3"
reset_fake 0 0 1 2 3 4 5
runs_json "${stranded_slot2}"
echo '{"total_count":1}' >"${FAKE}/jobs-61.json"
cmd_kick >/dev/null 2>&1
expect "kick: the same run with a job still holds slot 2" "$(grep -oE 'slot=[0-9]+' "${FAKE}/dispatches" | paste -sd' ' -)" "slot=1 slot=3"
rm -f "${FAKE}/jobs-61.json"
reset_fake 0 0 1
cmd_kick >/dev/null 2>&1
expect "kick: no more runs than queued issues" "$(grep -c . "${FAKE}/dispatches")" 1
reset_fake 7 0 1 2 3 4 5
cmd_kick >/dev/null 2>&1
expect "kick: no more runs than maxOpenPrs leaves room for (7 open of 8)" "$(grep -c . "${FAKE}/dispatches")" 1
reset_fake 0 0 1 2 3
runs_json '[{"status":"in_progress","display_title":"x (slot 1)"},{"status":"queued","display_title":"x (slot 2)"},{"status":"in_progress","display_title":"x (slot 3)"}]'
cmd_kick >/dev/null 2>&1
expect "kick: every slot busy, nothing dispatched" "$(cat "${FAKE}/dispatches" 2>/dev/null | grep -c .)" 0
expect "pick_slot: all busy, the first slot with nothing waiting" "$(coder_pick_slot)" 1
runs_json '[{"status":"in_progress","display_title":"x (slot 1)"}]'
expect "pick_slot: the first free slot" "$(coder_pick_slot)" 2
expect "pick_slot: nothing with N = 1" "$(AGENT_POLICY="${REPO_ROOT}/.github/agents/policy.json" coder_pick_slot)" ""
rm -f "${FAKE}/dispatches"
(AGENT_INBOX_NO_MAIN=1 source "${REPO_ROOT}/.github/scripts/agent-inbox.sh" && dispatch coder 7) >/dev/null 2>&1
expect "inbox: /approve dispatches the coder into the free slot" "$(cat "${FAKE}/dispatches" 2>/dev/null)" \
  "workflow run agent-coder.yml --ref agent-runner -f issue=7 -f slot=2"

# --- 7. the sweep -----------------------------------------------------------------------------------
# shellcheck source=/dev/null
AGENT_SWEEP_NO_MAIN=1 source "${REPO_ROOT}/.github/scripts/agent-sweep.sh"
set +e
labeler_trusted() { return 0; }
reset_fake 0 0 1 2
RUN_ID=701 claim_issue 1 2>/dev/null
RUN_ID=702 claim_issue 2 2>/dev/null
echo '{"status":"completed","conclusion":"cancelled","run_started_at":"2026-11-05T11:00:00Z"}' >"${FAKE}/run-701.json"
echo '{"status":"in_progress","conclusion":null,"run_started_at":"2026-11-05T11:00:00Z"}' >"${FAKE}/run-702.json"
sweep_claims >/dev/null 2>&1
expect "sweep: the claim of an ended run is deleted, one of a run going stays" "$(claims)" 2
expect "sweep: an agent:in-progress issue whose claim's run is going is left alone" "$(claim_run_going 2; echo $?)" 0
expect "sweep: one with no claim is swept as before" "$(claim_run_going 1; echo $?)" 1
reset_fake 0 0 3
jq -n '{message: "agent-claim issue=3 at=x", committer: {date: "2026-11-05T11:00:00Z"}}' >"${FAKE}/commits/manual"
mkdir -p "${FAKE}/refs/agent-locks%issue-3" && echo manual >"${FAKE}/refs/agent-locks%issue-3/sha"
sweep_claims >/dev/null 2>&1
expect "sweep: a claim naming no run, an hour old, waits for lockTtlMinutes" "$(claims)" 3
AGENT_NOW_EPOCH=$((AGENT_NOW_EPOCH + 3 * 3600)) sweep_claims >/dev/null 2>&1
expect "sweep: and is deleted past it" "$(claims)" ""

# --- 8. review fixes ----------------------------------------------------------------------------------
reset_fake 0 0 1 2 3
jq '(.[] | select(.number != 1) | .body) = "no acceptance section"' "${FAKE}/issues.json" >"${FAKE}/i" && mv "${FAKE}/i" "${FAKE}/issues.json"
cmd_kick >/dev/null 2>&1
expect "kick: issues the pick would skip start no runs (1 of 3 takeable)" "$(grep -c . "${FAKE}/dispatches")" 1
# Nor issues whose every location is closed to the coder (agent-state.sh locations_closed).
reset_fake 0 0 1 2 3
jq '(.[] | select(.number != 1) | .body) = "> Imported from Claude Security.\n\n## Locations\n\n- [`.github/workflows/a.yml:1-2`](u)\n\n## Recommendation\n\nx"' \
  "${FAKE}/issues.json" >"${FAKE}/i" && mv "${FAKE}/i" "${FAKE}/issues.json"
cmd_kick >/dev/null 2>&1
expect "kick: issues whose every location is closed start no runs (1 of 3 takeable)" "$(grep -c . "${FAKE}/dispatches")" 1
reset_fake 0 0 7 8
(
  AGENT_INBOX_NO_MAIN=1 source "${REPO_ROOT}/.github/scripts/agent-inbox.sh"
  dispatch coder 7 && dispatch coder 8
) >/dev/null 2>&1
expect "inbox: two /approve in one comment take two different free slots" "$(grep -oE 'slot=[0-9]+' "${FAKE}/dispatches" | paste -sd' ' -)" "slot=1 slot=2"
reset_fake 0 0
jq '.roles.coder.infraGracePerDay = 1' "${TMP}/policy.json" >"${TMP}/policy-g.json"
for r in g1 g2 g3; do (AGENT_POLICY="${TMP}/policy-g.json" take_infra_grace coder 2026-11-05 2>/dev/null; echo $? >"${TMP}/grace.${r}") & done
wait
expect "infra grace of 1: of three runs at once exactly one takes it" "$(cat "${TMP}"/grace.g? | sort | paste -sd' ' -)" "0 2 2"
mkdir -p "${FAKE}/refs/agent-locks%grace%coder%2026-11-04%1"
sweep_grace_refs 2>/dev/null
expect "sweep: past days' grace refs are deleted, today's stay" \
  "$(cd "${FAKE}/refs" && ls -d agent-locks%grace%* | paste -sd' ' -)" "agent-locks%grace%coder%2026-11-05%1"

# --- 9. three runs finalize at once -----------------------------------------------------------------
git init -q --bare "${TMP}/ledger.git"
for r in 801 802 803; do
  (LEDGER_REMOTE="${TMP}/ledger.git" AGENT_LEDGER_BACKOFF=0 bash "${REPO_ROOT}/.github/scripts/agent-ledger.sh" append \
    "{\"role\":\"coder\",\"run_id\":\"${r}\",\"outcome\":\"pr-opened\",\"started_at\":\"2026-11-05T11:00:00Z\"}" >/dev/null 2>&1) &
done
wait
rows="$(git --git-dir="${TMP}/ledger.git" show agent-ledger:runs/2026-11.jsonl 2>/dev/null)"
expect "three finalizes at once: every run has exactly one row" "$(jq -rs 'map(.run_id) | sort | join(",")' <<<"${rows}")" "801,802,803"
expect "and the day counts three runs" "$(runs_on_day "${rows}" coder 2026-11-05)" 3

printf '\n[agents-parallel] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
