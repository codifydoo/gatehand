# The Gatehand dashboard

One local page for every repository where Gatehand is installed: what the agents are doing now,
what waits for you, and what they did this week.

```bash
python3 bin/dashboard.py
```

or `/gatehand:dashboard` in Claude Code. It needs `gh` signed in and Python 3.9 or later, nothing
else: no packages, no build, no server of ours. It opens your browser on `127.0.0.1`.

This file is not installed into your repositories; the dashboard runs on your machine and changes
nothing in them.

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
- It writes nothing to GitHub. `tests/dashboard/dashboard.test.sh` pins each point above.

## Options

| Option | |
|---|---|
| `--port N` | listen on this port (default: a free one) |
| `--no-open` | do not open a browser; print the address instead |
| `--print-url` | print the address with its secret |
| `--idle-minutes M` | stop after M minutes with no page open (default 120; 0 never) |
| `--config FILE` | keep the repository list here |
| `--ready-file FILE` | write `{port, token}` there (mode 0600) once listening, for scripts |
