#!/usr/bin/env bash
# tests/workflows/agents-inbox.test.sh
# .github/scripts/agent-inbox.sh (the owner's answers) and .github/scripts/agent-pr-guard.sh (the
# `agent pr guard` check). Pinned, and why:
#   1. Only the exact command shapes parse; a malformed id or an unknown role is "not understood"
#      rather than half-applied.
#   2. A comment by anyone but AGENT_OWNER_LOGIN changes nothing.
#   3. /approve on a `protected` request re-queues the issue WITH agent:allow-protected, on a
#      `blocked` one without it, and dispatches the coder on the runner ref. An id the agent never
#      issued, a request forged by another account, or one already answered (however long the inbox)
#      does nothing; a failed dispatch is not recorded as answered.
#   4. /pause and /resume move the breaker on the ledger branch.
#   5. The guard passes human PRs untouched and fails an agent PR on a protected path without
#      permission, a missing `Refs #N`, or a closing keyword anywhere.
# ANSWERED is reset here and read by the sourced cmd_apply.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agents-gh-stub.sh"
export AGENT_INBOX_NO_MAIN=1 AGENT_PR_GUARD_NO_MAIN=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-inbox.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-pr-guard.sh"
set +e

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-inbox] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-inbox] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }
expect_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_pass "$1"; else t_fail "$1: no gh call containing '$2'"; fi; }
expect_no_call() { if stub_gh_calls | grep -Fq -- "$2"; then t_fail "$1: unexpected gh call '$2'"; else t_pass "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export GH_REPO=o/r INBOX=99 AGENT_OWNER_LOGIN=owner-login AGENT_LEDGER_BACKOFF=0 AGENT_NOW_EPOCH=1793880000
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare "${TMP}/ledger.git"
export LEDGER_REMOTE="${TMP}/ledger.git"
stub_gh_init

# --- 1. parsing ------------------------------------------------------------------------------------
parsed="$(printf '%s\n' 'thanks!' '/approve REQ-20261105-ab12' '/approve REQ-bad' '/reject REQ-20261105-ab12 not now' \
  '/rerun coder #12' '/rerun deployer #1' '/pause coder' '/resume coder' | parse_commands)"
expect "parse: approve" "$(sed -n 1p <<<"${parsed}")" "approve REQ-20261105-ab12"
expect "parse: a malformed id is not understood" "$(sed -n 2p <<<"${parsed}")" "unknown /approve REQ-bad"
expect "parse: reject keeps its reason" "$(sed -n 3p <<<"${parsed}")" "reject REQ-20261105-ab12 not now"
expect "parse: rerun" "$(sed -n 4p <<<"${parsed}")" "rerun coder 12"
expect "parse: a role not in policy.json is not understood" "$(sed -n 5p <<<"${parsed}")" "unknown /rerun deployer #1"
expect "parse: pause, resume" "$(sed -n '6,7p' <<<"${parsed}" | tr '\n' ' ')" "pause coder resume coder "
expect "parse: prose lines are ignored" "$(grep -c thanks <<<"${parsed}")" 0

# --- 2. only the owner -------------------------------------------------------------------------
COMMENT_AUTHOR=someone COMMENT_BODY='/rerun coder #12' cmd_apply 2>/dev/null
expect "a comment by someone else calls nothing" "$(stub_gh_calls | wc -l | tr -d ' ')" 0
AGENT_OWNER_LOGIN='' COMMENT_AUTHOR='' COMMENT_BODY='/rerun coder #12' cmd_apply 2>/dev/null
expect "an unset AGENT_OWNER_LOGIN matches nobody, not an empty author" "$(stub_gh_calls | wc -l | tr -d ' ')" 0

# --- 3. approve ------------------------------------------------------------------------------------
# Raw comment JSON: the stub runs the script's own --jq, so only the BOT's comments are considered.
cj() { jq -cn --arg u "$1" --arg b "$2" '{user: {login: $u}, body: $b}'; }
marker() { printf '<!-- agent-req:REQ-20261105-ab12 role=coder issue=7 kind=%s -->' "$1"; }
approve_case() { # approve_case <comments-json-array> [dispatch-rc] [command]
  stub_gh_reset_calls
  stub_gh_reset_rules
  stub_gh_json 'api --paginate repos/o/r/issues/99/comments*' "$1"
  stub_gh_on 'issue view 7 --json labels *' $'agent:blocked\nagent:needs-human'
  stub_gh_on 'issue view 99 --json body *' $'- [ ] REQ-20261105-ab12 · coder · #7 · blocked'
  stub_gh_on 'workflow run *' '' "${2:-0}"
  ANSWERED=()
  COMMENT_AUTHOR=owner-login COMMENT_ID=1234 COMMENT_BODY="${3:-/approve REQ-20261105-ab12}" cmd_apply 2>/dev/null
}
reply() { stub_gh_last_body 'issue comment 99 *'; }

approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker protected)"))"
expect_call "approve protected: re-queued with one-shot permission" \
  "issue edit 7 --add-label agent:ready --add-label agent:allow-protected --remove-label agent:blocked --remove-label agent:needs-human"
