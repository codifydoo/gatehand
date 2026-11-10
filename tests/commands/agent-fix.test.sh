#!/usr/bin/env bash
# tests/commands/agent-fix.test.sh
# Pins .claude/commands/agent-fix.md to the job that runs it (agent-fixup.yml's `fix` job) and to
# .github/agents/policy.json, as tests/commands/agent-implement.test.sh pins the coder. The fixer
# gets EXACTLY the coder's tools and denies: it works in the same kind of job on the same box.
#
#   1. The command parses (frontmatter, description, allowed-tools) and reads `$ARGUMENTS`.
#   2. Its allowed-tools and the workflow's --allowedTools are the SAME set. A tool the command
#      needs but the workflow omits is denied silently in CI; one the workflow grants but the
#      command does not declare is a grant nobody reviewed.
#   3. The workflow's --disallowedTools keeps the denies that matter (push, PR/issue writes, gh api,
#      network, docker), and no allowed tool is also denied.
#   4. --model, --max-turns and timeout-minutes equal policy.json's fixer role.
#   5. The command still states the rules the outbox enforces: Refs not Closes, a fast-forward on the
#      PR's head, the outbox files, the untrusted-input framing, and that it cannot push.
#
# The needles match LITERAL text such as `$ARGUMENTS`, so they are single-quoted on purpose.
# shellcheck disable=SC2016
# t_pass always returns 0, so `test && t_pass … || t_fail …` cannot run both branches.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
CMD="${REPO_ROOT}/.claude/commands/agent-fix.md"
WORKFLOW="${REPO_ROOT}/.github/workflows/agent-fixup.yml"
CODER="${REPO_ROOT}/.github/workflows/agent-coder.yml"
POLICY="${REPO_ROOT}/.github/agents/policy.json"

