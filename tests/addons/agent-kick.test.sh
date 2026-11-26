#!/usr/bin/env bash
# tests/addons/agent-kick.test.sh: addons/hardened-runner/agent-kick.sh, the systemd timers that
# dispatch the scheduled workflows from an always-on box. It is not rendered into a repository, so
# this suite runs the package's copy, against a stub curl and systemctl on PATH.
# Pinned, and why:
#   1. With AGENT_KICK_CODER_SLOTS=1 (the default) the coder kick is unchanged: one dispatch with no
#      inputs, and none while a coder run is queued or running, because a second pending run in the
#      one concurrency group would cancel a person's named dispatch.
#   2. With N > 1 it dispatches one run per free slot, each with inputs.slot, reading the busy slots
#      from the titles of the dispatched runs that have not completed; a completed run frees its
#      slot, and a run without a slot in its title holds a runner, so it lowers the count. Without
#      this the kicker started one run at a time at any parallelism (tabulark, 2026-11-22).
#   3. Every slot busy: no dispatch. One failed dispatch of several still exits 0; all failed exits 1.
#   4. A bad AGENT_KICK_CODER_SLOTS stops the run before any API call, and stops install.
#   5. install writes AGENT_KICK_CODER_SLOTS into the service, with a start timeout that covers the
#      listing, up to 3 stranded-run jobs lookups and
#      1 + N API calls.
#   6. The token reaches curl on stdin, never in its arguments.
#   (1b) A run GitHub stranded (queued 60 minutes or more, no jobs) is not counted at either N, and
#      is named in the journal; a fresh, running, job-holding or unreadable one still is (the same
#      rule as agent-lib.sh coder_unfinished_runs). At most 3 runs get a jobs lookup; past that an old
#      queued run still counts, so the start timeout holds.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KICK="${PKG}/addons/hardened-runner/agent-kick.sh"

pass=0 fail=0
t_pass() { printf '\033[1;32m[kick] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[kick] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: want [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/creds"
printf 'ghp_testtoken123\n' >"${TMP}/creds/token"

# curl: logs "METHOD PATH DATA" per call to ${TMP}/calls, answers a runs listing from ${TMP}/runs.json
# and a dispatch with ${TMP}/dispatch-codes (one HTTP code per line, consumed in order; 204 after).
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" method=GET data="" url="" argv="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -w | -H | --max-time | --retry | --retry-max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
hdr="$(cat)"
[[ "${hdr}" == "Authorization: Bearer ghp_testtoken123" ]] || echo "bad-stdin" >>"${TMP_DIR}/calls"
[[ "${argv}" != *ghp_testtoken123* ]] || echo "token-in-argv" >>"${TMP_DIR}/calls"
path="${url#https://api.github.com}"
printf '%s %s %s\n' "${method}" "${path}" "${data}" >>"${TMP_DIR}/calls"
if [[ "${method}" == GET && "${path}" =~ ^/repos/o/r/actions/runs/([0-9]+)/jobs ]]; then
  f="${TMP_DIR}/jobs-${BASH_REMATCH[1]}.json"
  if [[ -f "${f}" ]]; then cp "${f}" "${out}"; cat "${TMP_DIR}/jobs-${BASH_REMATCH[1]}.code" 2>/dev/null || printf 200
  else printf '{"message":"Not Found"}' >"${out}"; printf 404; fi
elif [[ "${method}" == GET ]]; then
  cp "${TMP_DIR}/runs.json" "${out}"; printf 200
else
  code=204
  if [[ -s "${TMP_DIR}/dispatch-codes" ]]; then
    code="$(head -1 "${TMP_DIR}/dispatch-codes")"; sed -i.bak 1d "${TMP_DIR}/dispatch-codes"
  fi
  [[ "${code}" == 204 ]] && : >"${out}" || printf '{"message":"Unexpected inputs provided"}' >"${out}"
  printf '%s' "${code}"
fi
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP}/bin/systemctl"
chmod +x "${TMP}/bin/curl" "${TMP}/bin/systemctl"