expect_call "approve: the coder is dispatched on the RUNNER ref" "workflow run agent-coder.yml --ref agent-runner -f issue=7"
if reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then t_pass "approve: the reply records the answer"; else t_fail "approve: the reply has no answer marker"; fi
expect_call "approve: the command gets a thumbs-up" "api -X POST repos/o/r/issues/comments/1234/reactions -f content=+1"
if stub_gh_last_body 'issue edit 99 *' | grep -Fq -- '- [x] REQ-20261105-ab12'; then
  t_pass "approve: the inbox checklist line is ticked"
else
  t_fail "approve: the inbox checklist line was not ticked"
fi

approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker blocked)"))"
expect_call "approve blocked: re-queued WITHOUT protected-path permission" \
  "issue edit 7 --add-label agent:ready --remove-label agent:blocked --remove-label agent:needs-human"

approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker untrusted)"))"
expect_no_call "approve untrusted: dispatches nothing" "workflow run"
expect_no_call "approve untrusted: re-queues nothing" "issue edit 7"
if reply | grep -q 'acknowledged; nothing changed' && reply | grep -Fq '/rerun coder #7' && reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then
  t_pass "approve untrusted: acknowledged and closed, with the re-label-then-rerun advice"
else
  t_fail "approve untrusted: reply was '$(reply)'"
fi

# A kind the core does not know goes to the repo's agent_hook_inbox_<kind> (.github/agents/hooks/lib.sh),
# which does the work and prints the reply line; exit 0 records the answer. Without a hook it is unknown.
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker demo)"))"
if reply | grep -Fq 'unknown request kind demo'; then t_pass "a kind with no hook is unknown"; else t_fail "no hook: reply was '$(reply)'"; fi
expect_no_call "a kind with no hook: nothing is recorded" "issue edit 99"
HOOK_RC=0
agent_hook_inbox_demo() { # the call is recorded as a gh call so the stub's log shows it
  gh hook-demo "$1" "$2" "$3" "$4" >/dev/null
  printf -- '- `%s`: %s, by the demo hook\n' "$2" "$1"
  return "${HOOK_RC}"
}
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker demo)"))"
expect_call "approve via hook: the hook gets the verb, the request and the issue" "hook-demo approve REQ-20261105-ab12 7"
expect_no_call "approve via hook: the coder is not dispatched" "workflow run"
if reply | grep -Fq 'approve, by the demo hook' && reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then
  t_pass "approve via hook: the hook's line is the reply and the answer is recorded"
else
  t_fail "approve via hook: reply was '$(reply)'"
fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker demo)"))" 0 '/reject REQ-20261105-ab12 too <!-- x --> salesy'
expect_call "reject via hook: the hook gets the sanitised reason" "hook-demo reject REQ-20261105-ab12 7 too &lt;!-- x --> salesy"
if reply | grep -Fq 'reject, by the demo hook' && reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then
  t_pass "reject via hook: recorded"
