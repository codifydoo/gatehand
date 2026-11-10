# Changelog

## 0.2.3 (2026-11-10)

- The review verdict is also read from GitHub's own render of the review (`POST /markdown`), and the
  merge gate, the fixer and the digest see Approve or Request changes only when that reading agrees
  with the markdown one. Only top-level headings and paragraphs of the HTML count, so a verdict
  GitHub shows inside a quote, a list, a collapsed block or a struck-through line, or comments out
  (a raw `<!--` in a list item), no longer passes for the review's own. A render that fails reads
  as no verdict, and so does a later top-level heading in another form (`VERDICT`, `## Verdict`,
  `Verdict:`); a disagreement between the two readings is logged. Replayed over 449 real reviews,
  no verdict changed.
- The tests answer render calls with GitHub's recorded output (`tests/workflows/render-fixtures.jsonl`);
  `tests/record-renders.sh` re-records it.

## 0.2.2 (2026-11-10)

- The fixer's job no longer fails at its end when the repository's toolchain action uses an action
  with a post step (`actions/setup-node`, `actions/setup-go` and the like). The job removes main's
  copy of the setup actions before the model starts, and a post step reads its composite action's
  `action.yml` again at the end of the job, so the job failed after the fix was packaged and the fix
  was dropped. Main's copy is now checked out again, from the default branch, once the model and the
  packaging are done. Found by the fixer's first live run.

## 0.2.1 (2026-11-10)

Fixes from upgrading a 0.1.0 install to 0.2.0:

- `bin/render.sh` refreshes `.github/agents/hooks/lib.sh.example`, the package's reference for the
  hooks, wherever it is, so an update documents new hooks. Every other file of yours is still only
  created when missing, and the example is still not created once `hooks/lib.sh` exists.
- `bin/doctor.sh` warns when an hourly sweep has never run on its schedule two hours after
  `agent-sweep.yml` reached the default branch (the merge time of the PR that brought it), and the
  README says what to do then. GitHub reports nothing when a cron does not fire; one private
  repository on a Free personal account saw none at all. A sweep schedule that is not hourly is
  not checked.
- The note on a PR the review skipped says the review can be asked for before merging: a dispatch
  runs the default branch's copy of the workflow.
- The issue snapshot removes its temporary copy of the issue when sanitizing fails.

## 0.2.0 (2026-11-10)

- The coder may file what it noticed but left alone as `agent:candidate` issues (`followups.json`,
  at most `roles.coder.maxFollowups`; 2 in a new install's `policy.json`, off in an existing one
  until you add the key). Each needs a 10 to 90 character title, a body with a `### Done when`
  section, and no open issue with the same title. Mentions, markers and `@claude` are defused.
- The fixer's task now includes the issue the PR is for, as the same untrusted snapshot the coder
  read, when the run can still vouch for its text.
- The review verdict also reads a `**Verdict**` or `__Verdict__` heading at the start of a
  paragraph, and fails closed (verdict unknown) when a `<details>`, `<pre>`, `<script>`, `<style>`
  or `<textarea>` tag, or a line opening with a processing instruction (`<?`), a declaration
  (`<!X`) or CDATA, comes before the verdict line: GitHub can hide what follows them. A `<?php`
  mentioned mid-line does not count. A lone CR anywhere makes the verdict unknown too: CommonMark
  breaks the line there and the parser would not.
- New hooks in `.github/agents/hooks/lib.sh`: `agent_hook_labeler_trusted <issue>` vouches for
  issues the repo's own workflows queue as the bot (asked only when no person ever applied
  `agent:ready`), and `agent_hook_digest_done_pending` writes the digest's line for a merged issue
  that is waiting to go live. Every hook now runs with stdin closed.

## 0.1.0 (2026-11-10)

First release, extracted from agents that run unattended on a production codebase. Tested end to
end on GitHub-hosted `ubuntu-latest` (Ubuntu 26.04): an `agent:ready` issue became an agent PR,
CI and the PR guard passed, the Claude review approved it, and the merge gate's dry run would have
merged it.

- Coder, fixer, Claude review, merge gate, PR guard, sweep, inbox, digest and optional triage,
  rendered from `.github/agents/policy.json` by `bin/render.sh`.
- Repo-owned setup: `system/` (the only sudo step, run before agent code is on disk), `toolchain/`,
  `dependencies/`, `project.md`, and `hooks/lib.sh` for guard rules, inbox kinds and digest sections.
- The review's "already reviewed" check counts only the review bot's marker comment, so a pasted
  marker cannot suppress a PR's review.
- The model's job drops passwordless sudo in one root shell and fails if any passwordless grant is
  left (`sudo -n -l`), including on hosted runners' `sudo-rs`.
- Install, update and doctor skills; `bin/doctor.sh` checks a repository's setup read-only.
- `addons/hardened-runner`: self-hosted pool requirements, a reference egress allowlist, and kick
  timers.
