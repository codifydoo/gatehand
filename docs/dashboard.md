# The Gatehand dashboard

One local page for every repository where Gatehand is installed: what the agents are doing now,
what waits for you, and what they did this week; and buttons for the answers you would otherwise
type on GitHub.

```bash
python3 bin/dashboard.py
```

or `/gatehand:dashboard` in Claude Code. It needs `gh` signed in and Python 3.9 or later, nothing
else: no packages, no build, no server of ours. It opens your browser on `127.0.0.1`.

This file is not installed into your repositories; the dashboard runs on your machine, and what it
changes on GitHub is only what you could change by hand: a comment, a label, a workflow run, a
repository variable.

## What it shows

A sidebar leads to every view, with its count beside it: Needs you, Activity, Week, then one row per
repository. The view is in the address (`#/needs`, `#/activity`, `#/week`, `#/repos`,
`#/r/owner/name/pipeline|agents|runs|settings`), so a reload or a link lands on the same screen. The
number of things waiting for you is also in the tab's title.

| Where | What | Read from |
|---|---|---|
| Needs you | one row per thing you act on, newest first: open inbox requests, stopped roles, agent PRs held for a person, blocked issues with no open request; folded below them, agent PRs that passed the merge gate while auto-merge is a dry run ("to merge"), and merged issues to close once live ("to close") | the inbox issue's "Open requests" list and, when it lists any, the request comments themselves (only they say what kind a request is, and whether it was answered; when they cannot be read, or a line's comment is older than the newest 1,000, the kind is told from the line's text); `state/breaker.json` on the ledger branch; labels; and, for a repository in dry run with agent PRs, the merge gate's report |
| Activity | Gatehand's runs that are running or waiting to start, in every repository | the running and queued Actions runs of Gatehand's nine workflows |
| Week | each repository's runs over seven days per role: outcomes, runs today against `runsPerDay`, turns, time, cost | the ledger |
| Repositories | version, `AGENTS_ENABLED`, `AGENT_AUTO_MERGE`, runs today against each role's `runsPerDay`, seven-day cost, breakers, health | `install.lock.json`, the repository's Actions variables, the ledger, the runner ref's copy of `agent-coder.yml` against the default branch's |
| A repository, Pipeline | its inbox requests in full, agent PRs with the merge gate's last word on each, the queue by priority, in progress, blocked, candidates, on hold, merged to close | the inbox issue's newest 1,000 comments (the agent bot's only), the job logs of the newest three `Agent merge` runs that ran (a PR's newest line wins, so a run dispatched for one PR does not hide the others), labels |
| A repository, Agents | each role's breaker, runs running now | the ledger, Actions runs |
| A repository, Runs and spend | runs per role over seven days, ledger rows, recent finished runs | the ledger, Actions runs |
| A repository, Settings | the two switches, who may answer, the inbox, version, whether the runner ref matches the default branch | the repository's Actions variables, `install.lock.json`, `policy.json` |

Needs you counts the way it lists: a request about an agent PR (the fixer stopped, the merge gate
cannot update it, its review never posted) is that PR's row; a stopped role and its breaker request
are one row; a blocked issue with an open request is the request's row. The folded groups count. The
sidebar, the tab's title and "All" are the same number, and the chips above the list (Requests,
Stopped, PRs, Issues, To merge, To close) add up to it. Suggested (`agent:candidate`) issues are on
a repository's Pipeline tab, not here: queueing one is done on GitHub, next to its text.

A row marked NEW was not there the last time you looked at Needs you. That is remembered by this
browser for this address, so a dashboard started on another port (the default picks a free one)
marks everything NEW once; `--port` keeps it.

In the sidebar, the tab's title and the chips, a count that leaves out a part it could not read, or a
repository still loading, shows as "n+" (at least n), or "?" when nothing else is known. What could
not be read is listed under the rows, not counted.

Numbers are computed the way the agents compute them (`agent-digest.sh`, `agent-state.sh`): a ledger
line that does not parse costs that line only; a run with `counted: false` never reached the model
and is not a run for the daily cap. A part it cannot read is shown as `?` and listed under the
repository, never as zero, "off" or "nothing waits": Needs you says what it could not read,
as the digest does. Without the repository's variables (a login with less than write access) or its
`policy.json`, it does not guess which issue is the inbox.

