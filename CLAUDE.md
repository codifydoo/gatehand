# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Gatehand (formerly `repo-agents`) is a Claude Code plugin that installs unattended coding agents
into *other* GitHub repositories as plain GitHub Actions workflows: a coder, a fixer, a Claude
review, a merge gate, an inbox, a digest and a sweep. This repository is the package, not an
installation of it: nothing under `template/` runs here.

## Commands

```bash
bash tests/run.sh                                        # render, lint, run every suite
bash tests/run.sh tests/workflows/agents-merge.test.sh   # one suite (still renders and lints first)
AGENTS_TEST_POLICY_JQ='.runners.agent = ["self-hosted", "x-agent"] | .runners.ci = ["self-hosted", "x-ci"]' bash tests/run.sh
                                                         # CI's second pass: a self-hosted runner policy
bash bin/render.sh <repo>          # install or update the package files in <repo>
bash bin/render.sh --check <repo>  # exit 1 if <repo>'s package files differ from a fresh render
bash bin/doctor.sh <repo>          # read-only setup check of an installation
python3 bin/dashboard.py           # the local dashboard (opens a browser)
bash tests/record-renders.sh       # re-record tests/workflows/render-fixtures.jsonl (calls the real GitHub API)
```

Needs bash 4+ (macOS: `brew install bash`), git, jq, python3 3.9+. `actionlint` and `shellcheck`
are skipped with a `SKIP:` line when not installed; CI installs actionlint v1.7.7.

Suites cannot be run directly: `tests/run.sh` renders the package into a scratch repository and
exports it as `AGENTS_ROOT`, and every suite tests that rendered copy, never `template/`. The
suites use a stub `gh` (`tests/workflows/agents-gh-stub.sh`) and local git repositories; nothing
reaches the network.

## Architecture

**Render pipeline.** `bin/render.sh` is the installer. It copies `defaults/` into the target's
`.github/agents/` once (the adopter's own files, never overwritten), then renders `template/` into
the target's `.github/` and `.claude/`, replacing `@@PLACEHOLDER@@` tokens with values from the
target's `policy.json` merged over `defaults/policy.json`. `docs/README.md` is installed as the
target's `.github/agents/README.md`, so it is the adopters' runbook, not only this repo's docs.
Rendered files are recorded with hashes in `install.lock.json`; a hand-edited package file is not
overwritten without `--force`.

**The security rule everything rests on.** The model never shares a job with a write-capable
token, and nothing it wrote is executed by one. In `agent-coder.yml` and `agent-fixup.yml` the
model job holds a read-only `GITHUB_TOKEN` and commits locally to `agent-work`; a separate job
checks out the default branch, takes the commits from a git bundle, validates them
(`agent-outbox.sh`) and publishes with a GitHub App that has no Workflows permission. The model
talks to the publish job only through files in its outbox (`pr.json`, `pr-body.md`, `summary.md`,
`blocked.md`, `followups.json`). Read "Security model" in `docs/README.md` before changing a
workflow's jobs, permissions, checkouts or tool lists.

**Scripts hold the logic.** `template/.github/scripts/agent-*.sh` are deterministic and run
without a model; `agent-lib.sh` is the shared library (policy reads, sanitising, protected paths,
the inbox, infra-failure rules). The workflows are thin callers. State lives in GitHub itself:
labels, HTML-comment markers in bot comments, and JSON rows on the `agent-ledger` branch.

**Prompts are the three command files** in `template/.claude/commands/`. Tests pin them to the
workflows: the `allowed-tools` frontmatter of `agent-implement.md` and `agent-fix.md` must equal
the workflow's `--allowedTools` (both rendered from `BASE_ALLOW` / `BASE_DENY` in `render.sh` plus
the policy's `tools`), and `tests/commands/verify-pr.test.sh` greps `verify-pr.md` for exact
phrases (the review stance, the posting mandate, the marker). Changing wording there can fail a
suite; read the test's reason before changing either side.

**Plugin surface.** `.claude-plugin/` is the manifest; `skills/` (install, update, doctor,
dashboard) are thin instructions over `bin/`. They address the package as `<root>`, two
directories above the skill file.

**Dashboard.** `bin/dashboard.py` is a standard-library-only local server over the user's own
`gh` login, serving `dashboard/`. Its session secret travels in the URL fragment. The security
model and what each button does are in `docs/dashboard.md`; `tests/dashboard/dashboard.test.sh`
pins them.

## Conventions

- The version lives only in `.claude-plugin/plugin.json` (`render.sh` reads it). A release adds a
  `CHANGELOG.md` section that says whether installed repositories need an update.
- Commits are conventional with a scope, with the version in the subject on a release:
  `feat(dashboard): … (0.6.0)`.
- Each test suite opens with a comment listing what it pins and why; keep that current when
  adding a case.