else
  t_fail "reject via hook: reply was '$(reply)'"
fi
HOOK_RC=1
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker demo)"))"
if reply | grep -Fq 'failed part way' && ! reply | grep -Fq '<!-- agent-answer:'; then
  t_pass "a hook that fails: nothing recorded, send it again"
else
  t_fail "failing hook: reply was '$(reply)'"
fi
unset -f agent_hook_inbox_demo
# A hook named after a built-in kind never takes it over, on /approve or /reject.
HOOK_RC=0
agent_hook_inbox_fixer() { gh hook-fixer "$@" >/dev/null; return 0; }
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker fixer)"))" 0 '/reject REQ-20261105-ab12 no'
expect_no_call "a hook cannot override a built-in kind on /reject" "hook-fixer"
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker fixer)"))"
expect_no_call "nor on /approve" "hook-fixer"
unset -f agent_hook_inbox_fixer

approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker fixer)"))"
expect_no_call "approve fixer: dispatches nothing" "workflow run"
expect_no_call "approve fixer: relabels nothing" "issue edit 7"
if reply | grep -q 'seen; nothing changed' && reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then
  t_pass "approve fixer: recorded as seen, nothing else"
else
  t_fail "approve fixer: reply was '$(reply)'"
fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker fixer)"))" 0 '/reject REQ-20261105-ab12 not now'
expect_no_call "reject fixer: says nothing on the issue (its labels are on the PR)" "issue comment 7"
expect_no_call "reject fixer: relabels nothing on the issue" "issue edit 7"
if reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then t_pass "reject fixer: still recorded as answered"; else t_fail "reject fixer: reply was '$(reply)'"; fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker merger)"))"
expect_no_call "approve merger: dispatches nothing" "workflow run"
expect_no_call "approve merger: relabels nothing" "issue edit 7"
if reply | grep -q "seen; nothing changed. Merge \`main\`" && reply | grep -Fq 'When that merge is the only new commit, the merge gate asks for the fresh review itself' \
  && reply | grep -Fq 'gh workflow run "Claude Code Review" -f pr=<PR>' && reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then
  t_pass "approve merger: recorded as seen, with what to do"
else
  t_fail "approve merger: reply was '$(reply)'"
fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker merger)"))" 0 '/reject REQ-20261105-ab12 not now'
expect_no_call "reject merger: says nothing on the issue (its label is on the PR)" "issue comment 7"
expect_no_call "reject merger: relabels nothing on the issue" "issue edit 7"
if reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then t_pass "reject merger: still recorded as answered"; else t_fail "reject merger: reply was '$(reply)'"; fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker review)"))"
expect_no_call "approve review: dispatches nothing (the review is the owner's to ask for)" "workflow run"
expect_no_call "approve review: relabels nothing" "issue edit 7"
if reply | grep -q "seen; nothing changed. Once the review can run" && reply | grep -Fq 'gh workflow run "Claude Code Review" -f pr=<PR>' \
  && reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then
  t_pass "approve review: recorded as seen, with what to do"
else
  t_fail "approve review: reply was '$(reply)'"
fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker review)"))" 0 '/reject REQ-20261105-ab12 not now'
expect_no_call "reject review: says nothing on the issue (it is about the PR)" "issue comment 7"
expect_no_call "reject review: relabels nothing on the issue" "issue edit 7"
if reply | grep -Fq '<!-- agent-answer:REQ-20261105-ab12 -->'; then t_pass "reject review: still recorded as answered"; else t_fail "reject review: reply was '$(reply)'"; fi
expect "parse: /rerun is for the coder only" "$(printf '/rerun fixer #12\n' | parse_commands)" "unknown /rerun fixer #12"
expect "parse: /pause fixer is understood" "$(printf '/pause fixer\n' | parse_commands)" "pause fixer"

