# Changelog

## 0.3.2 (2026-11-12)

- Security: a review dispatched by hand for a fork's PR is refused before the PR is checked out.
  The review job checks out the PR's head and then runs that tree's `.github/actions/install-gh`
  and reads its `.claude/` with a PR-write token and an OIDC token, the Claude credential in later
  steps' reach. An automatic run skips a fork's PR, but a dispatch had no such check, and the
  workflow's own comment suggested dispatching one "after reading the PR". Its new first step
  asks the API for the PR's head repository and stops unless it is this one; the `pr` input must
  be a number. To review a fork's PR, push its head to a branch of the repository and open a PR
  from that branch. The automatic run's skip is not a control (a fork's PR runs its own copy of
  the workflow; GitHub gives it no secrets and a read-only token), and the comments and the
  runbook now say so: a public repository with a self-hosted review runner should require approval
  for workflows from fork PRs. Found by installing Gatehand into a fresh repository with
  `/gatehand:install`.
- The install skill and the default `toolchain/action.yml` no longer say `cache: false` for every
  setup action: `setup-node` and `setup-python` take a package manager's name there and reject
  `false`. Leave `cache` out on both, and on `setup-node` v5 or later set
  `package-manager-cache: false`, which is on by default.

## 0.3.1 (2026-11-11)

- The fixer's job restores main's copy of the setup actions for its post steps from the commit its
  toolchain and dependency steps checked out, not from the default branch's newest commit. When the default branch
  moved during a fix, a post step could read a different `action.yml` than the one its main step
  ran. The update changes `agent-fixup.yml`, so fast-forward your runner ref (`agent-runner` by
  default) once it merges.

## 0.3.0 (2026-11-11)

The package is renamed from `repo-agents` to Gatehand, and its repository from
`codifydoo/repo-agents` to `codifydoo/gatehand` (GitHub redirects the old address). Nothing the
agents read or write changes: the `agent:*` labels, the `agent-run:*` and `verify-pr-review`
markers, the workflow and script names, `.github/agents/`, and the variable and secret names all
stay as they are, so a running install needs no migration.

- The plugin is `gatehand@gatehand`, and its commands are `/gatehand:install`, `/gatehand:update`
  and `/gatehand:doctor`.
- A new install's defaults: the GitHub App name `<repo>-gatehand` (the manifest's `gatehand`), the
  bot `gatehand[bot]` in `defaults/policy.json`, and the branches `chore/install-gatehand` and
  `chore/update-gatehand`. An existing `policy.json` keeps its own `botLogin`.
- `addons/hardened-runner` installs its kick timers as `gatehand-kick@*` with the token in
  `/etc/gatehand-kick/token`.

Upgrading from 0.2.x:

- Swap the plugin: `/plugin uninstall repo-agents@repo-agents` and
  `/plugin marketplace remove repo-agents`, then `/plugin marketplace add codifydoo/gatehand`,
  `/plugin install gatehand@gatehand`, and `/gatehand:update` in your repository. Left installed,
  the old plugin's `/repo-agents:update` would render 0.2.x over 0.3.0.
- The update rewrites comments in `agent-coder.yml` and `agent-fixup.yml`, so fast-forward your
  runner ref (`agent-runner` by default) to the default branch once it merges, or the coder and
  fixer stop with `runner-ref-stale` until you do.
- If you installed the kick timers, move them over as root. First note the settings the old
  install used, from the `Environment=` line of `/etc/systemd/system/repo-agent-kick@.service`.
  Then:

  ```bash
  systemctl disable --now repo-agent-kick@{sweep,merge,coder,digest}.timer   # and @triage.timer if you had it
  mv /etc/repo-agent-kick /etc/gatehand-kick
  rm -f /etc/systemd/system/repo-agent-kick@* /usr/local/libexec/repo-agent-kick
  systemctl daemon-reload
  AGENT_KICK_REPO=<owner>/<repo> bash agent-kick.sh install   # from the new package, with the same AGENT_KICK_* values
  ```

## 0.2.6 (2026-11-11)

- Docs only. The 0.2.1 entry below said that in one private repository on a Free personal account
  no scheduled run fired at all, and the README stopped at the first seven hours. They did fire,
  late and rarely: the first came eight hours after the install, and the hourly crons then fired
  only every four to eight hours. The README's "Nothing runs on its schedule", that entry and a
  comment in `bin/doctor.sh` now say so. No workflow or script behaves differently; an update
  re-renders the agents' README and the lock file.

## 0.2.5 (2026-11-11)

- A Claude review the agents requested that never posts no longer leaves the PR waiting for good.
  A dispatched review run can end green without one (claude-code-action's OIDC exchange failed once
  with a "not retryable" workflow validation error, and the review's own check reads a run with no
  execution file as a skip), and `request_review` asked once per head, so nothing asked again. Now
  the merge gate makes a request again when it is older than 45 minutes (the review job's 30-minute
  timeout and slack), no review answered it and no review run of the PR is queued or running, at
  most twice per head. A review answers the request when it is a writer's posted after it, or the
  review bot's, unedited, from a job that started after it: an older head's review that was queued
  ahead of it and posts later does not. When the third request goes unanswered too, the agent inbox
  gets one request of the new `review` kind for that head (`/approve` and `/reject` record it as
  seen) and the PR waits; nothing is labelled. A new head starts over. Only the gate retries: the
  fixer's router, which runs on the same CI completion, still asks once per head, so the two cannot
  spend one retry twice.
- The merge gate retries on a head the fixer pushed too: a head whose review the agents already
  requested, missing nothing but its review (being behind main aside) and not conflicting, goes
  through `request_review` on every run, which does nothing until that request is stale. Before,
  only the gate's own branch updates were asked for, and such a fixer head waited for a person.

## 0.2.4 (2026-11-10)

- The fixer can rewrite the PR's description. When its fix makes the description untrue (what the
  PR does, how it was verified), it writes `pr-body.md` and the publish step replaces the
  description with it, under the coder's body rules (`Refs #N`, no closing keyword, the size cap)
  and keeping the coder's footer and its `agent-run:coder` marker verbatim. A description that
  anyone but the agent bot last edited is left as it is, as is one whose footer is gone; the fix
  comment says which. Only a fix with commits does this: a description-only answer to a review is
  not supported. Found live: a fix changed behaviour, the next review saw the PR contradict its own
  description, and asked for changes the fixer could not make.

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
  README says what to do then. GitHub reports nothing when a cron does not fire; in one private
  repository on a Free personal account the first scheduled run came eight hours after the
  install, and the hourly crons then fired only every four to eight hours. A sweep schedule that
  is not hourly is not checked.
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