# runs <title:status>...: the dispatched coder runs the listing returns.
runs() {
  local r t s first=1
  printf '{"workflow_runs":[' >"${TMP}/runs.json"
  for r in "$@"; do
    t="${r%:*}" s="${r##*:}"
    [[ "${first}" == 1 ]] || printf ',' >>"${TMP}/runs.json"
    first=0
    printf '{"display_title":"%s","status":"%s"}' "${t}" "${s}" >>"${TMP}/runs.json"
  done
  printf ']}' >>"${TMP}/runs.json"
}

# kick <slots>: run the coder kick; sets rc and out, and calls holds the API calls made.
kick() {
  : >"${TMP}/calls"
  out="$(PATH="${TMP}/bin:${PATH}" TMP_DIR="${TMP}" CREDENTIALS_DIRECTORY="${TMP}/creds" \
    AGENT_KICK_REPO=o/r AGENT_KICK_CODER_SLOTS="$1" bash "${KICK}" run coder 2>&1)"
  rc=$?
  calls="$(cat "${TMP}/calls")"
}
dispatches() { grep -c '^POST ' <<<"${calls}" || true; }
slots_sent() { grep -o '"slot":"[0-9]*"' <<<"${calls}" | grep -o '[0-9]*' | paste -sd, -; }

# 1. N = 1.
runs
kick 1
check "N=1, nothing going: exit 0" "${rc}" 0
check "N=1, nothing going: one dispatch without inputs" "$(grep '^POST ' <<<"${calls}")" \
  'POST /repos/o/r/actions/workflows/agent-coder.yml/dispatches {"ref":"agent-runner"}'
runs "Agent coder: auto pick:in_progress"
kick 1
check "N=1, a run going: no dispatch" "$(dispatches)" 0
check "N=1, a run going: exit 0" "${rc}" 0