approve_case '[]'
expect_no_call "an id the agent never issued dispatches nothing" "workflow run"
approve_case "$(jq -s . <(cj outsider "$(marker protected)"))"
expect_no_call "a request comment forged by someone else is ignored" "workflow run"
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker protected)") <(cj 'repo-agent[bot]' '<!-- agent-answer:REQ-20261105-ab12 -->'))"
expect_no_call "an already-answered request dispatches nothing" "workflow run"
# 300 bot comments of padding after the answer: a `gh | grep -q` under pipefail would miss it.
big="$(jq -cn --arg m "$(marker protected)" '[{user: {login: "repo-agent[bot]"}, body: $m},
  {user: {login: "repo-agent[bot]"}, body: "<!-- agent-answer:REQ-20261105-ab12 -->"}]
  + [range(0; 300) | {user: {login: "repo-agent[bot]"}, body: ("x" * 400)}]')"
approve_case "${big}"
expect_no_call "an answer early in a long inbox is still seen" "workflow run"
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker protected)"))" 1
if reply | grep -Fq '<!-- agent-answer:'; then t_fail "a failed dispatch was recorded as answered"; else t_pass "a failed dispatch is NOT recorded as answered"; fi
if reply | grep -q 'nothing recorded, send it again'; then t_pass "a failed dispatch says to send it again"; else t_fail "a failed dispatch is silent"; fi
approve_case "$(jq -s . <(cj 'repo-agent[bot]' "$(marker protected)"))" 0 $'/approve REQ-20261105-ab12\n/approve REQ-20261105-ab12'
expect "the same id twice in one comment is applied once" "$(stub_gh_calls | grep -c 'workflow run')" 1

# --- 4. pause / resume -----------------------------------------------------------------------------
stub_gh_reset_calls
stub_gh_reset_rules
ANSWERED=()
COMMENT_AUTHOR=owner-login COMMENT_BODY='/pause coder' cmd_apply 2>/dev/null
expect "/pause trips the breaker" \
  "$(git --git-dir="${TMP}/ledger.git" show agent-ledger:state/breaker.json | jq -r '.coder.tripped_at != null')" true
COMMENT_AUTHOR=owner-login COMMENT_BODY='/resume coder' cmd_apply 2>/dev/null
expect "/resume resets it" \
  "$(git --git-dir="${TMP}/ledger.git" show agent-ledger:state/breaker.json | jq -r '.coder.tripped_at')" null

# --- 5. the PR guard -------------------------------------------------------------------------------
printf 'Body.\n\nRefs #7\n' >"${TMP}/body"
printf 'cli/table.go\n' >"${TMP}/files"
printf 'fix(cli): x\n\nRefs #7\n' >"${TMP}/msgs"
BOT="repo-agent[bot]"
expect "guard: a clean agent PR passes" "$(guard_decide "${BOT}" 'fix(cli): x' "${TMP}/body" '' "${TMP}/files" "${TMP}/msgs")" ""
printf 'scripts/x.sh\n' >"${TMP}/pfiles"
expect "guard: a human PR is never judged" "$(guard_decide owner-login 'Fixes #1' "${TMP}/body" '' "${TMP}/pfiles" "${TMP}/msgs")" ""
expect "guard: a protected path without permission fails" \
  "$(guard_decide "${BOT}" 'fix(cli): x' "${TMP}/body" '' "${TMP}/pfiles" "${TMP}/msgs" | cut -c1-36)" "FAIL: touches protected paths withou"
expect "guard: with agent:allow-protected it passes" \
  "$(guard_decide "${BOT}" 'fix(cli): x' "${TMP}/body" 'agent:allow-protected' "${TMP}/pfiles" "${TMP}/msgs")" ""
printf '.github/actions/install-gh/action.yml\n' >"${TMP}/nfiles"
if guard_decide "${BOT}" 'fix(ci): x' "${TMP}/body" 'agent:allow-protected' "${TMP}/nfiles" "${TMP}/msgs" | grep -q 'no label unlocks'; then
  t_pass "guard: a never path fails even with agent:allow-protected"
