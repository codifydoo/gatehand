# Changelog

## 0.8.2 (2026-11-15)

- Dashboard: merged issues can be closed from the page. Needs you → To close (open issues labelled
  `agent:done-pending-deploy`) was link-only; now an issue's pane has **Close it** (key `a`), and
  each To close row has a checkbox, with Select all, Clear and **Close n…**, which closes the ticked
  issues in one confirm (one preview per repository, like Pause all). It goes through the same
  preview and one-time confirm token as the other actions, re-planned from a fresh read: it closes
  only open issues that still carry `agent:done-pending-deploy`, as completed, never the inbox or a
  PR, and nothing while the inbox cannot be told; it needs write access and takes at most 50 issues
  per repository per confirm. If one ticked issue was closed or relabelled since the preview, that
  repository's whole confirm is refused. Labels stay on the closed issue, as with GitHub's own Close
  button. Installed repositories need no update: the dashboard runs from the package (an update
  only refreshes one line in their `.github/agents/README.md`).

## 0.8.1 (2026-11-15)

- Sweep: a stale coder lock is matched only to a ledger row for its own issue. "Re-run all jobs" on
  a coder run whose first attempt died before the model keeps the run id and attempt number but
  picks its issue again, so the run's row could be another issue's; the sweep then labelled the
  first issue `agent:pr-open` for a PR that was never its own. Now that lock is released as stale
  (back to `agent:ready`, or blocked on the last attempt). Installed repositories need an update
  (`bash bin/render.sh <repo>`) to get it.