# 1b. A run GitHub stranded: queued an hour or more with no jobs. It is not counted, and is named;
# fresh, in_progress, with a job, or with jobs that cannot be read, it still is.
OLD=2020-01-01T00:00:00Z
FRESH="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
runs_full() { jq -n --argjson r "$1" '{workflow_runs: $r}' >"${TMP}/runs.json"; }
rm -f "${TMP}"/jobs-*.json
echo '{"total_count":0,"jobs":[]}' >"${TMP}/jobs-41.json"
echo '{"total_count":0,"jobs":[]}' >"${TMP}/jobs-42.json"
echo '{"total_count":1}' >"${TMP}/jobs-43.json"
runs_full "[{\"id\":41,\"status\":\"queued\",\"created_at\":\"${OLD}\",\"display_title\":\"Agent coder: auto pick (slot 2)\"}]"
kick 1
check "N=1, a run queued for years with no jobs: one dispatch" "$(dispatches)" 1
check "N=1, the stranded run: its jobs were asked for" "$(grep -c '^GET /repos/o/r/actions/runs/41/jobs' <<<"${calls}")" 1
if [[ "${out}" == *"GitHub left coder run 41 queued with no jobs since ${OLD}"* ]]; then t_pass "N=1, the stranded run is named"
else t_fail "N=1, the stranded run is not named: output was [${out}]"; fi
runs_full "[{\"id\":42,\"status\":\"queued\",\"created_at\":\"${FRESH}\"}]"
kick 1
check "N=1, a fresh queued run with no jobs: busy" "$(dispatches)" 0
check "N=1, a fresh queued run: its jobs are not asked for" "$(grep -c '/jobs' <<<"${calls}")" 0
runs_full "[{\"id\":43,\"status\":\"queued\",\"created_at\":\"${OLD}\"}]"
kick 1
check "N=1, an old queued run with a job: busy" "$(dispatches)" 0
runs_full "[{\"id\":41,\"status\":\"in_progress\",\"created_at\":\"${OLD}\"}]"
kick 1
check "N=1, an old in_progress run: busy" "$(dispatches)" 0
runs_full "[{\"id\":44,\"status\":\"queued\",\"created_at\":\"${OLD}\"}]"
kick 1
check "N=1, an old queued run whose jobs cannot be read (404): busy" "$(dispatches)" 0
echo '{}' >"${TMP}/jobs-46.json"
runs_full "[{\"id\":46,\"status\":\"queued\",\"created_at\":\"${OLD}\"}]"
kick 1
check "N=1, an old queued run whose jobs answer has no total_count: busy" "$(dispatches)" 0
echo '{"total_count":0}' >"${TMP}/jobs-47.json"
printf 500 >"${TMP}/jobs-47.code"
runs_full "[{\"id\":47,\"status\":\"queued\",\"created_at\":\"${OLD}\"}]"
kick 1
check "N=1, an old queued run whose jobs call fails (500, total_count 0 in the body): busy" "$(dispatches)" 0
runs_full '[{"id":41,"status":"queued"}]'
kick 1
check "N=1, a queued run without created_at: busy" "$(dispatches)" 0
runs_full "[{\"id\":\"41\",\"status\":\"queued\",\"created_at\":\"${OLD}\"}]"
kick 1
check "N=1, a queued run whose id is not a number: busy" "$(dispatches)" 0
# Age runs from run_started_at: a re-run keeps its old created_at but starts afresh.
runs_full "[{\"id\":41,\"status\":\"queued\",\"created_at\":\"${OLD}\",\"run_started_at\":\"${FRESH}\"}]"
kick 1
check "N=1, a re-run of an old run, started just now: busy" "$(dispatches)" 0
check "N=1, a fresh re-run: its jobs are not asked for" "$(grep -c '/jobs' <<<"${calls}")" 0
runs_full "[{\"id\":41,\"status\":\"queued\",\"created_at\":\"2019-01-01T00:00:00Z\",\"run_started_at\":\"${OLD}\"}]"
kick 1
check "N=1, a re-run started long ago with no jobs: one dispatch" "$(dispatches)" 1
if [[ "${out}" == *"GitHub left coder run 41 queued with no jobs since ${OLD}"* ]]; then t_pass "N=1, the re-run is named with the time it last started"
else t_fail "N=1, the re-run is not named with run_started_at: output was [${out}]"; fi
runs_full "[{\"id\":41,\"status\":\"queued\",\"created_at\":\"${OLD}\",\"run_started_at\":null}]"
kick 1
check "N=1, run_started_at null falls back to created_at: one dispatch" "$(dispatches)" 1
for i in 51 52 53 54; do echo '{"total_count":0}' >"${TMP}/jobs-${i}.json"; done
runs_full "[$(for i in 51 52 53 54; do printf '{"id":%s,"status":"queued","created_at":"%s"},' "${i}" "${OLD}"; done | sed 's/,$//')]"
kick 1
check "N=1, four stranded runs: only three jobs lookups" "$(grep -c '/jobs' <<<"${calls}")" 3
check "N=1, and the fourth still counts: busy" "$(dispatches)" 0
runs_full "[{\"id\":41,\"status\":\"queued\",\"created_at\":\"${OLD}\",\"display_title\":\"a (slot 2)\"},{\"id\":45,\"status\":\"in_progress\",\"display_title\":\"b (slot 1)\"}]"
kick 3
check "N=3, a stranded run in slot 2 holds no slot: dispatches into slots 2 and 3" "$(slots_sent)" "2,3"
rm -f "${TMP}"/jobs-*.json "${TMP}"/jobs-*.code

