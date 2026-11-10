#!/usr/bin/env bash
# addons/hardened-runner/agent-kick.sh: dispatch the agents' scheduled workflows on time, from a box
# that is always on (your self-hosted agent box). Optional.
#
# Why: GitHub's scheduler can fire crons late or not at all on a busy day, while events (CI
# completions, comments, dispatches) arrive on time. A systemd timer per workflow dispatches the same
# workflow on the same schedule; the workflows keep their own `schedule:` as a backup. A doubled run
# changes nothing: every agent job re-checks the kill switch, the breaker and the day's caps itself,
# and a second digest in the same week edits the first.
#
# The token is a fine-grained PAT: access to the one repository only, repository permission
# Actions: Read and write, nothing else. It lives in /etc/repo-agent-kick/token (root-owned, 0600).
# The service runs as a dynamic user that cannot read that file; systemd hands it over as a
# credential, and this script gives it to curl on stdin, never in argv.
#
# Usage, as root:
#   AGENT_KICK_REPO=<owner>/<repo> bash agent-kick.sh install   # copy, write the units, enable timers
#   systemctl list-timers 'repo-agent-kick@*'
#   journalctl -u 'repo-agent-kick@*' --since today
#   systemctl start repo-agent-kick@sweep.service              # one kick now, through systemd
# `run <job>` is what each timer's service executes; it needs systemd's credential directory.
#
# The calendars below are the DEFAULT schedules of .github/agents/policy.json. If you change a
# schedule there, change job_calendar here to the same time and re-run install.
set -euo pipefail

REPO="${AGENT_KICK_REPO:-}"
RUNNER_REF="${AGENT_KICK_RUNNER_REF:-agent-runner}"
BASE_REF="${AGENT_KICK_BASE_REF:-main}"
API=https://api.github.com
# Tests point ROOT at a temp dir; the paths written INTO the units never carry it.
ROOT="${AGENT_KICK_ROOT:-}"
TOKEN_FILE=/etc/repo-agent-kick/token
BIN=/usr/local/libexec/repo-agent-kick
UNIT_DIR=/etc/systemd/system

# job -> workflow file, ref, systemd OnCalendar (each the policy's default cron, in UTC).
# The coder goes to the runner ref (policy.json runnerRef), never the base branch: its gate refuses that.
# Triage only when the repo renders it (policy.json workflows.triage): AGENT_KICK_TRIAGE=true.
TRIAGE="${AGENT_KICK_TRIAGE:-false}"
JOBS=(sweep merge coder digest)
[[ "${TRIAGE}" == true ]] && JOBS+=(triage)
job_workflow() {
  case "$1" in
    sweep) echo agent-sweep.yml ;;
    merge) echo agent-merge.yml ;;
    triage) echo agent-triage.yml ;;
    coder) echo agent-coder.yml ;;
    digest) echo agent-digest.yml ;;
    *) return 1 ;;
  esac
}
job_ref() { case "$1" in coder) echo "${RUNNER_REF}" ;; *) echo "${BASE_REF}" ;; esac; }
job_calendar() {
  case "$1" in
    sweep) echo '*-*-* *:41:00 UTC' ;;                        # 41 * * * *
    merge) echo '*-*-* *:11:00 UTC' ;;                        # 11 * * * *
    triage) echo '*-*-* 05:17:00 UTC' ;;                      # 17 5 * * *
    coder) echo '*-*-* 06,08,10,12,14,16,18,20:17:00 UTC' ;; # 17 6-20/2 * * *
    digest) echo 'Mon *-*-* 06:30:00 UTC' ;;                  # 30 6 * * 1
    *) return 1 ;;
  esac
}

log() { printf 'agent-kick: %s\n' "$*"; }
die() { printf 'agent-kick: %s\n' "$*" >&2; exit 1; }

# --- run ------------------------------------------------------------------------------------------

TOKEN=""
BODY=""

# api METHOD PATH [DATA]: prints the HTTP status; the response body lands in ${BODY}. The token goes
# to curl as a header file on stdin, so it never appears in a process listing.
api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS --max-time 30 --retry 2 --retry-max-time 90 -o "${BODY}" -w '%{http_code}' -X "${method}"
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H @-)
  [[ -n "${data}" ]] && args+=(--data "${data}")
  printf 'Authorization: Bearer %s\n' "${TOKEN}" | curl "${args[@]}" "${API}${path}"
}

# The API's own error message, for the journal. The body never carries the token.
api_message() {
  python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("message", "")[:200])
except Exception: print(open(sys.argv[1], errors="replace").read(200))' "${BODY}" 2>/dev/null || true
}

# The coder's scheduled kick dispatches only when no coder dispatch is queued or running, because
# GitHub keeps one pending run per concurrency group and cancels the older: a kick must never
# cancel a person's named dispatch. Same rule as agent-state.sh's cmd_kick.
coder_busy() {
  local code wf="${1:-agent-coder.yml}"
  code="$(api GET "/repos/${REPO}/actions/workflows/${wf}/runs?event=workflow_dispatch&per_page=30")" \
    || die "could not list ${wf} runs"
  [[ "${code}" == 200 ]] || die "could not list ${wf} runs: HTTP ${code}: $(api_message)"
  python3 -I -c 'import json,sys
runs = json.load(open(sys.argv[1]))["workflow_runs"]
print(sum(1 for r in runs if r.get("status") != "completed"))' "${BODY}" \
    || die "could not read the coder run list"
}

