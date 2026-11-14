#!/usr/bin/env bash
# tests/workflows/review-post.test.sh
# #1147: the review model holds no token that can write. claude-code-review.yml hands the action
# this job's read-only GITHUB_TOKEN, takes the review from the model's final message, and posts it
# from a later step with a Claude App token that step mints itself (OIDC, then Anthropic's token
# exchange) and revokes. This drives the REAL `run:` blocks of the probe and post steps against a
# stubbed `curl`, and pins the job's shape around them.
# t_pass always returns 0, so `test && t_pass … || t_fail …` cannot run both branches.
# shellcheck disable=SC2015
# `${{ … }}` in single quotes is literal workflow text to match, never shell.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
WORKFLOW="${REPO_ROOT}/.github/workflows/claude-code-review.yml"
MARKER='<!-- verify-pr-review -->'

pass=0
fail=0
t_pass() { printf '\033[1;32m[review-post] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[review-post] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

[[ -f "${WORKFLOW}" ]] || { t_fail "claude-code-review.yml is missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

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
extract_run_block "${WORKFLOW}" probe >"${TMP}/probe.sh"
extract_run_block "${WORKFLOW}" post >"${TMP}/post.sh"
[[ -s "${TMP}/probe.sh" && -s "${TMP}/post.sh" ]] || { t_fail "could not extract the probe's or the post step's run block"; exit 1; }

# The stub curl: logs "METHOD URL" per call, keeps its argv and stdin (the -K config), answers by
# URL. EXCHANGE_STATUS / EXCHANGE_BODY shape the token exchange; POST_FAIL=1 fails the comment.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'STUB'
cfg="$(cat)"
printf '%s\n' "$@" >>"${CURL_ARGV}"
printf '%s\n' "${cfg}" >>"${CURL_STDIN}"
method=GET url="" data="" wfmt="" fail=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    --data-binary) data="$(cat "${2#@}")"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -o|-H|-K|--retry|--retry-delay) shift 2 ;;
    -fsS|-f) fail=1; shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "${url}" ]] || url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"${cfg}")"
[[ -n "${data}" && "${method}" == GET ]] && method=POST
printf '%s %s\n' "${method}" "${url}" >>"${CURL_LOG}"
answer() { # <status> <body>
  printf '%s' "$2"
  [[ -n "${wfmt}" ]] && printf '\n%s' "$1"
  [[ "${fail}" == 1 && "$1" -ge 400 ]] && exit 22
  exit 0
}
case "${url}" in
  *audience=claude-code-github-action*) answer 200 '{"value":"oidc-jwt-for-the-test"}' ;;
  *github-app-token-exchange*) printf '%s\n' "${data}" >"${EXCHANGE_DATA}"
    answer "${EXCHANGE_STATUS:-200}" "${EXCHANGE_BODY:-{\"token\":\"ghs_appTokenForTheReviewPostTest01\"}}" ;;
  */installation/token) answer 204 '' ;;
  */comments) [[ "${POST_FAIL:-0}" == 1 ]] && answer 500 '{"message":"boom"}'
    printf '%s' "${data}" >"${POSTED}"; answer 201 '{"id":1}' ;;
  *) echo "stub curl: unexpected ${url}" >&2; exit 7 ;;
esac
STUB
chmod +x "${TMP}/bin/curl"

reset() { for f in argv stdin log posted exchange output; do : >"${TMP}/${f}"; done; }
envs=(CURL_ARGV="${TMP}/argv" CURL_STDIN="${TMP}/stdin" CURL_LOG="${TMP}/log" POSTED="${TMP}/posted"
  EXCHANGE_DATA="${TMP}/exchange" GITHUB_OUTPUT="${TMP}/output" GITHUB_API_URL='https://api.example.test'
  ACTIONS_ID_TOKEN_REQUEST_URL='https://token.example.test/oidc?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN='reqTokenForTheTest'
  REVIEW_MARKER="${MARKER}" REPO='acme/repo' PATH="${TMP}/bin:${PATH}")
run_probe() { reset; out="$(env "${envs[@]}" "$@" bash "${TMP}/probe.sh" 2>&1)"; rc=$?; }
run_post() { # <result text> [VAR=value…]
  reset
  jq -n --arg r "$1" '[{type: "system"}, {type: "assistant"}, {type: "result", subtype: "success", result: $r}]' >"${TMP}/exec.json"
  shift
  out="$(env "${envs[@]}" PR=7 EXECUTION_FILE="${TMP}/exec.json" "$@" bash "${TMP}/post.sh" 2>&1)"
  rc=$?
}
called() { grep -qF -- "$1" "${TMP}/log"; }
APP='ghs_appTokenForTheReviewPostTest01'
no_secret_in_argv() { ! grep -qE "${APP}|oidc-jwt-for-the-test|reqTokenForTheTest" "${TMP}/argv"; }

