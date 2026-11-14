#!/usr/bin/env bash
# tests/workflows/review-post.test.sh
# #1147: the review model holds no token that can write, and cannot read its environment or reach
# another host. claude-code-review.yml:
#   - claude-review: read-only GITHUB_TOKEN, no id-token grant; the model reaches gh only through
#     review-gh (a wrapper this file writes), and its final message is saved as an artifact;
#   - post-review: no model, no checkout; mints a Claude App token (OIDC, then Anthropic's token
#     exchange), posts the review to the run's PR, revokes the token and asserts the comment landed,
#     or posts the "not reviewed" note.
# This drives the REAL `run:` blocks of the wrapper step and the post step against stubs, and pins
# the jobs' shape around them.
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
extract_run_block "${WORKFLOW}" review_gh >"${TMP}/wrap-step.sh"
extract_run_block "${WORKFLOW}" post >"${TMP}/post.sh"
[[ -s "${TMP}/wrap-step.sh" && -s "${TMP}/post.sh" ]] || { t_fail "could not extract the wrapper's or the post step's run block"; exit 1; }

# --- review-gh ---------------------------------------------------------------------------------------
# A fake gh that records its argv and environment; the step writes the wrapper around it.
mkdir -p "${TMP}/realbin" "${TMP}/runner"
cat >"${TMP}/realbin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${GH_ARGV_FILE:-/dev/null}"
env | sort >"${GH_ENV_FILE:-/dev/null}"
STUB
chmod +x "${TMP}/realbin/gh"
: >"${TMP}/github_path"
(cd "${TMP}" && env PATH="${TMP}/realbin:${PATH}" RUNNER_TEMP="${TMP}/runner" GITHUB_PATH="${TMP}/github_path" \
  GITHUB_REPOSITORY='acme/repo' GITHUB_SERVER_URL='https://github.com' bash "${TMP}/wrap-step.sh") \
  || t_fail "the wrapper step failed"
RGH="${TMP}/runner/review-bin/review-gh"
grep -qx "${TMP}/runner/review-bin" "${TMP}/github_path" && [[ -x "${RGH}" ]] \
  && t_pass "wrapper: review-gh is written and put on the PATH" || t_fail "wrapper: review-gh is missing or not on GITHUB_PATH"
# The env -i in review-gh hands gh a fixed PATH, so the fake must be found by absolute path: the
# step resolved `command -v gh` to it.
grep -qF "${TMP}/realbin/gh" "${RGH}" && t_pass "wrapper: it calls the gh it found, by absolute path" || t_fail "wrapper: REAL_GH is not the gh on the PATH"

rgh() { # review-gh args… ; sets rc, argv, envs
  : >"${TMP}/gh_argv"; : >"${TMP}/gh_env"
  GH_ARGV_FILE="${TMP}/gh_argv" GH_ENV_FILE="${TMP}/gh_env" GH_TOKEN='ghs_readOnlyTokenForTheTest' \
    CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-secret' ACTIONS_ID_TOKEN_REQUEST_TOKEN='req' \
    "${RGH}" "$@" >/dev/null 2>"${TMP}/gh_err"
  rc=$?
}
# The fake writes its files through the env vars it gets, and review-gh clears the environment, so
# for the allowed calls point it at fixed paths by wrapping the real fake.
cat >"${TMP}/realbin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${TMP}/gh_argv"
env | sort >"${TMP}/gh_env"
STUB
rgh pr view 7 --json title,body,files
if [[ "${rc}" -eq 0 && "$(head -2 "${TMP}/gh_argv" | tr '\n' ' ')" == "pr view " ]]; then
  t_pass "wrapper: pr view goes through"
else
  t_fail "wrapper: pr view gave rc=${rc}: $(cat "${TMP}/gh_err")"
fi
if grep -qx 'GH_TOKEN=ghs_readOnlyTokenForTheTest' "${TMP}/gh_env" && grep -qx 'GH_REPO=acme/repo' "${TMP}/gh_env" \
  && grep -qx 'GH_HOST=github.com' "${TMP}/gh_env" && ! grep -qE 'CLAUDE_CODE_OAUTH_TOKEN|ACTIONS_ID_TOKEN' "${TMP}/gh_env"; then
  t_pass "wrapper: gh gets the read-only token, the repository and the host, and nothing else of the caller's environment"
else
  t_fail "wrapper: gh's environment was $(tr '\n' ' ' <"${TMP}/gh_env")"
fi
for ok in "pr diff 7" "pr list --state open" "issue view 12 --json body" "search prs fix --limit 5"; do
  # shellcheck disable=SC2086
  rgh ${ok}
  [[ "${rc}" -eq 0 && -s "${TMP}/gh_argv" ]] && t_pass "wrapper: '${ok}' goes through" || t_fail "wrapper: '${ok}' was refused: $(cat "${TMP}/gh_err")"
