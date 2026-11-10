#!/usr/bin/env bash
# tests/workflows/agents-workflows.test.sh
# Static checks over the agent workflows (.github/workflows/agent-*.yml) for the properties the
# agents' safety rests on. Each is a line someone could delete in a tidy-up without noticing what
# it held up:
#   1. Every job has timeout-minutes and every workflow a top-level permissions block (this repo's
#      Actions default is WRITE on everything, so an omitted block is a wide one).
#   2. Nothing merges with --admin, and every App token is narrowed with permission-* inputs (an
#      unnarrowed token carries everything the App was granted).
#   3. The coder's code job: the agent pool, read-only permissions, no id-token, no App key, no
#      dependency caches (they would let a hijacked run poison main's caches), and the read-only
#      GITHUB_TOKEN handed to the action.
#   4. The publish job checks out the default branch without persisted credentials; the guard
#      checks out the PR's BASE; the inbox needs AGENT_OWNER_LOGIN and holds no Claude credential.
#   5. The review accepts the agent bot. Without `allowed_bots` the review silently skips every
#      agent PR, and it is the only qualitative gate before one merges. The
#      coder's own action step accepts it too, or every inbox-dispatched run fails.
#   6. Every job that mints the App token runs on the configured agent runner (policy.json
#      runners.agent), never wherever CI runs PR code; every coder checkout is of the default branch (the run's ref only scopes
#      caches); the gate is told the run's ref.
# t_pass always returns 0, so `test && t_pass … || t_fail …` cannot run both branches.
# shellcheck disable=SC2015
# `${{ … }}` in single quotes is literal workflow text to match, never shell.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
WF="${REPO_ROOT}/.github/workflows"

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-workflows] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-workflows] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
has() { if grep -Eq -- "$2" <<<"$3"; then t_pass "$1"; else t_fail "$1"; fi; }
hasline() { if grep -Fxq -- "$2" <<<"$3"; then t_pass "$1"; else t_fail "$1: no line '$2'"; fi; }
POLICY="${REPO_ROOT}/.github/agents/policy.json"
# The runs-on line render.sh writes for the agent runner: a label, or a flow sequence of labels.
AGENT_RUNS_ON="    runs-on: $(jq -r '.runners.agent | if type == "array" then "[" + (map(tojson) | join(", ")) + "]" else . end' "${POLICY}")"
hasnt() { if grep -Eq -- "$2" <<<"$3"; then t_fail "$1"; else t_pass "$1"; fi; }

# step_with <job-text> <regex>: the names of the steps with a line matching <regex>, one per line
# (a step without `name:` reads as its `uses:` value).
step_with() {
  awk -v re="$2" '/^      - / {n = $0; sub(/^      - (name|uses): /, "", n)} $0 ~ re && n != "" && !(n in seen) {seen[n] = 1; print n}' <<<"$1"
}
# job_block <file> <job-id>: the job's lines, from its key to the next job key.
job_block() { awk -v j="  $2:" '$0 == j {on = 1; print; next} on && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {on = 0} on' "$1"; }
# jobs_of <file>: the job ids.
jobs_of() { awk '/^jobs:[[:space:]]*$/ {on = 1; next} on && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {k = $1; sub(/:$/, "", k); print k}' "$1"; }

# Every agent-*.yml except agent-release.yml (the agent BINARY's release, not part of the agent
# system), so a new agent workflow gets these checks on arrival rather than when someone remembers
# to list it. The ones the agents cannot do without must exist.
files=()
for f in "${WF}"/agent-*.yml; do [[ "$(basename "${f}")" == agent-release.yml ]] || files+=("${f}"); done
for n in agent-coder.yml agent-inbox.yml agent-pr-guard.yml agent-sweep.yml agent-fixup.yml agent-merge.yml agent-triage.yml; do
  [[ -f "${WF}/${n}" ]] && t_pass "${n} exists" || t_fail "${n} is missing"
done
[[ " ${files[*]} " == *"/agent-release.yml "* ]] && t_fail "agent-release.yml is checked as an agent workflow" || t_pass "agent-release.yml is left out"

# --- 1 + 2 -----------------------------------------------------------------------------------------
for f in "${files[@]}"; do
  n="$(basename "${f}")"
  grep -q '^permissions:' "${f}" && t_pass "${n}: top-level permissions block" || t_fail "${n}: no top-level permissions block"
  while IFS= read -r job; do
    has "${n}: job '${job}' has timeout-minutes" '^    timeout-minutes: [0-9]+' "$(job_block "${f}" "${job}")"
  done < <(jobs_of "${f}")
  hasnt "${n}: never merges with --admin" '--admin' "$(cat "${f}")"
  # Every create-github-app-token step narrows its token.
  bad="$(awk '/uses: actions\/create-github-app-token@/ {on = 1; seen = 0; next}
    on && /^      - / { if (!seen) print NR; on = 0 }
    on && /permission-[a-z-]+: (read|write)/ { seen = 1 }
    END { if (on && !seen) print "eof" }' "${f}")"
  [[ -z "${bad}" ]] && t_pass "${n}: every App token is narrowed with permission-*" || t_fail "${n}: an App token step without permission-* (before line ${bad})"
done

