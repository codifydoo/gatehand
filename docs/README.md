# Autonomous agents (repo-agents)

Written by [repo-agents](https://github.com/codifydoo/repo-agents); `bin/render.sh` overwrites this
file on update. Your settings live next to it: `policy.json`, `protected-paths.txt`, `project.md`,
`system/`, `toolchain/`, `dependencies/` and `hooks/`.

## What runs

| Workflow | What it does | Model |
|---|---|---|
| `agent-coder.yml` | Takes one `agent:ready` issue, implements it, opens a PR that says `Refs #N` | `roles.coder.model` |
| `agent-fixup.yml` | Fixes its own PR when CI fails (at most `maxCiFixes`) or a review asks for changes (`maxReviewFixes`) | `roles.fixer.model` |
| `claude-code-review.yml` | Reviews every PR once (on open and on ready-for-review); its verdict gates the merge | `review.model` |
| `agent-merge.yml` | Merges an agent PR when every condition below holds. A dry run until `AGENT_AUTO_MERGE` is `true` | none |
| `agent-pr-guard.yml` | The `agent pr guard` check: protected paths, `Refs #N`, no closing keywords, your hook's rules | none |
| `agent-sweep.yml` | Hourly: frees stale locks, moves issues whose PR merged or closed, recovers dead fix runs | none |
| `agent-inbox.yml` | Applies your `/approve`, `/reject`, `/rerun`, `/pause`, `/resume` on the inbox issue | none |
| `agent-digest.yml` | A weekly comment on the inbox: what waits for you, PRs, runs and cost, the queue | none |
| `agent-triage.yml` | Optional (`workflows.triage`): queues Low/Medium Claude Security findings a writer filed | none |

## How one coder run goes

1. **preflight** (seconds, App token, no model). Stops unless `AGENTS_ENABLED` is `true`, the run is
   on the `agent-runner` ref and that ref's copy of the workflow equals the default branch's, the
   breaker is closed, today's runs are under `runsPerDay` and open agent PRs under `maxOpenPrs`.
   Then it picks the issue (the one named, or the highest-priority oldest eligible `agent:ready`
   one), locks it, and reads it ONCE: title, body, and only comments by people with write access,
   framed as untrusted data. It checks again that nobody without write access changed it since.
2. **code** (the model). Runs your `system`, `toolchain` and `dependencies` actions, drops
   passwordless sudo, then `/agent-implement`. The model edits, tests and commits on a local branch.
   Its GitHub token reads repository contents only, every `gh` command is denied to it, and it
   cannot push, comment or label.
3. **publish** (App token, no model). A fresh checkout of the default branch takes the agent's
   commits from a git bundle, validates them (`agent-outbox.sh`: commit shape, bot authorship, no
   closing keywords, `Refs #N`, size caps, protected paths), pushes `<type>/agent-<slug>` and opens
   the PR. Then labels, an issue comment, an inbox request if needed, a ledger row, the breaker.
   Last, what the coder noticed but left alone (`followups.json`, at most `roles.coder.maxFollowups`,
   each with a `### Done when` section) is filed as `agent:candidate` issues for you to queue or
   close; the digest lists them.

The PR then goes through your CI and the Claude review like any other. The fixer and the merge gate
take it from there. The fixer reads the failure or the review, the PR as the coder described it, and
the issue itself when the run can still vouch for its text (the same snapshot rules as the coder).

## Security model

The model never shares a job with a write-capable token, and nothing it wrote is executed by one.

- **Read-only model job.** `permissions: contents: read`, no `id-token`, and the read-only
  `GITHUB_TOKEN` handed to claude-code-action explicitly, so the action does not exchange OIDC for a
  write-capable Claude App token. `--disallowedTools` denies push, every `gh` command, curl, wget,
  ssh, docker, sudo, WebFetch and WebSearch (`policy.json` `tools.deny` adds more).
- **A separate publish job** with the App token runs only the default branch's scripts, in a new job.
  The App has no Workflows permission, so GitHub itself refuses any push touching `.github/workflows/`.
- **Sudo once, before agent code.** Your `system` action is the only setup step that may use sudo.
  In the fixer it runs before the agent PR's head is checked out, and passwordless sudo is gone
  before anything from that head runs. All setup actions come from the default branch's copy. On
  GitHub-hosted runners the job's user is also in the `docker` group, so dropping sudo does not make
  the job unprivileged there: the per-job VM and the read-only token are the boundary. On a
  self-hosted pool, give the runner no Docker access (`addons/hardened-runner`).
- **Protected paths.** Lines in `protected-paths.txt` need a writer's `agent:allow-protected` on the
  issue (one attempt only, and such a PR is never auto-merged); its `!` lines never open. Under
  that is a floor no file can lower (`AGENT_NEVER_FLOOR` in `agent-lib.sh`): `.github/`, `.claude/`,
  every `CLAUDE.md`, `.mcp.json`. The outbox and the PR guard both enforce it, both from the default
  branch's copy.
- **The `agent-runner` ref.** The model controls its own job, including the Actions runtime token
  later steps hold, so it could write cache entries. Runs are dispatched on `agent-runner`, whose
  cache scope the default branch and PRs never read, and the code job restores no caches.
- **Untrusted text.** Issue text is framed as data, stripped of invisible format characters, and
  only writers' comments reach the model. Text the bot posts has `@mentions` and `<!--` neutralised.
- **Trust anchored on a person.** The coder takes an issue only if the latest `agent:ready` a person
  applied came from someone with write access, and nobody without write access edited it since.
  Inbox commands count only from `AGENT_OWNER_LOGIN`.

Residual risks you accept by running this:

- **The model's own job.** A prompt-injected run controls its job and can read the Claude credential
  from its environment. Use a capped API key (`claude.auth: "api-key"`) if that matters to you, and
  on self-hosted runners an egress allowlist (`addons/hardened-runner`).
- **CI runs agent code.** An agent PR's code runs in your CI like any PR's, without a person reading
  it first. Keep secrets out of PR-triggered CI jobs, and on self-hosted runners keep the agent pool
  apart from the CI pool.
- **Shared subscription.** With `claude.auth: "oauth"` the runs count against the same Claude
  subscription as your interactive sessions; `runsPerDay` is the guard.

## Setup

The install skill (`/repo-agents:install`) walks through this; it is here for reference.

1. **Create the GitHub App** (Settings → Developer settings → GitHub Apps → New, or from the
   package's `docs/app-manifest.json`). Webhook off. Repository permissions: Contents, Issues, Pull
   requests and Actions read and write; Checks, Commit statuses and Metadata read. Nothing else, and
   **no Workflows**. Install it on this repository only. Its slug must match `policy.json`
   `botLogin` (`<slug>[bot]`).
2. **Install the Claude GitHub App** (https://github.com/apps/claude) on this repository: the review
   posts its verdict as `claude[bot]`.
3. **Secrets and variables:**

   ```bash
   gh secret set AGENT_APP_PRIVATE_KEY < path/to/app.private-key.pem
   gh variable set AGENT_APP_CLIENT_ID --body "<the App's Client ID>"
   gh variable set AGENT_BOT_ID --body "$(gh api 'users/<slug>[bot]' --jq .id)"
   gh variable set AGENT_OWNER_LOGIN --body "<your GitHub login>"
   gh secret set CLAUDE_CODE_OAUTH_TOKEN   # from `claude setup-token`; or ANTHROPIC_API_KEY with claude.auth "api-key"
   ```

4. **Labels and the runner ref:**

   ```bash
   bash .github/scripts/agent-labels.sh
   git push origin origin/main:refs/heads/agent-runner
   ```

5. **Actions defaults:** Settings → Actions → General → Workflow permissions: "Read repository
   contents", and untick "Allow GitHub Actions to create and approve pull requests". Every workflow
   here declares its own permissions.
6. **Turn it on:** `gh variable set AGENTS_ENABLED --body true`. Leave `AGENT_AUTO_MERGE` unset until
   you have read a few of the merge gate's dry-run summaries.
7. **After the first agent PR:** pin the "Needs a human (agent inbox)" issue, and add `agent pr guard`
   to the default branch's required status checks (on a person's PR it is skipped, which counts as
   passing). A private repository on GitHub Free has no required checks; the merge gate still
   checks `agent pr guard` itself, but people's merges are then unguarded.

**After every change to `agent-coder.yml` or `agent-fixup.yml` on the default branch**, fast-forward
the runner ref, or the gate stops with `runner-ref-stale`:

```bash
git fetch origin main && git push origin origin/main:agent-runner
```

## Day to day

- **Queue work:** label an issue `agent:ready`, or file it with the "Agent task" template. It is taken
  only with an acceptance section (`Done when`, `Acceptance`, `Recommendation`, `Suggested fix` or
  `Expected`), not `size: L`, `agent:hold` or `question`, fewer than `maxAttemptsPerIssue` attempts,
  and no merged PR that already names it.
- **Start a run now:** `gh workflow run agent-coder.yml --ref agent-runner [-f issue=<n>]`.
- **Keep an issue away from the agents:** `agent:hold`.
- **Allow protected paths for one issue:** a writer adds `agent:allow-protected` to the issue.
- **Auto-merge:** `gh variable set AGENT_AUTO_MERGE --body true`. The gate merges an agent PR only
  when, on its current head: the agents are on and no breaker is tripped; it is the bot's, open, not
  a draft, mergeable, and carries none of `agent:hold`, `agent:blocked`, `agent:needs-human`,
  `agent:fixing`, `agent:allow-protected`; every `requiredChecks` entry and `agent pr guard` passed;
  the newest review verdict (by `claude[bot]` or a writer) is Approve and newer than the head; no
  changed file is protected or in `humanPaths`; and the head contains the default branch's tip. It
  merges with a merge commit pinned to that head, never `--admin`. With `requiredChecks` empty it
  merges nothing. The issue then becomes
  `agent:done-pending-deploy`: close it yourself once the fix is live.

## The inbox

Everything that needs a person lands as a comment on the "Needs a human (agent inbox)" issue.
Answer with a comment that starts with a command; only `AGENT_OWNER_LOGIN` counts.

| Command | Effect |
|---|---|
| `/approve REQ-…` | Do what the request proposes |
| `/reject REQ-… [reason]` | Leave it as it is |
| `/rerun coder #N` | Re-queue #N and start the coder on it |
| `/pause <role>` · `/resume <role>` | Stop or restart a role (also resets its breaker) |

**Kill switch:** `gh variable set AGENTS_ENABLED --body false` stops every agent job at its next
start; the inbox still works.

## When something is stuck

- **`runner-ref-stale`:** fast-forward `agent-runner` (see Setup).
- **`no-go:ledger-unreadable`:** the App token cannot read the `agent-ledger` branch. Check the App
  is installed with Contents access. The gate fails closed on purpose.
- **`refused` with a reason:** the outbox rule that fired is in the reason and on the issue; the
  agent's commits are in the run's `agent-outbox` artifact for 14 days.
- **`untrusted-change`:** someone without write access changed the issue after the label. Read the
  change, re-apply `agent:ready` yourself, then `/rerun coder #N`.
- **An issue stuck in `agent:in-progress`:** the hourly sweep frees it once the lock expires and its
  run has ended. To free it sooner, swap the label back to `agent:ready` yourself.
- **An agent PR that is green but not merged:** the newest "Agent merge" run's summary lists every
  reason it is waiting.
- **A run that failed before the model started** (a mirror outage in your setup steps) costs no
  attempt, no daily run and no breaker step, `infraGracePerDay` times per role per day.

## Changing the rules

- **Numbers, models, schedules, runners, tools:** edit `policy.json`, then re-render
  (`/repo-agents:update`, or `bin/render.sh .` from a checkout of the package) and commit both.
- **Your project's rules and checks:** `project.md`. The coder and fixer read it on every run. Every
  check command must also be in `policy.json` `tools.allow`, as `Bash(<prefix>:*)`.
- **Setup:** `system/action.yml` (sudo, fixed packages only), `toolchain/action.yml`,
  `dependencies/action.yml`.
- **Behaviour the package does not have:** `hooks/lib.sh` (see `hooks/lib.sh.example`): extra
  guard rules, inbox request kinds for your own workflows, extra digest sections, your own line for
  a merged issue waiting to go live, and a rule that vouches for issues your own workflows file
  and queue as the bot.
- **Never edit the rendered package files** (the workflows, `.github/scripts/agent-*.sh`, the
  commands): an update refuses to overwrite a hand-edited file, and the change belongs in one of the
  places above.
