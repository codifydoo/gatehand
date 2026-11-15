# The Gatehand dashboard

One local page for every repository where Gatehand is installed: what waits for you, what the
agents are doing now, and what they did this week; and buttons for the answers you would otherwise
type on GitHub.

```bash
python3 bin/dashboard.py
```

or `/gatehand:dashboard` in Claude Code. It needs `gh` signed in and Python 3.9 or later, nothing
else: no packages, no build, no server of ours. It opens your browser on `127.0.0.1`.

This file is not installed into your repositories; the dashboard runs on your machine, and what it
changes on GitHub is only what you could change by hand: a comment, a label, a workflow run, a
repository variable.

## The page

The bar at the top holds Pause all… (below), when the page last read, the API calls left this hour
(`API n/m`), Refresh, and the login it acts as. Under the bar, when they apply, are the two notices
that concern every repository (`gh` signed out, the API limit; see Health) and the Pause all line.

The sidebar leads to every view, with its figure beside it: Needs you (how many things wait for
you), Activity (how many runs are going), Week (the seven-day cost, amber over the budget's warning
line), then Repositories and one row per repository, with what waits for you there ("stopped" when
one of its roles is), and Find · add. Needs you and a repository show no badge when nothing waits
(Activity then says "none running"); with no repositories at all, Needs you, Activity and Week are
greyed. In a window narrower than about 760 px the sidebar folds
into one line naming where you are, and ☰ opens it.

The view is in the address (`#/needs`, `#/activity`, `#/week`, `#/repos`,
`#/r/owner/name/pipeline|agents|runs|settings`; on Needs you also the chip and the open item, as
`#/needs?kind=…&open=…`), so a reload or a link lands on the same screen. The page opens on Needs you, and the number of things waiting for
you is also in the tab's title.

| Where | What | Read from |
|---|---|---|
| Needs you | one row per thing you act on, newest first: open inbox requests, stopped roles, agent PRs held for a person, blocked issues with no open request; folded below them, agent PRs that passed the merge gate while auto-merge is a dry run ("to merge"), and merged issues to close once live ("to close"); at the end, what could not be read | the inbox issue's "Open requests" list and, when it lists any, the request comments themselves (only they say what kind a request is, and whether it was answered; when they cannot be read, or a line's comment is older than the newest 1,000, the kind is told from the line's text); `state/breaker.json` on the ledger branch; labels; and, for a repository in dry run with agent PRs, the merge gate's report |
| Activity | in every repository: running now, each with Cancel; not moving and not waiting on you, one row per cause per repository with when it moves; finished today | the running and queued Actions runs of Gatehand's nine workflows; `AGENTS_ENABLED`; `state/breaker.json`, the ledger and `policy.json`'s `runsPerDay` and `maxOpenPrs`; labels |
| Week | the last seven days (today partial): the cost, as a floor, against your weekly budget with a warning line; cost by day against the budget's daily pace; runs, cost and runs with no cost by repository; runs, outcomes, turns, time and cost by role; PRs the merge gate merged and coder runs that opened a PR | the ledger, the budget in the config file |
| Repositories | per repository: version, `AGENTS_ENABLED`, `AGENT_AUTO_MERGE`, what waits for you, open agent PRs, the queue, runs going, the coder's and the fixer's runs today against `runsPerDay`, seven-day cost, breakers, health, and Hide | `install.lock.json`, the repository's Actions variables, labels, Actions runs, the ledger, `policy.json`, the runner ref's copy of `agent-coder.yml` against the default branch's |
| A repository, Pipeline | its inbox requests in full, agent PRs with the merge gate's last word on each, the queue by priority (with when the coder runs next and its runs today), in progress, blocked, candidates, on hold, merged to close | the inbox issue's newest 1,000 comments (the agent bot's only), the job logs of the newest three `Agent merge` runs that ran (a PR's newest line wins, so a run dispatched for one PR does not hide the others), labels |
| A repository, Agents | each role: stopped or paused and since when, running or idle, runs today against `runsPerDay`, failures in a row against `breakerThreshold`, open agent PRs against `maxOpenPrs`, and when it runs next; each scheduled workflow with its cron (UTC), its last finished run and its next run; runs running now; each role's limits | the ledger, `state/breaker.json`, Actions runs, `policy.json`, the workflow files' `schedule:` (see Limits and schedules) |
| A repository, Runs and spend | seven days of cost (a floor) and runs per role, the ledger rows with each one's issue or PR and its run, recent finished Actions runs | the ledger, Actions runs |
| A repository, Settings | the two switches with what each does now, who may answer, the inbox, version, whether the runner ref matches the default branch, where the limits are set, and Hide | the repository's Actions variables, `install.lock.json`, `policy.json` |

