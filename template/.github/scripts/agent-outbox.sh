#!/usr/bin/env bash
# .github/scripts/agent-outbox.sh
# The coder's OUTBOX: turns what the agent left behind into a pushed branch and a PR, or refuses.
#
# THE BOUNDARY THIS ENFORCES. The coder model runs in a job whose GitHub token is read-only, and it
# may only write files: commits on a local `agent-work` branch plus pr.json / pr-body.md /
# summary.md / blocked.md in its outbox directory. A LATER job, on a different runner, checks out
# the DEFAULT BRANCH (so this script and .github/agents/ are main's copies, not the agent's), takes
# the agent's commits from a git bundle, and runs this. Only here does a write-capable token exist,
# and nothing the agent wrote is executed: the bundle is data, the files are read with jq/grep/sed.
# So text in an issue that talks the model into "push to main" or "comment on #1" cannot do either:
# the model never had the means, and this script does only the one thing it was built for.
#
# What is refused (outcome=refused, the reason says which rule):
#   - pr.json not an object, a type outside policy.branchTypes, a bad slug, a title that is not
#     `type(scope): subject` or does not match the type
#   - no commits, a merge commit, more than 50 commits, a commit subject that is not conventional
#     with a scope, a commit not authored and committed as the agent bot (it could otherwise commit
#     as the owner with `--author`), any closing keyword (`fixes #N`…) in a commit, the title or
#     the body
#   - a PR body without `Refs #<issue>`, or longer than policy.maxPrBodyBytes (refused, never cut,
#     because cutting could drop the `Refs` line after it was checked)
#   - more than policy.maxChangedFiles files, a path with a control character, any `!` path in
#     .github/agents/protected-paths.txt (reason `never:<paths>`), or any other protected path unless
#     a person put `agent:allow-protected` on the issue (reason `protected:<paths>`)
#   - an open agent PR for the same issue already exists
#
# FIXES (publish-fix): the fixer's commits go on top of an existing agent PR's branch instead. The
# same commit rules apply to them, the range must sit on the PR's head as preflight saw it, and the
# push is a fast-forward or nothing (a person who pushed meanwhile wins). Paths are checked over the
# fix's own range AND the whole PR after it: protected paths only with the bot-applied
# agent:allow-protected on the PR, `!` paths never. A pr-body.md from the fixer replaces the PR's
# description (update_pr_body). Then one `<!-- agent-run:fix … sha=… -->` comment with the fixer's
# summary goes on the PR; that marker is what makes the router ask for a fresh review once CI is
# green on the new head.
#
# Usage: agent-outbox.sh publish | publish-fix
# Env:   OUTBOX (the downloaded artifact), FINAL_DIR (sanitised summary.md/blocked.md for finalize),
#        ISSUE, ATTEMPT, RUN_ID, RUN_URL, CODE_RESULT (the code job's result), SNAPSHOT_RESULT
#        (preflight's snapshot step outcome), GH_TOKEN, GH_REPO,
#        AGENT_BOT_EMAIL (the identity every agent commit must carry);
#        PUSH_URL and BASE_REF override the remote and the base (tests); AGENT_OUTBOX_NO_MAIN=1.
#        publish-fix also: PR, BRANCH, HEAD_SHA (preflight's view of the PR head), KIND, N.
# Outputs: outcome (pr-opened|blocked|no-op|refused|failed), reason, pr_number, pr_url, branch;
#          publish-fix: outcome fix-pushed|blocked|no-op|refused|failed, reason, new_head.
# Always exits 0 once it has decided an outcome: the finalize step reads the outputs.
#
# Backticks in the single-quoted printf formats are literal markdown, never meant to expand.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agent-lib.sh"

REFUSAL=""
# Reasons quote agent-written values (a pr.json field, a commit subject) and are posted as the bot,
# so they are flattened and sanitised here, once, for every rule.
refuse() { REFUSAL="$(printf '%s' "$1" | agent_oneline 300)"; return 1; }

# A conventional subject WITH a scope, the repo's commit style: `fix(cli): handle a nil table`.
conventional_re() { printf '^(%s)\\([a-z0-9][a-z0-9._/-]*\\)!?: [^[:space:]].{2,}$' "$(policy '.branchTypes | join("|")')"; }