- A coder or fixer run re-run with "Re-run all jobs" is told apart from its first attempt. The lock, the
  `no-attempt` markers and the ledger rows now carry GitHub's `run_attempt` (the attempt that took
  the lock), and a `no-attempt` marker voids only the lock of its own run attempt. Before, when a
  run's first attempt failed before the model and someone re-ran it on the same issue: the first
  attempt's marker voided the re-run's lock too, so a re-run that reached the model and failed never
  counted towards `maxAttemptsPerIssue` (or the fixer's caps); and when the re-run died before its
  finalize, the sweep took the first attempt's uncounted row for its own and re-queued it with no
  row, comment or breaker step, even on the last attempt. Markers and rows written before this
  carry no `run_attempt` and still match every attempt of their run. The dashboard counts review
  fixes the same way. Not covered: "Re-run failed jobs" after the first attempt's finalize ran
  re-uses that attempt's lock, so a re-run that then reaches the model is still not counted towards
  the attempt caps (it does count towards the breaker). Installed repositories need an update
  (`bash bin/render.sh <repo>`) to get it.
- Installed repositories need an update (`bash bin/render.sh <repo>`, or the update skill) to get
  both fixes: they are in the installed scripts and the coder and fixer workflows.

## 0.8.0 (2026-11-15)

- Hand back to the merge gate says in its confirm whether the PR's head moved since it was blocked:
  whether the head commit is newer than the last time `agent:blocked` or `agent:needs-human` was put
  on (#25). An unmoved head is a warning, not a refusal. The server answers it from a preview of the
  label change (`type: "label"` on `/api/action/preview`), which only reads and hands out no confirm
  token; the label change itself is unchanged. Installed repositories need no update: the dashboard
  runs from the package.
- Dashboard: an answered inbox request says how (`answer`: approved, rejected, seen or acknowledged),
  when (`answered_at`) and, for a reject, the owner's one-line reason (`reason`), read only from
  `AGENT_OWNER_LOGIN`'s own `/reject`, never an edited one (#23). The blocked-issue pane shows it
  ("its last one, REQ-…, was rejected by you on Nov 11: not now"), as does a request's pane once someone answered first ("approved at
  17:29") and the Pipeline tab's recently answered requests. Installed repositories need no update:
  the dashboard runs from the package.
- A blocked or failed request's pane says under step 1 whether someone with write access has
  commented on the issue since the request, and who and when (#24). The server reads it per request,
  for the open pane only (when it opens and on each refresh), from the new
  `/api/repo/<owner>/<name>/request/<REQ-id>`; the comment's text is never read, and the agent bot's
  comments do not count. Installed repositories
  need no update: the dashboard runs from the package.
- Dashboard: "Rerun coder" is refused, with the reason, when the issue is no longer blocked
  (neither `agent:blocked` nor `agent:needs-human`), is `agent:in-progress` or `agent:pr-open`, is
  closed or a PR, or has an open `untrusted` request; the server reads the issue's labels afresh
  before posting, so two clicks from stale pages no longer post two reruns (#27). Installed
  repositories need no update: the dashboard runs from the package.
- Week shows the last seven days' cost as a floor against a weekly budget you set on the page (kept
  on this machine, #28), with its warning line; cost by day against the budget's pace, by repository
  and outcomes by role; PRs merged by the gate and coder runs that opened a PR. Runs with no cost
  recorded are counted and listed, and an unreadable repository is named, never $0. Over the
  warning line the sidebar's Week figure turns amber; nothing is paused.
- Dashboard: a failed read says why, as one cause from a fixed set (`sso`, `signed_out`,
  `rate_limited` with the time the limit resets, `not_found`, `no_access`, `unknown`), in each
  repository's new `unreadable` list, beside `error` in a failed request's answer, and for a scan
  that could not see everything in `scan_unreadable` beside its notes; Needs you shows it as health
  rows. Installed repositories need no update: the dashboard runs from the package.
- The dashboard is laid out as a sidebar and views instead of one long page: Needs you, Activity,
  Week, a Repositories list, and per repository four tabs (Pipeline, Agents, Runs and spend,
  Settings). The view is in the address, so a reload or a link keeps it, and the number waiting for
  you is in the tab's title. The total tiles are gone: what waits for you, runs going and the week's cost sit
  in the sidebar; open PRs, queued issues and run counts are per repository, on Repositories and Week. Every list and
  button is still there, and sends exactly what it did.
- Needs you is one list with one row per thing you act on, newest first, with chips to filter it
  (Requests, Stopped, PRs, Issues, To merge, To close) that add up to its count. A request about an
  agent PR shows as that PR; a stopped role and its breaker request are one row. New: agent PRs that
  passed the merge gate while auto-merge is a dry run, folded under "to merge", since a person has
  to merge them. A row you have not seen before is marked NEW. Suggested issues are no longer in
  Needs you; they stay on the repository's Pipeline tab.
- A row of Needs you opens in an item pane beside the list, the top one open on arrival. A request's
  pane says why it is stuck, shows what the agent wrote, links to the step on GitHub that comes
  first (such as commenting on the blocked issue), and answers it with a confirm that opens in the
  pane, naming the exact inbox line and what follows. Disabled, refused (nothing posted) and waiting
  for the Agent inbox workflow are said in the pane.
- A stopped role and an agent PR held for a person have panes of their own. The role's shows its
  newest runs, why the breaker tripped and what it holds up, and resets it from the pane (Reset the
  breaker for its request, or Resume). The PR's says why it is held and the merge gate's last word,
  links to the PR to fix it, and hands it back from the pane; Hold, Run review, Run merge gate,
  Approve… and Request changes… confirm there too, with the server's preview.
- A blocked issue's pane reruns the coder or holds it from the pane. The "to merge" and "to close"
  panes link to GitHub to merge or close (the page does neither), and to Settings for auto-merge.
- A repository's tabs route instead of acting twice: an open request, a stopped role, a held PR,
  a blocked issue, a PR to merge and an issue to close link to their item in Needs you. What has no
  item (pausing a role, the switches, unqueue, hold, starting the coder, running the merge gate,
  cancelling a run) confirms under its own button, as in a pane, with the same writes as before.
  Agents shows each role's runs today, failures in a row and open PRs against its limits, when it
  runs next, and each scheduled workflow's cron, last run and next run; Runs and spend links each
  ledger row to its item and its run. The Pipeline says when the agents are off, and what to do
  when nothing is queued. Installed repositories need no update.
- Activity lists, across every repository, what is running now (with Cancel), what is not moving
  and not waiting on you, one row per cause per repository with when it moves (agents off, a role
  stopped, a daily or open-PR limit reached, a lock no run holds), and the agent runs that finished
  today. A part that could not be read is named and counts as unknown, never as none. With nothing
  running, it shows the next scheduled runs ("Next: merge gate 18:11 in 3 repositories, coder 18:17
  in 2"); a repository with the agents off adds only the digest, and a workflow whose time is not
  known in every repository is left out rather than guessed.
- Dashboard: the repository payload carries each role's `maxAttemptsPerIssue`, `maxCiFixes`,
  `breakerThreshold` and `timeoutMinutes` (null when `policy.json` does not set one), and each
  scheduled workflow's cron lines and next run in UTC, read from the workflow files on the default
  branch (null with no schedule, `"unknown"` and an error when the file cannot be read). Reads only
  (#21, #22); Activity shows the next scheduled runs, and a repository's Agents tab shows the limits
  and schedules.
- In a narrow window the open item of Needs you expands in place under its row, as in a mail app,
  and the sidebar folds into one line with ☰.
- Needs you with nothing in it says what is true and what to do next: nothing needs you (with what
  is running and queued), nothing that could be read (naming what could not), or no repositories
  found; a repository still being read shows a "reading…" line.
- Keys on Needs you: j/k move, o goes into the item, a opens its primary action's confirm (Enter
  confirms), r opens Reject…, Esc closes the confirm, ? lists them.
- What could not be read has a health row at the end of Needs you, never counted, whose pane says
  why (the server's cause) and the one thing that helps: authorize gh for an organization's SSO,
  find a repository that moved, ask for access; "Check again" re-reads that repository only. A
  signed-out gh and the API limit are said once under the bar, and Refresh is off until the limit
  resets.
- Dashboard: Pause all's record. A `set_variable` that turns `AGENTS_ENABLED` off can carry
  `"pause_all": true`; once that write succeeds, the repository is kept in a `paused` list in the
  dashboard's local config file, which `/api/session` returns, so Resume turns on only what Pause
  all turned off. The list is dropped per repository when the page turns its agents on, or a read
  finds them on. No new write to GitHub; a config file from before loads unchanged (#29).
- Dashboard: "Pause all…" in the global bar turns `AGENTS_ENABLED` off in every repository where it
  is on, after one confirm that lists every repository with its preview; the bar then says "Agents
  off in n of m" on every screen, names what was refused, and offers "Resume n…", which turns on
  only what Pause all turned off.
- Dashboard: a weekly budget in US dollars and a warning line (a share of it, 80% by default), kept
  in the dashboard's local config file, set through `POST /api/budget` and returned by
  `/api/session`. A setting on this machine only: nothing is written to GitHub, no agent reads it,
  and it stops nothing. A config file from before loads unchanged; Week shows and sets it
  (#28).
- Project site: `site/` holds five static pages (home, how it works, security, the dashboard, get
  started), published to GitHub Pages by `.github/workflows/pages.yml` on a push to `main`. Not
  part of the package: nothing changes in installed repositories.
- `docs/dashboard.md` describes the page as built, in the order you meet it: the bar and sidebar,
  Needs you with its panes, health and keys, Activity, Week, a repository's tabs, then the actions,
  the security model, and what the server sends. Repositories now lists every column it shows.
- Review: `/verify-pr` now says how to write its two headings (plain `###` markdown, with the
  verdict alone on the line under `### Verdict`). In one installation, 45 of 316 reviews in a month
  wrote the Verdict heading as HTML, in bold or on one line with the verdict, and the merge gate
  read 10 of them as unknown, which leaves an agent PR waiting for a person. Installed repositories
  get the wording on their next update.
- Prompts: the coder and fixer commands no longer say "Plan with TodoWrite" or cap `summary.md` at
  30 lines (it is "a short comment" now); `/verify-pr`'s opening stance reads "Check what the PR
  claims against the code, and do NOT assume correctness."; and a comment in
  `claude-code-review.yml` names the policy key `review.model` correctly. Installed repositories get them on their next update.
- Nothing else installed into repositories changes: an update (`bash bin/render.sh <repo>`, or the
  update skill) is needed only to get the review and prompt wording above.

## 0.7.0 (2026-11-14)

- Security: the Claude review's model no longer holds a token that can write, and can no longer read
  its environment or reach another host. claude-code-action was given no `github_token`, so it minted
  the Claude App's token (contents, issues and pull_requests write) and handed it to the model, which
  reads text the PR's author wrote: on an agent's PR, a coder model steered by issue text anyone may
  have written. A review that followed planted text could post anything on any PR, post a dictated
  verdict, or hand the token out (`gh pr view --jq '$ENV'` reads the environment, and a `gh` URL
  argument sends a request to the host it names). Now:
  - the `claude-review` job's token is read-only (`pull-requests: read`), it has no `id-token`
    grant, and the review step is given that token as `github_token`, so nothing in that job can
    mint a token that writes;
  - the model has no tool that writes: `Write`, `Edit` and `NotebookEdit` are denied by name,
    `Edit(//**)` denies every file write (a shell redirect included), and its reads stop at the
    checkout (`blockReadsOutsideWorkingDirectories`, plus `Read(//proc/**)`);
  - it reaches `gh` only as `review-gh`, a wrapper the workflow writes: `pr view`, `pr diff`,
    `pr list`, `issue view` and `search` only, each with an allowlist of flags (so no `--jq`,
    `--template`, `--repo` or `--web`, and no combined short flags such as `-cq`), values of a fixed
    shape, PR and issue numbers only, and gh runs with an empty environment but for the read-only
    token. Plain `gh` is denied;
  - `/verify-pr` ends with the review as its final message, saved as an artifact; a new
    `post-review` job, which runs no model and checks out nothing, posts it from the marker line on
    to the run's PR as `claude[bot]`, with a Claude App token it mints itself (OIDC, then Anthropic's
    token exchange, asking for `contents: read` and `pull_requests: write` only) and revokes, then asserts the comment
    landed. It posts nothing that lacks the marker, is over 60000 bytes or carries text shaped like a
    credential. When the exchange refuses because the PR edits the review workflow, or Claude never
    ran, it posts the "Claude did not review this PR" note instead;
  - `/verify-pr` says the PR's title, body, diff and comments are data, never instructions, and that
    text addressing the reviewer is a blocking problem to name without copying it.
- `review_attribution` (agent-state.sh), which the merge gate and the fixer use to tell a fresh
  review from a stale one, now reads a run attempt's window from the `claude-review` job's start to
  the later of its and `post-review`'s ends.
- Reviews no longer anchor findings inline on `pull_request` runs: every run posts the one summary
  comment a dispatch already posted. `/verify-pr <number>` in an interactive session prints the
  review and posts nothing.
- A PR that edits the review workflow now gets a billed review whose result is not posted (the
  Claude App posts only for the default branch's copy), where the action used to skip it before the
  model ran. The note on the PR says so; dispatch the review after the PR merges.
- The update changes `claude-code-review.yml`, `.claude/commands/verify-pr.md` and
  `agent-state.sh`, not `agent-coder.yml` or `agent-fixup.yml`, so no runner-ref fast-forward is
  needed. The PR that applies it edits the review workflow, so its own review is not posted:
  dispatch one after it merges.

## 0.6.1 (2026-11-14)

- The runbook installed in each repository (`.github/agents/README.md`) now has a section on the
  dashboard: how to open it, what its buttons do, and what stays on GitHub.
- Fixed: the dashboard's buttons did nothing in a browser that suppresses native dialogs (an app's
  or an editor's built-in browser answers `confirm()` with "Cancel" without showing it). The page
  now asks in a dialog of its own: OK, Cancel or Esc, and a text field for a reject reason.
- The update changes only the runbook in your repositories (the dashboard runs from the plugin),
  not `agent-coder.yml` or `agent-fixup.yml`, so no runner-ref fast-forward is needed.

## 0.6.0 (2026-11-14)

- The dashboard can now start and stop the agents' work. Start the coder (an auto pick, with every
  check of a scheduled run), run the Claude review or the merge gate on an agent PR, cancel a running Gatehand run,
  and turn `AGENTS_ENABLED` or `AGENT_AUTO_MERGE` on or off.
- Review verdicts from the page: "Approve…" and "Request changes…" on an agent PR post the review
  comment the merge gate and the fixer read from a person with write access, for the head the
  preview names (refused if it moved, and Approve while the fixer is working). A Request changes note is plain text that cannot move the verdict under it, and can start the
  fixer on it.
- These show a preview first (the exact GitHub calls, the comment, what to expect, anything in the
  way) and are done only if nothing changed since: a new head, a changed variable or a coder run that
  started waiting all refuse.
- Fixed: "Hand back to the merge gate" (0.5.0) was always refused.
- Nothing installed into repositories changes: no update is needed.

## 0.5.0 (2026-11-14)

- The dashboard can now answer the agents. Each open inbox request has its own button (named for
  what approving it does: "Requeue and rerun", "Reset the breaker", "Mark as seen"…) and "Reject…";
  blocked issues have "Rerun coder"; each role has "Pause" or "Resume". These post the same
  `/approve`, `/reject`, `/rerun`, `/pause` and `/resume` comment on the inbox issue that you would
  type, with your own login, so the `Agent inbox` workflow applies them exactly as before, and only
  for `AGENT_OWNER_LOGIN`. The server checks the workflow's own conditions first and refuses, with a
  reason, a command it would ignore: another login, an inbox it would not answer, a request the agent
  never filed or one already answered.
- One command at a time: until the `Agent inbox` workflow has answered your last command, the page
  sends no other (two runs at once would both apply), for up to ten minutes.
- Labels from the page, for anyone with write access: unqueue an issue (`agent:ready` off), hold or
  release an issue or agent PR (`agent:hold`), and hand a fixed PR back to the merge gate (removing
  `agent:blocked` and `agent:needs-human`). The page never adds `agent:ready`, which vouches for issue
  text it does not show: candidates link to GitHub to be read and queued there. `agent:allow-protected`
  is never offered.
- Every write asks you to confirm and says what will happen. Nothing installed into repositories
  changes: no update is needed.

## 0.4.0 (2026-11-14)

- New: a local dashboard, `/gatehand:dashboard` or `python3 bin/dashboard.py`. One page for every
  repository where Gatehand is installed (found by scanning your repositories for
  `install.lock.json`): what waits for you, open inbox requests in full, agent PRs with the merge
  gate's last word on each, running and recent runs, the queue, and seven days of runs, cost and
  breakers per role. It reads the ledger, labels, inbox and runs the way the agents' own scripts do,
  through your `gh` login, and writes nothing to GitHub. It listens on 127.0.0.1 behind a per-launch
  secret, Host and Origin checks; `docs/dashboard.md` has the security model. Python 3.9+ and `gh`,
  no packages.
- Nothing installed into repositories changes: no update is needed.

## 0.3.3 (2026-11-12)

- Security: a review dispatched by hand for a fork's PR is refused before the PR is checked out. The
  review job checks out the PR's head and then runs that tree's `.github/actions/install-gh` and
  reads its `.claude/` with a PR-write token and an OIDC token, the Claude credential in later
  steps' reach. An automatic run skips a fork's PR, but a dispatch had no such check, and the
  workflow's own comment suggested dispatching one "after reading the PR". Its new first step asks
  the API for the PR's head repository and stops unless it is this one; the `pr` input must be a
  number. To review a fork's PR, push its head to a branch of the repository and open a PR from that
  branch. The automatic run's skip is not a control (a fork's PR runs its own copy of the workflow;
  GitHub gives it no secrets and a read-only token, unless a private repository's fork settings send
  them), and the comments and the runbook now say so: a public repository with a self-hosted review
  runner should require approval for all external contributors' workflows. Found by installing
  Gatehand into a fresh repository with `/gatehand:install`.
- The install skill and the default `toolchain/action.yml` no longer say `cache: false` for every
  setup action: `setup-node` and `setup-python` take a package manager's name there and reject
  `false`. Leave `cache` out on both, and on `setup-node` v5 or later set
  `package-manager-cache: false` (that cache is on by default).
- The update changes `claude-code-review.yml`, the install skill and the default
  `toolchain/action.yml`, not `agent-coder.yml` or `agent-fixup.yml`, so no runner-ref
  fast-forward is needed.

## 0.3.2 (2026-11-12)

- The fixer can now fix a PR that touches protected paths. Before, `/agent-fix` told it never to
  touch them, while preflight and publish-fix let a fix through on a PR carrying the bot's
  `agent:allow-protected`, so on exactly those PRs the fixer blocked where it could have fixed.
  Preflight now opens protected paths in the task file (`Protected paths: OPEN.`, above the data)
  when publish-fix would accept them, and `/agent-fix` follows that line; `!` paths stay closed.
  The fixer reads `/agent-fix` from the PR's own branch, so this reaches agent PRs opened after the
  update merges; older ones keep blocking as before. A PR whose labels cannot be read now stops
  preflight (no attempt spent) instead of running with protected paths closed.
  The update changes `agent-fixup.sh` and `agent-fix.md`, not the workflows, so no runner-ref
  fast-forward is needed.

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