The inbox requests on a repository's Pipeline come from the agent bot's own request comments and can list a
request the "Open requests" checklist missed (that list is a best-effort summary; the comments are
the record). Needs you takes its open requests from the checklist, so the same list counts for every
repository, open or not: a request the checklist missed is only on the Pipeline tab. A role whose
breaker was reset with `/resume` while its breaker request stays open still has a row, "breaker
request still open", until the request is answered.

### The item pane

A row opens beside the list, in the item pane; the address keeps it (`#/needs?open=…`), and with
none named the top row is opened and put in the address, so a newer row arriving does not take the
pane from you. A request's pane is the place to answer it:

- a header line (repository, request id, kind, role, age), the title, and for a request about an
  issue the stage it is stuck at;
- why it is stuck and what happens next, in the words of the request the agent filed;
- what the agent wrote, from its request comment, shown as plain text;
- where an answer must go first, as a link to GitHub: for `blocked`, a comment on the issue itself
  (the next run reads comments from people with write access, not the inbox); for `failed`, an edit
  if the issue was unclear; for `untrusted`, re-applying `agent:ready` yourself;
- the primary action (named for the kind, as in the table below) and Reject…, with the requesting
  role's runs on the issue and their cost over the last seven days beside them (runs that never
  reached the agent left out; the cost a floor: a run with no cost recorded adds nothing);
- the confirm, which opens under the button rather than in a dialog: who it acts as, the exact line
  posted on the inbox, what the Agent inbox workflow then does, and what to expect (its reply within
  a minute or two; for a requeue, that a run named for an issue skips the attempt cap, today's runs
  against the daily cap, and whether the agents are off);
- the last seven days of ledger rows about the issue and the request itself, as a timeline, and the
  issue's labels, the inbox and `AGENT_OWNER_LOGIN`, folded.

Where the confirm was, the pane says which of three states it is in: disabled, with the reason (the
same checks as below); refused, saying nothing was posted and why (the server's own reason, such as
the request being answered already); or waiting for the Agent inbox workflow, with the line posted
and a link to it, until its answer arrives. If the dashboard fails after it may have posted, or does
not answer, the pane says it is not known whether anything was posted. When the answer is in, the row leaves Needs you and the
pane says what happened. A request whose comment was not read (the inbox could not be read, or it is
older than the newest 1,000 comments) is not answered from the pane: it links to the inbox.

