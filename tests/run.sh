#!/usr/bin/env bash
# tests/run.sh [suite...]: render the package into a scratch repository with the test policy, lint
# what was rendered, then run every tests/*/*.test.sh (or the named ones) against it, with
# AGENTS_ROOT pointing at the rendered repository.
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
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
for t in "${suites[@]}"; do
  if out="$(bash "${t}" 2>&1)"; then
    printf 'ok    %s\n' "${t#"${PKG}"/}"
  else
    printf 'FAIL  %s\n' "${t#"${PKG}"/}"
    printf '%s\n' "${out}" | grep -E 'FAIL|not ok|✗|Error|error' | head -15 | sed 's/^/      /'
    rc=1
  fi
done
exit "${rc}"