done
refused() { # label, args…
  local label="$1"; shift
  rgh "$@"
  [[ "${rc}" -ne 0 && ! -s "${TMP}/gh_argv" ]] && t_pass "wrapper: ${label} is refused before gh runs" \
    || t_fail "wrapper: ${label} gave rc=${rc}, gh ran: $([[ -s "${TMP}/gh_argv" ]] && echo yes || echo no)"
}
refused "pr comment" pr comment 7 --body x
refused "pr review" pr review 7 --approve
refused "api" api /user
refused "auth token" auth token
refused "search repos" search repos x
refused "--jq" pr view 7 --json title --jq '$ENV'
refused "--jq=" pr view 7 --json title '--jq=$ENV'
refused "-q" pr view 7 --json title -q '$ENV'
refused "--template" pr view 7 --json title --template '{{env}}'
refused "-t" pr view 7 --json title -t x
refused "--repo" pr view 7 --repo other/repo
refused "-R" pr view 7 -R other/repo
refused "--hostname" pr view 7 --hostname evil.example
refused "--web" pr view 7 --web
refused "a URL" pr view 'https://evil.example/acme/repo/pull/7'
refused "a host path" pr view 'evil.example/acme/repo/pull/7'
refused "a URL on github.com too" pr view 'https://github.com/other/repo/pull/7'
refused "an ssh remote" pr view 'git@evil.example:acme/repo'
refused "a flag before the subcommand" --repo other/repo pr view 7

# --- the post ----------------------------------------------------------------------------------------
# The stub curl: logs "METHOD URL TOKEN-KIND" per call, keeps argv and the -K config, keeps the
# comments posted in a JSON list that the GET then serves after the EXISTING ones.
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
who=none
grep -qF 'ghs_jobTokenForTheTest' <<<"${cfg}" && who=job
grep -qF 'ghs_appTokenForTheReviewPostTest01' <<<"${cfg}" && who=app
printf '%s %s %s\n' "${method}" "${url}" "${who}" >>"${CURL_LOG}"
answer() { # <status> <body>
  printf '%s' "$2"
  [[ -n "${wfmt}" ]] && printf '\n%s' "$1"
  [[ "${fail}" == 1 && "$1" -ge 400 ]] && exit 22
  exit 0
}
case "${method} ${url}" in
  *audience=claude-code-github-action*) answer 200 '{"value":"oidc-jwt-for-the-test"}' ;;
  *github-app-token-exchange*) printf '%s\n' "${data}" >"${EXCHANGE_DATA}"
    answer "${EXCHANGE_STATUS:-200}" "${EXCHANGE_BODY:-{\"token\":\"ghs_appTokenForTheReviewPostTest01\"}}" ;;
  *"/installation/token") answer 204 '' ;;
  "POST "*/comments) [[ "${POST_FAIL:-0}" == 1 ]] && answer 500 '{"message":"boom"}'
    [[ "${POST_DROP:-0}" == 1 ]] || jq --argjson b "${data}" --arg who "${who}" '. + [{id: (900 + length), user: {login: $who}, body: $b.body}]' "${POSTED}" >"${POSTED}.n" && mv "${POSTED}.n" "${POSTED}"
    answer 201 '{"id":1}' ;;
  "GET "*/comments*) answer 200 "$(jq -c --argjson e "${EXISTING:-[]}" '$e + .' "${POSTED}")" ;;
  *) echo "stub curl: unexpected ${method} ${url}" >&2; exit 7 ;;
esac
STUB
chmod +x "${TMP}/bin/curl"

reset() { for f in argv stdin log exchange; do : >"${TMP}/${f}"; done; echo '[]' >"${TMP}/posted"; }
envs=(CURL_ARGV="${TMP}/argv" CURL_STDIN="${TMP}/stdin" CURL_LOG="${TMP}/log" POSTED="${TMP}/posted"
  EXCHANGE_DATA="${TMP}/exchange" GITHUB_API_URL='https://api.example.test' GH_API_TOKEN='ghs_jobTokenForTheTest'
  ACTIONS_ID_TOKEN_REQUEST_URL='https://token.example.test/oidc?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN='reqTokenForTheTest'
  REVIEW_MARKER="${MARKER}" REPO='acme/repo' RUN_URL='https://example.test/run/1' BASELINE=10 PATH="${TMP}/bin:${PATH}")