Numbers are computed the way the agents compute them (`agent-digest.sh`, `agent-state.sh`): a ledger
line that does not parse costs that line only; a run with `counted: false` never reached the model
and is not a run for the daily cap. Without the repository's variables (a login with less than write
access) or its `policy.json`, the page does not guess which issue is the inbox.

Data arrives in parts, a repository at a time, and rows fill in place. A part that could not be read
is never shown as zero, "off" or "nothing waits": it is `?`, and named under the repository. In the
sidebar, the tab's title and the chips, a count that leaves out a part it could not read, or a
repository still loading, shows as "n+" (at least n), or "?" when nothing else is known.

## Needs you

Needs you counts the way it lists: a request about an agent PR (the fixer stopped, the merge gate
cannot update it, its review never posted) is that PR's row; a stopped role and its breaker request
are one row; a blocked issue with an open request is the request's row. The folded groups count;
what could not be read does not. The sidebar, the tab's title and "All" are the same number, and the
chips above the list (Requests, Stopped, PRs, Issues, To merge, To close) add up to it. Suggested
(`agent:candidate`) issues are on a repository's Pipeline tab, not here: queueing one is done on
GitHub, next to its text.

Needs you takes its open requests from the inbox's "Open requests" checklist, so the same list
counts for every repository. A repository's Pipeline lists requests from the agent bot's own request
comments, and can show one the checklist missed (that list is a best-effort summary; the comments
are the record); such a request is only on the Pipeline tab. A role whose breaker was reset with
`/resume` while its breaker request stays open still has a row, "breaker request still open", until
the request is answered.

A row marked NEW was not there the last time you looked at Needs you. That is remembered by this
browser for this address, so a dashboard started on another port (the default picks a free one)
marks everything NEW once; `--port` keeps it.

A repository still being read has a "reading…" line under the rows until it answers; rows that
arrive are placed by time (the folded groups stay last), so a newer one can appear above those
already shown. With nothing in it, Needs you says what is true and the one useful next step where
the item would be: "Nothing needs you", with the runs going and issues queued and a link to
Activity; "Nothing that could be read needs you" while a repository is unread, naming each and
linking to the first (never an all clear); or, with no repositories, that none were found (or that
finding them failed, and how many are hidden), the scan's notes, and where to find or add one.

### The item pane

A row opens beside the list, in the item pane; the address keeps it, and with none named the top
row is opened and put in the address, so a newer row arriving does not take the pane from you. In a
window narrower than about 1000 px the item opens in place, under its row, and that row is scrolled
to the top; tapping it again closes the item.