A stopped role's pane shows, where the stages would be, the role's newest ledger rows, as many as
its breaker counts in a row (or "Paused by the owner" for a role paused with `/pause`), then why it
stopped (the breaker's own reason) and what that holds up: that role's runs, and every agent PR's
merge, since the merge gate stops on any tripped breaker. Its one action: "Reset the breaker" posts
`/approve REQ-…` for its open breaker request, which resets it and ticks the request; with no request
(paused by hand) it reads "Resume" and posts `/resume <role>`, offered only for a role in
`policy.json`. Neither starts a run: the coder's next scheduled run picks from the queue, and the
fixer runs again the next time CI fails or a review asks for changes. A role whose breaker was reset
while its request stayed open has the same pane, to answer it.

An agent PR's pane says why it is held (the fixer's request, the merge gate unable to update it, a
review that never posted, or just the labels; a request's kind is used only once its comment is read),
the merge gate's last word on it, and what the agent wrote. A PR no longer among the open agent PRs
is said to be so, not guessed at. Its first step is a link to the PR on GitHub, to fix it yourself; then "Hand back to the merge
gate" takes `agent:blocked` and `agent:needs-human` off, one label at a time. Beside it: Mark request
as seen (`/approve REQ-…`), Hold or Release, Run review, Run merge gate, Approve… and Request
changes…. The last four confirm with the server's preview in the pane: what it will do, notes, the
exact GitHub calls and the comment; Request changes… takes its note first and previews it, and a note
changed after its preview is previewed again before anything is sent. A PR's runs and their cost over
the last seven days are beside the buttons; Claude review runs are not in the ledger. If labels are
taken off one by one and a later one is refused, the pane says which were done.

A blocked issue with no open request has a pane that says so (it was answered, or never filed), that
the coder picks only `agent:ready` issues, and offers "Rerun coder" (`/rerun coder #N`) with the issue's
coder runs and cost beside it, and Hold or Release; Rerun is disabled, with the reason, while the issue
has an open `untrusted` request, or carries `agent:hold` (a run named for a held issue does not take it).
If the issue also carries `agent:ready`, the pane says the coder may take it on its next scheduled run.
The server refuses a second command until the inbox workflow replies; after that, a rerun from a page
not yet refreshed would be posted again, since a rerun names no request.

The two folded groups open link-only panes, since the page merges nothing and closes nothing. "To
merge" says the gate found nothing in the way and auto-merge is a dry run, shows the gate's line, and
links to merge the PR on GitHub or to turn auto-merge on in Settings; Hold, Run review, Run merge gate
and Request changes… stay available, quieter. "To close" says a merge is not a deploy and links to
close the issue on GitHub once the fix is live.

### Limits and schedules

`/api/repo/<owner>/<name>` also carries the figures the page shows beside an action that spends
another run ("attempt 2 of 2", "next coder run 12:17"):

| Field | What | Read from |
|---|---|---|
| `policy.roles.<role>` | `runsPerDay`, `maxOpenPrs`, `maxReviewFixes`, `maxAttemptsPerIssue`, `maxCiFixes`, `breakerThreshold`, `timeoutMinutes` | `policy.json` on the default branch. A key the role does not set is `null`, never the default the scripts would use; with `policy.json` unreadable, `roles` is empty and `policy_ok` is `false` |
| `schedules.<coder\|merge\|sweep\|digest\|triage>` | `{"cron": [...], "next_run": "…Z"}`: the workflow's cron lines and the first minute after now that one of them matches, in UTC as GitHub runs cron. `null`: the workflow has no `schedule:`, or is not on the default branch (triage is optional). `"unknown"`: the file could not be read, or its `on:` is in a shape the reader does not follow; listed under the repository's errors | the `schedule:` lines of `agent-coder.yml`, `agent-merge.yml`, `agent-sweep.yml`, `agent-digest.yml` and `agent-triage.yml` on the default branch, not `policy.json`'s `schedules` (those take effect only once the workflows are re-rendered) |

`next_run` is when the schedule falls due after `fetched_at` (the payload is cached for a minute, so
it can already have passed: that is "due now"); GitHub often starts a scheduled run some minutes
late, and skips it while the workflow is disabled. It is `null`, and listed under the errors, for a cron the
server cannot read (only `*`, numbers, `-`, `,` and `/`, the operators GitHub documents) or one
that matches no day in nine years.

## What you can do from it

Every button asks you to confirm, says what will happen, and then does it with your own `gh` login,
so the agents see exactly what they would see if you had done it on GitHub, and apply the same rules.

| Button | Where | What it does | Who it counts from |
|---|---|---|---|
| Approve (named for the request: "Requeue and rerun", "Reset the breaker", "Mark as seen"…), Reject… | each open inbox request on the Pipeline tab, and the item pane of its row in Needs you (a request about a PR is in the PR's pane, a breaker request in the role's) | posts `/approve REQ-…` or `/reject REQ-… <reason>` on the inbox issue | `AGENT_OWNER_LOGIN` only |
| Rerun coder | blocked issues, on the Pipeline tab and in the issue's pane | posts `/rerun coder #N` | `AGENT_OWNER_LOGIN` only |
| Pause, Resume | each role, on a repository's Agents tab; Resume also in a stopped role's pane | posts `/pause <role>` or `/resume <role>` | `AGENT_OWNER_LOGIN` only |
| Unqueue | the queue | removes `agent:ready` from an issue | people with write access |
| Read and queue on GitHub | candidates | opens the issue; you add `agent:ready` there | people with write access |
| Hold, Release | issues and agent PRs, on the Pipeline tab and in their panes | adds or removes `agent:hold` | people with write access |
| Hand back to the merge gate | agent PRs with `agent:blocked` or `agent:needs-human`, on the Pipeline tab and in the PR's pane | removes those labels, once you have fixed the PR yourself | people with write access |
| Turn agents on/off, Turn auto-merge on/off | a repository's Settings tab | sets `AGENTS_ENABLED` or `AGENT_AUTO_MERGE` to `true` or `false` | people who may set Actions variables |
| Start the coder on the next one | the queue | dispatches an auto-pick `agent-coder.yml` run on `policy.runnerRef` | people with write access |
| Approve…, Request changes… | agent PRs | posts a review comment the merge gate and the fixer read (below); Request changes can also start the fixer on it | people with write access, never the agent bot |
| Run review, Run merge gate | agent PRs | dispatches `claude-code-review.yml` or `agent-merge.yml` on the default branch, for that PR (or every agent PR) | people with write access |
| Cancel | Activity, and a repository's Agents tab | cancels a run of one of Gatehand's nine workflows | people with write access |

A button the agents would ignore from you is shown disabled with the reason. After an inbox command
the page re-reads the inbox every ten seconds for two minutes until the agent's answer appears; the
`Agent inbox` workflow does the actual work, exactly as for a typed comment. Until it has answered,
the page sends no other command (the workflow has no concurrency group, so two runs at once would
both apply: an Approve sent twice, or an Approve and a Reject); a command that gets no answer for ten
minutes stops blocking.

The page never adds `agent:ready`. That label vouches for the issue's text as it stands (the agents
trust everything written before a writer applied it, model-written follow-ups and triage imports
included), and the page does not show that text, so queueing stays on GitHub next to it. For the
same reason "Rerun coder" is disabled on an issue with an open `untrusted` request: someone without
write access changed its text, and a rerun alone would be refused again.