run_post() { # <final message> [VAR=value…]
  reset
  printf '%s' "$1" >"${TMP}/final.md"
  shift
  out="$(env "${envs[@]}" PR=7 EVENT=pull_request CLAUDE_RAN=true FINAL="${TMP}/final.md" "$@" bash "${TMP}/post.sh" 2>&1)"
  rc=$?
}
calls() { tr '\n' '|' <"${TMP}/log"; }
posted_by() { jq -r --arg w "$1" '[.[] | select(.user.login == $w) | .body] | last // ""' "${TMP}/posted"; }
APP='ghs_appTokenForTheReviewPostTest01'
no_secret_in_argv() { ! grep -qE "${APP}|ghs_jobTokenForTheTest|oidc-jwt-for-the-test|reqTokenForTheTest" "${TMP}/argv"; }
REVIEW=$'<!-- verify-pr-review -->\n\n### Blocking problems\nNone.\n\n### Verdict\nApprove'

run_post $'Here is the review of #9 you asked for.\n'"${REVIEW}"
[[ "${rc}" -eq 0 && "$(posted_by app)" == "${REVIEW}" ]] && t_pass "post 1: the final message is posted from the marker line on, as the App" \
  || t_fail "post 1: rc=${rc}, posted '$(posted_by app)': ${out}"
expected='GET https://token.example.test/oidc?api-version=2.0&audience=claude-code-github-action none|POST https://api.anthropic.com/api/github/github-app-token-exchange none|POST https://api.example.test/repos/acme/repo/issues/7/comments app|DELETE https://api.example.test/installation/token app|GET https://api.example.test/repos/acme/repo/issues/7/comments?per_page=100&page=1 job|'
[[ "$(calls)" == "${expected}" ]] && t_pass "post 1: OIDC, exchange, one comment on this run's PR, revoke, then the check with the job's token" \
  || t_fail "post 1: calls were $(calls)"
[[ "$(jq -c . "${TMP}/exchange")" == '{"permissions":{"pull_requests":"write"}}' ]] && t_pass "post 1: the exchange asks for pull_requests write only" \
  || t_fail "post 1: the exchange asked for '$(cat "${TMP}/exchange")'"
no_secret_in_argv && t_pass "post 1: no token or request value is in curl's argv" || t_fail "post 1: a secret is in argv"

run_post $'### Blocking problems\nNone.\n\n### Verdict\nApprove'
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 2: a final message without the marker posts nothing and mints nothing" \
  || t_fail "post 2: rc=${rc}, calls $(calls)"
