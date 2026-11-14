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

| Where | What | Read from |
|---|---|---|
| Totals | repositories, items waiting for you, open agent PRs, queued issues, runs now, runs and cost over seven days | everything below, added up |
| Waiting for you | unticked inbox requests, stopped roles, blocked issues and PRs, `agent:candidate` issues, merged issues to close once live | the inbox issue's "Open requests" list, `state/breaker.json` on the ledger branch, labels; the same list the weekly digest posts |
| Repositories | version, `AGENTS_ENABLED`, `AGENT_AUTO_MERGE`, runs today against each role's `runsPerDay`, seven-day cost, breakers, health | `install.lock.json`, the repository's Actions variables, the ledger, the runner ref's copy of `agent-coder.yml` against the default branch's |
| A repository | its inbox requests in full, agent PRs with the merge gate's last word on each, running and recent runs, the queue by priority, in progress, blocked, candidates, on hold, ledger rows | the inbox issue's newest 1,000 comments (the agent bot's only), the job logs of the newest three `Agent merge` runs that ran (a PR's newest line wins, so a run dispatched for one PR does not hide the others), the running, queued and finished Actions runs of Gatehand's nine workflows |

Numbers are computed the way the agents compute them (`agent-digest.sh`, `agent-state.sh`): a ledger
line that does not parse costs that line only; a run with `counted: false` never reached the model
and is not a run for the daily cap. A part it cannot read is shown as `?` and listed under the
repository, never as zero, "off" or "nothing waits": "Waiting for you" says what it could not read,
as the digest does. Without the repository's variables (a login with less than write access) or its
`policy.json`, it does not guess which issue is the inbox.

The inbox requests in the detail view come from the agent bot's own request comments and can list a
request the "Open requests" checklist missed (that list is a best-effort summary; the comments are
the record).

## What you can do from it

Every button asks you to confirm, says what will happen, and then does it with your own `gh` login,
so the agents see exactly what they would see if you had done it on GitHub, and apply the same rules.

| Button | Where | What it does | Who it counts from |
|---|---|---|---|
| Approve (named for the request: "Requeue and rerun", "Reset the breaker", "Mark as seen"…), Reject… | each open inbox request | posts `/approve REQ-…` or `/reject REQ-… <reason>` on the inbox issue | `AGENT_OWNER_LOGIN` only |
| Rerun coder | blocked issues | posts `/rerun coder #N` | `AGENT_OWNER_LOGIN` only |
| Pause, Resume | each role under Breakers | posts `/pause <role>` or `/resume <role>` | `AGENT_OWNER_LOGIN` only |
| Unqueue | the queue | removes `agent:ready` from an issue | people with write access |
| Read and queue on GitHub | candidates | opens the issue; you add `agent:ready` there | people with write access |
| Hold, Release | issues and agent PRs | adds or removes `agent:hold` | people with write access |
| Hand back to the merge gate | agent PRs with `agent:blocked` or `agent:needs-human` | removes those labels, once you have fixed the PR yourself | people with write access |
| Turn agents on/off, Turn auto-merge on/off | Switches | sets `AGENTS_ENABLED` or `AGENT_AUTO_MERGE` to `true` or `false` | people who may set Actions variables |
| Start the coder on the next one | the queue | dispatches an auto-pick `agent-coder.yml` run on `policy.runnerRef` | people with write access |
| Approve…, Request changes… | agent PRs | posts a review comment the merge gate and the fixer read (below); Request changes can also start the fixer on it | people with write access, never the agent bot |
| Run review, Run merge gate | agent PRs | dispatches `claude-code-review.yml` or `agent-merge.yml` on the default branch, for that PR (or every agent PR) | people with write access |
| Cancel | Running now | cancels a run of one of Gatehand's nine workflows | people with write access |

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
non-archived ones whose default branch has `.github/agents/install.lock.json`. "Find repositories"
scans again. Add one by hand by `owner/name`; "Hide" keeps one out of later scans too. The list
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
