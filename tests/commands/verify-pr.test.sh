#!/usr/bin/env bash
# tests/commands/verify-pr.test.sh
# Guards the contract that lets ONE command file serve both an interactive session and CI.
#
# The CI half is the fragile half: --allowedTools in .github/workflows/claude-code-review.yml is
# the only ALLOW list claude-code-action contributes (in agent mode it appends claude_args verbatim
# and injects no list of its own), so a tool the command needs but the workflow omits is not
# granted by the action, the call is denied silently, and the review ends having posted nothing.
# Seven PRs in a row once looked exactly like that.
#
# The flag ALLOWS; it does not RESTRICT — .claude/settings.json's `permissions.allow` is checked
# out into the CI workspace and read too, so the effective grant is wider than this list. That is
# the workflow's problem to bound (it does, with --disallowedTools) and not something these cases
# can see. What they check is the narrower thing: that nothing the command NEEDS is missing.
#
# The needles below match the LITERAL text `$ARGUMENTS` in a markdown file, so they are
# single-quoted on purpose — expansion here would defeat the test. Silence SC2016 ("expressions
# don't expand in single quotes") file-wide, as tests/bootstrap/stamp-bootstrap.test.sh does.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
CMD="${REPO_ROOT}/.claude/commands/verify-pr.md"
WORKFLOW="${REPO_ROOT}/.github/workflows/claude-code-review.yml"