cmd_run() {
  local job="${1:-}" wf ref code busy
  wf="$(job_workflow "${job}")" || { printf 'agent-kick: unknown job %q (want: %s)\n' "${job}" "${JOBS[*]}" >&2; exit 2; }
  [[ "${job}" != triage || "${TRIAGE}" == true ]] || die "triage is off (AGENT_KICK_TRIAGE is not true); no kick"
  ref="$(job_ref "${job}")"
  [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "${CREDENTIALS_DIRECTORY}/token" ]] \
    || die "no token credential: run it through systemd (systemctl start repo-agent-kick@${job}.service)"
  [[ "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "AGENT_KICK_REPO is unset or not owner/repo"
  # The first line, with surrounding blanks trimmed by read; anything else in it is malformed.
  IFS=$' \t' read -r TOKEN <"${CREDENTIALS_DIRECTORY}/token" || true
  [[ "${TOKEN}" =~ ^[A-Za-z0-9_]+$ ]] || die "the token credential is empty or malformed"
  BODY="$(mktemp)"
  trap 'rm -f "${BODY}"' EXIT

  if [[ "${job}" == coder ]]; then
    busy="$(coder_busy "${wf}")"
    [[ "${busy}" =~ ^[0-9]+$ ]] || die "unexpected ${job} run count '${busy}'"
    if [[ "${busy}" != 0 ]]; then log "a ${job} run is already queued or running; no kick"; return 0; fi
  fi

  code="$(api POST "/repos/${REPO}/actions/workflows/${wf}/dispatches" "{\"ref\":\"${ref}\"}")" \
    || die "dispatch of ${wf} on ${ref} failed (curl)"
  case "${code}" in
    200 | 204) log "dispatched ${wf} on ${ref}" ;;
    *) die "dispatch of ${wf} on ${ref} failed: HTTP ${code}: $(api_message)" ;;
  esac
}

# --- install --------------------------------------------------------------------------------------

render_service() {
  cat <<EOF
# Written by agent-kick.sh install. Re-run that to change it.
[Unit]
Description=Dispatch the agents' %i workflow (agent-kick.sh)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN} run %i
Environment=AGENT_KICK_REPO=${REPO} AGENT_KICK_RUNNER_REF=${RUNNER_REF} AGENT_KICK_BASE_REF=${BASE_REF} AGENT_KICK_TRIAGE=${TRIAGE}
# The token reaches the service only as a credential; the dynamic user cannot read the file.
LoadCredential=token:${TOKEN_FILE}
DynamicUser=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
# Two API calls at most; --retry-max-time 90 keeps each under about 2 min, Retry-After included.
TimeoutStartSec=5min
EOF
}

render_timer() {
  cat <<EOF
# Written by agent-kick.sh install. Re-run that to change it.
[Unit]
Description=Dispatch the agents' $1 workflow on its schedule

[Timer]
OnCalendar=$(job_calendar "$1")
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# The token file: present, a regular file, owned by the installing user (root on a real box), and
# readable by its owner only.
check_token_file() {
  local f="${ROOT}${TOKEN_FILE}" perms uid
  [[ -f "${f}" && -s "${f}" ]] || die "no token at ${TOKEN_FILE}: create it first (see the runbook), then re-run install"
  read -r perms _ uid _ < <(ls -ln "${f}")
  [[ "${uid}" == "${EUID}" ]] || die "${TOKEN_FILE} must be owned by root"
  # A trailing `+` (an ACL, which can grant others access) is refused; `.` is an SELinux context.
  [[ "${perms}" =~ ^-r[w-]-------[.@]?$ ]] || die "${TOKEN_FILE} must be readable by its owner only (chmod 600, no ACL)"
}

cmd_install() {
  local job units=()
  [[ -n "${ROOT}" || "${EUID}" -eq 0 ]] || die "install needs root"
  [[ "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "set AGENT_KICK_REPO=<owner>/<repo>"
  [[ "${RUNNER_REF}" =~ ^[A-Za-z0-9._/-]+$ && "${BASE_REF}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "bad ref name"
  [[ "${TRIAGE}" == true || "${TRIAGE}" == false ]] || die "AGENT_KICK_TRIAGE must be true or false"
  check_token_file
  command -v curl >/dev/null || die "curl is missing"
  command -v python3 >/dev/null || die "python3 is missing"

  install -d -m 0755 "${ROOT}$(dirname "${BIN}")" "${ROOT}${UNIT_DIR}"
  install -m 0755 "${BASH_SOURCE[0]}" "${ROOT}${BIN}"
  render_service >"${ROOT}${UNIT_DIR}/repo-agent-kick@.service"
  for job in "${JOBS[@]}"; do
    render_timer "${job}" >"${ROOT}${UNIT_DIR}/repo-agent-kick@${job}.timer"
    units+=("repo-agent-kick@${job}.timer")
  done
  if [[ "${TRIAGE}" != true && -e "${ROOT}${UNIT_DIR}/repo-agent-kick@triage.timer" ]]; then
    systemctl disable --now repo-agent-kick@triage.timer || true
    rm -f "${ROOT}${UNIT_DIR}/repo-agent-kick@triage.timer"
    log "triage is off: removed its timer"
  fi
  systemctl daemon-reload
  systemctl enable --now "${units[@]}"
  log "installed ${BIN} and ${#units[@]} timers"
  systemctl list-timers --no-pager 'repo-agent-kick@*' || true
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    install) cmd_install ;;
    *) echo "usage: $0 install | run <$(IFS='|'; echo "${JOBS[*]}")>" >&2; exit 2 ;;
  esac
}

main "$@"