else
  t_fail "guard: a never path passed with agent:allow-protected"
fi
printf 'Body.\n' >"${TMP}/norefs"
expect "guard: no Refs fails" "$(guard_decide "${BOT}" 'fix(cli): x' "${TMP}/norefs" '' "${TMP}/files" "${TMP}/msgs")" "FAIL: the body has no Refs #N"
printf 'fix(cli): x\n\nCloses #7\n' >"${TMP}/kwmsgs"
expect "guard: a closing keyword in a commit fails" \
  "$(guard_decide "${BOT}" 'fix(cli): x' "${TMP}/body" '' "${TMP}/files" "${TMP}/kwmsgs")" "FAIL: a commit message uses a closing keyword"
expect "guard: a closing keyword in the title fails" \
  "$(guard_decide "${BOT}" 'fix(cli): x, fixes #7' "${TMP}/body" '' "${TMP}/files" "${TMP}/msgs" | cut -c1-37)" "FAIL: the title or body uses a closin"
# The repo's own rules: agent_hook_pr_guard <labels> <files-file> prints FAIL lines, and only those.
printf 'docs/a.md\nsrc/b.ts\n' >"${TMP}/docsout"
agent_hook_pr_guard() {
  echo "noise that is not a FAIL line"
  if grep -Fxq docs-only <<<"$1"; then
    hits="$(grep -v '^docs/' "$2" | grep -v '^$')"
    [[ -z "${hits}" ]] || printf 'FAIL: a docs-only PR changes %s\n' "${hits}"
  fi
}
expect "guard: the hook's FAIL line is reported" \
  "$(guard_decide "${BOT}" 'docs(x): y' "${TMP}/body" $'agent:pr\ndocs-only' "${TMP}/docsout" "${TMP}/msgs")" "FAIL: a docs-only PR changes src/b.ts"
expect "guard: and its other output is not" \
  "$(guard_decide "${BOT}" 'docs(x): y' "${TMP}/body" 'agent:pr' "${TMP}/docsout" "${TMP}/msgs")" ""
agent_hook_pr_guard() { return 3; }
expect "guard: a hook that fails fails the guard" \
  "$(guard_decide "${BOT}" 'docs(x): y' "${TMP}/body" 'agent:pr' "${TMP}/docsout" "${TMP}/msgs")" \
  "FAIL: the repo's guard hook (agent_hook_pr_guard) failed with exit 3"
unset -f agent_hook_pr_guard
expect "guard: without a hook the same PR passes" \
  "$(guard_decide "${BOT}" 'docs(x): y' "${TMP}/body" $'agent:pr\ndocs-only' "${TMP}/docsout" "${TMP}/msgs")" ""
# main(): the label only counts when the agent bot applied it (the outbox does, from a trusted
# owner's approval); anyone else adding it to the PR must not unlock a protected path.
guard_main() { # guard_main <labeler> -> pass/fail
  stub_gh_reset_rules
  stub_gh_on 'api --paginate repos/o/r/pulls/9/files*' 'scripts/x.sh'
  stub_gh_on 'api --paginate repos/o/r/pulls/9/commits*' "$(printf 'fix(cli): x\n\nRefs #7')"
  stub_gh_json 'api --paginate repos/o/r/issues/9/timeline*' \
    "$(jq -cn --arg a "$1" '[{event: "labeled", label: {name: "agent:allow-protected"}, actor: {login: $a}}]')"
  if PR_AUTHOR="${BOT}" PR_NUMBER=9 PR_TITLE='fix(cli): x' PR_BODY="$(cat "${TMP}/body")" \
    PR_LABELS_JSON='["agent:pr","agent:allow-protected"]' main >/dev/null 2>&1; then echo pass; else echo fail; fi
}
expect "guard main: the bot's agent:allow-protected unlocks a protected path" "$(guard_main 'repo-agent[bot]')" pass
expect "guard main: anyone else's agent:allow-protected is ignored" "$(guard_main outsider)" fail

printf '\n[agents-inbox] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