# --- 3. the coder's code job -----------------------------------------------------------------------
code="$(job_block "${WF}/agent-coder.yml" code)"
# The negative checks read the job WITHOUT its comments: a comment that explains why a line is
# absent ("no id-token") must not read as the line being present.
code_nc="$(grep -v '^[[:space:]]*#' <<<"${code}")"
[[ -n "${code}" ]] && t_pass "agent-coder.yml: code job found" || t_fail "agent-coder.yml: no code job (renamed? these checks see nothing)"
hasline "code job runs on the agent runner" "${AGENT_RUNS_ON}" "${code}"
perms="$(awk '/^    permissions:/ {on = 1; next} on && /^      / {print; next} on {exit}' <<<"${code_nc}")"
hasnt "code job permissions grant no write" 'write' "${perms}"
# claude-code-action exports its github_token to the model as GH_TOKEN whatever the job sets, so the
# token itself must not reach issue or PR text: contents read, nothing more.
expect_eq() { [[ "$2" == "$3" ]] && t_pass "$1" || t_fail "$1: got '$2'"; }
perm_lines="$(grep -v '^[[:space:]]*$' <<<"${perms}" | tr -d ' ' | tr '\n' ' ')"
expect_eq "code job token is contents: read and nothing else" "${perm_lines}" "contents:read "
hasnt "code job requests no id-token" 'id-token' "${code_nc}"
hasnt "code job never sees the App private key" 'AGENT_APP_PRIVATE_KEY' "${code_nc}"
hasnt "code job mints no App token" 'create-github-app-token' "${code_nc}"
hasnt "code job saves no pnpm cache" 'cache: pnpm' "${code_nc}"
hasnt "code job restores no cache" 'actions/cache@|cache: (true|npm|pnpm|yarn|pip|gradle|maven)' "${code_nc}"
has "code job hands the action the read-only GITHUB_TOKEN" 'github_token: \$\{\{ secrets.GITHUB_TOKEN \}\}' "${code}"
has "code job checks out without persisting credentials" 'persist-credentials: false' "${code}"
# The repo's setup is two composite actions from MAIN's checkout, then sudo goes, then the model.
corder="$(grep -oE '^      - name: (project system packages|project toolchain|project dependencies|drop sudo|implement)$' <<<"${code_nc}" | sed 's/^      - name: //' | tr '\n' '|')"
expect_eq "code job: system packages, toolchain, dependencies, drop sudo, then the model" "${corder}" "project system packages|project toolchain|project dependencies|drop sudo|implement|"
has "code job's system packages are the repo's composite action" '^        uses: \./\.github/agents/system$' "${code_nc}"
has "code job's toolchain is the repo's composite action" '^        uses: \./\.github/agents/toolchain$' "${code_nc}"
has "code job's dependencies are the repo's composite action" '^        uses: \./\.github/agents/dependencies$' "${code_nc}"
# The sudo drop must come BEFORE the model step, or it protects nothing.
# The action's ref is cut off: tests/workflows/actions-pinned.test.sh is what checks it is a SHA.
order="$(grep -nE 'name: drop sudo|uses: anthropics/claude-code-action' <<<"${code_nc}" | cut -d: -f2- | sed -E 's/@.*$//' | tr -d ' ' | tr '\n' ' ')"
[[ "${order}" == "-name:dropsudo uses:anthropics/claude-code-action " ]] \
  && t_pass "code job drops sudo before the model runs" || t_fail "code job: sudo is not dropped before the model step (${order})"
# GitHub-hosted images keep the runner's grant in the 0750 /etc/sudoers.d: a glob there expanded by
# the runner user stays literal and deletes nothing, and once the grant is gone a second `sudo` line
# is refused. Both removals must be one root shell (the first live runs hit each in turn).
# The check must be `sudo -n -l` (any passwordless grant left, even one limited to a few commands),
# and all of it must sit in the `drop sudo` step itself, whose place before the model is checked above.
DROP_SUDO_LINE="          sudo sh -c 'sed -i -E \"/^[^#].*NOPASSWD/d\" /etc/sudoers && find /etc/sudoers.d -mindepth 1 -delete'"
DROP_SUDO_CHECK="          if sudo -n -l >/dev/null 2>&1 || sudo -n true 2>/dev/null; then"
sudoers_deleted_as_root() {
  local step
  step="$(awk '/^      - name: drop sudo$/ {on = 1; next} on && /^      - / {exit} on' <<<"$2")"
  if grep -qE 'sudoers\.d/\*' <<<"$2"; then t_fail "$1: a shell glob on /etc/sudoers.d expands as the runner user"
  elif grep -qE '^        (continue-on-error|if):' <<<"${step}"; then t_fail "$1: the drop sudo step can be skipped or fail without stopping the job"
  elif ! grep -qxF -- "${DROP_SUDO_LINE}" <<<"${step}"; then t_fail "$1: the drop sudo step does not remove both grants in one root shell"
  elif ! grep -qxF -- "${DROP_SUDO_CHECK}" <<<"${step}"; then t_fail "$1: the drop sudo step does not check for any passwordless grant left"
  elif [[ "$(grep -A3 -xF -- "${DROP_SUDO_CHECK}" <<<"${step}" | grep -cxE '            exit 1')" -ne 1 ]]; then t_fail "$1: the drop sudo check does not fail the job"
  else t_pass "$1 drops sudo in one root shell and fails if any passwordless grant is left"; fi
}
sudoers_deleted_as_root "code job" "${code_nc}"
pre="$(job_block "${WF}/agent-coder.yml" preflight)"
has "preflight is behind the AGENTS_ENABLED kill switch" "^    if: .*vars.AGENTS_ENABLED == 'true'$" "${pre}"

