#!/usr/bin/env bash
# bin/doctor.sh [<repo-dir>]: check an installed repository's setup. Read-only: it changes nothing,
# locally or on GitHub. Needs gh (authenticated, with read access to the repository), jq, bash 4+.
#
# Prints one line per check, `ok`, `WARN` or `FAIL`, and exits 1 when any check FAILs.
# ok, warn and bad always return 0, so `test && ok … || bad …` never runs both.
# shellcheck disable=SC2015
set -uo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${1:-.}" && pwd)"
POLICY="${REPO_DIR}/.github/agents/policy.json"
rc=0
ok() { printf 'ok    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; rc=1; }

[[ -f "${POLICY}" ]] || { bad "no .github/agents/policy.json: not installed (run the install skill)"; exit 1; }
p() { jq -r "$1" "${POLICY}"; }

# --- local files -----------------------------------------------------------------------------------
if out="$("${PKG}/bin/render.sh" --check "${REPO_DIR}" 2>&1)"; then
  ok "package files match policy.json and repo-agents $(jq -r .version "${PKG}/.claude-plugin/plugin.json")"
else
  bad "package files differ from a fresh render (re-render with the update skill):"
  while IFS= read -r l; do printf '        %s\n' "${l}"; done <<<"${out}"
fi
grep -q 'No toolchain configured' "${REPO_DIR}/.github/agents/toolchain/action.yml" 2>/dev/null && warn "toolchain/action.yml installs nothing: the agent may not be able to build or test"
grep -q 'No dependencies configured' "${REPO_DIR}/.github/agents/dependencies/action.yml" 2>/dev/null && warn "dependencies/action.yml installs nothing"
grep -q '(example)' "${REPO_DIR}/.github/agents/project.md" 2>/dev/null && warn "project.md still has its (example) lines: the agent has no checks to run"
[[ "$(p '.requiredChecks | length')" -gt 0 ]] || warn "policy.json requiredChecks is empty: auto-merge would wait only for the guard and the review"

# --- GitHub ---------------------------------------------------------------------------------------
command -v gh >/dev/null || { bad "gh is not installed; skipping the GitHub checks"; exit "${rc}"; }
NWO="$(cd "${REPO_DIR}" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
  || { bad "gh cannot see this repository (gh auth status?)"; exit "${rc}"; }
DEFAULT="$(cd "${REPO_DIR}" && gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
[[ "${DEFAULT}" == "$(p .baseBranch)" ]] && ok "baseBranch is the default branch (${DEFAULT})" \
  || bad "policy.json baseBranch is '$(p .baseBranch)' but the default branch is '${DEFAULT}'"

vars="$(gh variable list --repo "${NWO}" --json name,value 2>/dev/null)" || { warn "cannot list variables (needs admin); skipping"; vars='[]'; }
# An empty list is a real answer (no secrets yet); only a failed call skips the secret checks.
# Organisation secrets shared with the repo count too; they are not in the repo's own list.
if secrets="$(gh secret list --repo "${NWO}" --json name --jq '.[].name' 2>/dev/null)"; then
  can_secrets=1
  # On an error gh prints the error body to stdout, so append only on success. Fails on personal repos.
  if org="$(gh api --paginate "repos/${NWO}/actions/organization-secrets" --jq '.secrets[].name' 2>/dev/null)"; then
    secrets+=$'\n'"${org}"
  fi
else
  warn "cannot list secrets (needs admin); skipping"; can_secrets=0
fi
var() { jq -r --arg n "$1" '.[] | select(.name == $n) | .value' <<<"${vars}"; }
for v in AGENT_APP_CLIENT_ID AGENT_BOT_ID AGENT_OWNER_LOGIN; do
  [[ -n "$(var "${v}")" ]] && ok "variable ${v} is set" || bad "variable ${v} is not set"
done
[[ "${can_secrets}" -eq 0 ]] || { grep -qx AGENT_APP_PRIVATE_KEY <<<"${secrets}" && ok "secret AGENT_APP_PRIVATE_KEY is set" || bad "secret AGENT_APP_PRIVATE_KEY is not set"; }
case "$(p '.claude.auth // "oauth"')" in
  oauth) cred=CLAUDE_CODE_OAUTH_TOKEN ;;
  *) cred=ANTHROPIC_API_KEY ;;
esac
[[ "${can_secrets}" -eq 0 ]] || { grep -qx "${cred}" <<<"${secrets}" && ok "secret ${cred} is set" || bad "secret ${cred} is not set (policy.json claude.auth)"; }

bot="$(p .botLogin)"
if bot_id="$(gh api "users/${bot}" --jq .id 2>/dev/null)"; then
  [[ "$(var AGENT_BOT_ID)" == "${bot_id}" ]] && ok "AGENT_BOT_ID matches ${bot}" \
    || bad "AGENT_BOT_ID is '$(var AGENT_BOT_ID)', but ${bot} has id ${bot_id}"
else
  bad "no GitHub user ${bot}: create the App (its slug must be '${bot%\[bot\]}') or fix policy.json botLogin"
fi
case "$(var AGENTS_ENABLED)" in
  true) ok "AGENTS_ENABLED is true" ;;
  *) warn "AGENTS_ENABLED is not true: the agents are off" ;;
esac
[[ "$(var AGENT_AUTO_MERGE)" == true ]] && ok "AGENT_AUTO_MERGE is on" || warn "AGENT_AUTO_MERGE is off: the merge gate is a dry run"