# --- the probe -------------------------------------------------------------------------------------
run_probe
[[ "${rc}" -eq 0 ]] && grep -qx 'valid=true' "${TMP}/output" && t_pass "probe 1: an exchange that works says valid=true" \
  || t_fail "probe 1: rc=${rc}, output '$(cat "${TMP}/output")': ${out}"
called 'DELETE https://api.example.test/installation/token' && t_pass "probe 1: and the token is revoked at once" \
  || t_fail "probe 1: the probe's token was not revoked: $(cat "${TMP}/log")"
[[ "$(jq -c . "${TMP}/exchange")" == '{"permissions":{"pull_requests":"write"}}' ]] && t_pass "probe 1: it asks for pull_requests write only" \
  || t_fail "probe 1: the exchange asked for '$(cat "${TMP}/exchange")'"
no_secret_in_argv && t_pass "probe 1: no token or request value is in curl's argv" || t_fail "probe 1: a secret is in argv"
grep -qF 'audience=claude-code-github-action' "${TMP}/stdin" && t_pass "probe 1: the OIDC token is asked for the action's audience" \
  || t_fail "probe 1: the OIDC request has another audience"

run_probe EXCHANGE_STATUS=401 EXCHANGE_BODY='{"message":"Workflow validation failed. The workflow file must exist and have identical content to the version on the repository default branch."}'
[[ "${rc}" -eq 0 ]] && grep -qx 'valid=false' "${TMP}/output" && t_pass "probe 2: a workflow that differs from the default branch's says valid=false" \
  || t_fail "probe 2: rc=${rc}, output '$(cat "${TMP}/output")': ${out}"
run_probe EXCHANGE_STATUS=400 EXCHANGE_BODY='{"error":{"message":"nope","details":{"error_code":"workflow_not_found_on_default_branch"}}}'
[[ "${rc}" -eq 0 ]] && grep -qx 'valid=false' "${TMP}/output" && t_pass "probe 2: so does a workflow missing from the default branch" \
  || t_fail "probe 2b: rc=${rc}: ${out}"
run_probe EXCHANGE_STATUS=500 EXCHANGE_BODY='{"message":"internal"}'
[[ "${rc}" -ne 0 ]] && ! grep -q '^valid=' "${TMP}/output" && t_pass "probe 3: any other failure fails the step (no billed review that cannot post)" \
  || t_fail "probe 3: a 500 gave rc=${rc}, output '$(cat "${TMP}/output")'"
run_probe EXCHANGE_STATUS=401 EXCHANGE_BODY='{"message":"bad credentials"}'
[[ "${rc}" -ne 0 ]] && t_pass "probe 3: a 401 that is not workflow validation fails too" || t_fail "probe 3b: rc=${rc}"

# --- the post --------------------------------------------------------------------------------------
REVIEW=$'<!-- verify-pr-review -->\n\n### Blocking problems\nNone.\n\n### Verdict\nApprove'
run_post $'Here is the review of #9 you asked for.\n'"${REVIEW}"
posted="$(jq -r .body "${TMP}/posted" 2>/dev/null)"
[[ "${rc}" -eq 0 && "${posted}" == "${REVIEW}" ]] && t_pass "post 1: the final message is posted from the marker line on" \
  || t_fail "post 1: rc=${rc}, posted '${posted}': ${out}"
called 'POST https://api.example.test/repos/acme/repo/issues/7/comments' && t_pass "post 1: to this run's PR, whatever the text names" \
  || t_fail "post 1: posted to $(grep comments "${TMP}/log")"
[[ "$(grep -c . "${TMP}/log")" -eq 4 ]] && tail -1 "${TMP}/log" | grep -qF 'DELETE https://api.example.test/installation/token' \
  && t_pass "post 1: OIDC, exchange, one comment, then the token is revoked" || t_fail "post 1: calls were $(tr '\n' '|' <"${TMP}/log")"
grep -qF "Authorization: Bearer ${APP}" "${TMP}/stdin" && no_secret_in_argv && t_pass "post 1: the App token goes to curl on stdin, never in argv" \
  || t_fail "post 1: the token was not passed as curl config"

run_post $'### Blocking problems\nNone.\n\n### Verdict\nApprove'
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 2: a final message without the marker posts nothing and mints nothing" \
  || t_fail "post 2: rc=${rc}, calls $(tr '\n' '|' <"${TMP}/log")"
run_post ''
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 2: nor does an empty one" || t_fail "post 2b: rc=${rc}"