# --- 4 ---------------------------------------------------------------------------------------------
pub="$(job_block "${WF}/agent-coder.yml" publish)"
has "publish checks out the default branch" 'ref: \$\{\{ github.event.repository.default_branch \}\}' "${pub}"
has "publish checks out without persisting credentials" 'persist-credentials: false' "${pub}"
# A failed lock (or any preflight step after the gate) still releases the issue: publish runs on the
# gate's go, whatever became of the rest of preflight and of the code job.
has "publish runs on the gate's go, even when preflight or the code job failed" \
  "^    if: always\(\) && needs.preflight.outputs.go == 'true'$" "${pub}"
hasnt "publish runs no model" 'claude-code-action' "$(grep -v '^[[:space:]]*#' <<<"${pub}")"
guard="$(cat "${WF}/agent-pr-guard.yml")"
has "the guard reads main's scripts (the PR's base commit)" 'ref: \$\{\{ github.event.pull_request.base.sha \}\}' "${guard}"
has "the guard's job is named 'agent pr guard' (the required-check name)" 'name: agent pr guard' "${guard}"
has "the guard can read the PR timeline (who applied agent:allow-protected)" '^      issues: read$' "$(job_block "${WF}/agent-pr-guard.yml" guard)"
inbox="$(cat "${WF}/agent-inbox.yml")"
has "the inbox requires AGENT_OWNER_LOGIN" "vars.AGENT_OWNER_LOGIN != ''" "${inbox}"
has "the inbox matches the author to AGENT_OWNER_LOGIN" 'github.event.comment.user.login == vars.AGENT_OWNER_LOGIN' "${inbox}"
hasnt "the inbox holds no Claude credential" 'CLAUDE_CODE_OAUTH_TOKEN|claude-code-action' "$(grep -v '^[[:space:]]*#' <<<"${inbox}")"
# step_blocks <file> <uses-regex>: every step whose `uses:` matches, one per NUL-separated record.
step_blocks() {
  awk -v re="$2" '
    /^      - / { if (on) { printf "%s%c", buf, 0 } on = 0; buf = "" }
    /^      - / || on { buf = buf $0 "\n" }
    $0 ~ "uses: " re { on = 1 }
    /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { if (on) { printf "%s%c", buf, 0 } on = 0; buf = "" }
    END { if (on) printf "%s%c", buf, 0 }' "$1"
}
for f in "${files[@]}"; do
  n="$(basename "${f}")"
  k=0
  while IFS= read -r -d '' step; do
    k=$((k + 1))
    has "${n}: claude-code-action step ${k} gets an explicit github_token (no OIDC App token)" '^          github_token: ' "${step}"
    has "${n}: claude-code-action step ${k} accepts the agent bot as actor" '^          allowed_bots: repo-agent$' "${step}"
  done < <(step_blocks "${f}" 'anthropics/claude-code-action')
  [[ "${n}" != agent-coder.yml || "${k}" -ge 1 ]] && t_pass "${n}: claude-code-action steps found: ${k}" || t_fail "${n}: no claude-code-action step found (renamed?)"
done

# --- 6 ---------------------------------------------------------------------------------------------
for f in "${files[@]}"; do
  n="$(basename "${f}")"
  while IFS= read -r job; do
    block="$(job_block "${f}" "${job}")"
    if grep -q 'create-github-app-token' <<<"${block}"; then
      # Positive: the configured agent runner, so a typo or a copied CI label cannot put the key
      # somewhere nobody chose.
      hasline "${n}: job '${job}' mints the App token, so it runs on the agent runner" "${AGENT_RUNS_ON}" "${block}"
    fi
  done < <(jobs_of "${f}")
done
coder="$(cat "${WF}/agent-coder.yml")"
co_total="$(grep -c 'uses: actions/checkout@' <<<"${coder}")"
co_default="$(grep -A3 'uses: actions/checkout@' <<<"${coder}" | grep -c 'ref: \${{ github.event.repository.default_branch }}')"
[[ "${co_total}" -ge 3 && "${co_total}" == "${co_default}" ]] && t_pass "every coder checkout (${co_total}) is of the default branch" \
  || t_fail "${co_default} of ${co_total} coder checkouts pin the default branch"