runner_ref="$(p .runnerRef)"
blob() { gh api "repos/${NWO}/contents/.github/workflows/$1?ref=$2" --jq .sha 2>/dev/null; }
if gh api "repos/${NWO}/branches/${runner_ref}" >/dev/null 2>&1; then
  for wf in agent-coder.yml agent-fixup.yml; do
    if [[ -n "$(blob "${wf}" "${DEFAULT}")" && "$(blob "${wf}" "${DEFAULT}")" == "$(blob "${wf}" "${runner_ref}")" ]]; then
      ok "${runner_ref} has ${DEFAULT}'s ${wf}"
    else
      bad "${runner_ref}'s ${wf} is not ${DEFAULT}'s: git fetch origin ${DEFAULT} && git push origin origin/${DEFAULT}:${runner_ref}"
    fi
  done
else
  bad "no ${runner_ref} branch: git push origin origin/${DEFAULT}:refs/heads/${runner_ref}"
fi

# GitHub fires a cron only from the default branch and says nothing when it does not (one private repo
# on a Free personal account got its first scheduled run eight hours after the install, then one every
# four to eight hours, cause unconfirmed). An hourly sweep should have a
# scheduled run, even a skipped one, two hours after agent-sweep.yml reached the default branch: when
# its oldest commit came in through a PR, that is the PR's merge time, not the commit's own date.
sweep_cron="$(jq -r -s '(.[0] * .[1]).schedules.sweep // ""' "${PKG}/defaults/policy.json" "${POLICY}")"
read -r _ c_hour c_dom c_mon c_dow _ <<<"${sweep_cron}"
oldest="" added="" fired=""
if [[ "${c_hour:-}|${c_dom:-}|${c_mon:-}|${c_dow:-}" == '*|*|*|*' ]]; then
  oldest="$(gh api --paginate "repos/${NWO}/commits?sha=${DEFAULT}&path=.github/workflows/agent-sweep.yml&per_page=100" \
    --jq '.[] | "\(.sha) \(.commit.committer.date)"' 2>/dev/null | tail -n 1)" || oldest=""
  if [[ "${oldest}" == *" "* ]]; then
    added="${oldest#* }"
    merged="$(gh api "repos/${NWO}/commits/${oldest%% *}/pulls" 2>/dev/null \
      | jq -r --arg d "${DEFAULT}" '[.[] | select(.merged_at != null and .base.ref == $d) | .merged_at] | min // empty' 2>/dev/null)" || merged=""
    [[ -n "${merged}" ]] && added="${merged}"
  fi
  fired="$(gh api "repos/${NWO}/actions/workflows/agent-sweep.yml/runs?event=schedule&per_page=1" --jq .total_count 2>/dev/null)" || fired=""
fi
if [[ -z "${sweep_cron}" ]]; then
  warn "cannot read schedules.sweep from policy.json; not checking whether the sweep fires"
elif [[ "${c_hour:-}|${c_dom:-}|${c_mon:-}|${c_dow:-}" != '*|*|*|*' ]]; then
  ok "the sweep's schedule (${sweep_cron}) is not hourly; not checking whether it fires"
elif [[ -z "${added}" || ! "${fired}" =~ ^[0-9]+$ ]]; then
  warn "cannot tell whether the sweep runs on its schedule (no agent-sweep.yml on ${DEFAULT}, or the API refused)"
elif [[ "${fired}" -gt 0 ]]; then
  ok "the sweep has run on its schedule"
else
  hours="$(jq -n --arg d "${added}" '(now - ($d | fromdateiso8601)) / 3600 | floor')"
  if [[ "${hours}" -ge 2 ]]; then
    warn "the sweep has never run on its schedule in the ${hours} h since agent-sweep.yml reached ${DEFAULT}: dispatch the workflows by hand or from your own machine (README: Nothing runs on its schedule)"
  else
    ok "agent-sweep.yml reached ${DEFAULT} under 2 h ago; too early to check its schedule"
  fi
fi

labels="$(gh label list --repo "${NWO}" --limit 300 --json name --jq '.[].name' 2>/dev/null)"
missing=()
for l in agent:ready agent:in-progress agent:pr-open agent:pr agent:blocked agent:needs-human agent:hold agent:allow-protected agent:fixing; do
  grep -Fxq -- "${l}" <<<"${labels}" || missing+=("${l}")
done
[[ "${#missing[@]}" -eq 0 ]] && ok "the agent labels exist" || warn "missing labels (the workflows create them on first use, or run .github/scripts/agent-labels.sh): ${missing[*]}"

perm="$(gh api "repos/${NWO}/actions/permissions/workflow" 2>/dev/null)"
if [[ -n "${perm}" ]]; then
  [[ "$(jq -r .default_workflow_permissions <<<"${perm}")" == read ]] && ok "Actions' default token is read-only" \
    || warn "Actions' default GITHUB_TOKEN permission is write (Settings, Actions, General: choose read)"
  [[ "$(jq -r .can_approve_pull_request_reviews <<<"${perm}")" == false ]] && ok "Actions cannot approve PRs" \
    || warn "Actions may create and approve PRs (Settings, Actions, General: untick it)"
fi
if checks="$(gh api "repos/${NWO}/rules/branches/${DEFAULT}" --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | .[]' 2>/dev/null)"; then
  grep -Fxq 'agent pr guard' <<<"${checks}" && ok "'agent pr guard' is a required check" \
    || warn "'agent pr guard' is not a required check on ${DEFAULT} yet (add it after the first agent PR)"
else
  warn "cannot read ${DEFAULT}'s branch rules (for example a private repo on GitHub Free, which has none); the merge gate still checks 'agent pr guard' itself"
fi

exit "${rc}"
