#!/usr/bin/env bash
# tests/workflows/review-fork-guard.test.sh
# Drives the REAL `run:` block of claude-code-review.yml's fork guard against a stubbed `curl`. A
# dispatched review checks out the PR's head and then runs that tree's .github/actions/install-gh
# and .claude/ with the job's write and OIDC tokens; the guard must stop a fork's PR before that.
#
# Asserts:
#   1. a PR from a branch of the repository passes
#   2. a fork's PR is refused, and the error names the fork
#   3. a PR whose fork was deleted (head.repo null) is refused
#   4. a failed API call fails the step (no answer is not a yes)
#   5. a pr input that is not a number is refused before any call
#   6. the token reaches curl on stdin, never in its argv, and the URL is the PR's
#   7. the guard runs on a dispatch only, and comes before the checkout and install-gh
set -uo pipefail

REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
WORKFLOW="${REPO_ROOT}/.github/workflows/claude-code-review.yml"

pass=0
fail=0
t_pass() { printf '\033[1;32m[review-fork-guard] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[review-fork-guard] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

[[ -f "${WORKFLOW}" ]] || { t_fail "claude-code-review.yml is missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The same extraction as review-dedup.test.sh: steps at 6 spaces, keys at 8, a run block at 10.
extract_run_block() { # <file> <id>
  awk -v want="$2" '
    $0 ~ "^        id: " want "$" { in_step = 1; next }
    in_step && /^      - / { exit }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 == "") { print ""; next }
      if ($0 !~ /^          /) { exit }
      sub(/^          /, ""); print
    }
  ' "$1"
}
extract_run_block "${WORKFLOW}" fork_guard >"${TMP}/guard.sh"
[[ -s "${TMP}/guard.sh" ]] || { t_fail "could not extract the fork guard's run block"; exit 1; }

# Stub curl: record argv and stdin, then answer with the case's fixture (or fail like curl -f).
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${CURL_ARGV}"
cat >"${CURL_STDIN}"
[[ "${CURL_FAIL:-0}" == 1 ]] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "${CURL_FIXTURE}"
STUB
chmod +x "${TMP}/bin/curl"

TOKEN='ghs_fakeTokenForTheGuardTest'
# run_guard <fixture> <pr> [fail]: sets rc and out.
run_guard() {
  : >"${TMP}/argv"; : >"${TMP}/stdin"
  out="$(CURL_ARGV="${TMP}/argv" CURL_STDIN="${TMP}/stdin" CURL_FIXTURE="${TMP}/$1.json" CURL_FAIL="${3:-0}" \
    PR="$2" REPO='acme/repo' TOKEN="${TOKEN}" GITHUB_API_URL='https://api.example.test' \
    PATH="${TMP}/bin:${PATH}" bash "${TMP}/guard.sh" 2>&1)"
  rc=$?
}
mk() { printf '%s\n' "$1" >"${TMP}/$2.json"; }
mk '{"number":7,"head":{"repo":{"full_name":"acme/repo"}}}' branch
mk '{"number":7,"head":{"repo":{"full_name":"mallory/repo"}}}' fork
mk '{"number":7,"head":{"repo":null}}' deleted_fork

run_guard branch 7
[[ "${rc}" -eq 0 ]] && t_pass "1: a PR from a branch of the repository passes" \
  || t_fail "1: a branch PR was refused (rc=${rc}): ${out}"

run_guard fork 7
[[ "${rc}" -ne 0 && "${out}" == *"mallory/repo"* ]] && t_pass "2: a fork's PR is refused and the fork is named" \
  || t_fail "2: a fork's PR was not refused (rc=${rc}): ${out}"

run_guard deleted_fork 7
[[ "${rc}" -ne 0 ]] && t_pass "3: a PR whose fork is gone is refused" \
  || t_fail "3: a PR with no head repository passed: ${out}"

run_guard branch 7 1
[[ "${rc}" -ne 0 ]] && t_pass "4: a failed API call fails the step" \
  || t_fail "4: the guard passed although the API call failed: ${out}"

run_guard branch '7; touch pwned'
if [[ "${rc}" -ne 0 && ! -s "${TMP}/argv" ]]; then
  t_pass "5: a pr that is not a number is refused before any call"
else
  t_fail "5: pr '7; touch pwned' got rc=${rc}, curl called: $([[ -s "${TMP}/argv" ]] && echo yes || echo no)"
fi

run_guard branch 7
if grep -qF "${TOKEN}" "${TMP}/argv"; then
  t_fail "6: the token is in curl's argv"
elif grep -qF "Authorization: Bearer ${TOKEN}" "${TMP}/stdin" && grep -qx -- '-K' "${TMP}/argv"; then
  t_pass "6: the token goes to curl as config on stdin"
else
  t_fail "6: curl did not get the token as config on stdin"
fi
grep -qx 'https://api.example.test/repos/acme/repo/pulls/7' "${TMP}/argv" \
  && t_pass "6: the guard asks for the dispatched PR" || t_fail "6: the guard asked for another URL: $(tr '\n' ' ' <"${TMP}/argv")"

# 7: placement and gate. Line numbers of the guard, the checkout and install-gh inside the job.
gate="$(awk '/^        id: fork_guard$/ { f = 1; next } f && /^        if: / { sub(/^        if: /, ""); print; exit } f && /^      - / { exit }' "${WORKFLOW}")"
[[ "${gate}" == "github.event_name == 'workflow_dispatch'" ]] && t_pass "7: the guard runs on a dispatch" \
  || t_fail "7: the guard's if: is '${gate}'"
first_step="$(awk '/^    steps:$/ { s = 1; next } s && /^      - / { print; exit }' "${WORKFLOW}")"
[[ "${first_step}" == "      - name: refuse a fork's PR" ]] && t_pass "7: the guard is the job's first step" \
  || t_fail "7: the job's first step is '${first_step}', not the fork guard"
guard_at="$(grep -n '^        id: fork_guard$' "${WORKFLOW}" | cut -d: -f1)"
checkout_at="$(grep -n 'uses: actions/checkout@' "${WORKFLOW}" | head -1 | cut -d: -f1)"
gh_at="$(grep -n 'uses: ./.github/actions/install-gh' "${WORKFLOW}" | head -1 | cut -d: -f1)"
if [[ -n "${guard_at}" && -n "${checkout_at}" && -n "${gh_at}" && "${guard_at}" -lt "${checkout_at}" && "${guard_at}" -lt "${gh_at}" ]]; then
  t_pass "7: the guard comes before the checkout and install-gh"
else
  t_fail "7: guard line ${guard_at:-?}, checkout ${checkout_at:-?}, install-gh ${gh_at:-?}"
fi

printf '\n[review-fork-guard] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
