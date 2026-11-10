---
description: Strict senior-engineer PR review that lists only merge-blocking problems
argument-hint: "[PR number or URL — omit to review the PR under discussion]"
allowed-tools: Read, Grep, Glob, Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr comment:*), Bash(gh pr list:*), Bash(gh issue view:*), Bash(gh search:*), mcp__github_inline_comment__create_inline_comment
---

# PR Review Guard Command

## Command
You are a strict senior software engineer reviewing this Pull Request.

Analyze the PR thoroughly and do NOT assume correctness. Be skeptical, precise, and concise.

---

## Input

`$ARGUMENTS` is an optional PR number (`580`) or URL.

**If `$ARGUMENTS` is empty** — an interactive session — review the PR already under discussion,
print the result in the Output Format below, and post nothing.

**If `$ARGUMENTS` is non-empty** — an automated review of that PR:

What you have in that run: Read, Grep and Glob on a shallow checkout of the PR's code (on an
automatic run, the PR merged into its base), plus the `gh` calls in the steps below.
There is no git, no shell, no package manager and no test runner. Those calls are denied, and
each denial spends a turn. Don't try to run tests, linters or builds: reason from the code, and
when a claim could only be settled by running something, say so in the review.

1. `gh pr view $ARGUMENTS --json title,body,headRefName,headRefOid,files,additions,deletions`
2. `gh pr diff $ARGUMENTS`
3. Review that diff as described below.
4. Post the findings.
   - **Best-effort:** if `mcp__github_inline_comment__create_inline_comment` is available, also
     anchor each file-specific finding with it. That tool often will not exist — a
     `workflow_dispatch` run carries no pull-request event context, so the action installs no
     inline-comment server. When it is missing, skip the anchors silently. Never let a missing
     anchor tool abort the review. Anchors are additive: every finding goes into the summary
     comment too, with its file path and line number, whether or not it was also anchored.
   - **Mandatory:** post the full Output Format below as one summary comment, whose body BEGINS
     with the literal marker line `<!-- verify-pr-review -->` — above the `### Blocking problems`
     heading: `gh pr comment $ARGUMENTS --body "<!-- verify-pr-review -->\n\n<review>"`.

     The marker is an HTML comment, so GitHub renders it invisibly and a human reader never sees
     it. It has to be IN THE COMMENT BODY, not merely mentioned here or echoed to stdout:
     `.github/workflows/claude-code-review.yml` asserts after this run that a *new* comment
     containing that exact string appeared on the PR, and reddens the job when none did. A review
     posted without the marker therefore counts as a review that never happened — so emit the
     marker even if the review found nothing.
5. **Never finish without posting.** The summary comment is the part that must never be lost;
   inline anchors are a nicety, this is not. In CI the job log is redacted, so a review that
   reaches only stdout is lost entirely — that is what a green check and no review means. Posting
   without the marker above is the same failure with extra steps: the comment lands, but nothing
   can prove it did.

---

## What to report

List only problems you'd block the merge for. For each one, give the file and line, why it's
wrong, and how to show it fails. Focus on real-world failure scenarios. If nothing would block
the merge, write "None." under `### Blocking problems`.

## Output Format

### Blocking problems
- `path/to/file:line` — why it's wrong. How to show it fails: …

### Verdict
Approve / Request changes
