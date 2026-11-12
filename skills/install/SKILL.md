---
name: install
description: Install the Gatehand autonomous coding agents (coder, fixer, Claude review, merge gate) into the current GitHub repository. Use when the user asks to install, set up or add the autonomous agents / Gatehand to a repo.
---

# Install Gatehand into this repository

The package root is two directories above this file (this file is `<root>/skills/install/SKILL.md`).
`<root>/bin/render.sh` does the file work; your job is to fill in the repo's settings well, and to
walk the user through the steps only they can do. Read `<root>/docs/README.md` first: it is the
runbook that will be installed, and it explains every setting below.

Never push, open a PR, create a GitHub App, set a secret or variable, or change repository settings
without the user's explicit go-ahead for that step. Prefer giving them the exact command.

## 1. Check the ground

- The current directory is the repository's root, a git checkout with a clean working tree, and
  `gh auth status` works. `bash --version` is 4 or later (macOS: `brew install bash`), `jq` exists.
- `gh repo view --json nameWithOwner,defaultBranchRef,visibility,isFork`. Refuse a fork: the agents
  need secrets that forks do not get.
- If `.github/agents/install.lock.json` exists, this is an update: use the update skill instead.

## 2. Learn the repository

Find, without changing anything:
- The CI workflow that runs on pull requests: its file name and its `name:`, and the job names that
  should gate a merge (these become `requiredChecks`; a job's check name is its `name:`, else its id).
- The language(s), package manager and lockfile, and the exact commands CI runs to build, lint,
  typecheck and test, per area of the repo.
- What CI installs first (runtimes, system packages).
- `CLAUDE.md` or `AGENTS.md` and other contributor docs: standing rules worth binding the agent to.
- Release or deploy tooling (`deploy/`, `scripts/release*`, `Dockerfile`s CI pushes): candidates for
  protected paths.
- Existing rulesets: `gh api repos/<o>/<r>/rules/branches/<default>`.

## 3. Decide with the user

Ask (AskUserQuestion), recommending defaults:
- The GitHub App's name (its slug becomes `botLogin`, `<slug>[bot]`). Default: `<repo>-gatehand`.
- The owner login whose inbox commands count. Default: `gh api user --jq .login`.
- Claude auth: `oauth` (a `claude setup-token` subscription token) or `api-key` (an Anthropic
  Console key, which can be spend-capped; recommended for teams).
- Runners: GitHub-hosted (default) or a self-hosted pool (then read
  `<root>/addons/hardened-runner/README.md` with them first).
- Which CI checks must pass before an agent PR merges.

## 4. Render

On a new branch `chore/install-gatehand`:

```bash
bash <root>/bin/render.sh .
```

That writes the package files and, once, the files that are the repo's own under `.github/agents/`.
Then edit those to fit what you found:
- `policy.json`: `botLogin`, `baseBranch`, `ci.workflowName`, `ci.workflowFile`, `requiredChecks`,
  `runners`, `claude.auth`, and `tools.allow` with one `Bash(<command prefix>:*)` per check command
  in `project.md` (for example `Bash(npm test:*)`, `Bash(go:*)`). Keep the defaults for the limits.
  If a check command matches a `tools.deny` entry or the built-in deny list (git push, gh, curl,
  docker, sudo…), it cannot be allowed: say so.
- `project.md`: the standing rules and, under "Checks", the commands per area. Concrete and short.
- `protected-paths.txt`: add the release and deploy tooling you found as normal (label-unlockable)
  lines. Never remove a `!` line.
- `system/action.yml` (sudo, fixed packages only), `toolchain/action.yml` (setup-* actions with
  every cache off: `cache: false` where the action caches by default, as setup-go does; setup-python
  rejects `false` and caches only when `cache:` is set, so leave it out there),
  `dependencies/action.yml` (lockfile-exact install): mirror what CI does.

Re-render (`bash <root>/bin/render.sh .`) and confirm `bash <root>/bin/render.sh --check .` passes.
If the repo lints workflows with actionlint, add the ignore rules from
`<root>/tests/lint/actionlint.yaml` (and any self-hosted labels) to its `.github/actionlint.yaml`.

Show the user a summary of the diff and the settings you chose, then commit on their go-ahead
(`chore: install Gatehand <version>`) and, on a second go-ahead, push and open the PR.

## 5. The steps only the user can do

Give them these, in order, as commands where possible (the runbook's "Setup" has the details):

1. Create the GitHub App: the manifest is `<root>/docs/app-manifest.json` (set `name` to the chosen
   slug). Permissions: Contents, Issues, Pull requests, Actions read and write; Checks, Commit
   statuses, Metadata read; **no Workflows**. Install it on this repository only.
2. Install the Claude GitHub App on the repository (https://github.com/apps/claude).
3. Secrets and variables: `AGENT_APP_PRIVATE_KEY`, `AGENT_APP_CLIENT_ID`, `AGENT_BOT_ID`,
   `AGENT_OWNER_LOGIN`, and `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`.
4. Actions defaults: read-only token, no PR approval by Actions.
5. After the install PR merges: `bash .github/scripts/agent-labels.sh`, then
   `git push origin origin/<default>:refs/heads/agent-runner`.
6. Run the doctor skill. Then `gh variable set AGENTS_ENABLED --body true`, and queue one small
   issue with an acceptance section: `gh workflow run agent-coder.yml --ref agent-runner -f issue=<n>`.
7. After the first agent PR: pin the inbox issue and make `agent pr guard` a required check. Leave
   `AGENT_AUTO_MERGE` off until a few merge-gate dry runs read right.