has "the gate is told the run's ref" 'RUN_REF: \$\{\{ github.ref_name \}\}' "${pre}"
# The task is read ONCE, in preflight, right after the trust checks; the code job only gets that copy.
# A second read later would let an edit made in between reach the model unchecked.
has "preflight snapshots the task" 'agent-state.sh snapshot ' "${pre}"
has "preflight uploads the snapshot" 'name: agent-task' "${pre}"
has "preflight exports the snapshot's outcome" 'snapshot: \$\{\{ steps.snapshot.outcome \}\}' "${pre}"
has "publish hands the snapshot's outcome to the outbox" 'SNAPSHOT_RESULT: \$\{\{ needs.preflight.outputs.snapshot \}\}' "${pub}"
has "the code job downloads the snapshot" 'name: agent-task' "${code}"
hasnt "the code job never reads the issue itself" 'agent-sanitize-input.sh|gh issue view' "${code_nc}"
# Nor does the model: with gh it could read the live issue, its comments by anyone, and any other
# issue, which is the text the snapshot leaves out. No gh tool, a blanket deny, and no token for it.
hasnt "the model is granted no gh command" 'Bash\(gh ' "$(grep -E -- '^[[:space:]]*--allowedTools ' <<<"${code_nc}")"
has "the model is denied every gh command" 'Bash\(gh:\*\)' "$(grep -E -- '^[[:space:]]*--disallowedTools ' <<<"${code_nc}")"
hasnt "the code job installs no gh" 'install-gh' "${code_nc}"
# No step sets GH_TOKEN: the only token in this job is the read-only one the action hands the model.
expect_eq "the code job sets GH_TOKEN nowhere" "$(step_with "${code_nc}" 'GH_TOKEN')" ""
# On a cancelled run, steps without always() are skipped, and the lock would stay until its TTL.
pub_nc="$(grep -v '^[[:space:]]*#' <<<"${pub}")"
steps_n="$(grep -c '^      - ' <<<"${pub_nc}")"
always_n="$(awk '/^      - / {s++} /^        if: always\(\)/ {a[s] = 1} END {n = 0; for (k in a) n++; print n}' <<<"${pub_nc}")"
[[ "${steps_n}" -ge 5 && "${steps_n}" == "${always_n}" ]] && t_pass "every publish step (${steps_n}) runs even on a cancelled run" \
  || t_fail "publish: ${always_n} of ${steps_n} steps have if: always()"

# --- 7. the sweep ----------------------------------------------------------------------------------
sweep="$(cat "${WF}/agent-sweep.yml")"
sweep_job="$(job_block "${WF}/agent-sweep.yml" sweep)"
hasline "the sweep's schedule is policy.json's" "    - cron: \"$(jq -r .schedules.sweep "${POLICY}")\"" "${sweep}"
has "the sweep is behind the AGENTS_ENABLED kill switch" "^    if: vars.AGENTS_ENABLED == 'true'$" "${sweep_job}"
has "the sweep checks out the default branch" 'ref: \$\{\{ github.event.repository.default_branch \}\}' "${sweep_job}"
has "the sweep checks out without persisting credentials" 'persist-credentials: false' "${sweep_job}"
has "the sweep runs main's sweep script" 'run: bash .github/scripts/agent-sweep.sh run$' "${sweep_job}"
hasnt "the sweep runs no model" 'claude-code-action|CLAUDE_CODE_OAUTH_TOKEN' "$(grep -v '^[[:space:]]*#' <<<"${sweep}")"
has "the sweep's token can read whether a lock's run is still going, and re-dispatch a dead fix" '^          permission-actions: write$' "${sweep_job}"

# --- 8. the fixer ---------------------------------------------------------------------------------
# The same walls as the coder's code job, on the fix job: it runs code the agent wrote.
FX="${WF}/agent-fixup.yml"
fix="$(job_block "${FX}" fix)"
fix_nc="$(grep -v '^[[:space:]]*#' <<<"${fix}")"
[[ -n "${fix}" ]] && t_pass "agent-fixup.yml: fix job found" || t_fail "agent-fixup.yml: no fix job (renamed? these checks see nothing)"
hasline "fix job runs on the agent runner" "${AGENT_RUNS_ON}" "${fix}"
fperms="$(awk '/^    permissions:/ {on = 1; next} on && /^      / {print; next} on {exit}' <<<"${fix_nc}")"
expect_eq "fix job token is contents: read and nothing else" "$(grep -v '^[[:space:]]*$' <<<"${fperms}" | tr -d ' ' | tr '\n' ' ')" "contents:read "
hasnt "fix job requests no id-token" 'id-token' "${fix_nc}"
hasnt "fix job never sees the App private key" 'AGENT_APP_PRIVATE_KEY' "${fix_nc}"
hasnt "fix job mints no App token" 'create-github-app-token' "${fix_nc}"
hasnt "fix job saves no pnpm cache" 'cache: pnpm' "${fix_nc}"
hasnt "fix job restores no cache" 'actions/cache@|cache: (true|npm|pnpm|yarn|pip|gradle|maven)' "${fix_nc}"
has "fix job hands the action the read-only GITHUB_TOKEN" 'github_token: \$\{\{ secrets.GITHUB_TOKEN \}\}' "${fix}"
has "fix job checks out the head preflight checked" 'ref: \$\{\{ needs.preflight.outputs.head \}\}' "${fix}"
has "fix job checks out without persisting credentials" 'persist-credentials: false' "${fix}"
has "fix job runs only on preflight's go" "^    if: needs.preflight.outputs.go == 'true'$" "${fix}"
hasnt "fix job installs no gh" 'install-gh' "${fix_nc}"
expect_eq "fix job sets GH_TOKEN nowhere" "$(step_with "${fix_nc}" 'GH_TOKEN')" ""
# The fix job checked out the PR's head, so the repo's setup actions come from a sparse checkout of
# MAIN's .github/agents: the toolchain step still has sudo.
has "fix job's toolchain comes from main's copy" '^        uses: \./\.agents-main/\.github/agents/toolchain$' "${fix_nc}"
has "so do its dependencies" '^        uses: \./\.agents-main/\.github/agents/dependencies$' "${fix_nc}"
hasnt "fix job runs no setup action from the PR's head" 'uses: \./\.github/agents/' "${fix_nc}"
has "main's copy is a sparse checkout of .github/agents" '^          sparse-checkout: \.github/agents$' "${fix_nc}"
hasnt "the fixer model is granted no gh command" 'Bash\(gh ' "$(grep -E -- '^[[:space:]]*--allowedTools ' <<<"${fix_nc}")"
has "the fixer model is denied every gh command" 'Bash\(gh:\*\)' "$(grep -E -- '^[[:space:]]*--disallowedTools ' <<<"${fix_nc}")"
# Sudo is used once, for main's system packages, before the PR's head is on disk at all; then the
# toolchain and the dependencies (the PR's install scripts) run without it. Main's copy of the setup
# actions is gone before the model.
fsetup="$(grep -oE '^      - name: .*' <<<"${fix_nc}" | sed 's/^      - name: //' | grep -xE "main's system setup|project system packages|drop sudo|main's agent setup|project toolchain|project dependencies|remove main's agent setup|fix" | tr '\n' '|')"
expect_eq "fix job: system packages, drop sudo, then main's setup, toolchain, dependencies, cleanup, the model" \
  "${fsetup}" "main's system setup|project system packages|drop sudo|main's agent setup|project toolchain|project dependencies|remove main's agent setup|fix|"
