# Gatehand

Formerly `repo-agents`.

Unattended Claude coding agents for a GitHub repository, as a Claude Code plugin that installs
plain GitHub Actions workflows into your repo:

- a **coder** that turns `agent:ready` issues into pull requests that say `Refs #N`;
- a **fixer** that answers red CI and review findings on its own PRs;
- a **Claude review** of every PR, whose verdict gates the merge;
- a **merge gate** that merges an agent PR only when CI, the review and every rule agree (a dry run
  until you turn it on);
- an **inbox** issue where everything that needs a person lands, answered with `/approve`, `/reject`,
  `/rerun`, `/pause`, `/resume`; a weekly **digest**; an hourly **sweep** that recovers stuck state.

It came out of running exactly this, unattended, on a production codebase. The design rests on one
rule: **the model never shares a job with a write-capable token.** The model job holds a read-only
`GITHUB_TOKEN` and can only commit locally; a separate job, running your default branch's scripts,
validates what it wrote and publishes it with a GitHub App that has no Workflows permission. The
full security model and its residual risks are in [`docs/README.md`](docs/README.md), which is also
installed into your repo as `.github/agents/README.md`.

## Install

In Claude Code, from your repository:

```text
/plugin marketplace add codifydoo/gatehand
/plugin install gatehand@gatehand
/gatehand:install
```

The install skill reads your CI, toolchain and contributor docs, drafts the configuration with you,
renders the files on a branch, and walks you through the steps only you can do (creating the GitHub
App, secrets, turning it on). Nothing is pushed or changed on GitHub without your go-ahead.

Without Claude Code: clone this repository and run `bin/render.sh <your-repo>`, then follow
"Setup" in [`docs/README.md`](docs/README.md).

Requirements: a GitHub repository with Actions, a Claude subscription token
(`claude setup-token`) or an Anthropic API key, and locally bash 4+, git, jq and `gh`.

## What you own, what the package owns

`.github/agents/` holds your settings, created once and never overwritten:

| File | What it is |
|---|---|
| `policy.json` | Limits (runs per day, open PRs, attempts), models, schedules, runners, extra tools, required checks |
| `project.md` | Your standing rules and the check commands per area; the agents read it every run |
| `protected-paths.txt` | Paths an agent PR needs a person's label for, and `!` paths it may never touch |
| `system/`, `toolchain/`, `dependencies/` | Composite actions that set up the agent's job like your CI |
| `hooks/lib.sh` | Optional: extra PR-guard rules, inbox request kinds, digest sections and lines, a trust rule for issues your workflows queue |

Everything else (the workflows, `.github/scripts/agent-*.sh`, the Claude commands) is rendered by
the package and recorded in `.github/agents/install.lock.json`. `/gatehand:update` re-renders
them; it refuses to overwrite a file you edited by hand, because that change belongs in one of the
files above.

## Dashboard

`/gatehand:dashboard`, or `python3 bin/dashboard.py`, opens a local page with every repository
where Gatehand is installed: what waits for you (inbox requests, stopped roles, blocked issues),
agent PRs and why the merge gate holds them, what is running, the queue, and the week's runs and
cost. Its buttons answer inbox requests, rerun, pause or resume a role, and hold or unqueue issues, as
you, through your own `gh` login: the same comment or label you would make by hand. See
[`docs/dashboard.md`](docs/dashboard.md).

## Runners

GitHub-hosted runners by default: a fresh VM per job is the isolation the design needs. For your own
machines, see [`addons/hardened-runner`](addons/hardened-runner/README.md): what a self-hosted agent
pool must give you, a reference egress allowlist, and systemd timers that dispatch the schedules on
time.

## Developing

```bash
bash tests/run.sh
```

renders the package into a scratch repository, lints the result (actionlint, shellcheck) and runs
every suite under `tests/` against it. The suites drive the scripts against a stub `gh` and local git
repositories; nothing reaches the network.

## License

MIT, see [LICENSE](LICENSE).