# 2. N = 3.
runs "Agent coder: auto pick (slot 1):in_progress"
kick 3
check "N=3, slot 1 busy: dispatches into slots 2 and 3" "$(slots_sent)" "2,3"
check "N=3, slot 1 busy: on the runner ref" "$(grep -c '"ref":"agent-runner","inputs"' <<<"${calls}")" 2
check "N=3, slot 1 busy: exit 0" "${rc}" 0
runs "Agent coder: auto pick (slot 1):in_progress" "Agent coder: issue 7 (slot 3):queued" "Agent coder: auto pick (slot 2):completed"
kick 3
check "N=3, slots 1 and 3 busy, slot 2 completed: dispatches into slot 2" "$(slots_sent)" "2"
runs "Agent coder: auto pick:in_progress" "Agent coder: auto pick (slot 1):in_progress"
kick 3
check "N=3, a slotless run and slot 1 going: one dispatch, into slot 2" "$(slots_sent)" "2"
runs
kick 3
check "N=3, nothing going: dispatches into slots 1, 2 and 3" "$(slots_sent)" "1,2,3"

# 3. Busy and failures.
runs "a (slot 1):in_progress" "b (slot 2):queued" "c (slot 3):waiting"
kick 3
check "N=3, every slot busy: no dispatch" "$(dispatches)" 0
check "N=3, every slot busy: exit 0" "${rc}" 0
if [[ "${out}" == *"every coder slot is busy"* ]]; then t_pass "every slot busy: says so"; else t_fail "every slot busy: output was [${out}]"; fi
runs
printf '422\n' >"${TMP}/dispatch-codes"
kick 3
check "one dispatch of three fails: exit 0" "${rc}" 0
check "one dispatch of three fails: all three tried" "$(slots_sent)" "1,2,3"
if [[ "${out}" == *"slot 1 failed: HTTP 422: Unexpected inputs provided"* ]]; then t_pass "a failed dispatch names its slot and the API's message"
else t_fail "a failed dispatch: output was [${out}]"; fi
printf '422\n422\n' >"${TMP}/dispatch-codes"
runs "a (slot 3):in_progress"
kick 3
check "every dispatch fails: exit 1" "${rc}" 1

# 4. A bad slot count.
for bad in 0 abc 21 "2 3" 03 18446744073709551617; do
  runs
  kick "${bad}"
  check "AGENT_KICK_CODER_SLOTS='${bad}': exit 1" "${rc}" 1
  check "AGENT_KICK_CODER_SLOTS='${bad}': no API call" "${calls}" ""
done

# 5. install.
ROOT_DIR="${TMP}/root"
mkdir -p "${ROOT_DIR}/etc/gatehand-kick"
(umask 077; printf 'ghp_x\n' >"${ROOT_DIR}/etc/gatehand-kick/token")
install_with() {
  PATH="${TMP}/bin:${PATH}" AGENT_KICK_ROOT="${ROOT_DIR}" AGENT_KICK_REPO=o/r AGENT_KICK_CODER_SLOTS="$1" \
    bash "${KICK}" install >/dev/null 2>&1
}
install_with 3
check "install with 3 slots: exit 0" "$?" 0
svc="${ROOT_DIR}/etc/systemd/system/gatehand-kick@.service"
if grep -q '^Environment=.* AGENT_KICK_CODER_SLOTS=3$' "${svc}"; then t_pass "install writes AGENT_KICK_CODER_SLOTS into the service"
else t_fail "the service has no AGENT_KICK_CODER_SLOTS=3: $(grep Environment "${svc}")"; fi
check "install with 3 slots: start timeout covers 7 calls (listing, 3 jobs lookups, 3 dispatches)" "$(grep '^TimeoutStartSec=' "${svc}")" "TimeoutStartSec=15min"
install_with 1
check "install with 1 slot: start timeout covers 5 calls" "$(grep '^TimeoutStartSec=' "${svc}")" "TimeoutStartSec=11min"
install_with 0
check "install with 0 slots: exit 1" "$?" 1

# 6. The token.
kick 3
if grep -qE 'bad-stdin|token-in-argv' "${TMP}/calls"; then t_fail "the token was not passed on stdin only"; else t_pass "the token reaches curl on stdin only"; fi

printf '\n[kick] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