A pane's actions confirm under their button, not in a dialog. Where the confirm was, the pane says which of three states it is in: disabled,
with the reason (the same checks as under What you can do from it); refused, saying nothing was
posted and why (the server's own reason, such as the request being answered already); or waiting
for the Agent inbox workflow, with the line posted and a link to it, until its answer arrives. If
the dashboard fails after it may have posted, or does not answer, the pane says it is not known
whether anything was posted. When the answer is in, the row leaves Needs you and the pane says what
happened.

**A request.** Its pane is the place to answer it:

- a header line (repository, request id, kind, role, age), the title, and for a request about an
  issue the stage it is stuck at;
- why it is stuck and what happens next, in the words of the request the agent filed;
- what the agent wrote, from its request comment, shown as plain text;
- where an answer must go first, as a link to GitHub: for `blocked`, a comment on the issue itself
  (the next run reads comments from people with write access, not the inbox); for `failed`, an edit
  if the issue was unclear; for `untrusted`, re-applying `agent:ready` yourself. Under it, for an
  open `blocked` or `failed` request, whether someone with write access has commented on the issue
  since the request, and who and when (never what they wrote); nothing until that is first read, or
  when it cannot be told;
- the primary action (named for the kind, as in the table under What you can do from it) and
  Reject…, with the requesting role's runs on the issue and their cost over the last seven days
  beside them (runs that never reached the agent left out; the cost a floor: a run with no cost
  recorded adds nothing);
- the confirm: who it acts as, the exact line posted on the inbox, what the Agent inbox workflow
  then does, and what to expect (its reply within a minute or two; for a requeue, that a run named
  for an issue skips the attempt cap, today's runs against the daily cap, and whether the agents are
  off);
- the last seven days of ledger rows about the issue and the request itself, as a timeline, and the
  issue's labels, the inbox and `AGENT_OWNER_LOGIN`, folded.

A request whose comment was not read (the inbox could not be read, or it is older than the newest
1,000 comments) is not answered from the pane: it links to the inbox.

**A stopped role.** Where the stages would be, the role's newest ledger rows, as many as its breaker
counts in a row (or "Paused by the owner" for a role paused with `/pause`), then why it stopped (the
breaker's own reason) and what that holds up: that role's runs, and every agent PR's merge, since
the merge gate stops on any tripped breaker. Its one action: "Reset the breaker" posts
`/approve REQ-…` for its open breaker request, which resets it and ticks the request; with no request
(paused by hand) it reads "Resume" and posts `/resume <role>`, offered only for a role in
`policy.json`. Neither starts a run: the coder's next scheduled run picks from the queue, and the
fixer runs again the next time CI fails or a review asks for changes. A role whose breaker was reset
while its request stayed open has the same pane, to answer it.

**An agent PR held for a person.** Why it is held (the fixer's request, the merge gate unable to
update it, a review that never posted, or just the labels; a request's kind is used only once its
comment is read), the merge gate's last word on it, and what the agent wrote. A PR no longer among
the open agent PRs is said to be so, not guessed at. Its first step is a link to the PR on GitHub,
to fix it yourself; then "Hand back to the merge gate" takes `agent:blocked` and `agent:needs-human`
off, one label at a time (if a later one is refused, the pane says which were done). Beside it:
Mark request as seen (`/approve REQ-…`), Hold or Release, Run review, Run merge gate, Approve… and
Request changes…. The last four confirm with the server's preview in the pane: what it will do,
notes, the exact GitHub calls and the comment; Request changes… takes its note first and previews
it, and a note changed after its preview is previewed again before anything is sent. A PR's runs
and their cost over the last seven days are beside the buttons; Claude review runs are not in the
ledger.

**A blocked issue with no open request.** The pane says so (it was answered, or never filed), that
the coder picks only `agent:ready` issues, and offers "Rerun coder" (`/rerun coder #N`) with the
issue's coder runs and cost beside it, and Hold or Release. Rerun is disabled, with the reason,
while the issue has an open `untrusted` request, or carries `agent:hold` (a run named for a held
issue does not take it). If the issue also carries `agent:ready` and not `agent:hold`, the pane says
the coder may take it on its next scheduled run. The server refuses a second command until the inbox
workflow replies; after that, a rerun from a page not yet refreshed would be posted again, since a
rerun names no request.

**To merge, to close.** The two folded groups open link-only panes, since the page merges nothing
and closes nothing. "To merge" says the gate found nothing in the way and auto-merge is a dry run,
shows the gate's line, and links to merge the PR on GitHub or to turn auto-merge on in Settings;
Hold, Run review, Run merge gate and Request changes… stay available, quieter. "To close" says a
merge is not a deploy and links to close the issue on GitHub once the fix is live.

### Health: what could not be read

A repository that could not be read, wholly or in part, has a health row at the end of Needs you. It
is never counted, and it is never the item opened on arrival. Its pane gives the cause (see Why a
read failed) and what `gh` said, as text, and the one thing that helps, which is always outside the
page:

- **SSO not authorized:** run `gh auth refresh -h github.com` (a Copy button puts that fixed text on
  the clipboard) and follow the browser prompt, or use the organization's sign-in page on GitHub;
- **not found:** find the new name or get access back on GitHub;
- **too little access:** ask for access; without the variables, which issue is the inbox cannot be told;
- **anything else:** usually passes.

A repository that cannot be read at all can also be hidden from its pane (the existing local setting).
Where parts fail for different reasons, the pane leads with the cause whose fix is most specific (SSO,
then access, then not found).

"Check again" reads that repository only, past the cache, with its inbox and the merge gate's report,
and says whether it is still unread (and why) or readable again. It writes nothing. Two causes hit
every repository and are said once, under the bar, instead of in rows: `gh` signed out (with the
command to copy and Check again), and the API limit, with when reads resume; Refresh, the
five-minute refresh, whether a writer has commented on a request's issue, and Pause all, Resume n…
and Retry n… (which read every repository first) are off until then.

### Keys

Keys on Needs you: `j` and `k` move to the next or previous item as listed; `o` goes into the open
item (or opens one); `a` opens the item's primary action's confirm, and Enter (or Space) then
confirms, so the primary action is two keys as it is two clicks (on a to-merge or to-close item, `a`
opens the GitHub link instead; on a health item it runs Check again, a read); `r` opens Reject…; Esc
closes a confirm; `?` lists them. Keys do nothing while you type in a field (except Esc) or with a
modifier held, and there is no key that posts without its confirm.

## Activity

Activity's middle list holds what keeps the agents still without asking anyone, one row per cause
per repository: agents off (`AGENTS_ENABLED` is not `true`; the other causes wait behind it, so it is
that repository's only row), a role stopped by its breaker, a role at its daily limit (runs today
against `runsPerDay`), the coder at its open-PR limit (open `agent:pr` PRs against `maxOpenPrs`), and
an issue in `agent:in-progress` or a PR in `agent:fixing` with no run holding it (no coder run in
progress; for a PR, no dispatched fixer run) and no `agent:hold` (a lock the hourly sweep frees once
it expires). Without `policy.json` the limits are not known, and that is said. A stale runner ref is
not listed here; Repositories shows it under health.

Each row says when it moves only where the page's data can say: a daily limit lifts at 00:00 UTC, as
the coder's gate counts days; a lock's expiry time is not read, and a role's next scheduled run is
not used there (a run that starts while the role is stopped or at a limit does nothing), so nothing
is shown for them. A stopped role is also a row of Needs you, where it is reset.

"Finished today" is the ledger's rows that ended today, by this browser's clock: agent runs, a merge
by the merge gate, and a stale lock the sweep closed. The Claude review, and merge gate or sweep runs
that merge or close nothing, write no ledger row and are not in it. Each list counts as the sidebar
does: "n+" while a repository loads or a part of it could not be read, with that part named under
the list.

With nothing running, Activity says so and, under it, the next scheduled runs: for each scheduled
workflow, the soonest next run across the repositories, in this browser's time, and how many
repositories run then ("Next: merge gate 18:11 in 3 repositories, coder 18:17 in 2"); a time six
or more days out carries its date, and one already past is "due now". They come from `schedules`
(see Limits and schedules). A repository with no such schedule (`null`), or archived, adds nothing;
one whose agents are off adds only the digest, which the switch does not stop. A workflow is left
out of the line when any repository's time for it is not known (`"unknown"`, a `next_run` of
`null`, variables it cannot read for a workflow the switch stops, a repository it cannot read),
since its soonest time and count would be a guess. The line shows only with "Nothing is running.",
so not while a repository loads or when one's runs cannot be read. A scheduled run still starts when
its role is stopped or at a limit; "Not moving" says why it will do nothing.

## Week

Week shows the last seven days against a weekly budget in US dollars, with a warning line as a share
of it (80% unless you set another). The budget is a personal setting on the machine the dashboard
runs on, kept in the dashboard's config file (`budget_usd`, `budget_warn`): nothing is written to
GitHub, `policy.json` does not hold it, and no agent reads it. It is for warning only and stops
nothing; to stop the agents, turn them off. Week sets, changes and clears it ("Set a budget…", then
"Edit budget…"), and shows the seven-day cost against it: a bar with the warning line, the share
spent, and, over the budget, the repository that spent most. Over the warning line the sidebar's
Week figure turns amber. With no budget it shows the cost and no bar. With no runs it says so, with
the budget and the last run it knows of; a ledger that could not be read is named, and the total is
"?".

That cost is a floor, never a total: a ledger row with no `cost_usd` adds nothing and is counted and
listed beside it, Claude review runs are not in the ledger, and a repository that cannot be read is
named and adds nothing, never $0. The merge gate's rows are merges, not model runs, and count only
in "PRs merged by the gate"; a PR merged by hand leaves no row. Week counts seven calendar days on
your computer's clock, today the last; the cost columns on Repositories and Runs and spend count
the server's last 168 hours, so they can differ from it by part of a day.

## A repository's tabs

Lists route; they do not act. Whatever on a tab has a row in Needs you (an open request, a stopped
role, a held agent PR, a blocked issue, an agent PR to merge, an issue to close) links to that row's
item ("Open item →"), and is acted on there. What has no row is acted on in place, with the same
confirm as an item pane, opening under its button: Pause for a role that runs, the two switches,
Unqueue and Hold on a queued issue, Release on a held one, Start on the next one (the coder) and Run
merge gate… (every agent PR) on the Agents tab's schedules, Cancel… on a running run, the quieter
actions on an agent PR nobody holds, and a request with no row: one the inbox's checklist missed, or
an older breaker request of a role that has a newer one.

The Agents tab says when a role runs next by the run gate's rules, in its order: not while the
agents are off, not while the runner branch's `agent-coder.yml` differs from the default branch's
(the coder), not until its breaker is reset, not today once its runs are used up, not while the open
agent PRs are at the coder's `maxOpenPrs`; else the coder's next scheduled run. If a part one of
these rules needs could not be read (`policy.json` included), or `runnerRef` is the default branch
itself (the gate refuses that), it says nothing. It does not read `AGENT_BOT_ID` or the fixer's own
workflow on the runner branch, so for the fixer it gives only reasons it will not run, never a time.
A figure is "n of m" only where `policy.json` sets m, and a next run is shown only where the server
read one: where either is null or unknown the page shows nothing in its place, never a default.
Times are on this machine's clock; crons are as written, in UTC. A run row that never reached the
model is marked "not counted".

With the agents off, the Pipeline says so above its rows (which stay): what skips its runs, how many
queued issues (not held) and open PRs wait (each only if it was read and not zero), that inbox
answers still work, and a link to the switch in Settings; each queued issue reads "Waiting on:
agents off". With nothing queued, it says the page never queues work and links to the suggested
(`agent:candidate`) issues on GitHub when there are any.

## Repositories

On first start it lists every repository your login can see, through GraphQL, and keeps the
non-archived ones whose default branch has `.github/agents/install.lock.json`. "Find repositories",
under Repositories, scans again. Add one by hand by `owner/name` there; "Hide" (there, or on a
repository's Settings tab) keeps one out of later scans too. The list lives in
`${XDG_CONFIG_HOME:-~/.config}/gatehand/dashboard.json` (mode 0600; `--config` to move it), with the
Pause all record and the weekly budget. None of it is ever sent to GitHub. A scan that cannot see
everything (an organisation that requires SAML authorisation for your token, more than 3,000
repositories) keeps what it found and says what it missed.

Each repository costs about seven API calls per refresh, cached for a minute; the page refreshes
every five minutes while it is visible, and on "Refresh". The server stops after `--idle-minutes`
with no page open; a page in a background tab counts as open.

## What you can do from it

Every button asks you to confirm and says what will happen: in an item pane or on a repository's
tabs, under the button; for Pause all, under the bar; on Activity, in a dialog. Then it does it with
your own `gh` login, so the agents see exactly what they would see if you had done it on GitHub, and
apply the same rules.

| Button | Where | What it does | Who it counts from |
|---|---|---|---|
| Approve (named for the request: "Requeue and rerun", "Reset the breaker", "Mark as seen"…), Reject… | the item pane of its row in Needs you (a request about a PR is in the PR's pane, a breaker request in the role's); on the Pipeline tab, only a request with no row | posts `/approve REQ-…` or `/reject REQ-… <reason>` on the inbox issue | `AGENT_OWNER_LOGIN` only |
| Rerun coder | a blocked issue's pane | posts `/rerun coder #N` | `AGENT_OWNER_LOGIN` only |
| Pause, Resume | Pause: a role that runs, on a repository's Agents tab; Resume: a stopped role's pane | posts `/pause <role>` or `/resume <role>` | `AGENT_OWNER_LOGIN` only |
| Unqueue | the queue, on the Pipeline tab | removes `agent:ready` from an issue | people with write access |
| Read and queue on GitHub | candidates | opens the issue; you add `agent:ready` there | people with write access |
| Hold, Release | issues and agent PRs in their panes; on the Pipeline tab, queued and held issues and agent PRs with no row in Needs you | adds or removes `agent:hold` | people with write access |
| Hand back to the merge gate | the pane of an agent PR with `agent:blocked` or `agent:needs-human` | removes those labels, once you have fixed the PR yourself | people with write access |
| Turn agents on/off, Turn auto-merge on/off | a repository's Settings tab | sets `AGENTS_ENABLED` or `AGENT_AUTO_MERGE` to `true` or `false` | people who may set Actions variables |
| Pause all…, Resume n… | the bar | sets `AGENTS_ENABLED` to `false` in every repository where it is `true`, or back to `true` in those Pause all turned off (see Pause all) | people who may set Actions variables, per repository |
| Start the coder on the next one | the coder's schedule, on a repository's Agents tab | dispatches an auto-pick `agent-coder.yml` run on `policy.runnerRef` | people with write access |
| Approve…, Request changes… | an agent PR's pane, or on the Pipeline tab for one with no row in Needs you | posts a review comment the merge gate and the fixer read (see Verdicts); Request changes can also start the fixer on it | people with write access, never the agent bot |
| Run review, Run merge gate | an agent PR's pane, or on the Pipeline tab for one with no row; Run merge gate for every agent PR on the Agents tab | dispatches `claude-code-review.yml` or `agent-merge.yml` on the default branch, for that PR (or every agent PR) | people with write access |
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
branch; a review of a fork's PR. Dispatch inputs are the workflows' own, in the shapes their scripts
check.

The coder is only ever started as an auto pick, with every check of a scheduled run. A run named for
one issue is the owner's choice and skips them, the check that a writer applied `agent:ready`
included, so it stays on GitHub, next to the issue's text, like queueing.

Cancelling a coder or fixer run: its last job still runs, releases the issue or unlocks the PR, and
records the attempt; the fixer does not retry a run a person cancelled. If that job cannot run, the
hourly sweep does the same once the lock expires. A cancel after the agent's own job has finished
does not stop publishing: the PR still opens, or the fix is still pushed (and a fix that pushed
nothing may be retried).

### Verdicts

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

### Pause all

"Pause all…" in the bar is the "Turn agents off" switch once per repository. The page asks the
server for one preview per repository where `AGENTS_ENABLED` is `true`, and shows them in one
confirm that lists every repository: the change, or why it is skipped (already off, cannot be read,
refused at the preview), and what is running there now. Confirming sends each repository's own
one-time token, one at a time; each is planned again and refused on its own, so the result is per
repository. It adds no kind of write to GitHub. The preview and the confirm carry one more field,
`pause_all`, which is `true` or `false` and nothing else; it is part of the plan the token stands
for, and it is accepted only for setting `AGENTS_ENABLED` to `false` where it is `true` now.

What is new is a record on this machine: once a repository's own write succeeds, the server adds it
to `paused` in the dashboard's config file (the one that holds the repository list), and
`/api/session` returns that list. While any repository on it is off, the line under the bar says
"Agents off in n of m" on every screen, names the repositories that could not be read or were
refused, and offers "Resume n…": the same confirm in reverse, for only the repositories on the list
that are still off. A repository that was already off before Pause all (unset counts as off), or was
turned off in its own Settings, stays off. A repository leaves the list when the page turns its
agents on, Resume or the switch alike, and when a read that began after the pause finds
`AGENTS_ENABLED` is `true` (someone turned it on elsewhere); that is the one local write a read can
make, and it only ever takes a repository off. A repository whose variables cannot be read is
skipped and named, never counted as paused or as on.

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
  request from the page is passed through. Reading writes nothing to GitHub. `tests/dashboard/dashboard.test.sh`
  pins each point above, runs every command the page can post through the real `parse_commands`, and
  every verdict through the real `review_verdict`.
- Besides GitHub and the files above, it writes only its own config file: the repository list, the
  Pause all record and the weekly budget, each a fixed shape the server validates, kept with mode
  0600.

## What the server sends

For scripts and tests; the page uses the same fields.

### Why a read failed

Each failed read also says why, as one cause from a fixed set, so the page can offer the one thing
that helps instead of Refresh. The server sends it:

- per repository, in `unreadable`: one entry per part whose `gh` read failed (`repository`,
  `policy.json`, `install.lock.json`, `ledger`, `ledger runs`, `ledger breaker.json`, `variables`,
  `issues`, `runs`), as `{"part", "cause", "error"}`, where `error` is the same text as that part's
  line in `errors`. A line in `errors` that is not a failed read (a file that does not parse,
  Gatehand not installed, no inbox issue, more than 500 open issues) has no entry;
- on a request that failed as a whole (the repository, its inbox, the merge gate's report, the
  session), in the 502 answer beside `error`; and a first scan that failed, as `scan_cause` beside
  `scan_error`;
- for a scan that could not see everything, in `scan_unreadable` beside `scan_notes` (the session
  and the answer to "Find repositories"): one `{"cause", "error"}` per note that is a failed read
  (an organisation's SAML enforcement hiding its repositories, say), where `error` is the note. The
  notes "stopped after 3000 repositories" and "kept N repositories found by an earlier scan" have
  none. They are kept with the list in `dashboard.json` until the next scan, so a `resets_at` there
  may be in the past.

| `cause` | Means | Matched on what `gh` prints |
|---|---|---|
| `signed_out` | `gh` has no login, or its token was revoked or expired | exit code 4, `gh auth login`, or `HTTP 401` |
| `sso` | an organisation requires SAML SSO authorization for your token | `Authorize in your web browser:` (gh prints it when GitHub sends an SSO challenge), or `SAML enforcement` in GitHub's message |
| `rate_limited` | a primary or secondary rate limit; also `resets_at` | `HTTP 429`, `API rate limit exceeded`, `secondary rate limit` (or its older name, `abuse detection mechanism`), or a GraphQL `RATE_LIMITED` error |
| `not_found` | not there, or hidden from your login (GitHub answers both alike) | `HTTP 404`, a GraphQL `NOT_FOUND` error, or a repository GitHub returns as null |
| `no_access` | your login can see it but not read this | `HTTP 403`, or a GraphQL `FORBIDDEN` error, when none of the above matched |
| `unknown` | anything else: a server error, a timeout, a message not listed here | — |

The first three are tried in that order, then a GraphQL error's type, then `HTTP 404` and
`HTTP 403`: a SAML or rate-limit refusal, which GitHub also sends as a 403, is never `no_access`.
`resets_at` is when the exhausted limit (`core` for REST, `graphql` for GraphQL) resets, from
`GET /rate_limit` (which costs nothing against the limit; read at most every 30 seconds); it is
`null` when that limit is not exhausted (a secondary limit, whose end GitHub does not say), has
reset since it was read, or cannot be read. A cause is never guessed: what matches nothing is
`unknown`.

### Whether a writer answered

`/api/repo/<owner>/<name>/request/<REQ-id>` answers for one open `blocked` or `failed` request (any
other id, kind, or an answered request is a 404). The page asks for the open pane only: each time a
request's pane opens and on each refresh, never for every request on a page load, and not during the
API limit. The answer is cached for a minute and each commenter's access for ten, both read again
with `?fresh=1`, which the page sends whenever it has asked before.

```json
{"id": "REQ-20261113-ab12", "issue": 42, "writer_comment": {"login": "maintainer", "at": "2026-11-14T08:00:00Z"}}
```

`writer_comment` is the newest comment on the request's issue made after the request by an account
with write access or more (`admin`, `maintain` or `write` from
`GET /repos/<repo>/collaborators/<login>/permission`, as `agent-lib.sh` `actor_trusted` decides; never
`author_association`), or `null` when there is none. The agent bot's own comments do not count, and
an App's never do. Only the login and the time are sent: the server does not ask GitHub for the
comment's text. Comments are read newest first back to the request, at most 300; when more than
that came after the request and none of them is a writer's, `writer_comment` is left out (not
known), and the page says nothing. A permission lookup that fails for any reason but a 404 fails
the request, as any read does, rather than count someone as not a writer.

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

### The weekly budget

`POST /api/budget` takes exactly `{"weekly_usd": <number of 0 or more, or null to clear>,
"warn_at": <share from 0 to 1, or null for the default>}` (`warn_at` may be left out to keep it);
anything else is refused with a reason. `/api/session` returns the budget as `budget`.

## Options

| Option | |
|---|---|
| `--port N` | listen on this port (default: a free one) |
| `--no-open` | do not open a browser; print the address instead |
| `--print-url` | print the address with its secret |
| `--idle-minutes M` | stop after M minutes with no page open (default 120; 0 never) |
| `--config FILE` | keep the repository list, the Pause all record and the weekly budget here |
| `--ready-file FILE` | write `{port, token}` there (mode 0600) once listening, for scripts |