sudo_line="$(grep -n '^      - name: drop sudo$' <<<"${fix_nc}" | cut -d: -f1)"
head_line="$(grep -n 'ref: \${{ needs.preflight.outputs.head }}' <<<"${fix_nc}" | cut -d: -f1)"
[[ -n "${sudo_line}" && -n "${head_line}" && "${sudo_line}" -lt "${head_line}" ]] && t_pass "fix job drops sudo before it checks out the PR's head" \
  || t_fail "fix job: sudo is still there when the PR's head is checked out (drop sudo at ${sudo_line:-?}, head at ${head_line:-?})"
has "fix job's system packages come from main's copy" '^        uses: \./\.agents-main/\.github/agents/system$' "${fix_nc}"
has "main's copy is kept out of the agent's commits" '^        run: echo "\.agents-main/" >> \.git/info/exclude$' "${fix_nc}"
forder="$(grep -nE 'name: drop sudo|uses: anthropics/claude-code-action' <<<"${fix_nc}" | cut -d: -f2- | sed -E 's/@.*$//' | tr -d ' ' | tr '\n' ' ')"
[[ "${forder}" == "-name:dropsudo uses:anthropics/claude-code-action " ]] && t_pass "fix job drops sudo before the model runs" \
  || t_fail "fix job: sudo is not dropped before the model step (${forder})"
sudoers_deleted_as_root "fix job" "${fix_nc}"
route="$(job_block "${FX}" route)"
has "route is behind the AGENTS_ENABLED kill switch" "vars.AGENTS_ENABLED == 'true'" "${route}"
hasnt "route runs no model" 'claude-code-action|CLAUDE_CODE_OAUTH_TOKEN' "$(grep -v '^[[:space:]]*#' <<<"${route}")"
has "route runs main's router" 'run: bash .github/scripts/agent-fixup.sh route$' "${route}"
# workflow_run.name is the RUN-name ("Claude review of PR #N" for the review), never the workflow's
# name: until 2026-11-07 a name match routed no review and skipped the gate after every dispatched
# review. Runs are told apart by their workflow file.
has "route matches a review run by its workflow file" \
  "github.event.workflow_run.path == '.github/workflows/claude-code-review.yml'" "${route}"
has "route hands the router the run's workflow file" '^          WR_PATH: \$\{\{ github.event.workflow_run.path \}\}$' "${route}"
fpre="$(job_block "${FX}" preflight)"
# Only a dispatched run (on agent-runner) gets as far as the model: workflow_run runs sit in main's
# cache scope and review runs in the PR's, where code the agent wrote must never run.
has "preflight runs only in a dispatched run, behind the kill switch" \
  "^    if: github.event_name == 'workflow_dispatch' && vars.AGENTS_ENABLED == 'true'$" "${fpre}"