for secret in 'sk-ant-oat01-AbCdEfGhIjKlMnOp' 'ghs_0123456789abcdefghijABCDEFGHIJ' 'github_pat_0123456789abcdefghij_xyz' \
  '-----BEGIN RSA PRIVATE KEY-----' 'ACTIONS_ID_TOKEN_REQUEST_TOKEN=abc' 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ4In0.sig'; do
  run_post "${REVIEW}"$'\n\nenv: '"${secret}"
  [[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 3: a review carrying ${secret:0:14}… is not posted" \
    || t_fail "post 3: a review carrying ${secret:0:14}… gave rc=${rc}, calls $(tr '\n' '|' <"${TMP}/log")"
done
big="$(head -c 61000 /dev/zero | tr '\0' 'a')"
run_post "${REVIEW}"$'\n'"${big}"
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 4: an oversized review is not posted" || t_fail "post 4: rc=${rc}"

reset
jq -n --arg r "${REVIEW}" '[{type: "result", result: $r}]' >"${TMP}/exec.json"
out="$(env "${envs[@]}" PR='7; touch pwned' EXECUTION_FILE="${TMP}/exec.json" bash "${TMP}/post.sh" 2>&1)"; rc=$?
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 5: a pr that is not a number is refused before any call" || t_fail "post 5: rc=${rc}"

run_post "${REVIEW}" POST_FAIL=1
[[ "${rc}" -ne 0 ]] && tail -1 "${TMP}/log" | grep -qF 'DELETE https://api.example.test/installation/token' \
  && t_pass "post 6: a failed comment fails the step and still revokes the token" || t_fail "post 6: rc=${rc}, calls $(tr '\n' '|' <"${TMP}/log")"
[[ "$(grep -c '/comments' "${TMP}/log")" -eq 1 ]] && t_pass "post 6: and the comment is not retried (no double post)" \
  || t_fail "post 6: the comment was sent $(grep -c '/comments' "${TMP}/log") times"

run_post "${REVIEW}" EXCHANGE_STATUS=500 EXCHANGE_BODY='{"message":"internal"}'
[[ "${rc}" -ne 0 && ! -s "${TMP}/posted" ]] && t_pass "post 7: no token, no comment, a red step" || t_fail "post 7: rc=${rc}"

# --- the job around them ---------------------------------------------------------------------------
job() { awk -v j="  $1:" '$0 == j {on = 1; print; next} on && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {on = 0} on' "${WORKFLOW}"; }
review_job="$(job claude-review)"
perms="$(awk '/^    permissions:$/ {on = 1; next} on && /^      / {print; next} on {exit}' <<<"${review_job}" | tr -d ' ' | sort | tr '\n' ' ')"
[[ "${perms}" == "contents:read id-token:write issues:read pull-requests:read " ]] && t_pass "job: the review job's token is read-only (plus the OIDC grant the post step needs)" \
  || t_fail "job: the review job's permissions are '${perms}'"
order="$(grep -oE '^        id: (probe|claude-review|post|assert)$' <<<"${review_job}" | sed 's/^        id: //' | tr '\n' '|')"
[[ "${order}" == "probe|claude-review|post|assert|" ]] && t_pass "job: probe, review, post, assert" || t_fail "job: the steps run as ${order}"
post_step="$(awk '/^        id: post$/ {on = 1} on && /^      - / {exit} on' <<<"${review_job}")"
grep -qx "        if: steps.claude-review.outputs.execution_file != ''" <<<"${post_step}" \
  && t_pass "job: the post step runs only when the review ran" || t_fail "job: the post step's if: is $(grep 'if:' <<<"${post_step}")"
[[ "$(grep -c 'uses: anthropics/claude-code-action' <<<"${review_job}")" -eq 1 ]] && ! grep -v '^[[:space:]]*#' <<<"${review_job}" | grep -q 'always()' \
  && t_pass "job: one model step, and nothing runs regardless of the steps before it" || t_fail "job: a second model step or an always() in the review job"
skip_job="$(job skip-note)"
grep -qx '      pull-requests: write' <<<"${skip_job}" && grep -qF 'ref: ${{ github.event.repository.default_branch }}' <<<"${skip_job}" \
  && ! grep -q 'claude-code-action' <<<"${skip_job}" && grep -qx '    needs: claude-review' <<<"${skip_job}" \
  && t_pass "skip-note: the only write token is in a job that checks out the default branch and runs no model" \
  || t_fail "skip-note: the job's shape changed"
grep -qx "    if: github.event_name == 'pull_request' && needs.claude-review.outputs.skipped == 'true'" <<<"${skip_job}" \
  && t_pass "skip-note: only on an automatic run whose review never ran" || t_fail "skip-note: its if: changed"
[[ "$(grep -c 'pull-requests: write' "${WORKFLOW}")" -eq 1 ]] && t_pass "pull-requests: write appears once in the workflow (the skip note's)" \
  || t_fail "pull-requests: write appears $(grep -c 'pull-requests: write' "${WORKFLOW}") times"

printf '\n[review-post] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
