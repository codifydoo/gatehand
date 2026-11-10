# Changelog

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