pass=0
fail=0
t_pass() { printf '\033[1;32m[verify-pr] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[verify-pr] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

[[ -f "${CMD}" ]] || { t_fail ".claude/commands/verify-pr.md is missing"; exit 1; }

# Case 1: frontmatter contract. Claude Code parses the file only if it opens with a --- fence.
if [[ "$(head -1 "${CMD}")" == "---" ]] && grep -q '^description: ' "${CMD}"; then
  t_pass "frontmatter opens with --- and carries a description"
else
  t_fail "frontmatter contract broken — the command will not be discoverable"
fi

# Case 2: it declares the tools it needs. Without allowed-tools an interactive run prompts for
# every gh call, which in a headless CI run means it never gets one.
if grep -q '^allowed-tools: ' "${CMD}"; then
  t_pass "command declares allowed-tools"
else
  t_fail "command has no allowed-tools — every gh call would need interactive approval"
fi

# Case 3: it takes a PR argument. Without $ARGUMENTS the CI invocation `/verify-pr 580` silently
# drops the number and the review has no PR to fetch.
if grep -q '\$ARGUMENTS' "${CMD}"; then
  t_pass "command reads \$ARGUMENTS"
else
  t_fail "command ignores \$ARGUMENTS — CI would pass a PR number into the void"
fi

# Case 4: it fetches and it posts. A review that only prints is lost: claude-code-action redacts
# the job log for security, which is how seven PRs once passed green having reviewed nothing visibly.
#
# FRONTMATTER IS STRIPPED FIRST, and that is the whole point of the helper. `allowed-tools:` on
# line 4 names every gh verb the command is permitted to use, so grepping the raw file satisfied
# `gh pr comment` from the PERMISSION DECLARATION rather than from any instruction to post.
# Verified: replacing steps 4-5 with a bare `4. Print the findings in the Output Format below.` —
# literally that silent behaviour — left this suite 11/0 green. What CI executes is the prose, so
# the prose is what this case has to read.
#
# Cases 6+7 deliberately still read the WHOLE file, frontmatter included; see their comment. The
# split is intentional: 6+7 pin the two permission grants to each other, Case 4 pins the behaviour.
cmd_body() {
  awk 'NR==1 && $0=="---" {fm=1; next} fm==1 && $0=="---" {fm=2; next} fm!=1' "${CMD}"
}
body="$(cmd_body)"
[[ -n "${body}" ]] || t_fail "frontmatter strip left nothing — verify-pr.md reformatted? Case 4 cannot check anything"
for needle in 'gh pr view' 'gh pr diff' 'gh pr comment'; do
  if grep -qF "${needle}" <<<"${body}"; then
    t_pass "command body uses ${needle}"
  else
    t_fail "command body never calls ${needle} — it cannot fetch or post"
  fi
done

# Case 4b: the posting behaviour itself, pinned by its exact wording. The verbs above prove the
# command MENTIONS `gh pr comment`; these two prove it is still ORDERED to post — the mandatory
# summary comment and the "no silent exit" rule that makes it mandatory. Delete steps 4-5 and both
# go with them, which is the mutation Case 4 alone could not see.
for needle in 'gh pr comment $ARGUMENTS --body' 'Never finish without posting'; do
  if grep -qF "${needle}" <<<"${body}"; then
    t_pass "command still mandates posting: \"${needle}\""
  else
    t_fail "command lost \"${needle}\" — a review that only prints is the silent no-post failure"
  fi
done

# Case 5: the interactive path is preserved. The Mac's usage is argument-less, and losing it is the
# whole reason this file is shared rather than forked.
if grep -qiE 'if .*\$ARGUMENTS.* (is )?empty' "${CMD}"; then
  t_pass "command documents an argument-less interactive path"
else
  t_fail "command has no argument-less path — interactive use on the Mac would break"
fi

# Cases 6+7 both check membership in the workflow's --allowedTools, so hoist that ONE line's
# quoted value first and match against the string, never against the file.
#
# Matching the file was a false pass: claude-code-review.yml is heavily commented and names tools
# inside those comments, so `grep "${needle}" "${WORKFLOW}"` was satisfied by a mention in prose.
# Deleting a verb from the real list and explaining the deletion in a comment — the natural shape
# of a narrowing edit — left the suite green. `Task` is the live example: the workflow explains at
# length why it is NOT in the allowlist, so a file-wide grep for it would find it and conclude the
# opposite. (Deliberately no line numbers here or below. This paragraph cited one, and the quoted
# comment text below was quoted verbatim; the 2026-08-27 rewrite of that workflow invalidated both
# while every assertion still passed, which is precisely the rot these needles are meant to catch.)
#
# Membership is tested with the value comma-wrapped on both ends, so `,Read,` cannot be satisfied
# by a substring of some longer tool name.
#
# The extraction is ANCHORED to the start of the line (`^[[:space:]]*`) and takes the match, not
# the line. Both halves are load-bearing:
#   - Taking the match, not the line, is why a prose comment that begins `# --allowedTools ...`
#     well above the flag does not swallow the value: a plain `grep -m1 -- '--allowedTools'` would
#     return that PROSE and every tool would then read as missing.
#   - The `^` anchor is what a QUOTED example inside a comment cannot get past. Unanchored, this
#     matched the first quoted occurrence ANYWHERE in the file, so the ordinary shape of a
#     narrowing edit — cut the real flag down and preserve the old value above it as
#     `# Was: --allowedTools "…"` — silently handed the extractor the OLD, wide list while CI ran
#     the new, narrow one. Verified: narrowing the live flag to `Read,Grep,Glob` (no `gh` at all,
#     so the review can neither fetch nor post) with the old value kept in a `# Was:` comment left
#     this suite 11/0 green. Anchored, the comment is unmatchable because a comment line begins
#     with `#`, and only the real flag begins with `--allowedTools "`.
# `--disallowedTools` on the following line is likewise unmatchable: after the leading whitespace
# the anchor demands the literal `--allowedTools`, which `--disallowedTools` is not.
# The guard below is what makes a reformat loud instead of mysterious.
alw="$(grep -m1 -oE -- '^[[:space:]]*--allowedTools "[^"]*"' "${WORKFLOW}" \
  | sed 's/^[[:space:]]*--allowedTools "//; s/"$//')"
[[ "${alw}" == *,* ]] || t_fail "no quoted --allowedTools tool list in ${WORKFLOW##*/} — reformatted? Cases 6+7 cannot check anything"

# Case 6: every gh verb the command needs is in that allowlist. This is the assertion that would
# have caught those seven PRs before they merged.
#
# The extractor reads the WHOLE command file, frontmatter included, so a verb declared only in
# `allowed-tools:` counts too. That is deliberate and stricter than it first looks: the frontmatter
# is what an interactive run enforces and the workflow list is what CI enforces, so this pins the
# two to each other rather than only to the calls spelled out in the prose. A command that works on
# the Mac and is denied in CI is the exact failure being guarded against.
#
# `Bash(gh search:*)` is NOT matched — the extractor wants a space after the noun, not a colon.
# Nothing in the prose calls `gh search`, so nothing rides on that today; widening the regex would
# be the fix if it ever does.
missing=""
while read -r verb; do
  grep -qF ",Bash(${verb}:*)," <<<",${alw}," || missing="${missing} ${verb}"
done < <(grep -oE 'gh (pr|issue|search) [a-z-]+' "${CMD}" | sort -u)
if [[ -z "${missing}" ]]; then
  t_pass "every gh verb the command uses is in the workflow's --allowedTools"
else
  t_fail "workflow --allowedTools is missing:${missing} — those calls are denied silently in CI"
fi

# Case 7: the NON-gh half of the allowlist. `--allowedTools` covers every tool, not just Bash
# verbs, and .claude/settings.json grants none of Read/Grep/Glob — its `permissions.allow` is all
# `Bash(...)` entries — so dropping `Read` or `Grep` from the workflow's list leaves the reviewer
# unable to open a single file in CI: a review that fetches the diff and then cannot inspect the
# repo around it.
# Case 6 is blind to that entirely.
#
# Only bare capitalised names are extracted (`^[A-Z][A-Za-z]+$`): that is Read, Grep, Glob.
# `Bash(...)` entries are Case 6's job, and mcp__github_inline_comment__create_inline_comment is
# skipped for a purely mechanical reason — `mcp__…` is not a bare capitalised name, so the
# extractor never yields it. That is NOT a statement about whether the workflow lists it. It does:
# claude-code-review.yml regained its `pull_request` trigger, and claude-code-action installs the
# inline-comment MCP server whenever the triggering event carries PR context (context.isPR).
#
# Step 4 of the command still treats inline anchoring as best-effort and the summary comment as
# mandatory, and that is still correct: `workflow_dispatch` remains a valid trigger for that
# workflow, and a dispatch run carries no PR context, so on that path the server is absent and the
# tool does not exist. The command has to work on both paths from one file.
missing_tools=""
while read -r tool; do
  grep -qF ",${tool}," <<<",${alw}," || missing_tools="${missing_tools} ${tool}"
done < <(grep -m1 '^allowed-tools: ' "${CMD}" | sed 's/^allowed-tools: //' | tr ',' '\n' \
  | sed 's/^ *//; s/ *$//' | grep -E '^[A-Z][A-Za-z]+$' | sort -u)
if [[ -z "${missing_tools}" ]]; then
  t_pass "every non-gh tool the command declares is in the workflow's --allowedTools"
else
  t_fail "workflow --allowedTools is missing:${missing_tools} — the reviewer cannot read the repo in CI"
fi

# Case 8: the review stance survives. Every case above pins structure or plumbing; this is the only
# thing telling the reviewer HOW to read the diff, and it was dropped once already — by a copy range
# that started one section too low. Without it the file is an output format with no persona, which
# is a materially weaker review than the one that was approved. Both needles live only in
# `## Command`: the frontmatter description says "senior-engineer", which neither matches.
for needle in 'strict senior software engineer' 'do NOT assume correctness'; do
  if grep -qF "${needle}" "${CMD}"; then
    t_pass "command carries the review stance: \"${needle}\""
  else
    t_fail "command lost \"${needle}\" — the review persona is gone, leaving a bare output format"
  fi
done

# Case 9: the summary marker is the SAME string on both sides. The workflow's final step no longer
# asks who wrote the new comment — it asks whether a new comment's BODY contains a marker — because
# a login filter was wrong twice over: the review posts under claude-code-action's own App token
# rather than as `github-actions[bot]` (its `github_token` input has no default, so it mints one via
# OIDC and overwrites GH_TOKEN before spawning the CLI), and `github-actions[bot]` is anyway the
# login ci.yml's `explainer drift` job posts under on the very same `pull_request` event. So the
# guard identifies the ARTIFACT, not the author.
#
# That makes the marker a contract between two files that are never executed together: the workflow
# greps for it, the command is what emits it, and neither notices if the other's copy changes. A
# renamed marker in one file alone turns every real review red (workflow renamed) or turns the guard
# into a permanent pass-by-accident that can never fire (command renamed) — and both only show up on
# a live PR, after a billed run. This case is what makes that a red suite instead.
#
# The workflow value is EXTRACTED, not hard-coded here, so this test cannot itself become a third
# divergent copy. Anchored to the start of the line for the reason Cases 6+7 spell out at length: an
# assignment is the only thing that begins a line with `marker=`, so the extractor cannot be
# satisfied by the string appearing in a comment or in an `echo`. The guard below makes a reformat
# of that step loud instead of mysterious — without it, a failed extraction would leave `marker`
# empty and `grep -qF ""` matches every file, i.e. a silent unconditional pass.
# Read the SINGLE job-level definition. The workflow used to spell the marker twice — inline in
# the baseline step's jq and again as a `marker='…'` assignment in the assert step — so the two
# could drift apart with every individual test still green. One `env:` entry now feeds both.
# Anchored to the key at its exact indentation so a mention in a comment cannot satisfy it.
marker="$(grep -m1 -oE -- "^      REVIEW_MARKER: '[^']*'" "${WORKFLOW}" \
  | sed "s/^      REVIEW_MARKER: '//; s/'$//")"
if [[ -z "${marker}" ]]; then
  t_fail "no job-level REVIEW_MARKER in ${WORKFLOW##*/} — reformatted, or the marker was re-inlined into a step?"
elif grep -qF "${marker}" "${CMD}"; then
  t_pass "command emits the marker the workflow asserts on: \"${marker}\""
else
  t_fail "command never mentions \"${marker}\" — the workflow's post-review assertion can never pass"
fi

# Case 10: the review model is set, and set to Opus. Without `--model` the CLI default applies,
# and that default is Sonnet — confirmed from a real run log, not from docs. So DELETING this flag
# is a silent downgrade of the only qualitative gate this repo has before a merge (main requires
# zero human approvals), and nothing else would notice.
#
# Matched on "opus" rather than the exact model id so a legitimate version bump does not redden
# this, while a revert to the default or a switch to Sonnet still does.
model_line="$(grep -m1 -oE -- '^[[:space:]]*--model[[:space:]]+[A-Za-z0-9._-]+' "${WORKFLOW}" || true)"
if [[ -z "${model_line}" ]]; then
  t_fail "no --model in ${WORKFLOW##*/} claude_args — the review silently falls back to the CLI default, which is Sonnet"
elif [[ "${model_line}" == *opus* ]]; then
  t_pass "review model is pinned to Opus (${model_line##*[[:space:]]})"
else
  t_fail "review model is '${model_line##*[[:space:]]}', not an Opus model — this is the only qualitative gate before merge"
fi

# Case 11: the review's scope and where its findings go. The first needle is the whole substance of
# the blocking-only format; a copy-range edit that drops `## What to report` would otherwise leave
# this suite green, the same mutation Case 8 exists for. The second pins anchors as ADDITIVE: with a
# single findings list, "anchor inline instead of summarising" would post a summary reading "None."
# on the normal pull_request path while the inline comments say the opposite, and the workflow's
# marker assertion cannot tell that apart from a clean PR.
for needle in "List only problems you'd block the merge for" \
  'Anchors are additive: every finding goes into the summary'; do
  if grep -qF "${needle}" <<<"${body}"; then
    t_pass "command carries: \"${needle}\""
  else
    t_fail "command lost \"${needle}\" — the review either widens past merge blockers or can post an empty summary"
  fi
done

# Case 12: step 4 places the marker above a heading by name, and the Output Format defines that
# heading. They are two copies of one string in one file, so a rename of either alone leaves step 4
# pointing at a heading the review never writes. The guard makes a reworded step 4 loud.
heading="$(grep -oE 'above the `### [^`]+`' <<<"${body}" | head -1 | sed -E 's/^above the `### //; s/`$//')"
if [[ -z "${heading}" ]]; then
  t_fail "step 4 no longer names the heading the marker sits above — reworded? Case 12 cannot check anything"
elif grep -qxF "### ${heading}" <<<"${body}"; then
  t_pass "step 4's heading is the one the Output Format defines: \"### ${heading}\""
else
  t_fail "step 4 names \"### ${heading}\" but the Output Format has no such heading"
fi

# Case 13: the command tells the CI reviewer what it cannot run, and that stays true. Without the
# paragraph, runs spent 1-11 turns each on denied git/test/shellcheck calls (counted from the run
# logs on 2026-11-07). It must sit in the CI branch of `## Input`. The paragraph claims "no git, no package manager, no test runner", which is
# only true while --disallowedTools says so, so the two are pinned together here. The extraction is
# anchored like Cases 6+7's, so a quoted value in a comment cannot satisfy it.
# Read only the CI branch of `## Input`: the same paragraph under the argument-less branch would
# tell an interactive session, which does have git and a shell, that it has neither.
ci_branch="$(awk '/^\*\*If `\$ARGUMENTS` is non-empty\*\*/ { on = 1; next } on && /^1\. `gh pr view/ { exit } on' <<<"${body}")"
if grep -qF 'each denial' <<<"${ci_branch}" && grep -qF 'no git, no shell, no package manager and no test runner' <<<"${ci_branch}"; then
  t_pass "command tells the CI reviewer what it cannot run"
else
  t_fail "command lost the paragraph on what the CI run cannot do — reviews go back to spending turns on denied calls"
fi
dis="$(grep -m1 -oE -- '^[[:space:]]*--disallowedTools "[^"]*"' "${WORKFLOW}" \
  | sed 's/^[[:space:]]*--disallowedTools "//; s/"$//')"
missing_dis=""
for verb in git pnpm npm go gofmt; do
  grep -qF ",Bash(${verb}:*)," <<<",${dis}," || missing_dis="${missing_dis} ${verb}"
done
if [[ -n "${dis}" && -z "${missing_dis}" ]]; then
  t_pass "the workflow still denies what the command says the reviewer cannot run"
else
  t_fail "workflow --disallowedTools no longer denies:${missing_dis:- (no list found)} — the command's 'no git, no package manager' paragraph is now false"
fi

printf '\n[verify-pr] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