Before posting, the server checks what the inbox workflow will check, and refuses with a reason
rather than post something that would be ignored: you are `AGENT_OWNER_LOGIN` to the letter; the
inbox issue is open, carries `<!-- agent-inbox -->` and was opened by the agent bot or the owner; the
request is one the agent bot filed and nobody has answered yet; no command of yours is still waiting
for its answer; a role is one in `policy.json`. Labels are never changed on the inbox issue itself. The
command line it posts is built by the server in exactly the grammar `agent-inbox.sh` parses; a reject
reason is cut to one line of 300 characters. `agent:allow-protected` is never offered: opening
protected paths stays behind approving the agent's own `protected` request.

### Runs, verdicts and switches: preview, then confirm

These change what the agents do next, so the server first shows exactly what it will do: each
GitHub call with its body, the comment it would post, what to expect, and anything in the way (a
coder run already running, or waiting: GitHub keeps one waiting run per concurrency group and
cancels the older one for the newer). Confirming sends a one-time token, valid five minutes. The
server plans the action again from fresh state and does it only if the plan is the one you saw: a PR
whose head moved, a variable someone changed or a coder run that started waiting in between all
refuse, and you preview again.

It refuses early what the workflow would skip or refuse: a coder or fixer run while `AGENTS_ENABLED`
is not `true` or while the runner ref's copy of the workflow is not main's; the fixer on a PR its
`pr_refusal` turns down (not the bot's, a draft, a fork, another base, not an agent branch, held,
blocked or already fixing) or past its review-fix cap, where it would block the PR instead; the
fixer while its breaker is tripped or today's runs are used up; a runner ref that is the default
branch; a review
of a fork's PR. Dispatch inputs are the workflows' own, in the shapes their scripts check.

The coder is only ever started as an auto pick, with every check of a scheduled run. A run named for
one issue is the owner's choice and skips them, the check that a writer applied `agent:ready`
included, so it stays on GitHub, next to the issue's text, like queueing.

A verdict is a comment, the way a person's review counts for the merge gate and the fixer. GitHub's
Approve button is no verdict for them; a writer's GitHub "Request changes" review does stop the merge
until that person approves or it is dismissed, and an Approve from the page does not clear it.

```text
<!-- verify-pr-review -->
Review by <you>, from the Gatehand dashboard, of head `<sha>`.

### What to change

<your note, Request changes only>

### Verdict

Approve | Request changes
```