run_post ''
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 2: nor does an empty one" || t_fail "post 2b: rc=${rc}"
for secret in 'sk-ant-oat01-AbCdEfGhIjKlMnOp' 'ghs_0123456789abcdefghijABCDEFGHIJ' 'github_pat_0123456789abcdefghij_xyz' \
  '-----BEGIN RSA PRIVATE KEY-----' 'ACTIONS_ID_TOKEN_REQUEST_TOKEN=abc' 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ4In0.sig'; do
  run_post "${REVIEW}"$'\n\nenv: '"${secret}"
  [[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 3: a review carrying ${secret:0:14}… is not posted" \
    || t_fail "post 3: a review carrying ${secret:0:14}… gave rc=${rc}, calls $(calls)"
done
run_post "${REVIEW}"$'\n'"$(head -c 61000 /dev/zero | tr '\0' 'a')"
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 4: an oversized review is not posted" || t_fail "post 4: rc=${rc}"
run_post "${REVIEW}" PR='7; touch pwned'
[[ "${rc}" -ne 0 && ! -s "${TMP}/log" ]] && t_pass "post 5: a pr that is not a number is refused before any call" || t_fail "post 5: rc=${rc}"
run_post "${REVIEW}" POST_FAIL=1
[[ "${rc}" -ne 0 && "$(tail -1 "${TMP}/log")" == 'DELETE https://api.example.test/installation/token app' && "$(grep -c '^POST .*/comments' "${TMP}/log")" -eq 1 ]] \
  && t_pass "post 6: a failed comment fails the step, is not retried, and the token is still revoked" || t_fail "post 6: rc=${rc}, calls $(calls)"
run_post "${REVIEW}" POST_DROP=1
[[ "${rc}" -ne 0 && "${out}" == *"Review posted nothing"* ]] && t_pass "post 7: a comment that did not land reddens the job (the assertion)" \
  || t_fail "post 7: rc=${rc}: ${out}"
run_post "${REVIEW}" EXISTING="[{\"id\":5,\"user\":{\"login\":\"claude[bot]\"},\"body\":\"${MARKER} old\"}]" POST_DROP=1
[[ "${rc}" -ne 0 ]] && t_pass "post 7: an older review below the baseline does not satisfy it" || t_fail "post 7b: rc=${rc}"
run_post "${REVIEW}" EXCHANGE_STATUS=500 EXCHANGE_BODY='{"message":"internal"}'
[[ "${rc}" -ne 0 && "$(posted_by app)$(posted_by job)" == "" ]] && t_pass "post 8: a failed exchange posts nothing and reddens the job" || t_fail "post 8: rc=${rc}, calls $(calls)"
run_post "${REVIEW}" EXCHANGE_STATUS=401 EXCHANGE_BODY='{"message":"Workflow validation failed. The workflow file must exist and have identical content to the version on the repository default branch."}'
[[ "${rc}" -eq 0 && "$(posted_by app)" == "" && "$(posted_by job)" == *'<!-- verify-pr-skipped -->'* && "$(posted_by job)" != *"${MARKER}"* ]] \
  && t_pass "post 9: a workflow that differs from the default branch's gets the not-reviewed note, never a review" || t_fail "post 9: rc=${rc}, calls $(calls): ${out}"

# --- the not-reviewed note ---------------------------------------------------------------------------
run_post '' CLAUDE_RAN=false
[[ "${rc}" -eq 0 && "$(posted_by job)" == *'<!-- verify-pr-skipped -->'*'-f pr=7'* ]] && ! grep -q 'oidc\|exchange' "${TMP}/log" \
  && t_pass "note 1: a review that never ran gets the note, with the job's token and no App token" || t_fail "note 1: rc=${rc}, calls $(calls)"
[[ "$(posted_by job)" != *"${MARKER}"* ]] && t_pass "note 1: the note never carries the review marker" || t_fail "note 1: the note carries the review marker"
run_post '' CLAUDE_RAN=false EXISTING='[{"id":3,"user":{"login":"github-actions[bot]"},"body":"<!-- verify-pr-skipped -->\nold"}]'
[[ "${rc}" -eq 0 && "$(grep -c '^POST' "${TMP}/log")" -eq 0 ]] && t_pass "note 2: once per PR" || t_fail "note 2: calls $(calls)"
run_post '' CLAUDE_RAN=false EVENT=workflow_dispatch
[[ "${rc}" -eq 0 && ! -s "${TMP}/log" ]] && t_pass "note 3: a dispatch posts no note" || t_fail "note 3: calls $(calls)"

# --- the jobs ----------------------------------------------------------------------------------------
job() { awk -v j="  $1:" '$0 == j {on = 1; print; next} on && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {on = 0} on' "${WORKFLOW}"; }
perms_of() { awk '/^    permissions:$/ {on = 1; next} on && /^      / {print; next} on {exit}' <<<"$1" | tr -d ' ' | sort | tr '\n' ' '; }
review_job="$(job claude-review)"
post_job="$(job post-review)"
nc() { grep -v '^[[:space:]]*#' <<<"$1"; }
[[ "$(perms_of "${review_job}")" == "contents:read issues:read pull-requests:read " ]] \
  && t_pass "job: the review job's token is read-only, and it has no id-token grant" || t_fail "job: the review job's permissions are '$(perms_of "${review_job}")'"
[[ "$(perms_of "${post_job}")" == "contents:read id-token:write pull-requests:write " ]] \
  && t_pass "job: the post job holds the write and OIDC grants" || t_fail "job: the post job's permissions are '$(perms_of "${post_job}")'"
[[ "$(grep -cx '      id-token: write' "${WORKFLOW}")" -eq 1 && "$(grep -cx '      pull-requests: write' "${WORKFLOW}")" -eq 1 ]] \
  && t_pass "job: id-token and pull-requests write appear once each, in the post job" || t_fail "job: a write grant appears outside the post job"
! grep -qE 'uses: (anthropics/claude-code-action|actions/checkout|\./)' <<<"$(nc "${post_job}")" \
  && t_pass "job: the post job runs no model and nothing from any checkout" || t_fail "job: the post job checks out code or runs a model"
grep -qx "    needs: claude-review" <<<"${post_job}" && grep -q 'uses: actions/download-artifact@' <<<"${post_job}" \
  && t_pass "job: the post job takes the review job's saved final message" || t_fail "job: the post job does not download the review"
order="$(grep -oE '^        id: (review_gh|claude-review|save)$' <<<"${review_job}" | sed 's/^        id: //' | tr '\n' '|')"
[[ "${order}" == "review_gh|claude-review|save|" ]] && t_pass "job: the wrapper, the review, then the save" || t_fail "job: the steps run as ${order}"
[[ "$(grep -c 'uses: anthropics/claude-code-action' "${WORKFLOW}")" -eq 1 ]] && ! nc "$(cat "${WORKFLOW}")" | grep -q 'always()' \
  && t_pass "job: one model step, and nothing runs regardless of the steps before it" || t_fail "job: a second model step or an always()"
grep -q 'name: verify-pr-review' <<<"${review_job}" && t_pass "job: the review job uploads the final message" || t_fail "job: no upload of the review"

printf '\n[review-post] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