pass=0
fail=0
t_pass() { printf '\033[1;32m[agent-fix] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agent-fix] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

[[ -f "${CMD}" ]] || { t_fail ".claude/commands/agent-fix.md is missing"; exit 1; }

# --- 1 ---------------------------------------------------------------------------------------------
if [[ "$(head -1 "${CMD}")" == "---" ]] && grep -q '^description: ' "${CMD}" && grep -q '^allowed-tools: ' "${CMD}"; then
  t_pass "frontmatter: --- fence, description, allowed-tools"
else
  t_fail "frontmatter contract broken: the command will not be found, or will prompt for every tool"
fi
grep -q '\$ARGUMENTS' "${CMD}" && t_pass "reads \$ARGUMENTS" || t_fail "ignores \$ARGUMENTS: the issue number goes nowhere"
grep -q "prompt: \"/agent-fix " "${WORKFLOW}" && t_pass "the workflow invokes /agent-fix" || t_fail "the workflow does not invoke /agent-fix"

# --- 2 ---------------------------------------------------------------------------------------------
# Anchored to the start of the line and taking the match, for the reasons verify-pr.test.sh gives:
# a comment that mentions the flag must not be read as the flag.
flag() { grep -m1 -oE -- "^[[:space:]]*--$1 \"[^\"]*\"" "${2:-${WORKFLOW}}" | sed -E "s/^[[:space:]]*--$1 \"//; s/\"\$//"; }
wf_allow="$(flag allowedTools | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u)"
wf_deny="$(flag disallowedTools | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u)"
cmd_allow="$(grep -m1 '^allowed-tools: ' "${CMD}" | sed 's/^allowed-tools: //' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u)"
[[ -n "${wf_allow}" && -n "${wf_deny}" ]] || t_fail "could not read --allowedTools / --disallowedTools from the workflow (reformatted?)"
only_cmd="$(comm -23 <(printf '%s\n' "${cmd_allow}") <(printf '%s\n' "${wf_allow}") | tr '\n' ' ')"
only_wf="$(comm -13 <(printf '%s\n' "${cmd_allow}") <(printf '%s\n' "${wf_allow}") | tr '\n' ' ')"
[[ -z "${only_cmd// /}" ]] && t_pass "every tool the command declares is granted in CI" || t_fail "declared but not granted in CI (denied silently): ${only_cmd}"
[[ -z "${only_wf// /}" ]] && t_pass "the workflow grants nothing the command does not declare" || t_fail "granted in CI but not declared by the command: ${only_wf}"

# --- 3 ---------------------------------------------------------------------------------------------
missing=""
for must in 'Bash(git push:*)' 'Bash(git remote:*)' 'Bash(git config:*)' 'Bash(gh pr create:*)' 'Bash(gh pr merge:*)' \
  'Bash(gh pr comment:*)' 'Bash(gh issue comment:*)' 'Bash(gh issue edit:*)' 'Bash(gh api:*)' 'Bash(gh workflow:*)' \
  'Bash(gh secret:*)' 'Bash(gh auth:*)' 'Bash(curl:*)' 'Bash(wget:*)' 'Bash(ssh:*)' 'Bash(docker:*)' 'Bash(sudo:*)' \
  'Bash(gh:*)' 'WebFetch' 'WebSearch'; do
  grep -Fxq -- "${must}" <<<"${wf_deny}" || missing+=" ${must}"
done
[[ -z "${missing}" ]] && t_pass "--disallowedTools keeps every deny that bounds the agent" || t_fail "--disallowedTools lost:${missing}"
both="$(comm -12 <(printf '%s\n' "${wf_allow}") <(printf '%s\n' "${wf_deny}") | tr '\n' ' ')"
[[ -z "${both// /}" ]] && t_pass "no tool is both allowed and denied" || t_fail "allowed AND denied (deny wins, so the allow is dead): ${both}"
if grep -Fxq 'Bash' <<<"${wf_deny}"; then
  t_fail "a bare Bash deny removes the tool entirely, and every allowed command with it"
else
  t_pass "no bare Bash deny"
fi

[[ "$(flag allowedTools)" == "$(flag allowedTools "${CODER}")" ]] && t_pass "the fixer's --allowedTools are the coder's" || t_fail "the fixer's --allowedTools differ from the coder's"
[[ "$(flag disallowedTools)" == "$(flag disallowedTools "${CODER}")" ]] && t_pass "the fixer's --disallowedTools are the coder's" || t_fail "the fixer's --disallowedTools differ from the coder's"

# --- 4 ---------------------------------------------------------------------------------------------
want_model="$(jq -r '.roles.fixer.model' "${POLICY}")"
want_turns="$(jq -r '.roles.fixer.maxTurns' "${POLICY}")"
want_timeout="$(jq -r '.roles.fixer.timeoutMinutes' "${POLICY}")"
got_model="$(grep -m1 -oE '^[[:space:]]*--model [^[:space:]]+' "${WORKFLOW}" | awk '{print $2}')"
got_turns="$(grep -m1 -oE '^[[:space:]]*--max-turns [0-9]+' "${WORKFLOW}" | awk '{print $2}')"
got_timeout="$(awk '/^  fix:/ {on = 1} on && /^    timeout-minutes:/ {print $2; exit}' "${WORKFLOW}")"
[[ "${got_model}" == "${want_model}" ]] && t_pass "--model is policy's ${want_model}" || t_fail "--model is '${got_model}', policy says '${want_model}'"
[[ "${got_turns}" == "${want_turns}" ]] && t_pass "--max-turns is policy's ${want_turns}" || t_fail "--max-turns is '${got_turns}', policy says '${want_turns}'"
[[ "${got_timeout}" == "${want_timeout}" ]] && t_pass "fix job timeout-minutes is policy's ${want_timeout}" || t_fail "fix job timeout is '${got_timeout}', policy says '${want_timeout}'"

# --- 5 ---------------------------------------------------------------------------------------------
body="$(awk 'NR==1 && $0=="---" {fm=1; next} fm==1 && $0=="---" {fm=2; next} fm!=1' "${CMD}")"
for needle in 'Refs #N' 'Never write `Closes`' 'blocked.md' 'summary.md' 'fast-forward' \
  '<untrusted-fix-input>' 'CANNOT push' 'protected-paths.txt' 'Never weaken'; do
  grep -Fq -- "${needle}" <<<"${body}" && t_pass "the command says: ${needle}" || t_fail "the command no longer says: ${needle}"
done

printf '\n[agent-fix] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