Approve takes no note. A Request changes note is plain text, at most 2,000 characters, with no `<`
and no code fence, so nothing in it can hide or swallow the verdict line under it; a note may write
its own "Verdict" heading, and the last one, the page's, still wins. The merge gate counts the
verdict only while it is the newest review and newer than the head: a push after it makes it stale.
The verdict is for the head the preview names (the confirm refuses if it moved); read that head on
GitHub first. Approve is refused while the fixer works on the PR, since its push would come after.
A person's comment starts the fixer only when the fixer routes reviews, after the next Claude review
run in the repository; "Start the fixer on it" dispatches `agent-fixup.yml` with
`source=comment-<id>` of the comment just posted, at once. Either way the fixer checks it is still
the newest review of the head, and counts it against its review-fix cap.

Cancelling a coder or fixer run: its last job still runs, releases the issue or unlocks the PR, and
records the attempt; the fixer does not retry a run a person cancelled. If that job cannot run, the
hourly sweep does the same once the lock expires. A cancel after the agent's own job has finished
does not stop publishing: the PR still opens, or the fix is still pushed (and a fix that pushed
nothing may be retried).

## Repositories

On first start it lists every repository your login can see, through GraphQL, and keeps the
non-archived ones whose default branch has `.github/agents/install.lock.json`. "Find repositories",
under Repositories, scans again. Add one by hand by `owner/name` there; "Hide" (there, or on a
repository's Settings tab) keeps one out of later scans too. The list
lives in `${XDG_CONFIG_HOME:-~/.config}/gatehand/dashboard.json` (mode 0600; `--config` to move it).
A scan that cannot see everything (an organisation that requires SAML authorisation for your token,
more than 3,000 repositories) keeps what it found and says what it missed.

Each repository costs about seven API calls per refresh, cached for a minute; the page refreshes
every five minutes while it is visible, and on "Refresh". The server stops after `--idle-minutes`
with no page open; a page in a background tab counts as open.

## Security model

The server can read everything your `gh` login can, so the page is built so that nothing but the
tab it opened can talk to it.

- It listens on `127.0.0.1` only.
- Every `/api/` request needs the per-launch secret. The secret travels in the address's fragment
  (never sent to any server, not in logs or `Referer`); the page moves it to the tab's
  `sessionStorage`, removes it from the address bar, and sends it as `X-Gatehand-Token`. It is printed
  only with `--print-url` (or `--no-open`). The browser is not started with the address on its
  command line, which every local user can read: it opens a private file (mode 0600, in a 0700
  directory, deleted after two minutes) that redirects to it. `--ready-file` always writes a new
  0600 file.
- The `Host` header must be `127.0.0.1:<port>` or `localhost:<port>`, so a site that rebinds its
  DNS name to 127.0.0.1 gets nothing.
- A POST must come from the page's own origin and be `application/json`, so another site's form or
  script cannot send one (it cannot pass the preflight either: the server answers none).
- Repository paths must match `owner/name` and be on the list; the page's three files are the only
  files served.
- Issue titles, request bodies and run names are text the agents and other people wrote. The page
  sets them only as text, never as HTML, links only to `https://github.com/`, and runs under
  `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'`.
- The token never enters the dashboard's process: every call is a `gh` subprocess with an argument
  list. Issue bodies stay on the server; only what the page shows is sent to it.
- It writes to GitHub only through the actions above: a comment on the inbox issue, one of five
  label changes, a dispatch of four workflows, a cancel of a Gatehand run, a verdict comment on an
  agent PR, two variables set to `true` or `false`. Each is a fixed shape the server builds; no
  request from the page is passed through. Reading writes nothing. `tests/dashboard/dashboard.test.sh`
  pins each point above, runs every command the page can post through the real `parse_commands`, and
  every verdict through the real `review_verdict`.

## Options

| Option | |
|---|---|
| `--port N` | listen on this port (default: a free one) |
| `--no-open` | do not open a browser; print the address instead |
| `--print-url` | print the address with its secret |
| `--idle-minutes M` | stop after M minutes with no page open (default 120; 0 never) |
| `--config FILE` | keep the repository list here |
| `--ready-file FILE` | write `{port, token}` there (mode 0600) once listening, for scripts |