has "the fixer's gate is told the run's ref" 'RUN_REF: \$\{\{ github.ref_name \}\}' "${fpre}"
fpub="$(job_block "${FX}" publish)"
fpub_nc="$(grep -v '^[[:space:]]*#' <<<"${fpub}")"
has "finalize gets the fix job's result (it tells a person's cancel from a timeout)" '^          FIX_RESULT: \$\{\{ needs\.fix\.result \}\}$' "${fpub}"
has "the fix job's name is the one finalize reads from the jobs API" '^    name: fix \(agent\)$' "$(job_block "${FX}" fix)"
# GitHub never cancels a job whose if: is always(), so a cancelled() in one of publish's steps would
# be true only on publish's own timeout, and would read that as a person's cancel.
hasnt "no publish step asks cancelled()" 'cancelled\(\)' "${fpub_nc}"
has "publish's token can read the annotations that say a job timed out" '^          permission-checks: read$' "${fpub}"
has "so can the sweep's" '^          permission-checks: read$' "${sweep_job}"
# cancelled(), always(), success() and failure() are allowed only in an `if:`. Anywhere else GitHub
# rejects the whole file, and none of the required checks runs a workflow linter.
status_misuse="$(grep -nE '(cancelled|always|success|failure)\(\)' "${WF}"/agent-*.yml | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(- )?if: |^[^:]+:[0-9]+:[[:space:]]*#')"
expect_eq "status functions appear only in if: lines of the agent workflows" "${status_misuse}" ""
# The fixer and the merge gate find a Claude review's job by these two names; renaming either
# would make every claude[bot] review unattributable and wedge every agent PR.
crr="$(cat "${WF}/claude-code-review.yml")"
has "the review workflow's run-name is the one review_runs matches" "^run-name: 'Claude review of PR #\\\$\\{\\{ inputs.pr \\|\\| github.event.pull_request.number \\}\\}'$" "${crr}"
has "the review job's id is claude-review" '^  claude-review:$' "${crr}"
has "an automatic review skips a fork's PR (it gets no secrets)" 'github.event.pull_request.head.repo.full_name == github.repository' "$(job_block "${WF}/claude-code-review.yml" claude-review)"
hasnt "and it has no name: that would override the id" '^    name: ' "$(job_block "${WF}/claude-code-review.yml" claude-review)"
has "review_attribution matches that job name" 'select\(.name == "claude-review"\)' "$(cat "${REPO_ROOT}/.github/scripts/agent-state.sh")"
has "review_runs matches that run-name" 'display_title == \\"Claude review of PR #' "$(cat "${REPO_ROOT}/.github/scripts/agent-state.sh")"
hasnt "the fixer's publish runs no model" 'claude-code-action' "${fpub_nc}"
order="$(grep -oE 'agent-outbox\.sh publish-fix|agent-fixup\.sh finalize' <<<"${fpub_nc}" | tr '\n' '|')"
expect_eq "publish validates and pushes the fix, then finalizes" "${order}" "agent-outbox.sh publish-fix|agent-fixup.sh finalize|"
fsteps="$(grep -c '^      - ' <<<"${fpub_nc}")"
falways="$(awk '/^      - / {s++} /^        if: always\(\)/ {a[s] = 1} END {n = 0; for (k in a) n++; print n}' <<<"${fpub_nc}")"
[[ "${fsteps}" -ge 5 && "${fsteps}" == "${falways}" ]] && t_pass "every fixer publish step (${fsteps}) runs even on a cancelled run" \
  || t_fail "fixer publish: ${falways} of ${fsteps} steps have if: always()"
fx_total="$(grep -c 'uses: actions/checkout@' "${FX}")"
fx_default="$(grep -A3 'uses: actions/checkout@' "${FX}" | grep -c 'ref: \${{ github.event.repository.default_branch }}')"
[[ "${fx_total}" -ge 4 && "${fx_default}" == "$((fx_total - 1))" ]] && t_pass "every fixer checkout but the fix job's (${fx_default} of ${fx_total}) is of the default branch" \
  || t_fail "${fx_default} of ${fx_total} fixer checkouts pin the default branch (want all but the fix job's)"
has "one dispatched fix per PR at a time" "format\('agent-fixup-pr-\{0\}', inputs.pr\)" "$(cat "${FX}")"

# --- 9. the merge gate ----------------------------------------------------------------------------
MG="${WF}/agent-merge.yml"
mg="$(cat "${MG}")"
mg_nc="$(grep -v '^[[:space:]]*#' <<<"${mg}")"
gate="$(job_block "${MG}" gate)"
has "the merge gate is behind the AGENTS_ENABLED kill switch" "vars.AGENTS_ENABLED == 'true'" "${gate}"
has "the merge gate runs after a review run, matched by its workflow file" \
  "github.event.workflow_run.path == '.github/workflows/claude-code-review.yml'" "${gate}"