# check_meta <pr.json>: sets META_TYPE, META_SLUG, META_TITLE.
check_meta() {
  local f="$1" re
  jq -e 'type == "object"' "${f}" >/dev/null 2>&1 || { refuse "pr.json is not a JSON object"; return 1; }
  META_TYPE="$(jq -r '.type // "" | tostring' "${f}")"
  META_SLUG="$(jq -r '.slug // "" | tostring' "${f}")"
  META_TITLE="$(jq -r '.title // "" | tostring' "${f}" | tr -d '\r' | head -1)"
  if ! jq -e --arg t "${META_TYPE}" '.branchTypes | index($t) != null' "${AGENT_POLICY}" >/dev/null; then
    refuse "pr.json type '${META_TYPE}' is not one of $(policy '.branchTypes | join(", ")')"
    return 1
  fi
  [[ "${META_SLUG}" =~ ^[a-z0-9][a-z0-9-]{2,59}$ ]] \
    || { refuse "pr.json slug '${META_SLUG}' must be 3-60 lowercase letters, digits or dashes"; return 1; }
  re="$(conventional_re)"
  [[ "${META_TITLE}" =~ ${re} ]] || { refuse "PR title is not 'type(scope): subject': ${META_TITLE}"; return 1; }
  [[ "${META_TITLE}" == "${META_TYPE}("* ]] || { refuse "PR title type does not match pr.json type '${META_TYPE}'"; return 1; }
  [[ ${#META_TITLE} -le 120 ]] || { refuse "PR title is longer than 120 characters"; return 1; }
  if printf '%s\n' "${META_TITLE}" | has_closing_keyword; then
    refuse "PR title uses a closing keyword; agent PRs say Refs #N"
    return 1
  fi
}

# check_commits <base> <head>
check_commits() {
  local base="$1" head="$2" n sha subject re who bot
  bot="$(policy '.botLogin')"
  [[ -n "${AGENT_BOT_EMAIL:-}" ]] || { refuse "AGENT_BOT_EMAIL is not set, so commit identity cannot be checked"; return 1; }
  n="$(git rev-list --count "${base}..${head}")"
  [[ "${n}" -ge 1 ]] || { refuse "no commits on top of the base"; return 1; }
  [[ "${n}" -le 50 ]] || { refuse "${n} commits; more than 50 is not one change"; return 1; }
  [[ -z "$(git rev-list --merges "${base}..${head}")" ]] || { refuse "a merge commit is in the range"; return 1; }
  re="$(conventional_re)"
  while IFS= read -r sha; do
    subject="$(git log -1 --format=%s "${sha}")"
    [[ "${subject}" =~ ${re} ]] || { refuse "commit ${sha:0:9} subject is not 'type(scope): subject': ${subject}"; return 1; }
    who="$(git log -1 --format='%an <%ae>|%cn <%ce>' "${sha}")"
    [[ "${who}" == "${bot} <${AGENT_BOT_EMAIL}>|${bot} <${AGENT_BOT_EMAIL}>" ]] \
      || { refuse "commit ${sha:0:9} is not authored and committed as ${bot}: ${who}"; return 1; }
    if git log -1 --format=%B "${sha}" | has_closing_keyword; then
      refuse "commit ${sha:0:9} uses a closing keyword; agent commits say Refs #N"
      return 1
    fi
  done < <(git rev-list --reverse "${base}..${head}")
}

# check_body <pr-body.md> <issue>
check_body() {
  local f="$1" issue="$2" max
  max="$(policy '.maxPrBodyBytes')"
  [[ -s "${f}" ]] || { refuse "pr-body.md is empty"; return 1; }
  [[ "$(wc -c <"${f}")" -le "${max}" ]] || { refuse "pr-body.md is longer than ${max} bytes"; return 1; }
  grep -Eq "(^|[^[:alnum:]_])Refs #${issue}([^0-9]|$)" "${f}" || { refuse "PR body does not say Refs #${issue}"; return 1; }
  if has_closing_keyword <"${f}"; then refuse "PR body uses a closing keyword; agent PRs say Refs #N"; return 1; fi
}

# check_paths <base> <head> <allow-protected: 0|1>: sets PROTECTED_ALLOWED when protected paths are
# touched with permission. --no-renames lists a rename as delete + add, so moving a protected file
# out of a protected directory still counts as touching it.
check_paths() {
  local base="$1" head="$2" allow="$3" files="" n max hits p
  # NUL-separated (`-z`), which git prints verbatim. Plain `--name-only` wraps a path with a
  # non-ASCII byte, a tab, a quote or a backslash in double quotes with octal escapes
  # (`".claude/skills/r\303\251/x"`), and the anchored globs below would never match it.
  while IFS= read -r -d '' p; do
    if [[ "${p}" =~ [[:cntrl:]] ]]; then refuse "a changed path contains a control character"; return 1; fi
    files+="${p}"$'\n'
  done < <(git diff -z --name-only --no-renames "${base}" "${head}")
  files="${files%$'\n'}"
  n="$(grep -c . <<<"${files}")"
  max="$(policy '.maxChangedFiles')"
  [[ "${n}" -le "${max}" ]] || { refuse "${n} files changed; the limit is ${max}"; return 1; }
  hits="$(never_hits <<<"${files}")"
  if [[ -n "${hits}" ]]; then
    refuse "never:$(tr '\n' ' ' <<<"${hits}" | head -c 300)"
    return 1
  fi
  hits="$(protected_hits <<<"${files}")"
  PROTECTED_ALLOWED=0
  if [[ -n "${hits}" ]]; then
    if [[ "${allow}" == "1" ]]; then
      PROTECTED_ALLOWED=1
    else
      refuse "protected:$(tr '\n' ' ' <<<"${hits}" | head -c 300)"
      return 1
    fi
  fi
}

# check_single_pr <issue>: one open agent PR per issue.
check_single_pr() {
  local issue="$1" dup
  dup="$(gh pr list --state open --label agent:pr --limit 100 --json number,body \
    --jq "[.[] | select(.body | test(\"(^|[^A-Za-z0-9_])Refs #${issue}([^0-9]|\$)\"))][0].number // empty")" \
    || { refuse "could not list open agent PRs"; return 1; }
  [[ -z "${dup}" ]] || { refuse "an open agent PR for #${issue} already exists: #${dup}"; return 1; }
}

push_url() {
  if [[ -n "${PUSH_URL:-}" ]]; then printf '%s\n' "${PUSH_URL}"; return; fi
  printf 'https://x-access-token:%s@github.com/%s.git\n' "${GH_TOKEN:?}" "${GH_REPO:?}"
}

finish() {
  output outcome "$1"
  output reason "$2"
  agent_log "outcome: $1${2:+ ($2)}"
}

# file_followups <outbox> <issue> <pr>: the things the coder noticed but left alone, from
# followups.json ([{title, body}]), filed as issues labelled agent:candidate: a person decides
# whether an agent takes one (agent-digest.sh lists them every week). At most
# roles.coder.maxFollowups per run; a title of 10 to 90 characters; a body of at least 40 with an
# acceptance section (the pick skips an issue without one, agent-state.sh `acceptance`, so an
# approved follow-up would never run); none with the title of an open issue. Both are sanitised like
# the PR body (no live mention, no marker), and an email-style `x@claude` is broken too, since
# Claude's GitHub workflow (claude.yml in many repos) starts on any `@claude` in a new issue. Best effort: a bad file or a failed call files
# nothing more and never changes the run's outcome, which is written before this runs.
file_followups() {
  local f="$1/followups.json" issue="$2" pr="$3" max n=0 row title len body open seen="" tmp url
  [[ -s "${f}" ]] || return 0
  max="$(policy '.roles.coder.maxFollowups // 0')"
  [[ "${max}" =~ ^[0-9]+$ ]] && (( max > 0 )) || return 0
  jq -e 'type == "array"' "${f}" >/dev/null 2>&1 || { agent_log "followups.json is not a list; no follow-up filed"; return 0; }
  open="$(gh issue list --state open --limit 500 --json title --jq '.[].title')" \
    || { agent_log "could not list open issues; no follow-up filed"; return 0; }
  open="$(tr '[:upper:]' '[:lower:]' <<<"${open}")"
  tmp="$(mktemp)"
  while IFS= read -r row; do
    (( n >= max )) && break
    title="$(jq -r '.title // "" | tostring' <<<"${row}" | agent_oneline 400 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/@([Cc][Ll][Aa][Uu][Dd][Ee])/@-\1/g')"
    # Characters, not bytes: 90 of them fit in 400 bytes, so the byte cut above only ever shortens a
    # title that is refused here anyway, and never splits a character of one that is filed.
    len="$(jq -rn --arg t "${title}" '$t | length')"
    if (( len < 10 || len > 90 )); then agent_log "follow-up skipped: title not 10 to 90 characters"; continue; fi
    if grep -Fxq -- "$(tr '[:upper:]' '[:lower:]' <<<"${title}")" <<<"${open}${seen}"; then
      agent_log "follow-up skipped: an open issue has the title '${title}'"
      continue
    fi
    body="$(jq -r '.body // "" | tostring' <<<"${row}" | agent_cap 3000 | agent_sanitize | sed -E 's/@([Cc][Ll][Aa][Uu][Dd][Ee])/@-\1/g')"
    if (( ${#body} < 40 )); then agent_log "follow-up skipped: '${title}' has no body"; continue; fi
    if ! grep -Eiq '^#{2,3} +(recommendation|done when|acceptance( criteria)?|suggested fix|expected( behaviou?r)?)([^[:alnum:]_]|$)|^\*\*(done when|acceptance)' <<<"${body}"; then
      agent_log "follow-up skipped: '${title}' has no ### Done when section"
      continue
    fi
    {
      printf '%s\n\n---\n' "${body}"
      printf '<sub>Noticed by the coder agent while working on #%s (PR #%s) and left alone. ' "${issue}" "${pr}"
      printf 'A candidate: add `agent:ready` if an agent should take it, or close it.</sub>\n'
      printf '<!-- agent-followup:issue=%s pr=%s -->\n' "${issue}" "${pr}"
    } >"${tmp}"
    if url="$(gh issue create --title "${title}" --body-file "${tmp}" --label agent:candidate </dev/null)"; then
      agent_log "follow-up filed: ${url}"
      n=$((n + 1))
      seen+=$'\n'"$(tr '[:upper:]' '[:lower:]' <<<"${title}")"
    else
      agent_log "follow-up '${title}' could not be filed"
    fi
  done < <(jq -c '.[] | select(type == "object")' "${f}" | head -n 20)
  rm -f "${tmp}"
  output followups "${n}"
}

cmd_publish() {
  local outbox="${OUTBOX:?}" final="${FINAL_DIR:?}" issue="${ISSUE:?}" base head labels allow url branch
  local body title max_body labels_csv err
  mkdir -p "${final}"
  # A failed snapshot means someone without write access changed the issue after the label the run
  # trusts (for a named dispatch that can be days ago), or the trust check could not run, and
  # nothing reached the agent. finalize_plan blocks it rather than re-queueing it.
  if [[ "${SNAPSHOT_RESULT:-}" == "failure" ]]; then
    finish refused "untrusted-change: someone without write access changed the issue after the label this run trusts, or the trust check failed, so nothing reached the agent (see the preflight log). Read the change, then re-apply agent:ready yourself and /rerun coder #${issue}"
    return 0
  fi
  if [[ "${CODE_RESULT:-}" != "success" ]]; then finish failed "the code job ended as ${CODE_RESULT:-unknown}"; return 0; fi
  if [[ ! -d "${outbox}" ]]; then finish failed "no outbox artifact"; return 0; fi

  max_body="$(policy '.maxCommentBytes')"
  # Capped BEFORE sanitising: a cut inside a code span the sanitiser kept would leave a live mention.
  if [[ -s "${outbox}/summary.md" ]]; then agent_cap "${max_body}" <"${outbox}/summary.md" | agent_sanitize >"${final}/summary.md"; fi
  if [[ -s "${outbox}/blocked.md" ]]; then
    agent_cap "${max_body}" <"${outbox}/blocked.md" | agent_sanitize >"${final}/blocked.md"
    finish blocked "the agent asked for a decision"
    return 0
  fi
  if [[ ! -s "${outbox}/agent.bundle" ]]; then finish no-op "the agent made no commits"; return 0; fi
  if [[ ! -s "${outbox}/pr.json" || ! -s "${outbox}/pr-body.md" ]]; then
    finish no-op "commits but no pr.json or pr-body.md"
    return 0
  fi

  if ! git bundle verify -q "${outbox}/agent.bundle" >/dev/null 2>&1; then finish refused "the bundle does not verify"; return 0; fi
  if ! git fetch -q "${outbox}/agent.bundle" "+refs/heads/agent-work:refs/agent/work" 2>/dev/null; then
    finish refused "the bundle has no agent-work branch"
    return 0
  fi
  head="refs/agent/work"
  if ! base="$(git merge-base "${BASE_REF:-origin/$(policy '.baseBranch')}" "${head}")"; then
    finish refused "the agent's work shares no history with the base branch"
    return 0
  fi
  if ! labels="$(gh issue view "${issue}" --json labels --jq '.labels[].name')"; then
    finish failed "could not read #${issue}"
    return 0
  fi
  # The label counts only if a writer (or the bot, acting on the owner's /approve) applied it:
  # a triage collaborator, or a workflow token with issues: write, can label issues too.
  allow=0
  if grep -Fxq 'agent:allow-protected' <<<"${labels}"; then
    local who
    who="$(label_applier "${issue}" agent:allow-protected)"
    if actor_trusted "${who}"; then
      allow=1
    else
      agent_log "ignoring agent:allow-protected on #${issue}: applied by ${who:-unknown}, who has no write access"
    fi
  fi

  if ! { check_meta "${outbox}/pr.json" && check_commits "${base}" "${head}" \
    && check_body "${outbox}/pr-body.md" "${issue}" && check_paths "${base}" "${head}" "${allow}" \
    && check_single_pr "${issue}"; }; then
    finish refused "${REFUSAL}"
    return 0
  fi

  url="$(push_url)"
  # `<type>/agent-<slug>`: the repo's `<type>/<slug>` convention (CLAUDE.md), marked as the agent's.
  branch="${META_TYPE}/agent-${META_SLUG}"
  if git ls-remote --exit-code --heads "${url}" "refs/heads/${branch}" >/dev/null 2>&1; then
    branch="${branch}-${RUN_ID:-$$}"
  fi
  err="$(mktemp)"
  if ! git push -q "${url}" "${head}:refs/heads/${branch}" 2>"${err}"; then
    # A push touching .github/workflows/ is refused by GitHub itself (the App has no Workflows
    # permission) even when agent:allow-protected let it this far: workflow changes stay human-made.
    finish refused "the push was rejected: $(sed -e "s#${GH_TOKEN:-__none__}#***#g" "${err}" | tr '\n' ' ' | head -c 300)"
    rm -f "${err}"
    return 0
  fi
  rm -f "${err}"

  body="$(mktemp)"
  {
    agent_sanitize <"${outbox}/pr-body.md"
    printf '\n\n---\n<sub>Opened by the coder agent for #%s (attempt %s, [run](%s)). ' "${issue}" "${ATTEMPT:-1}" "${RUN_URL:-}"
    printf 'It merges only through CI and the Claude review. Deploys and closing the issue stay with a person.</sub>\n'
    if [[ "${PROTECTED_ALLOWED:-0}" == "1" ]]; then
      printf '\n**Touches protected paths, with `agent:allow-protected` on #%s. A person merges this one.**\n' "${issue}"
    fi
    printf '<!-- agent-run:coder run=%s issue=%s -->\n' "${RUN_ID:-local}" "${issue}"
  } >"${body}"
  title="$(printf '%s\n' "${META_TITLE}" | agent_sanitize)"
  labels_csv="agent:pr"
  [[ "${PROTECTED_ALLOWED:-0}" == "1" ]] && labels_csv+=",agent:allow-protected"
  ensure_labels || agent_log "could not ensure labels; gh pr create may fail on a missing one"
  if ! url="$(gh pr create --base "$(policy '.baseBranch')" --head "${branch}" --title "${title}" \
    --body-file "${body}" --label "${labels_csv}")"; then
    rm -f "${body}"
    finish failed "gh pr create failed; the branch ${branch} is pushed"
    output branch "${branch}"
    return 0
  fi
  rm -f "${body}"
  output pr_url "${url}"
  output pr_number "${url##*/}"
  output branch "${branch}"
  finish pr-opened ""
  file_followups "${outbox}" "${issue}" "${url##*/}"
}

# update_pr_body <pr> <issue> <outbox>: when the fixer wrote pr-body.md (its fix made the PR's
# description untrue), it replaces the description, so the next review does not find the PR
# contradicting itself. It passes the coder's body rules (check_body). The coder's footer, from the
# `---` above "Opened by the coder agent" to the end, is kept verbatim from the PR as it is now: it
# carries the agent-run:coder marker that pr_issue reads. Left alone when a person edited the
# description (their words win), or when the footer is gone. Prints one line for the fix comment;
# never fails the fix, which is already pushed.
coder_footer() { awk '{l[NR] = $0} END {s = 0; for (i = 1; i < NR; i++) if (l[i] == "---" && index(l[i + 1], "<sub>Opened by the coder agent") == 1) s = i; if (s) for (i = s; i <= NR; i++) print l[i]}'; }
before_footer() { awk '{l[NR] = $0} END {s = NR + 1; for (i = 1; i < NR; i++) if (l[i] == "---" && index(l[i + 1], "<sub>Opened by the coder agent") == 1) { s = i; break }; for (i = 1; i < s; i++) print l[i]}'; }
update_pr_body() {
  local pr="$1" issue="$2" f="$3/pr-body.md" cur editor footer bot text new
  [[ -s "${f}" ]] || return 0
  bot="$(policy '.botLogin')"
  text="$(mktemp)"
  # The footer is the outbox's to keep: drop a copy the fixer pasted in despite its instructions.
  before_footer <"${f}" >"${text}"
  if ! check_body "${text}" "${issue}"; then
    rm -f "${text}"; printf 'The description was not updated: %s.\n' "${REFUSAL}"; return 0
  fi
  if ! cur="$(gh pr view "${pr}" --json body --jq '.body // ""')"; then
    rm -f "${text}"; printf 'The description was not updated: the current one could not be read.\n'; return 0
  fi
  if ! editor="$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){editor{login}}}}' \
    -f o="${GH_REPO%%/*}" -f r="${GH_REPO#*/}" -F n="${pr}" --jq '.data.repository.pullRequest.editor.login // ""')"; then
    rm -f "${text}"; printf 'The description was not updated: who last edited it could not be read.\n'; return 0
  fi
  if [[ -n "${editor}" && "${editor}" != "${bot}" && "${editor}" != "${bot%\[bot\]}" ]]; then
    rm -f "${text}"; printf 'The description was not updated: %s edited it, so it stays as they left it.\n' "$(printf '%s' "${editor}" | agent_oneline 60)"; return 0
  fi
  footer="$(printf '%s\n' "${cur}" | coder_footer)"
  if ! grep -Eq "<!-- agent-run:coder run=[0-9a-z]+ issue=${issue} -->" <<<"${footer}"; then
    rm -f "${text}"; printf 'The description was not updated: its coder footer is missing.\n'; return 0
  fi
  new="$(mktemp)"
  { agent_sanitize <"${text}"; printf '\n%s\n' "${footer}"; } >"${new}"
  if gh pr edit "${pr}" --body-file "${new}" >/dev/null; then
    printf 'The PR description was updated to match the change.\n'
  else
    printf 'The description was not updated: the edit failed.\n'
  fi
  rm -f "${text}" "${new}"
}

cmd_publish_fix() {
  local outbox="${OUTBOX:?}" final="${FINAL_DIR:?}" pr="${PR:?}" branch="${BRANCH:?}" head="${HEAD_SHA:?}" issue="${ISSUE:?}"
  local url remote_head allow=0 max_body body err base pr_state st draft labels l a described
  mkdir -p "${final}"
  if [[ "${CODE_RESULT:-}" != "success" ]]; then finish failed "the fix job ended as ${CODE_RESULT:-unknown}"; return 0; fi
  if [[ ! -d "${outbox}" ]]; then finish failed "no outbox artifact"; return 0; fi
  max_body="$(policy '.maxCommentBytes')"
  # Capped BEFORE sanitising (agent_sanitize says why).
  if [[ -s "${outbox}/summary.md" ]]; then agent_cap "${max_body}" <"${outbox}/summary.md" | agent_sanitize >"${final}/summary.md"; fi
  if [[ -s "${outbox}/blocked.md" ]]; then
    agent_cap "${max_body}" <"${outbox}/blocked.md" | agent_sanitize >"${final}/blocked.md"
    finish blocked "the fixer asked for a decision"
    return 0
  fi
  if [[ ! -s "${outbox}/agent.bundle" ]]; then finish no-op "the fixer made no commits"; return 0; fi
  # The PR's head first: the bundle needs it as a prerequisite, and a checkout of main lacks it.
  url="$(push_url)"
  git fetch -q "${url}" "+refs/heads/${branch}:refs/agent/pr-head" 2>/dev/null || { finish failed "could not fetch ${branch}"; return 0; }
  remote_head="$(git rev-parse refs/agent/pr-head)"
  if [[ "${remote_head}" != "${head}" ]]; then
    finish refused "the PR moved while the fixer worked (${head:0:9} -> ${remote_head:0:9}); nothing was pushed"
    return 0
  fi
  # Re-read the PR itself: a person may have closed it, or taken it from the agents, while the fix ran.
  if ! pr_state="$(gh pr view "${pr}" --json state,isDraft,labels --jq '"\(.state) \(.isDraft) \([.labels[].name] | join(","))"')"; then
    finish failed "could not re-read #${pr}"
    return 0
  fi
  read -r st draft labels <<<"${pr_state}"
  if [[ "${st}" != OPEN ]]; then finish refused "stopped: #${pr} is ${st}; nothing was pushed"; return 0; fi
  if [[ "${draft}" != false ]]; then finish refused "stopped: #${pr} is a draft; nothing was pushed"; return 0; fi
  if [[ ",${labels}," != *,agent:pr,* ]]; then finish refused "stopped: #${pr} lost agent:pr; nothing was pushed"; return 0; fi
  for l in agent:hold agent:blocked agent:needs-human; do
    if [[ ",${labels}," == *",${l},"* ]]; then finish refused "stopped: #${pr} is labelled ${l}; nothing was pushed"; return 0; fi
  done
  if ! git bundle verify -q "${outbox}/agent.bundle" >/dev/null 2>&1; then finish refused "the bundle does not verify"; return 0; fi
  if ! git fetch -q "${outbox}/agent.bundle" "+refs/heads/agent-work:refs/agent/work" 2>/dev/null; then
    finish refused "the bundle has no agent-work branch"
    return 0
  fi
  if ! git merge-base --is-ancestor "${head}" refs/agent/work; then
    finish refused "the fix does not sit on the PR's head"
    return 0
  fi
  pr_allow_protected "${pr}"
  a=$?
  if [[ "${a}" -eq 2 ]]; then finish failed "could not read #${pr}'s agent:allow-protected"; return 0; fi
  if [[ "${a}" -eq 0 ]]; then allow=1; fi
  if ! base="$(git merge-base "${BASE_REF:-origin/$(policy '.baseBranch')}" refs/agent/work)"; then
    finish refused "the fix shares no history with the base branch"
    return 0
  fi
  if ! { check_commits "${head}" refs/agent/work && check_paths "${head}" refs/agent/work "${allow}"; }; then
    finish refused "${REFUSAL}"
    return 0
  fi
  # The whole PR too, as the coder's was: a fix must not extend a PR that breaks a path rule.
  if ! check_paths "${base}" refs/agent/work "${allow}"; then
    finish refused "the PR as a whole: ${REFUSAL}"
    return 0
  fi
  err="$(mktemp)"
  # No force: a fast-forward of the PR branch or a rejection.
  if ! git push -q "${url}" "refs/agent/work:refs/heads/${branch}" 2>"${err}"; then
    finish refused "the push was rejected: $(sed -e "s#${GH_TOKEN:-__none__}#***#g" "${err}" | tr '\n' ' ' | head -c 300)"
    rm -f "${err}"
    return 0
  fi
  rm -f "${err}"
  output new_head "$(git rev-parse refs/agent/work)"
  # Before the comment: its marker is what asks for the fresh review, which reads the description.
  described="$(update_pr_body "${pr}" "${issue}" "${outbox}")"
  body="$(mktemp)"
  {
    printf '<!-- agent-run:fix kind=%s n=%s run=%s sha=%s -->\n' "${KIND:-ci}" "${N:-1}" "${RUN_ID:-local}" "$(git rev-parse refs/agent/work)"
    printf 'The fixer agent pushed a %s fix (attempt %s, [run](%s)) for #%s.\n\n' "${KIND:-ci}" "${N:-1}" "${RUN_URL:-}" "${issue}"
    if [[ -n "${described}" ]]; then printf '%s\n\n' "${described}"; fi
    if [[ -s "${final}/summary.md" ]]; then cat "${final}/summary.md"; fi
  } >"${body}"
  gh pr comment "${pr}" --body-file "${body}" >/dev/null || agent_log "publish-fix: the PR comment failed; the fix is pushed"
  rm -f "${body}"
  finish fix-pushed ""
}

main() {
  case "${1:-}" in
    publish) cmd_publish ;;
    publish-fix) cmd_publish_fix ;;
    *) agent_log "usage: agent-outbox.sh publish | publish-fix"; return 2 ;;
  esac
}

if [[ "${AGENT_OUTBOX_NO_MAIN:-}" != "1" ]]; then
  main "$@"
fi
