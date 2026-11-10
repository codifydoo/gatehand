# Changelog

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
  mentioned mid-line does not count.
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