has "the merge gate checks out the default branch" 'ref: \$\{\{ github.event.repository.default_branch \}\}' "${gate}"
has "the merge gate checks out without persisting credentials" 'persist-credentials: false' "${gate}"
has "the merge gate runs main's gate script" 'run: bash .github/scripts/agent-merge.sh run "\$WANT"$' "${gate}"
# Live only when the owner sets the variable: never a literal here.
has "AGENT_AUTO_MERGE comes from the repo variable" '^          AGENT_AUTO_MERGE: \$\{\{ vars.AGENT_AUTO_MERGE \}\}$' "${gate}"
hasnt "AGENT_AUTO_MERGE is never set to a literal" 'AGENT_AUTO_MERGE: *["'"'"']?true' "${mg_nc}"
hasnt "the merge gate runs no model" 'claude-code-action|CLAUDE_CODE_OAUTH_TOKEN' "${mg_nc}"
# On the job, not the workflow: every CI run starts this workflow, and a run whose job is skipped
# must not take the one pending slot from a gate run that matters.
has "one merge gate at a time, as a job-level group" '^      group: agent-merge$' "${gate}"
has "and a queued gate never cancels a running one" '^      cancel-in-progress: false$' "${gate}"
hasnt "no workflow-level concurrency for skipped runs to queue in" '^concurrency:' "${mg}"
hasline "it runs after CI (policy.json ci.workflowName), the Claude review and the guard" "    workflows: [$(jq -r '.ci.workflowName | tojson' "${POLICY}"), Claude Code Review, Agent PR guard]" "${mg}"
# actions: write dispatches the fresh review of a head the gate's own branch update made.
has "the gate's token can dispatch a review" '^          permission-actions: write$' "${gate}"
has "and update a branch (pull-requests: write)" '^          permission-pull-requests: write$' "${gate}"
hasnt "and holds no workflows permission (an update with workflow files goes to a person)" 'permission-workflows' "${gate}"
# Anchored at the start of a command line: prose and log messages that name the command do not count.
merge_calls="$(grep -E '^[[:space:]]*gh pr merge ' "${REPO_ROOT}/.github/scripts/agent-merge.sh")"
[[ -n "${merge_calls}" ]] && t_pass "the gate script has a gh pr merge call" || t_fail "no gh pr merge call in agent-merge.sh (renamed? these checks see nothing)"
hasnt "the gate never merges with --admin or --auto, nor squashes or rebases" '--admin|--auto|--squash|--rebase' "${merge_calls}"
while IFS= read -r c; do
  has "every gh pr merge is a merge commit pinned to the checked head" '--merge --match-head-commit "\$\{sha\}"' "${c}"
done <<<"${merge_calls}"

# --- 10. the coder's schedule and triage ----------------------------------------------------------
hasline "the coder's schedule is policy.json's" "    - cron: \"$(jq -r .schedules.coder "${POLICY}")\"" "${coder}"
kick="$(job_block "${WF}/agent-coder.yml" kick)"
kick_nc="$(grep -v '^[[:space:]]*#' <<<"${kick}")"
# A scheduled run is on main: it must do nothing but dispatch onto the runner ref.
has "the kick runs only on the schedule, behind the kill switch" "^    if: github.event_name == 'schedule' && vars.AGENTS_ENABLED == 'true'$" "${kick}"
has "the kick dispatches through main's script" 'run: bash .github/scripts/agent-state.sh kick$' "${kick}"
expect_eq "the kick's App token can dispatch and nothing else" \
  "$(grep -oE 'permission-[a-z-]+: (read|write)' <<<"${kick_nc}" | tr '\n' ' ')" "permission-actions: write "
hasnt "the kick runs no model" 'claude-code-action|CLAUDE_CODE_OAUTH_TOKEN' "${kick_nc}"
has "preflight runs only in a dispatched run (a scheduled run is on main)" \
  "^    if: github.event_name == 'workflow_dispatch' && vars.AGENTS_ENABLED == 'true'$" "${pre}"
has "the code job needs preflight's go" "^    if: needs.preflight.outputs.go == 'true'$" "${code}"
has "the scheduled run has its own concurrency group (a kick never cancels a pending dispatch)" \
  "^  group: \\$\\{\\{ github.event_name == 'schedule' && 'agent-coder-kick' \\|\\| 'agent-coder' \\}\\}$" "${coder}"
tri="$(cat "${WF}/agent-triage.yml")"
tri_job="$(job_block "${WF}/agent-triage.yml" triage)"
hasline "triage's schedule is policy.json's" "    - cron: \"$(jq -r .schedules.triage "${POLICY}")\"" "${tri}"
has "triage runs on new issues" '^    types: \[opened\]$' "${tri}"
has "triage is behind the kill switch, and takes only security issues from the issues event" \
  "contains\(github.event.issue.labels.\*.name, 'security'\)" "${tri_job}"
has "triage is behind AGENTS_ENABLED" "vars.AGENTS_ENABLED == 'true'" "${tri_job}"
has "triage checks out the default branch" 'ref: \$\{\{ github.event.repository.default_branch \}\}' "${tri_job}"
has "triage runs main's script, the issue through env" 'run: bash .github/scripts/agent-triage.sh run "\$ISSUE"$' "${tri_job}"
# Only a dispatch names one issue: an event run covers them all, since GitHub drops all but the
# newest pending run of a group and a batch import would otherwise leave most issues for tomorrow.
has "an event run triages every open security issue" '^          ISSUE: \$\{\{ inputs.issue \}\}$' "${tri_job}"
hasnt "triage runs no model" 'claude-code-action|CLAUDE_CODE_OAUTH_TOKEN' "$(grep -v '^[[:space:]]*#' <<<"${tri}")"
hasnt "no issue text is spliced into a run line" 'run:.*github\.event\.issue\.(title|body)' "${tri}"

# --- 5 ---------------------------------------------------------------------------------------------
has "claude-code-review.yml accepts the agent bot" '^          allowed_bots: repo-agent$' "$(cat "${WF}/claude-code-review.yml")"

# --- workflow_run is told apart by file, never by name ---------------------------------------------
for f in "${WF}"/agent-*.yml; do
  hasnt "$(basename "${f}"): no match on workflow_run.name (it is the run-name, not the workflow's)" \
    'workflow_run\.name' "$(grep -v '^[[:space:]]*#' "${f}")"
