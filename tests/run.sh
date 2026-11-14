#!/usr/bin/env bash
# tests/run.sh [suite...]: render the package into a scratch repository with the test policy, lint
# what was rendered, then run every tests/*/*.test.sh (or the named ones) against it, with
# AGENTS_ROOT pointing at the rendered repository.
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
OUT="$(mktemp -d)"
trap 'rm -rf "${ROOT}" "${OUT}"' EXIT
git -C "${ROOT}" init -q -b main
mkdir -p "${ROOT}/.github/agents"
# The test policy: the defaults, with every optional workflow on so its tests have files to read.
# AGENTS_TEST_POLICY_JQ adds a jq filter on top (CI runs the suites a second time with a self-hosted
# agent runner, so nothing passes only because every runner is ubuntu-latest).
jq ".workflows.triage = true | .requiredChecks = [\"build\", \"test (unit)\", \"lint\"] | ${AGENTS_TEST_POLICY_JQ:-.}" \
  "${PKG}/defaults/policy.json" >"${ROOT}/.github/agents/policy.json"
"${PKG}/bin/render.sh" "${ROOT}" >/dev/null || { echo "FAIL: render"; exit 1; }
# And two label-unlockable globs, the kind an adopter adds for release tooling, so the suites can
# exercise `agent:allow-protected` (the default list's only one is CLAUDE.md).
printf '%s\n' 'deploy/**' 'scripts/**' >>"${ROOT}/.github/agents/protected-paths.txt"
"${PKG}/bin/render.sh" --check "${ROOT}" >/dev/null || { echo "FAIL: render is not idempotent"; exit 1; }

rc=0
if command -v actionlint >/dev/null; then
  # Self-hosted runner labels from the policy, declared the way an adopter declares them.
  {
    printf 'self-hosted-runner:\n  labels:\n'
    jq -r '[.runners[] | arrays | .[] | select(. != "self-hosted")] | unique | .[] | "    - " + .' "${ROOT}/.github/agents/policy.json"
    cat "${PKG}/tests/lint/actionlint.yaml"
  } >"${ROOT}/.github/actionlint.yaml"
  (cd "${ROOT}" && actionlint .github/workflows/*.yml) || { echo "FAIL: actionlint"; rc=1; }
  rm -f "${ROOT}/.github/actionlint.yaml"
else
  echo "SKIP: actionlint not installed"
fi
if command -v shellcheck >/dev/null; then
  shellcheck -x "${ROOT}"/.github/scripts/*.sh "${PKG}"/bin/*.sh "${PKG}"/tests/run.sh || { echo "FAIL: shellcheck"; rc=1; }
else
  echo "SKIP: shellcheck not installed"
fi
# The dashboard's server (bin/dashboard.py): it must at least compile on this python3.
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "${PKG}/bin/dashboard.py" \
  || { echo "FAIL: bin/dashboard.py does not parse"; rc=1; }

export AGENTS_ROOT="${ROOT}"
if [[ $# -gt 0 ]]; then suites=("$@"); else suites=("${PKG}"/tests/*/*.test.sh); fi
# The suites only read AGENTS_ROOT and keep their own state in mktemp directories, so they run in
# parallel, up to AGENTS_TEST_JOBS at a time (default: one per CPU). Results print in suite order.
jobs_max="${AGENTS_TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
[[ "${jobs_max}" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: AGENTS_TEST_JOBS must be a positive integer"; exit 1; }
# Background jobs ignore SIGINT, so Ctrl-C would not stop them: terminate the running suites.
# shellcheck disable=SC2329 # invoked by the trap below
stop_suites() {
  local p
  for p in $(jobs -p); do pkill -TERM -P "${p}" 2>/dev/null; done
  exit 130
}
trap stop_suites INT TERM
for i in "${!suites[@]}"; do
  while [[ "$(jobs -rp | wc -l)" -ge "${jobs_max}" ]]; do wait -n; done
  { bash "${suites[i]}" >"${OUT}/${i}.out" 2>&1; echo "$?" >"${OUT}/${i}.rc"; } &
done
wait
for i in "${!suites[@]}"; do
  t="${suites[i]}"
  if [[ "$(cat "${OUT}/${i}.rc")" == 0 ]]; then
    printf 'ok    %s\n' "${t#"${PKG}"/}"
  else
    printf 'FAIL  %s\n' "${t#"${PKG}"/}"
    grep -E 'FAIL|not ok|✗|Error|error' "${OUT}/${i}.out" | head -15 | sed 's/^/      /'
    rc=1
  fi
done
exit "${rc}"