done
# The files the gate and the router look for, and the names their `workflows:` triggers list.
[[ -f "${WF}/claude-code-review.yml" ]] && t_pass "claude-code-review.yml is where the gate and the router expect it" || t_fail "claude-code-review.yml moved: update the workflow_run.path matches"
has "the review workflow is still named as the triggers list it" '^name: Claude Code Review$' "$(cat "${WF}/claude-code-review.yml")"
hasline "the fixer's trigger names the repo's CI workflow" "    workflows: [$(jq -r '.ci.workflowName | tojson' "${POLICY}"), Claude Code Review]" "$(cat "${FX}")"

# --- 10. runs that never reached the model (agent-lib.sh infra_failure) ----------------------------
# Finalize reads the run's jobs API to tell a failure before the model step from one after it, so the
# coder's publish token needs actions: read, and finalize needs both jobs' results.
has "the coder's publish token can read the run's jobs" '^          permission-actions: read$' "${pub}"
has "finalize gets the preflight job's result" '^          PREFLIGHT_RESULT: \$\{\{ needs.preflight.result \}\}$' "${pub}"
has "finalize gets the code job's result" '^          CODE_RESULT: \$\{\{ needs.code.result \}\}$' "${pub}"
has "finalize gets the snapshot's outcome (a failed snapshot is a refusal, never a free run)" '^          SNAPSHOT_RESULT: \$\{\{ needs.preflight.outputs.snapshot \}\}$' "${pub}"
has "the code job is named as finalize looks it up" '^    name: implement \(agent\)$' "${code}"
has "its model step is named as finalize looks it up" '^      - name: implement$' "${code}"
has "the fix job is named as finalize looks it up" '^    name: fix \(agent\)$' "${fix}"
has "its model step is named as finalize looks it up" '^      - name: fix$' "${fix}"
# shellcheck source=/dev/null
source "${REPO_ROOT}/.github/scripts/agent-lib.sh"
# step_names <job-text>: GitHub's display name of every step, in order: its `name:`, else "Run <uses>".
step_names() {
  awk '
    function emit() { if (seen) print (n != "" ? n : "Run " u) }
    /^      - / { emit(); seen = 1; n = ""; u = "" }
    /^      - name: |^        name: / { v = $0; sub(/^ *-? *name: /, "", v); n = v }
    /^      - uses: |^        uses: / { v = $0; sub(/^ *-? *uses: /, "", v); sub(/[[:space:]]+#.*$/, "", v); u = v }
    END { emit() }' <<<"$1"
}
# pre_steps <job-text> <stop-step>: the steps before <stop-step>, less the ones that may never be
# free (drop sudo, prepare the work branch).
pre_steps() { step_names "$1" | awk -v stop="$2" '$0 == stop {exit} {print}' | grep -vxF -e 'drop sudo' -e 'prepare the work branch'; }
# matches_one <name> <ere>...: exit 0 when <name> matches one of the anchored EREs.
matches_one() { local n="$1" re; shift; for re in "$@"; do [[ "${n}" =~ ^(${re})$ ]] && return 0; done; return 1; }
allow_check() { # allow_check <label> <job-text> <stop-step> <array-name>
  local label="$1" job="$2" stop="$3" arr="$4[@]" st re found bad="" unused=""
  local -a allow=("${!arr}")
  while IFS= read -r st; do matches_one "${st}" "${allow[@]}" || bad+="'${st}' "; done < <(pre_steps "${job}" "${stop}")
  [[ -z "${bad}" ]] && t_pass "${label}: every step before '${stop}' is classified" || t_fail "${label}: steps before '${stop}' missing from the allowlist: ${bad}"
  for re in "${allow[@]}"; do
    [[ "${re}" == 'Set up job' ]] && continue # GitHub's own first step, in no workflow file
    found=0
    while IFS= read -r st; do [[ "${st}" =~ ^(${re})$ ]] && { found=1; break; }; done < <(pre_steps "${job}" "${stop}")
    [[ "${found}" == 1 ]] || unused+="'${re}' "
  done
  [[ -z "${unused}" ]] && t_pass "${label}: every allowlist entry is a step before '${stop}'" || t_fail "${label}: allowlist entries that match no step before '${stop}': ${unused}"
}
allow_check "coder" "${code_nc}" implement CODER_PRE_AGENT_STEPS
# The fixer's checkout is the PR's head: from `project dependencies` on, the agent's code has run.
allow_check "fixer" "${fix_nc}" "project dependencies" FIXER_PRE_AGENT_STEPS
for re in "${FIXER_PRE_AGENT_STEPS[@]}"; do
  [[ "${re}" == 'project dependencies' || "${re}" == 'drop sudo' ]] && t_fail "fixer: '${re}' must never be a free failure"
done
for re in "${CODER_PRE_AGENT_STEPS[@]}"; do
  [[ "${re}" == 'drop sudo' || "${re}" == 'prepare the work branch' ]] && t_fail "coder: '${re}' must never be a free failure"
done
t_pass "neither allowlist frees drop sudo or prepare the work branch, nor the fixer's project dependencies"
has "the coder's daily grace is set" '^[0-9]+$' "$(jq -r '.roles.coder.infraGracePerDay' "${REPO_ROOT}/.github/agents/policy.json")"
has "the fixer's daily grace is set" '^[0-9]+$' "$(jq -r '.roles.fixer.infraGracePerDay' "${REPO_ROOT}/.github/agents/policy.json")"

printf '\n[agents-workflows] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
