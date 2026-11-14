#!/usr/bin/env bash
# tests/dashboard/dashboard.test.sh: bin/dashboard.py, the local dashboard, against a stubbed gh.
# Pinned, and why:
#   1. The server answers only its own page: no session secret, a foreign Host (DNS rebinding), a
#      foreign or missing Origin on a POST, a POST that is not JSON (CSRF), a repository not on the
#      list or a path that walks out of it are all refused. It can see everything the user's gh can.
#   2. The ledger reads the way the agents read it: one malformed line costs that line; a missing
#      file is "no runs"; any other failure is "unreadable" (null, and said so), never zero runs and
#      a closed breaker. A blob GraphQL truncates is read again in full.
#   3. Inbox requests are read from the exact shape agent-lib.sh inbox_request writes, only from the
#      agent bot's comments (anyone can paste a marker), and an answered one is marked answered.
#   4. The inbox issue is found as inbox_find finds it: AGENT_INBOX_ISSUE first, else the lowest
#      open issue with the marker opened by the agent bot or AGENT_OWNER_LOGIN.
#   5. The merge gate's report is read from its job log, timestamps and terminal escapes included.
#   6. Reading writes nothing to GitHub: every gh call a page load makes is a read.
#   7. Its writes are only what a person could do by hand, as that person: an inbox command in
#      exactly the grammar agent-inbox.sh parses (checked by running the real parser), sent only
#      when the viewer is AGENT_OWNER_LOGIN to the letter, the inbox is the one the workflow
#      answers, and the request is the agent's and still open; and a fixed set of agent labels,
#      only for a viewer with write access. agent:allow-protected is never one of them.
#   8. Runs, verdicts and switches go through a preview and a one-time confirm, and are done only if
#      the plan made afresh is the one previewed (a moved head, a new waiting run, a changed variable
#      refuse). Dispatches carry only inputs the rendered workflows declare, in the shapes the
#      scripts' own regexes accept, on the ref each workflow needs. A verdict, posted, reads as meant
#      through the real review_verdict (both readers, GitHub's render recorded), and a note cannot
#      move it. Only Gatehand's runs are cancelled; only AGENTS_ENABLED and AGENT_AUTO_MERGE are set.
#   9. Limits and schedules: a role limit policy.json does not set is null, never a default. The
#      schedules come from the workflow files on the default branch, not policy.json; no `schedule:`
#      (or no file) is null; a file, or a shape of `on:`, that cannot be read is "unknown" and listed
#      under the errors, never "no schedule". The next run is POSIX cron's, in UTC.
#  10. A failed read says why, from a fixed set (SSO not authorized, signed out, rate limited with
#      the time the exhausted limit resets, not found, too little access), beside its text: in each
#      `unreadable` entry of a repository, in a failed request's 502 and in each scan note that is a
#      failed read (kept across a restart only in that fixed shape). Each cause is matched on
#      one sample in the shape gh prints; a message that matches nothing, and a reset time that
#      cannot be read, stay unknown: the page acts on a cause, so a guess would send you the wrong way.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
# shellcheck source=/dev/null
source "${PKG}/tests/workflows/agents-gh-stub.sh"

pass=0 fail=0
t_pass() { printf '\033[1;32m[dashboard] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[dashboard] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }

TMP="$(mktemp -d)"
SRV=""
SRV2=""
trap '[[ -n "${SRV}" ]] && kill "${SRV}" 2>/dev/null; [[ -n "${SRV2}" ]] && kill "${SRV2}" 2>/dev/null; rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export AGENT_NOW_EPOCH=1794657600 # 2026-11-14T12:00:00Z
stub_gh_init

# --- 3. the request shape, as agent-lib.sh really writes it ----------------------------------------
(
  export GH_REPO=o/r AGENT_INBOX_ISSUE=7 AGENT_REQ_ID=REQ-20261113-ab12
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.github/scripts/agent-lib.sh"
  printf '**What:** the coder stopped on #42.\n\n> its note\n' >"${TMP}/req-body"
  inbox_request blocked coder 42 "blocked: the agent asked" "${TMP}/req-body" >/dev/null 2>&1
)
stub_gh_last_body "issue comment 7 *" >"${TMP}/req-comment"
if grep -q '^<!-- agent-req:REQ-20261113-ab12 role=coder issue=42 kind=blocked -->$' "${TMP}/req-comment"; then
  t_pass "inbox_request wrote a request to read"
else
  t_fail "inbox_request wrote no request comment: $(head -c 200 "${TMP}/req-comment")"
fi
stub_gh_reset_calls

# --- the pure readers: 2 (ledger), 3, 4, 5 -------------------------------------------------------------
REQ_COMMENT="${TMP}/req-comment" CFG_DIR="${TMP}/pycfg" python3 - "${PKG}/bin/dashboard.py" <<'PY' >"${TMP}/py.out" 2>&1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("dashboard", sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

def check(name, got, want):
    print(("PASS: " if got == want else "FAIL: ") + name + ("" if got == want else ": got %r, want %r" % (got, want)))

since = "2026-11-07T12:00:00Z"
text = "\n".join([
    json.dumps({"role": "coder", "outcome": "pr-opened", "started_at": "2026-11-14T08:00:00Z", "cost_usd": 1.25, "turns": 10, "duration_ms": 600000}),
    "{not json",
    json.dumps({"role": "coder", "outcome": "blocked", "started_at": "2026-11-13T08:00:00Z", "cost_usd": 0.75}),
    json.dumps({"role": "coder", "outcome": "infra_failure", "counted": False, "started_at": "2026-11-14T09:00:00Z"}),
    json.dumps({"role": "coder", "outcome": "pr-opened", "started_at": "2026-11-01T08:00:00Z", "cost_usd": 9}),
    json.dumps({"role": "merger", "outcome": "merged", "ended_at": "2026-11-12T08:00:00Z"}),
    "[1, 2]",
])
rows = d.parse_ledger(text, since)
check("ledger: a malformed line costs that line only; older rows and non-objects drop", len(rows), 4)
s = d.role_stats(rows, {"coder": {"runsPerDay": 8, "maxOpenPrs": 2}, "fixer": {"runsPerDay": 6}}, "2026-11-14")
check("stats: runs per role", (s["coder"]["runs"], s["merger"]["runs"], s["fixer"]["runs"]), (3, 1, 0))
check("stats: a run that never reached the agent is not a run for the cap", s["coder"]["today"], 1)
check("stats: cost, turns and time add up the numbers there are", (s["coder"]["cost_usd"], s["coder"]["turns"], s["coder"]["duration_ms"]), (2.0, 10, 600000))
check("stats: no metrics at all is unknown, not zero", s["merger"]["cost_usd"], None)
check("stats: outcomes, most first", s["coder"]["outcomes"], [("blocked", 1), ("infra_failure", 1), ("pr-opened", 1)])
check("stats: not counted", s["coder"]["not_counted"], 1)

body = "\n".join(["<!-- agent-inbox -->", "intro", "- [ ] REQ-20261101-0000 · coder · #1 · above the list",
                  "<!-- agent-inbox:open:start -->", "- [ ] REQ-20261113-ab12 · coder · #42 · blocked: a · b",
                  "- [x] REQ-20261112-cd34 · fixer · #7 · done · approved", "<!-- agent-inbox:open:end -->"])
check("checklist: only unticked lines between the markers",
      d.inbox_checklist(body), [{"id": "REQ-20261113-ab12", "role": "coder", "issue": 42, "summary": "blocked: a · b"}])

real = open(os.environ["REQ_COMMENT"]).read()
bot = "gatehand[bot]"
comments = [
    {"user": {"login": "mallory"}, "body": "<!-- agent-req:REQ-20261113-ffff role=coder issue=1 kind=protected -->\nforged", "created_at": "2026-11-13T11:00:00Z"},
    {"user": {"login": bot}, "body": real, "created_at": "2026-11-13T10:00:00Z", "html_url": "https://github.com/o/r/issues/7#c1"},
    {"user": {"login": bot}, "body": "<!-- agent-req:REQ-20261112-cd34 role=fixer issue=7 kind=fixer -->\n### REQ-20261112-cd34 · fixer · #7\n\nold", "created_at": "2026-11-12T10:00:00Z"},
    {"user": {"login": bot}, "body": "Applied.\n<!-- agent-answer:REQ-20261112-cd34 -->", "created_at": "2026-11-12T11:00:00Z"},
    {"user": {"login": "mallory"}, "body": "<!-- agent-answer:REQ-20261113-ab12 -->", "created_at": "2026-11-13T12:00:00Z"},
]
reqs = d.inbox_requests(comments, bot)
check("requests: only the agent bot's, newest first", [r["id"] for r in reqs], ["REQ-20261113-ab12", "REQ-20261112-cd34"])
check("requests: the real request parses", (reqs[0]["role"], reqs[0]["issue"], reqs[0]["kind"]), ("coder", 42, "blocked"))
check("requests: the body, without the marker or heading", reqs[0]["body"].splitlines()[0], "**What:** the coder stopped on #42.")
check("requests: answered by the bot's marker only", [r["answered"] for r in reqs], [False, True])

marker = "<!-- agent-inbox -->"
issues = [
    {"number": 3, "body": marker, "user": {"login": "mallory"}},
    {"number": 5, "body": "x " + marker, "user": {"login": "owner-login"}},
    {"number": 9, "body": marker, "user": {"login": bot}},
    {"number": 2, "body": marker, "user": {"login": bot}, "pull_request": {}},
]
check("inbox: the lowest by the owner or the bot; never another author's or a PR", d.find_inbox(issues, marker, bot, "owner-login")["number"], 5)
check("inbox: without an owner, only the bot's", d.find_inbox(issues, marker, bot, "")["number"], 9)
check("inbox: the owner login is matched exactly", d.find_inbox(issues, marker, bot, "Owner-Login")["number"], 9)

SAML = {"message": "Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization.", "type": "FORBIDDEN"}
pages = iter([({"viewer": {"repositories": {"nodes": [{"nameWithOwner": "a/b", "lock": {"oid": "1"}}], "pageInfo": {"hasNextPage": True, "endCursor": "x"}}}}, [SAML]),
               ({"viewer": {"repositories": {"nodes": [None], "pageInfo": {"hasNextPage": False}}}}, [SAML, {"message": "Something went wrong", "type": None}])])
real_graphql, d.graphql = d.graphql, lambda *a, **k: next(pages)
check("discovery keeps what a partly hidden scan found, says why once, and each note's cause", d.discover(),
      (["a/b"], [SAML["message"], "Something went wrong"], [{"cause": "sso", "error": SAML["message"]}, {"cause": "unknown", "error": "Something went wrong"}]))
d.graphql = real_graphql

# Labels with no inbox issue at all (closed, or not created yet): Hold still works.
d.gh_json = lambda args, stdin=None: {"number": 42, "state": "open"}
d.gh = lambda args, stdin=None: ""
base = {"viewer_permission": "ADMIN", "inbox": None}
check("labels work in a repo with no inbox issue", d.do_label("o/r", dict(base, inbox_state="none"), {"op": "add", "label": "agent:hold", "number": 42})["done"], "added agent:hold on #42")
try:
    d.do_label("o/r", dict(base, inbox_state="unknown"), {"op": "add", "label": "agent:hold", "number": 42}); got = "posted"
except d.ApiError as e:
    got = e.status
check("labels refused while the inbox cannot be told", got, 409)

w = d.waiting_items({"url": "https://github.com/o/r", "inbox_state": "unknown", "inbox": None, "breakers": None, "issues": None})
check("waiting: every unreadable part is an item, never nothing", [x["kind"] for x in w], ["unknown", "unknown", "unknown"])
pages = iter([({"viewer": {"repositories": {"nodes": [{"nameWithOwner": "a/b", "lock": {"oid": "1"}}], "pageInfo": {"hasNextPage": True, "endCursor": "x"}}}}, [{"message": "SAML", "type": None}]),
               ({"viewer": {"repositories": {"nodes": [None], "pageInfo": {"hasNextPage": False}}}}, [{"message": "SAML", "type": None}])])
real_graphql, d.graphql = d.graphql, lambda *a, **k: next(pages)
check("discovery keeps what a partly hidden scan found, and says why once", d.discover()[:2], (["a/b"], ["SAML"]))
d.graphql = real_graphql

w = d.waiting_items({"url": "https://github.com/o/r", "inbox_state": "none", "inbox": None, "breakers": {},
                     "issues": {"blocked": [], "candidate": [], "done_pending_deploy": []}, "prs": []})
check("waiting: all read and nothing there is nothing", w, [])

log = "\n".join(["2026-11-14T09:25:51.1Z ##[group]Run agent-merge.sh run", "2026-11-14T09:25:52.2Z #12: wait: CI is running",
                 "2026-11-14T09:25:52.3Z #13: would merge abc (dry run: AGENT_AUTO_MERGE is not true)", "#14: merged"])
check("gate: one line per PR", d.merge_gate_lines(log), {12: "wait: CI is running", 13: "would merge abc (dry run: AGENT_AUTO_MERGE is not true)", 14: "merged"})
check("gate: terminal escapes are stripped", d.ANSI_RE.sub("", "\x1b[36;1m#1: wait\x1b[0m"), "#1: wait")

# Schedules: the cron lines of the rendered workflows, and when each runs next (now is Saturday
# 2026-11-14 12:00 UTC).
from datetime import datetime, timezone
now = datetime(2026, 11, 14, 12, 0, tzinfo=timezone.utc)
wf = lambda f: open(os.path.join(os.environ["AGENTS_ROOT"], ".github/workflows", f)).read()
policy = json.load(open(os.path.join(os.environ["AGENTS_ROOT"], ".github/agents/policy.json")))
check("schedules: each scheduled workflow's cron is the one rendered from policy.json",
      {k: d.workflow_crons(wf(f)) for k, f in d.SCHEDULED.items()}, {k: [policy["schedules"][k]] for k in d.SCHEDULED})
check("schedules: a workflow with no schedule has none", d.workflow_crons(wf("agent-inbox.yml")), [])
check("schedules: an input named schedule is not one", d.workflow_crons(
    "on:\n  workflow_dispatch:\n    inputs:\n      schedule:\n        type: string\njobs:\n  schedule:\n"), [])
check("schedules: quoted, unquoted, commented, two of them", d.workflow_crons(
    "name: x\non: # why\n  push:\n  schedule:\n    # first\n    - cron: '5 4 * * *'  # four\n    - cron: 0 1 * * 1\njobs: {}\n"), ["5 4 * * *", "0 1 * * 1"])
check("schedules: a quoted key, items at the key's indent, a BOM, a comment naming schedule", d.workflow_crons(
    "﻿on:\n  push: # and on schedule\n  \"schedule\":\n  - cron: \"17 5 * * *\"\n  workflow_dispatch:\n"), ["17 5 * * *"])
for name, text in (("flow style", "on: [push, schedule]\n"), ("flow-style schedule", "on:\n  schedule: [{cron: '1 * * * *'}]\n"),
                   ("schedule with no cron", "on:\n  schedule:\n  push:\n"), ("a key it does not know", "on:\n  schedule:\n    - crons: x\n"),
                   ("an anchor on on:", "on: &t\n  schedule:\n    - cron: '11 * * * *'\n"), ("an alias", "on: *t\n"),
                   ("a tag", "on: !!map\n  schedule:\n    - cron: '11 * * * *'\n"),
                   ("an anchor on the cron", "on:\n  schedule:\n    - cron: &c '1 2 * * *'\n"), ("an alias for the cron", "on:\n  schedule:\n    - cron: *c\n"),
                   ("a schedule key it cannot read", "on:\n  ? schedule\n  : - cron: '11 * * * *'\n"),
                   ("a cron that is not a list item (GitHub would not run it)", "on:\n  schedule:\n    cron: '1 * * * *'\n")):
    try:
        d.workflow_crons(text); got = "read"
    except ValueError:
        got = "unknown"
    check("schedules: %s is unknown, never none" % name, got, "unknown")
nxt = lambda c: d.iso(d.next_cron_run(c, now))
check("next run: each default schedule, in UTC", {k: nxt(policy["schedules"][k]) for k in d.SCHEDULED},
      {"coder": "2026-11-14T12:17:00Z", "merge": "2026-11-14T12:11:00Z", "sweep": "2026-11-14T12:41:00Z",
       "digest": "2026-11-16T06:30:00Z", "triage": "2026-11-15T05:17:00Z"})
check("next run: strictly after now", nxt("0 12 * * *"), "2026-11-15T12:00:00Z")
check("next run: day of month or day of week when both are set (the 13th, or a Friday)", nxt("0 0 13 * 5"), "2026-11-20T00:00:00Z")
check("next run: Sunday is 0 or 7", (nxt("0 0 * * 7"), nxt("0 0 * * 0")), ("2026-11-15T00:00:00Z", "2026-11-15T00:00:00Z"))
check("next run: lists, ranges and steps", nxt("10,50 13-23/5 * 11-12 *"), "2026-11-14T13:10:00Z")
check("next run: 29 February", nxt("0 0 29 2 *"), "2028-02-29T00:00:00Z")
check("next run: a day that never comes is none", d.next_cron_run("0 0 31 2 *", now), None)
for c in ("60 * * * *", "* * * *", "*/0 * * * *", "0 0 * * MON", "@@CRON_CODER@@", "5-1 * * * *", "0 24 * * *", "١ * * * *"):
    try:
        d.next_cron_run(c, now); got = "read"
    except ValueError:
        got = "refused"
    check("next run: %r is refused" % c, got, "refused")

for r in ("o/r", "my-org/repo.name", "o/r_1"):
    check("repo name ok: %r" % r, d.valid_repo(r), True)
for r in ("o/..", "o/.", "../r", "o/r/x", "o", "-o/r", "o/r?x", "o/r%2F", "", "o/r\n", "o\n/r"):
    check("repo name refused: %r" % r, d.valid_repo(r), False)

# 10. Why a read failed. Each sample is in the shape gh prints (pkg/cmd/api/api.go: "gh: <message>
# (HTTP <status>)", the SSO line; pkg/cmd/root: the signed-out text and exit 4); the messages inside
# are GitHub's.
causes = [
    ("SAML: gh's SSO line", 1, "gh: Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization. (HTTP 403)\nAuthorize in your web browser: https://github.com/orgs/o/sso?authorization_request=x", [], "sso"),
    ("SAML over GraphQL: the message beats its FORBIDDEN type", 1, "gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization.", ["FORBIDDEN"], "sso"),
    ("signed out: no login at all", 4, "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.", [], "signed_out"),
    ("signed out: gh's exit code alone", 4, "", [], "signed_out"),
    ("signed out: a revoked token", 1, "gh: Bad credentials (HTTP 401)", [], "signed_out"),
    ("rate limited: the primary limit", 1, "gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID A:B. (HTTP 403)", [], "rate_limited"),
    ("rate limited: a secondary limit", 1, "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)", [], "rate_limited"),
    ("rate limited: a secondary limit's older name", 1, "gh: You have triggered an abuse detection mechanism. Please wait a few minutes before you try again. (HTTP 403)", [], "rate_limited"),
    ("rate limited: a GraphQL RATE_LIMITED type", 1, "gh: something new", ["RATE_LIMITED"], "rate_limited"),
    ("not found: REST", 1, "gh: Not Found (HTTP 404)", [], "not_found"),
    ("not found: a GraphQL NOT_FOUND type", 1, "gh: Could not resolve to a Repository with the name 'o/r'.", ["NOT_FOUND"], "not_found"),
    ("no access: REST", 1, "gh: Must have admin rights to Repository. (HTTP 403)", [], "no_access"),
    ("no access: an App token", 1, "gh: Resource not accessible by integration (HTTP 403)", [], "no_access"),
    ("unknown: a server error", 1, "gh: Bad Gateway (HTTP 502)", [], "unknown"),
    ("unknown: a timeout", -1, "Command '['gh', 'api', 'user']' timed out after 60 seconds", [], "unknown"),
    ("unknown: an unrecognised message and type", 1, "gh: the forbidden word, not found anywhere", ["INTERNAL"], "unknown"),
    ("unknown: nothing printed", 1, "", [], "unknown"),
]
for name, rc, err, types, want in causes:
    check("cause: " + name, d.read_cause(rc, err, types), want)
check("every cause is one of the fixed set", {d.read_cause(rc, err, t) for _, rc, err, t, _ in causes} <= set(d.CAUSES), True)
check("a GraphQL call counts against the graphql limit", d.GhError(["api", "graphql", "-f", "q"], 1, "x").resource, "graphql")
check("a REST call against core", d.GhError(["api", "repos/o/r"], 1, "x").resource, "core")

d._rate["at"] = None
d.gh_json = lambda args, stdin=None: {"resources": {"core": {"remaining": 0, "reset": 1794661200}, "graphql": {"remaining": 9, "reset": 1794661200}}}
check("rate limited: when the exhausted limit resets", d.cause_of(d.GhError(["api", "repos/o/r"], 1, "gh: API rate limit exceeded for user ID 1. (HTTP 403)")),
      {"cause": "rate_limited", "resets_at": "2026-11-14T13:00:00Z"})
check("rate limited, but not that limit (a secondary one): no time is guessed",
      d.cause_of(d.GhError(["api", "graphql"], 1, "gh: You have exceeded a secondary rate limit. (HTTP 403)")),
      {"cause": "rate_limited", "resets_at": None})
d._rate["at"] = None
d.gh_json = lambda args, stdin=None: {"resources": {"core": {"remaining": 0, "reset": 1794657600}}}
check("rate limited, but the limit read as exhausted has reset since: no stale time", d.rate_reset("core"), None)
d._rate["at"] = None
d.gh_json = lambda args, stdin=None: ["not", "an object"]
check("rate limited, and /rate_limit answered nonsense: no time, no crash", d.rate_reset("core"), None)
d._rate["at"] = None
d.gh_json = lambda args, stdin=None: {"resources": {"core": {"remaining": 0, "reset": 10 ** 20}}}
check("rate limited, and a reset time no clock can hold: no time, no crash", d.rate_reset("core"), None)
def unreadable(args, stdin=None):
    raise d.GhError(args, 1, "gh: HTTP 500")
d._rate["at"], d.gh_json = None, unreadable
check("rate limited, and the limits unreadable: no time", d.rate_reset("core"), None)
check("any other cause carries no time", d.cause_of(d.GhError(["api", "x"], 1, "gh: Not Found (HTTP 404)")), {"cause": "not_found"})
os.makedirs(os.environ["CFG_DIR"])
cfg = os.path.join(os.environ["CFG_DIR"], "dashboard.json")
json.dump({"scan_notes": ["n1"], "scan_unreadable": [
    {"cause": "sso", "error": "n1"}, {"cause": "rate_limited", "error": "n2", "resets_at": "2026-11-14T13:00:00Z"},
    {"cause": "<b>made up</b>", "error": "x"}, {"cause": "sso", "error": 5}, "z",
    {"cause": "sso", "error": "y", "resets_at": "2026-11-14T13:00:00Z"}, {"cause": "rate_limited", "error": "r1"},
    {"cause": "rate_limited", "error": "r2", "resets_at": "not a time"},
    {"cause": "rate_limited", "error": "r3", "resets_at": "2026-99-99T99:99:99Z"},
    {"cause": "rate_limited", "error": "r4", "resets_at": "\uff12\uff10\uff12\uff16-11-14T13:00:00Z"},
    {"cause": "unknown", "error": "e" * 400}]}, open(cfg, "w"))
check("scan causes are kept across a restart, only in the fixed shape", d.Config(cfg).data["scan_unreadable"],
      [{"cause": "sso", "error": "n1"}, {"cause": "rate_limited", "error": "n2", "resets_at": "2026-11-14T13:00:00Z"},
       {"cause": "sso", "error": "y"}, {"cause": "rate_limited", "error": "r1", "resets_at": None},
       {"cause": "rate_limited", "error": "r2", "resets_at": None}, {"cause": "rate_limited", "error": "r3", "resets_at": None},
       {"cause": "rate_limited", "error": "r4", "resets_at": None}, {"cause": "unknown", "error": "e" * 300}])
# A long note and its cause still match after a restart; the notes that are not failed reads have none.
long = "Although you appear to have the correct authorization credentials, the o organization has enabled OAuth App access restrictions. " * 3
pages = iter([({"viewer": {"repositories": {"nodes": [], "pageInfo": {"hasNextPage": False}}}}, [{"message": long, "type": "FORBIDDEN"}])])
real_graphql, d.graphql = d.graphql, lambda *a, **k: next(pages)
class Srv:
    config = d.Config(cfg)
    config.data["discovered"] = ["o/earlier"]
h = d.Handler.__new__(d.Handler)
h.server = Srv
h.rescan()
d.graphql = real_graphql
live = Srv.config.data
check("a long note is cut once, before it is sent or kept: the same before and after a restart",
      (len(live["scan_notes"][0]), live["scan_notes"][0] == live["scan_unreadable"][0]["error"]), (300, True))
again = d.Config(cfg).data
check("a long note and its cause match after a restart", (len(again["scan_notes"][0]), again["scan_notes"][0] == again["scan_unreadable"][0]["error"]), (300, True))
check("the kept-repositories note has no cause", (len(again["scan_notes"]), [x["cause"] for x in again["scan_unreadable"]]), (2, ["no_access"]))
PY
while IFS= read -r line; do
  case "${line}" in
    PASS:*) t_pass "${line#PASS: }" ;;
    FAIL:*) t_fail "${line#FAIL: }" ;;
    *) t_fail "python: ${line}" ;;
  esac
done <"${TMP}/py.out"

# --- the server, against the stub -------------------------------------------------------------------
Q1="api graphql -f name=r -f owner=o -f query=query(\$owner*"
Q2="api graphql -f breaker=agent-ledger:state/breaker.json -f cur=agent-ledger:runs/2026-11.jsonl -f name=r -f owner=o -f prev=agent-ledger:runs/2026-11.jsonl *"
POLICY="$(jq -c '.' "${REPO_ROOT}/.github/agents/policy.json")"
ROW1='{"role":"coder","outcome":"pr-opened","started_at":"2026-11-14T08:00:00Z","cost_usd":1.5}'
ROW2='{"role":"fixer","outcome":"fix-pushed","started_at":"2026-11-13T08:00:00Z","cost_usd":0.5}'
# The scheduled workflows as rendered; WF_EXTRA (a JSON object) replaces some of them.
WF_BLOBS="$(for k in coder merge sweep digest triage; do
  jq -nc --arg k "wf_${k}" --rawfile t "${REPO_ROOT}/.github/workflows/agent-${k}.yml" '{($k): {text: $t, isTruncated: false}}'
done | jq -sc 'add')"
WF_EXTRA='{}'
q1() { jq -nc --arg p "${POLICY}" --arg perm "${PERM:-ADMIN}" --argjson wf "${WF_BLOBS}" --argjson wfx "${WF_EXTRA}" '{data: {repository: ({nameWithOwner: "o/r", url: "https://github.com/o/r", viewerPermission: $perm,
  isArchived: false, defaultBranchRef: {name: "main"}, policy: {text: $p, isTruncated: false}, lock: {text: "{\"version\":\"9.9.9\"}", isTruncated: false}} + $wf + $wfx)}}'; }
q2() { # q2 <cur-blob-json> <breaker-blob-json>
  jq -nc --argjson c "$1" --argjson b "$2" '{data: {repository: {cur: $c, prev: $c, breaker: $b, wfRunner: {oid: "a"}, wfMain: {oid: "a"}}}}'
}
RATE_OK='{"resources":{"core":{"remaining":4999,"limit":5000}}}'
rules() {
  stub_gh_reset_rules
  stub_gh_on "api graphql -f query=query(\$cursor*" '{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"nameWithOwner":"o/r","isArchived":false,"lock":{"oid":"1"}},{"nameWithOwner":"o/plain","isArchived":false,"lock":null},
    {"nameWithOwner":"o/old","isArchived":true,"lock":{"oid":"2"}}]}}}}'
  stub_gh_on "api user" '{"login":"owner-login"}'
  stub_gh_on "api rate_limit" "${RATE_OUT:-${RATE_OK}}"
  stub_gh_on "${Q1}" "$(q1)"
  stub_gh_on "${Q2}" "${Q2_OUT}" "${Q2_RC:-0}" "${Q2_ERR:-}"
  stub_gh_on "api -H Accept: application/vnd.github.raw repos/o/r/contents/runs/2026-11.jsonl?ref=agent-ledger" "${RAW_LEDGER:-}"
  stub_gh_on "api -H Accept: application/vnd.github.raw repos/o/r/contents/.github/workflows/agent-digest.yml?ref=main" "" 1 "HTTP 502: Bad Gateway"
  stub_gh_on "api repos/o/r/actions/variables?per_page=100" "${VARS_OUT:-}" "${VARS_RC:-0}" "${VARS_ERR:-}"
  stub_gh_on "api repos/o/r/issues?state=open&per_page=100&page=1" "${ISSUES_OUT:-}" "${ISSUES_RC:-0}" "${ISSUES_ERR:-}"
  stub_gh_on "api repos/o/r/actions/runs?status=in_progress&per_page=100" '{"workflow_runs":[
    {"id":1,"path":".github/workflows/agent-coder.yml","status":"in_progress","display_title":"Agent coder: issue 43","created_at":"2026-11-14T11:00:00Z"},
    {"id":2,"path":".github/workflows/ci.yml","status":"in_progress"}]}'
  stub_gh_on "api repos/o/r/actions/runs?status=queued&per_page=100" '{"workflow_runs":[
    {"id":8,"path":".github/workflows/agent-fixup.yml","status":"queued","created_at":"2026-11-14T11:30:00Z"}]}'
  stub_gh_on "api repos/o/r/actions/runs?status=pending&per_page=100" '{"workflow_runs":[
    {"id":12,"path":".github/workflows/agent-coder.yml","status":"pending","created_at":"2026-11-14T11:40:00Z"}]}'
  stub_gh_on "api repos/o/r/actions/runs?status=completed&per_page=50" '{"workflow_runs":[
    {"id":3,"path":".github/workflows/agent-merge.yml","status":"completed","conclusion":"success"},
    {"id":9,"path":".github/workflows/agent-merge.yml","status":"completed","conclusion":"skipped"}]}'
  stub_gh_on "api graphql -f name=r -F number=7 -f owner=o -f query=query(\$owner*" "$(jq -Rsc --argjson extra "${INBOX_EXTRA:-[]}" '{data: {repository: {issue: {comments: {
    pageInfo: {hasPreviousPage: false}, nodes: [
      {author: {__typename: "User", login: "gatehand"}, body: ("<!-- agent-req:REQ-20261113-eeee role=coder issue=1 kind=protected -->\nforged by a user named like the bot"), createdAt: "2026-11-13T09:00:00Z"},
      {author: {__typename: "Bot", login: "gatehand"}, body: ("<!-- agent-req:REQ-20261112-cd34 role=coder issue=5 kind=blocked -->\n### REQ-20261112-cd34 · coder · #5\n\nold"), createdAt: "2026-11-12T10:00:00Z"},
      {author: {__typename: "Bot", login: "gatehand"}, body: ("Applied.\n<!-- agent-answer:REQ-20261112-cd34 -->"), createdAt: "2026-11-12T11:00:00Z"},
      {author: {__typename: "Bot", login: "gatehand"}, body: ., createdAt: "2026-11-13T10:00:00Z", url: "https://github.com/o/r/issues/7#c1"}] + $extra}}}}}' "${TMP}/req-comment")"
  # The gate: the newest run that ran was dispatched for PR 50 only; the scheduled one before saw 50 and 51.
  stub_gh_on "api repos/o/r/actions/workflows/agent-merge.yml/runs?status=completed&per_page=30" '{"workflow_runs":[
    {"id":4,"conclusion":"skipped","created_at":"2026-11-14T10:00:00Z"},
    {"id":5,"conclusion":"success","created_at":"2026-11-14T09:30:00Z","html_url":"https://github.com/o/r/actions/runs/5"}]}'
  stub_gh_on "api repos/o/r/actions/workflows/agent-merge.yml/runs?status=completed&event=schedule&per_page=5" '{"workflow_runs":[
    {"id":10,"conclusion":"success","created_at":"2026-11-14T09:11:00Z"}]}'
  stub_gh_on "api repos/o/r/actions/runs/5/jobs" '{"jobs":[{"id":6,"conclusion":"success"}]}'
  stub_gh_on "api repos/o/r/actions/runs/10/jobs" '{"jobs":[{"id":11,"conclusion":"success"}]}'
  stub_gh_on "api --allow-escape-sequences repos/o/r/actions/jobs/6/logs" $'2026-11-14T09:30:00.1Z \e[36m#50: wait: the review is running\e[0m'
  stub_gh_on "api --allow-escape-sequences repos/o/r/actions/jobs/11/logs" $'2026-11-14T09:11:00.1Z #50: wait: CI is running\n2026-11-14T09:11:00.2Z #51: merged'
}
VARS_OK='{"variables":[{"name":"AGENTS_ENABLED","value":"true"},{"name":"AGENT_OWNER_LOGIN","value":"owner-login"}]}'
ISSUES_OK='[
    {"number":7,"title":"Needs a human","body":"<!-- agent-inbox -->\n<!-- agent-inbox:open:start -->\n- [ ] REQ-20261113-ab12 · coder · #42 · blocked\n<!-- agent-inbox:open:end -->","user":{"login":"owner-login"},"labels":[]},
    {"number":42,"title":"Do a thing","body":"","user":{"login":"owner-login"},"labels":[{"name":"agent:blocked"},{"name":"agent:needs-human"}]},
    {"number":43,"title":"Queued","body":"","user":{"login":"owner-login"},"labels":[{"name":"agent:ready"},{"name":"priority: high"}]},
    {"number":50,"title":"feat: x","body":"","user":{"login":"gatehand[bot]"},"labels":[{"name":"agent:pr"}],"pull_request":{}}]'
VARS_OUT="${VARS_OK}" ISSUES_OUT="${ISSUES_OK}"
Q2_OUT="$(q2 "$(jq -nc --arg t "${ROW1}"$'\n'"${ROW2}" '{text: $t, isTruncated: false}')" '{"text":"{\"coder\":{\"tripped_at\":\"2026-11-14T07:00:00Z\",\"reason\":\"3 in a row\"}}","isTruncated":false}')"
rules

# A ready file that already exists (and is world-readable) is replaced by a fresh 0600 one.
printf 'stale' >"${TMP}/ready"
chmod 644 "${TMP}/ready"
python3 "${PKG}/bin/dashboard.py" --no-open --idle-minutes 0 --config "${TMP}/cfg/dashboard.json" --ready-file "${TMP}/ready" >"${TMP}/srv.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do jq -e .port "${TMP}/ready" >/dev/null 2>&1 && break; sleep 0.1; done
mode_of() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
expect "the ready file is a fresh one, mode 0600" "$(mode_of "${TMP}/ready")" 600
PORT="$(jq -r .port "${TMP}/ready")"
TOKEN="$(jq -r .token "${TMP}/ready")"
B="http://127.0.0.1:${PORT}"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
get() { curl -s -H "X-Gatehand-Token: ${TOKEN}" "${B}$1"; }

# 1. who may talk to it
expect "the page itself loads" "$(code "${B}/")" 200
expect "the page carries the CSP" "$(curl -sI "${B}/" | grep -ci "^content-security-policy: default-src 'none'; script-src 'self'")" 1
# A browser that suppresses native dialogs answers them "Cancel" unseen: the page asks in its own.
expect "the page never uses a native dialog" "$(curl -s "${B}/app.js" | grep -cE '\b(window\.)?(confirm|prompt|alert)\(')" 0
expect "no secret: refused" "$(code "${B}/api/session")" 401
expect "a wrong secret: refused" "$(code -H "X-Gatehand-Token: nope" "${B}/api/session")" 401
expect "a foreign Host (DNS rebinding): refused" "$(code -H "X-Gatehand-Token: ${TOKEN}" -H "Host: evil.example:${PORT}" "${B}/api/session")" 421
JSON=(-H "X-Gatehand-Token: ${TOKEN}" -H "Content-Type: application/json" -d '{"op":"rescan"}')
expect "a POST from another origin: refused" "$(code "${JSON[@]}" -H "Origin: http://evil.example" "${B}/api/repos")" 403
expect "a POST with no Origin: refused" "$(code "${JSON[@]}" "${B}/api/repos")" 403
expect "a POST that is not JSON: refused" "$(code -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: text/plain" -d '{"op":"rescan"}' "${B}/api/repos")" 415
expect "a same-origin JSON POST with no secret: refused" "$(code -H "Origin: ${B}" -H "Content-Type: application/json" -d '{"op":"rescan"}' "${B}/api/repos")" 401
expect "only the page's own files are served" "$(code --path-as-is "${B}/../bin/dashboard.py")" 404

# discovery
s="$(get /api/session)"
expect "the first session scans: installed, not archived, only" "$(jq -c .repos <<<"${s}")" '["o/r"]'
expect "the viewer" "$(jq -r .viewer <<<"${s}")" "owner-login"
expect "the list is kept, mode 0600" "$(mode_of "${TMP}/cfg/dashboard.json")" 600
expect "a repository not on the list: refused" "$(code -H "X-Gatehand-Token: ${TOKEN}" "${B}/api/repo/o/plain")" 404
expect "a path out of the list: refused" "$(code --path-as-is -H "X-Gatehand-Token: ${TOKEN}" "${B}/api/repo/o/..%2F..%2Fetc")" 404

# 2-5. one repository
r="$(get /api/repo/o/r)"
expect "version from the lock" "$(jq -r .version <<<"${r}")" "9.9.9"
expect "nothing unreadable" "$(jq -c .errors <<<"${r}")" "[]"
expect "today against the cap" "$(jq -c '[.stats.coder.today, .stats.coder.cap]' <<<"${r}")" "[1,$(jq '.roles.coder.runsPerDay' <<<"${POLICY}")]"
expect "seven days of cost" "$(jq -c '[.stats.coder.cost_usd, .stats.fixer.cost_usd]' <<<"${r}")" "[1.5,0.5]"
expect "the tripped breaker waits for you" "$(jq -r '[.waiting[] | select(.kind == "breaker")] | length' <<<"${r}")" 1
expect "the inbox the owner opened, and its open line" "$(jq -c '[.inbox.number, .inbox.checklist[0].id]' <<<"${r}")" '[7,"REQ-20261113-ab12"]'
expect "blocked issues wait for you" "$(jq -r '[.waiting[] | select(.kind == "blocked")][0].text' <<<"${r}")" "#42 Do a thing: agent:blocked, agent:needs-human."
expect "the queue, with its priority" "$(jq -c '[.issues.ready[] | [.number, .priority]]' <<<"${r}")" '[[43,"high"]]'
expect "agent PRs" "$(jq -c '[.prs[].number]' <<<"${r}")" "[50]"
expect "running, queued and pending (behind a concurrency group) Gatehand runs, newest first, nobody else's" "$(jq -c '[.active_runs[].id]' <<<"${r}")" "[12,8,1]"
expect "finished runs, without the skipped ones" "$(jq -c '[.recent_runs[].id]' <<<"${r}")" "[3]"
expect "the issue bodies stay on the server" "$(jq '[.. | objects | select(has("body"))] | length' <<<"${r}")" 0
expect "nothing waits as unknown" "$(jq '[.waiting[] | select(.kind == "unknown")] | length' <<<"${r}")" 0
expect "inbox requests: the Bot's, not a user's named like it" "$(get /api/repo/o/r/inbox | jq -c '[.requests[] | [.id, .answered]]')" '[["REQ-20261113-ab12",false],["REQ-20261112-cd34",true]]'
g="$(get /api/repo/o/r/gate)"
expect "the gate: the newest run that ran" "$(jq -r .run.url <<<"${g}")" "https://github.com/o/r/actions/runs/5"
expect "the gate: a PR's newest line wins; one the newest run skipped comes from the scheduled run" "$(jq -c '[.prs["50"].text, .prs["51"].text]' <<<"${g}")" '["wait: the review is running","merged"]'
expect "the gate: each line says which run it is from" "$(jq -c '[.prs["50"].at, .prs["51"].at]' <<<"${g}")" '["2026-11-14T09:30:00Z","2026-11-14T09:11:00Z"]'

# The per-role limits: what policy.json sets, and null (never a default) for what it does not.
LIMITS='[.policy.roles[] | [.maxAttemptsPerIssue, .maxCiFixes, .breakerThreshold, .timeoutMinutes]]'
expect "limits: each role's, from policy.json" "$(jq -c "${LIMITS}" <<<"${r}")" "$(jq -c '[.roles[] | [.maxAttemptsPerIssue, .maxCiFixes, .breakerThreshold, .timeoutMinutes]]' <<<"${POLICY}")"
expect "limits: a key the role does not have is null" "$(jq -c '[.policy.roles.coder.maxCiFixes, .policy.roles.fixer.maxAttemptsPerIssue]' <<<"${r}")" "[null,null]"
# The schedules: the cron the workflow file carries, and its next run in UTC.
expect "schedules: each scheduled workflow, its cron and next run" "$(jq -c '.schedules | [.coder, .merge, .sweep, .digest, .triage] | map([.cron[0], .next_run])' <<<"${r}")" \
  "$(jq -c '.schedules | [.coder, .merge, .sweep, .digest, .triage]' <<<"${POLICY}" | jq -c '[[.[0], "2026-11-14T12:17:00Z"], [.[1], "2026-11-14T12:11:00Z"], [.[2], "2026-11-14T12:41:00Z"], [.[3], "2026-11-16T06:30:00Z"], [.[4], "2026-11-15T05:17:00Z"]]')"
Q1_SAVE="${POLICY}"; POLICY="$(jq -c 'del(.roles.coder.breakerThreshold, .roles.fixer.timeoutMinutes)' <<<"${POLICY}")"
WF_EXTRA='{"wf_sweep":{"text":"on:\n  workflow_dispatch:\n","isTruncated":false},"wf_triage":null,"wf_digest":{"text":"","isTruncated":true},
  "wf_merge":{"text":"on:\n  schedule:\n    - cron: \"0 0 31 2 *\"\n","isTruncated":false},"wf_coder":{"text":null,"isTruncated":false}}'
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "limits: a key taken out of policy.json is null, not the default" "$(jq -c '[.policy.roles.coder.breakerThreshold, .policy.roles.fixer.timeoutMinutes, .policy.roles.coder.timeoutMinutes]' <<<"${r}")" \
  "[null,null,$(jq '.roles.coder.timeoutMinutes' <<<"${POLICY}")]"
expect "schedules: no schedule (or no file) is null" "$(jq -c '[.schedules.sweep, .schedules.triage]' <<<"${r}")" "[null,null]"
expect "schedules: a file that cannot be read (a failed read, a blob with no text) is unknown, not no schedule" "$(jq -c '[.schedules.digest, .schedules.coder]' <<<"${r}")" '["unknown","unknown"]'
expect "schedules: a cron that never runs keeps its cron, its next run null" "$(jq -c '.schedules.merge' <<<"${r}")" '{"cron":["0 0 31 2 *"],"next_run":null}'
expect "schedules: and both say so under the repository" "$(jq -c '[.errors[] | split(":")[0]]' <<<"${r}")" '[".github/workflows/agent-coder.yml",".github/workflows/agent-merge.yml",".github/workflows/agent-digest.yml"]'

POLICY="${Q1_SAVE}"; WF_EXTRA='{}'
rules
r="$(get '/api/repo/o/r?fresh=1')"

# Variables unreadable (a viewer without write access): the inbox is unknown, never a guess.
VARS_OUT="" VARS_RC=1 VARS_ERR="HTTP 403: Must have admin rights to Repository."
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "unreadable variables: unknown, not off" "$(jq -c '[.vars, .owner_login, .inbox, .inbox_state]' <<<"${r}")" '[null,null,null,"unknown"]'
expect "10. and why, beside the text: too little access" "$(jq -c '[.unreadable[] | [.part, .cause, .error == "variables: your login cannot read this repository'"'"'s Actions variables"]]' <<<"${r}")" '[["variables","no_access",true]]'
VARS_ERR=$'gh: Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization. (HTTP 403)\nAuthorize in your web browser: https://github.com/orgs/o/sso?authorization_request=x'
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "10. a SAML 403 on the variables: sso, and its own text, not \"cannot read\"" "$(jq -c '[[.unreadable[] | [.part, .cause]], (.errors | map(select(startswith("variables:"))) | .[0] | contains("SAML"))]' <<<"${r}")" '[[["variables","sso"]],true]'
expect "and the inbox's requests are an unknown, waiting" "$(jq -r '[.waiting[] | select(.kind == "unknown")] | length' <<<"${r}")" 1
VARS_OUT="${VARS_OK}" VARS_RC=0 VARS_ERR=""
# Issues unreadable: no queue, no PRs, no inbox, and it says so where blocked issues would be.
ISSUES_OUT="" ISSUES_RC=1 ISSUES_ERR="HTTP 502: Bad Gateway"
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "unreadable issues: unknown, not empty" "$(jq -c '[.issues, .prs, .inbox]' <<<"${r}")" "[null,null,null]"
expect "10. a failure it does not recognise: unknown, never a guess" "$(jq -c '[.unreadable[] | [.part, .cause]]' <<<"${r}")" '[["issues","unknown"]]'
expect "and two unknowns wait (issues, inbox)" "$(jq -r '[.waiting[] | select(.kind == "unknown")] | length' <<<"${r}")" 2
ISSUES_OUT="${ISSUES_OK}" ISSUES_RC=0 ISSUES_ERR=""

# 2. the ledger's three states
Q2_OUT="$(q2 '{"text":"","isTruncated":true}' 'null')"
RAW_LEDGER="${ROW1}"$'\n{broken\n'"${ROW2}"
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "a truncated ledger blob is read again in full, a broken line skipped" "$(jq -c '[.stats.coder.runs, .stats.fixer.runs]' <<<"${r}")" "[1,1]"
expect "no breaker file yet: no breaker tripped" "$(jq -c .breakers <<<"${r}")" "{}"
Q2_OUT="$(q2 'null' 'null')"
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "no ledger yet: no runs, nothing unreadable" "$(jq -c '[.stats.coder.runs, .errors]' <<<"${r}")" "[0,[]]"
Q2_OUT="$(q2 "$(jq -nc --arg t "${ROW1}" '{text: $t, isTruncated: false}')" '{"text":"[not an object]","isTruncated":false}')"
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "a broken breaker file: the breaker is unknown, the runs still read" "$(jq -c '[.breakers, .stats.coder.runs]' <<<"${r}")" "[null,1]"
expect "and a stopped role could hide there: it waits as unknown" "$(jq -r '[.waiting[] | select(.kind == "unknown")] | length' <<<"${r}")" 1
Q2_OUT="" Q2_RC=1 Q2_ERR="HTTP 502: Bad Gateway"
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "an unreadable ledger is unknown, never zero" "$(jq -c '[.stats, .runs, .breakers]' <<<"${r}")" "[null,null,null]"
expect "and says so" "$(jq -r '.errors[0]' <<<"${r}" | cut -c1-7)" "ledger:"
unset Q2_RC Q2_ERR

# A repository that cannot be read at all: everything that could wait is unknown, not nothing.
stub_gh_reset_rules
stub_gh_on "${Q1}" "" 1 "HTTP 502: Bad Gateway"
r="$(get '/api/repo/o/r?fresh=1')"
expect "an unreadable repository waits as unknown" "$(jq -c '[.waiting[].kind]' <<<"${r}")" '["unknown"]'

# 10. Why: each failed read carries its cause. A SAML refusal on the whole repository:
stub_gh_reset_rules
stub_gh_on "${Q1}" "" 1 $'gh: Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization. (HTTP 403)\nAuthorize in your web browser: https://github.com/orgs/o/sso?authorization_request=x'
r="$(get '/api/repo/o/r?fresh=1')"
expect "a SAML-protected repository: sso" "$(jq -c '[.unreadable[] | [.part, .cause]]' <<<"${r}")" '[["repository","sso"]]'
expect "and the text is still there" "$(jq -r '.errors[0][:11]' <<<"${r}")" "repository:"
stub_gh_reset_rules
stub_gh_on "${Q1}" '{"data":{"repository":null}}'
r="$(get '/api/repo/o/r?fresh=1')"
expect "a repository GitHub returns as null: not_found" "$(jq -c '[.unreadable[] | [.part, .cause]]' <<<"${r}")" '[["repository","not_found"]]'
# The ledger rate-limited: when the exhausted (GraphQL) limit resets, read from /rate_limit.
Q2_OUT="" Q2_RC=1 Q2_ERR="gh: API rate limit exceeded for user ID 1. (HTTP 403)"
RATE_OUT='{"resources":{"core":{"remaining":4999,"limit":5000,"reset":1794661200},"graphql":{"remaining":0,"limit":5000,"reset":1794661200}}}'
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "a rate-limited ledger: rate_limited, with the reset time" "$(jq -c '[.unreadable[] | [.part, .cause, .resets_at]]' <<<"${r}")" '[["ledger","rate_limited","2026-11-14T13:00:00Z"]]'
unset Q2_RC Q2_ERR RATE_OUT
# A failed request as a whole (the page's d.failed, the gate's and the inbox's error): the 502 says why.
# The repository is read (and cached) first: the inbox endpoint needs its inbox issue.
rules
get '/api/repo/o/r?fresh=1' >/dev/null
stub_gh_reset_rules
stub_gh_on "api repos/o/r/actions/workflows/agent-merge.yml/runs?status=completed&per_page=30" "" 4 $'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.'
stub_gh_on "api graphql -f name=r -F number=7 -f owner=o -f query=query(\$owner*" '{"data":null,"errors":[{"type":"NOT_FOUND","message":"Could not resolve to an Issue with the number of 7."}]}' 1 "gh: Could not resolve to an Issue with the number of 7."
c="$(curl -s -o "${TMP}/gate.json" -w '%{http_code}' -H "X-Gatehand-Token: ${TOKEN}" "${B}/api/repo/o/r/gate?fresh=1")"
expect "a signed-out gh: the gate's 502 says signed_out" "${c} $(jq -r .cause "${TMP}/gate.json")" "502 signed_out"
expect "an inbox GraphQL can no longer resolve: not_found, from the error's type" "$(get '/api/repo/o/r/inbox?fresh=1' | jq -c '[.cause, (.error | startswith("gh api graphql"))]')" '["not_found",true]'
rules
# A first scan that fails: the session still loads, with the scan's cause (a second server, never scanned).
stub_gh_reset_rules
stub_gh_on "api graphql -f query=query(\$cursor*" "" 1 "gh: Bad credentials (HTTP 401)"
stub_gh_on "api user" '{"login":"owner-login"}'
stub_gh_on "api rate_limit" "${RATE_OK}"
python3 "${PKG}/bin/dashboard.py" --no-open --idle-minutes 0 --config "${TMP}/cfg2/dashboard.json" --ready-file "${TMP}/ready2" >"${TMP}/srv2.log" 2>&1 &
SRV2=$!
for _ in $(seq 1 50); do jq -e .port "${TMP}/ready2" >/dev/null 2>&1 && break; sleep 0.1; done
s2="$(curl -s -H "X-Gatehand-Token: $(jq -r .token "${TMP}/ready2")" "http://127.0.0.1:$(jq -r .port "${TMP}/ready2")/api/session")"
kill "${SRV2}" 2>/dev/null
expect "a first scan that fails: scan_cause beside scan_error" "$(jq -c '[.scan_cause.cause, (.scan_error | test("HTTP 401"))]' <<<"${s2}")" '["signed_out",true]'
rules
# A scan an organisation's SAML enforcement hides part of: each note carries its cause.
stub_gh_reset_rules
stub_gh_on "api graphql -f query=query(\$cursor*" '{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":false},"nodes":[{"nameWithOwner":"o/r","isArchived":false,"lock":{"oid":"1"}},null]}}},"errors":[{"type":"FORBIDDEN","path":["viewer","repositories","nodes",1],"message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization."}]}' 1 "gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization."
s3="$(curl -s -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: application/json" -d '{"op":"rescan"}' "${B}/api/repos")"
expect "a partly hidden scan: the note and its cause" "$(jq -c '[.repos, .scan_notes == [.scan_unreadable[0].error], [.scan_unreadable[].cause]]' <<<"${s3}")" '[["o/r"],true,["sso"]]'
rules
expect "a clean scan clears them" "$(curl -s -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: application/json" -d '{"op":"rescan"}' "${B}/api/repos" | jq -c '[.scan_notes, .scan_unreadable]')" '[[],[]]'

# 6. read only. An allowlist of read shapes, not a list of write ones: a GraphQL call must be a
# `query` (not a mutation) and its only typed value a number; a REST call is `api` with no -f/-F/-X/
# --method/--input (gh POSTs whenever a field is given).
reads='^api (graphql( -(f [a-zA-Z]+=[^ ]*|F [a-zA-Z]+=[0-9]+))* -f query=query[({].*|(-H Accept: application/vnd\.github\.raw |--allow-escape-sequences )?(user|rate_limit|repos/[^ ]+))$'
# One call per line: a query's own newlines become spaces, each call starts at "api ".
calls="$(stub_gh_calls | tr '\n' ' ' | sed -E 's/ (api |issue |pr |run |workflow |variable |label )/\n\1/g; s/ +$//')"
writes="$(grep -vE "${reads}" <<<"${calls}" | grep -v '^issue comment 7 --body-file' || true)" # that one is inbox_request's, above
expect "every gh call was a read" "${writes}" ""
expect "no GraphQL call names a mutation" "$(grep -ci 'mutation' <<<"${calls}")" 0
for w in 'api graphql -f query=mutation{addComment}' 'api repos/o/r/issues/7/comments -f body=hi' 'run cancel 5' \
  'api -XPOST repos/o/r/x' 'api --method PATCH repos/o/r/x' 'api repos/o/r/x --input -'; do
  if grep -qE "${reads}" <<<"${w}"; then t_fail "the read allowlist lets a write through: ${w}"; else t_pass "the read allowlist refuses: ${w}"; fi
done


# 7. writes, as the viewer
stub_gh_reset_calls
INBOX_ISSUE='{"number":7,"state":"open","body":"<!-- agent-inbox -->\nanswer here","user":{"login":"owner-login"}}'
item() { jq -nc --argjson n "$1" --arg s "${2:-open}" --argjson pr "${3:-false}" '{number: $n, state: $s} + (if $pr then {pull_request: {}} else {} end)'; }
wrules() {
  rules
  stub_gh_on "api repos/o/r/issues/7" "${INBOX_ISSUE}"
  stub_gh_on "api repos/o/r/issues/42" "$(item 42)"
  stub_gh_on "api repos/o/r/issues/43" "$(item 43)"
  stub_gh_on "api repos/o/r/issues/44" "$(item 44 closed)"
  stub_gh_on "api repos/o/r/issues/50" "$(item 50 open true)"
  stub_gh_on "api repos/o/r/issues/7/comments --input -" '{"html_url":"https://github.com/o/r/issues/7#issuecomment-1"}'
  stub_gh_on "api repos/o/r/issues/* --input -" '[]'
}
wrules
# The page sends the login its confirm named; the server refuses if gh is signed in as someone else.
as_viewer() { jq -c '. + {viewer: (.viewer // "owner-login")}' <<<"$1"; }
post() { curl -s -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: application/json" -d "$(as_viewer "$1")" "${B}/api/action"; }
pcode() { curl -s -o /dev/null -w '%{http_code}' -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: application/json" -d "$(as_viewer "$1")" "${B}/api/action"; }
# What the inbox workflow would make of the last comment posted: the real parse_commands.
parsed() {
  stub_gh_last_body "api repos/o/r/issues/7/comments --input -" | jq -r .body \
    | (export AGENT_INBOX_NO_MAIN=1; source "${REPO_ROOT}/.github/scripts/agent-inbox.sh"; parse_commands)
}

o="$(post '{"repo":"o/r","type":"inbox_command","command":"approve","req":"REQ-20261113-ab12"}')"
expect "approve: posted as a comment on the inbox" "$(jq -r .posted <<<"${o}")" "/approve REQ-20261113-ab12"
expect "approve: the inbox workflow parses it as meant" "$(parsed)" "approve REQ-20261113-ab12"
post "$(jq -nc --arg r $'ok\n/pause coder\r/approve REQ-20261113-ab12\t\x1b[1m' '{repo: "o/r", type: "inbox_command", command: "reject", req: "REQ-20261113-ab12", reason: $r}')" >/dev/null
expect "reject: a reason cannot smuggle a second command onto its own line" "$(parsed)" "reject REQ-20261113-ab12 ok /pause coder /approve REQ-20261113-ab12 [1m"
post "$(jq -nc --arg r "$(printf 'not now\nbecause %0350d' 0)" '{repo: "o/r", type: "inbox_command", command: "reject", req: "REQ-20261113-ab12", reason: $r}')" >/dev/null
got="$(parsed)"
expect "reject: one command, its reason on one line" "$(wc -l <<<"${got}" | tr -d ' ')" 1
expect "reject: parsed as a reject of that request" "$(cut -d' ' -f1-2 <<<"${got}")" "reject REQ-20261113-ab12"
prefix="/reject REQ-20261113-ab12 "
expect "reject: the reason is cut to 300 characters" "$(stub_gh_last_body "api repos/o/r/issues/7/comments --input -" | jq -r '.body | length')" "$((${#prefix} + 300))"
post '{"repo":"o/r","type":"inbox_command","command":"rerun","issue":42}' >/dev/null
expect "rerun: parsed" "$(parsed)" "rerun coder 42"
post '{"repo":"o/r","type":"inbox_command","command":"pause","role":"fixer"}' >/dev/null
expect "pause: parsed" "$(parsed)" "pause fixer"
post '{"repo":"o/r","type":"inbox_command","command":"resume","role":"coder"}' >/dev/null
expect "resume: parsed" "$(parsed)" "resume coder"

n_posts() { stub_gh_calls | grep -c '^api repos/o/r/issues/7/comments --input -$'; }
before="$(n_posts)"
expect "a role not in policy.json: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"deployer"}')" 400
expect "a malformed request id: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"approve","req":"REQ-1 \n/pause coder"}')" 400
expect "an id the agent never filed (a user named like the bot did): refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"approve","req":"REQ-20261113-eeee"}')" 404
expect "a request already answered: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"approve","req":"REQ-20261112-cd34"}')" 409
expect "rerun of true (a bool is not a number): refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"rerun","issue":true}')" 400
expect "rerun of a non-number: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"rerun","issue":"42"}')" 400
expect "an unknown command: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"merge"}')" 400
VARS_OUT='{"variables":[{"name":"AGENT_OWNER_LOGIN","value":"Owner-Login"}]}'; wrules
expect "the owner login must match to the letter, as agent-inbox.sh compares it" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 403
VARS_OUT='{"variables":[]}'; wrules
expect "no AGENT_OWNER_LOGIN: nobody can answer" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
VARS_OUT="" VARS_RC=1 VARS_ERR="HTTP 403"; wrules
expect "variables unreadable: cannot tell who may answer" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
VARS_OUT="${VARS_OK}" VARS_RC=0 VARS_ERR=""
INBOX_ISSUE='{"number":7,"state":"open","body":"<!-- agent-inbox -->","user":{"login":"mallory"}}'; wrules
expect "an inbox the workflow would not answer (opened by someone else): refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
INBOX_ISSUE='{"number":7,"state":"closed","body":"<!-- agent-inbox -->","user":{"login":"owner-login"}}'; wrules
expect "a closed inbox: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
INBOX_ISSUE='{"number":7,"state":"open","body":"<!-- agent-inbox -->","user":{"login":"owner-login"},"pull_request":{}}'; wrules
expect "an inbox that is a PR: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
INBOX_ISSUE='{"number":7,"state":"open","body":"no marker","user":{"login":"owner-login"}}'; wrules
expect "an inbox without the literal marker: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
INBOX_ISSUE='{"number":7,"state":"open","body":"<!-- agent-inbox -->","user":{"login":"owner-login"}}'; wrules
# A command already sent and not yet answered: a second one would be applied by a second run at once.
INBOX_EXTRA='[{"author":{"__typename":"User","login":"owner-login"},"body":"/approve REQ-20261113-ab12","createdAt":"2026-11-14T11:58:00Z"}]'; wrules
expect "a request with an answer on its way shows as pending" "$(get '/api/repo/o/r/inbox?fresh=1' | jq -c '[.awaiting_reply, (.requests[] | select(.id == "REQ-20261113-ab12") | .pending)]')" "[true,true]"
expect "a second command while one waits for the inbox workflow: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"reject","req":"REQ-20261113-ab12"}')" 409
INBOX_EXTRA='[{"author":{"__typename":"User","login":"owner-login"},"body":"/approve REQ-20261113-ab12","createdAt":"2026-11-14T11:58:00Z"},
  {"author":{"__typename":"Bot","login":"gatehand"},"body":"<!-- agent-req:REQ-20261114-ffff role=fixer issue=9 kind=merger -->\n### x","createdAt":"2026-11-14T11:59:00Z"}]'; wrules
expect "a new request the bot files meanwhile is not a reply: still waiting" "$(get '/api/repo/o/r/inbox?fresh=1' | jq -c .awaiting_reply)" "true"
INBOX_EXTRA='[{"author":{"__typename":"User","login":"owner-login"},"body":"/approve REQ-20261113-ab12","createdAt":"2026-11-14T11:58:00Z"},
  {"author":{"__typename":"Bot","login":"gatehand"},"body":"- applied\n<!-- agent-answer:REQ-20261113-ab12 -->","createdAt":"2026-11-14T11:59:00Z"}]'; wrules
expect "the bot's reply ends the wait" "$(get '/api/repo/o/r/inbox?fresh=1' | jq -c '[.awaiting_reply, (.requests[] | select(.id == "REQ-20261113-ab12") | [.answered, .pending])]')" "[false,[true,false]]"
INBOX_EXTRA='[{"author":{"__typename":"User","login":"owner-login"},"body":"/approve REQ-20261113-ab12","createdAt":"2026-11-14T11:00:00Z"}]'; wrules
expect "one that never got an answer stops blocking after ten minutes" "$(get '/api/repo/o/r/inbox?fresh=1' | jq -c .awaiting_reply)" "false"
INBOX_EXTRA='[]'
Q1_SAVE="${POLICY}"; POLICY='[1]'; wrules
expect "policy.json unreadable: refused" "$(pcode '{"repo":"o/r","type":"inbox_command","command":"pause","role":"coder"}')" 409
POLICY="${Q1_SAVE}"; wrules
expect "nothing was posted for any refusal" "$(n_posts)" "${before}"

# labels
post '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":43}' >/dev/null
expect "hold: the label goes on as you" "$(stub_gh_last_body "api repos/o/r/issues/43/labels --input -" | jq -c .)" '{"labels":["agent:hold"]}'
expect "agent:ready is never added from the page (it vouches for text the page does not show)" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:ready","number":43}')" 400
expect "a number that is a bool: refused" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":true}')" 400
o="$(post '{"repo":"o/r","type":"label","op":"remove","label":"agent:blocked","number":50}')"
expect "hand back: the label comes off the PR" "$(stub_gh_calls | tail -1)" "api -X DELETE repos/o/r/issues/50/labels/agent%3Ablocked"
expect "and says what it did" "$(jq -r .done <<<"${o}")" "removed agent:blocked from #50"
expect "agent:ready off a PR: refused" "$(pcode '{"repo":"o/r","type":"label","op":"remove","label":"agent:ready","number":50}')" 400
expect "agent:blocked off an issue (that is /rerun): refused" "$(pcode '{"repo":"o/r","type":"label","op":"remove","label":"agent:blocked","number":42}')" 400
expect "agent:allow-protected: never" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:allow-protected","number":42}')" 400
expect "a label on the inbox issue itself: refused" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":7}')" 409
expect "a closed issue: refused" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":44}')" 409
PERM=TRIAGE; wrules
expect "without write access a label would not count: refused" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":42}')" 403
PERM=ADMIN; wrules
expect "a repository not on the list: refused" "$(pcode '{"repo":"o/plain","type":"label","op":"add","label":"agent:hold","number":42}')" 404
expect "gh signed in as someone other than the page says: refused" "$(pcode '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":42,"viewer":"someone-else"}')" 409
expect "an unknown action: refused" "$(pcode '{"repo":"o/r","type":"merge"}')" 400
expect "an action without the secret: refused" "$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: ${B}" -H "Content-Type: application/json" -d '{"repo":"o/r","type":"label","op":"add","label":"agent:hold","number":42}' "${B}/api/action")" 401

# The only writes: a comment on the inbox, a label on, a label off.
calls="$(stub_gh_calls | tr '\n' ' ' | sed -E 's/ (api )/\n\1/g; s/ +$//')"
writes="$(grep -vE "${reads}" <<<"${calls}" | grep -vE '^api repos/o/r/issues/7/comments --input -$|^api repos/o/r/issues/4[23]/labels --input -$|^api -X DELETE repos/o/r/issues/50/labels/agent%3Ablocked$' || true)"
expect "no other write was made" "${writes}" ""

# 8. runs, verdicts, switches: preview, then confirm
stub_gh_reset_calls
SHA=0123456789abcdef0123456789abcdef01234567
RUNNER="$(jq -r '.runnerRef' <<<"${POLICY}")"
BOT="$(jq -r '.botLogin' <<<"${POLICY}")" BASE="$(jq -r '.baseBranch' <<<"${POLICY}")"
PR50="$(jq -nc --arg sha "${SHA}" --arg bot "${BOT}" --arg base "${BASE}" '{number: 50, state: "open", draft: false, user: {login: $bot},
  labels: [{name: "agent:pr"}], base: {ref: $base}, head: {sha: $sha, ref: "fix/agent-50-x", repo: {full_name: "o/r"}}}')"
FIX_SHA_RUNNER=f1 PR50_COMMENTS='[]'
CODER_RUNS='{"workflow_runs":[{"id":1,"status":"in_progress","display_title":"Agent coder: issue 43"}]}'
Q2_OUT="$(q2 'null' 'null')" # the runner ref matches main
xrules() {
  wrules
  stub_gh_on "api repos/o/r/pulls/50" "${PR50}"
  stub_gh_on "api repos/o/r/pulls/51" '{"number":51,"state":"open","labels":[{"name":"agent:pr"}],"head":{"sha":"'"${SHA}"'","repo":{"full_name":"mallory/r"}}}'
  stub_gh_on "api repos/o/r/pulls/52" '{"number":52,"state":"open","labels":[],"head":{"sha":"'"${SHA}"'","repo":{"full_name":"o/r"}}}'
  stub_gh_on "api repos/o/r/pulls/53" '{"number":53,"state":"open","labels":[{"name":"agent:pr"},{"name":"agent:blocked"}],"head":{"sha":"'"${SHA}"'","repo":{"full_name":"o/r"}}}'
  stub_gh_on "api repos/o/r/actions/workflows/agent-coder.yml/runs?event=workflow_dispatch&per_page=30" "${CODER_RUNS}"
  stub_gh_on "api repos/o/r/contents/.github/workflows/agent-fixup.yml?ref=$(jq -rn --arg r "${RUNNER}" '$r|@uri')" "{\"sha\":\"${FIX_SHA_RUNNER}\"}"
  stub_gh_on "api repos/o/r/contents/.github/workflows/agent-fixup.yml?ref=main" '{"sha":"f1"}'
  stub_gh_on "api repos/o/r/issues/50/comments?per_page=100&page=1" "${PR50_COMMENTS}"
  stub_gh_on "api repos/o/r/actions/runs/1" '{"id":1,"path":".github/workflows/agent-coder.yml","status":"in_progress","display_title":"Agent coder: issue 43"}'
  stub_gh_on "api repos/o/r/actions/runs/2" '{"id":2,"path":".github/workflows/ci.yml","status":"in_progress"}'
  stub_gh_on "api repos/o/r/actions/runs/3" '{"id":3,"path":".github/workflows/agent-merge.yml","status":"completed"}'
  stub_gh_on "api -X POST repos/o/r/actions/workflows/agent-fixup.yml/dispatches --input -" "" "${FIX_RC:-0}" "${FIX_ERR:-}"
  stub_gh_on "api -X POST repos/o/r/actions/workflows/*/dispatches --input -" ""
  stub_gh_on "api -X POST repos/o/r/actions/runs/*/cancel" ""
  stub_gh_on "api -X POST repos/o/r/issues/*/comments --input -" '{"id":777,"html_url":"https://github.com/o/r/pull/50#issuecomment-777"}'
  stub_gh_on "api -X PATCH repos/o/r/actions/variables/* --input -" ""
  stub_gh_on "api -X POST repos/o/r/actions/variables --input -" ""
}
xrules
preview() { curl -s -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: application/json" -d "$(as_viewer "$1")" "${B}/api/action/preview"; }
# confirm <action> [preview-of]: preview (that one, or the action itself), then send the action with its token.
confirm() { local p; p="$(preview "${2:-$1}")"; post "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '. + {confirm: $t}' <<<"$1")"; }
ccode() { local p; p="$(preview "${2:-$1}")"; pcode "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '. + {confirm: $t}' <<<"$1")"; }
vcode() { curl -s -o /dev/null -w '%{http_code}' -H "X-Gatehand-Token: ${TOKEN}" -H "Origin: ${B}" -H "Content-Type: application/json" -d "$(as_viewer "$1")" "${B}/api/action/preview"; }
last_dispatch() { stub_gh_last_body "api -X POST repos/o/r/actions/workflows/$1/dispatches --input -" | jq -c .; }
# The inputs a rendered workflow declares under workflow_dispatch, sorted.
wf_inputs() { awk '/^  workflow_dispatch:/{w=1; next} w && /^    inputs:/{i=1; next} w && /^  [a-z]/{exit} i && /^      [a-z_]+:$/{sub(/^ +/, ""); sub(/:$/, ""); print}' \
  "${REPO_ROOT}/.github/workflows/$1" | sort | tr '\n' ' ' | sed 's/ $//'; }
# A script's own check of an input, taken from the rendered file: script_re <file> <var>.
script_re() { grep -oE "\"\\\$\\{$2\\}\" =~ [^ ]+" "${REPO_ROOT}/$1" | head -1 | sed -E 's/^[^~]*~ //'; }
matches() { local re; re="$(script_re "$1" "$2")"; [[ -n "${re}" && "$3" =~ ${re} ]] && echo yes || echo no; }

C43='{"repo":"o/r","type":"dispatch","workflow":"coder"}'
p="$(preview "${C43}")"
expect "coder: the preview names the exact call, on the runner ref" "$(jq -r '.calls[0]' <<<"${p}")" \
  "POST repos/o/r/actions/workflows/agent-coder.yml/dispatches {\"ref\": \"${RUNNER}\"}"
expect "coder: a running coder run is named (this one waits for it)" "$(jq -r '.warnings[0]' <<<"${p}")" "Agent coder: issue 43 is running: this run waits for it to finish"
expect "nothing is done by a preview" "$(stub_gh_calls | grep -c -- '-X ')" 0
o="$(post "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '. + {confirm: $t}' <<<"${C43}")")"
expect "coder: confirmed, it is started" "$(jq -r .done <<<"${o}")" "started the coder on the next queued issue"
expect "coder: an auto pick, as previewed, no inputs" "$(last_dispatch agent-coder.yml)" "{\"ref\":\"${RUNNER}\"}"
expect "a confirm token is spent once" "$(pcode "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '. + {confirm: $t}' <<<"${C43}")")" 409
expect "no token: refused" "$(pcode "${C43}")" 409
expect "a token for another action: refused" "$(ccode "${C43}" '{"repo":"o/r","type":"dispatch","workflow":"merge"}')" 409
# A run named for an issue skips the check that a writer queued it (labeler_trusted): never from the page.
expect "coder on a named issue: refused" "$(vcode '{"repo":"o/r","type":"dispatch","workflow":"coder","issue":43}')" 400
# A run starts waiting between the preview and the confirm: the confirm would cancel it.
p="$(preview "${C43}")"
CODER_RUNS='{"workflow_runs":[{"id":1,"status":"in_progress","display_title":"Agent coder: issue 43"},{"id":12,"status":"pending","display_title":"Agent coder: issue 42"}]}'; xrules
before="$(stub_gh_calls | grep -c 'agent-coder.yml/dispatches')"
expect "a coder run that started waiting since the preview: refused" "$(pcode "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '. + {confirm: $t}' <<<"${C43}")")" 409
expect "and the dispatch was not made" "$(stub_gh_calls | grep -c 'agent-coder.yml/dispatches')" "${before}"
expect "the preview says GitHub would cancel the waiting run" "$(preview "${C43}" | jq -r '.warnings[1]')" \
  "Agent coder: issue 42 is already waiting to start: GitHub cancels it and keeps this one instead"
CODER_RUNS='{"workflow_runs":[]}'; xrules
expect "a workflow that is not one of the page's: refused" "$(vcode '{"repo":"o/r","type":"dispatch","workflow":"sweep"}')" 400
VARS_OUT='{"variables":[{"name":"AGENTS_ENABLED","value":"false"},{"name":"AGENT_OWNER_LOGIN","value":"owner-login"}]}'; xrules
expect "the agents off: a coder run would be skipped, refused" "$(vcode "${C43}")" 409
VARS_OUT="${VARS_OK}"
Q2_SAVE="${Q2_OUT}"; Q2_OUT="$(jq -c '.data.repository.wfRunner.oid = "b"' <<<"${Q2_OUT}")"; xrules
expect "a stale runner ref: the coder would refuse, so is the dispatch" "$(vcode "${C43}")" 409
Q2_OUT="${Q2_SAVE}"; xrules

confirm '{"repo":"o/r","type":"dispatch","workflow":"review","pr":50}' >/dev/null
expect "review: on the default branch, the PR as claude-code-review.yml checks it" "$(last_dispatch claude-code-review.yml)" '{"ref":"main","inputs":{"pr":"50"}}'
expect "review: its input is the one the workflow declares" "$(wf_inputs claude-code-review.yml)" "pr"
expect "review: the shape the fork guard accepts" "$(matches .github/workflows/claude-code-review.yml PR 50)" yes
expect "review of a fork's PR: refused" "$(vcode '{"repo":"o/r","type":"dispatch","workflow":"review","pr":51}')" 409
confirm '{"repo":"o/r","type":"dispatch","workflow":"merge","pr":50}' >/dev/null
expect "merge gate on one PR: default branch, pr" "$(last_dispatch agent-merge.yml)" '{"ref":"main","inputs":{"pr":"50"}}'
expect "merge gate: its input is the one the workflow declares" "$(wf_inputs agent-merge.yml)" "pr"
expect "merge gate: the shape agent-merge.sh accepts" "$(matches .github/scripts/agent-merge.sh want 50)" yes
confirm '{"repo":"o/r","type":"dispatch","workflow":"merge"}' >/dev/null
expect "merge gate on every PR: no inputs" "$(last_dispatch agent-merge.yml)" '{"ref":"main"}'
expect "merge gate, auto-merge off: the preview says dry run" "$(preview '{"repo":"o/r","type":"dispatch","workflow":"merge"}' | jq -r .effect | cut -c1-9)" "a dry run"

confirm '{"repo":"o/r","type":"cancel_run","run":1}' >/dev/null
expect "cancel: a Gatehand run" "$(stub_gh_calls | tail -1)" "api -X POST repos/o/r/actions/runs/1/cancel"
expect "cancel of another workflow's run: refused" "$(vcode '{"repo":"o/r","type":"cancel_run","run":2}')" 400
expect "cancel of a finished run: refused" "$(vcode '{"repo":"o/r","type":"cancel_run","run":3}')" 409

# Verdicts: what the merge gate and the fixer will read, through agent-state.sh's own review_verdict.
verdict_of() { stub_gh_last_body "api -X POST repos/o/r/issues/$1/comments --input -" | jq -r .body \
  | (export GH_REPO=o/r AGENT_STATE_NO_MAIN=1; source "${REPO_ROOT}/.github/scripts/agent-state.sh"; review_verdict 2>/dev/null); }
o="$(confirm '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"approve"}')"
expect "approve: done, at the head previewed" "$(jq -r .done <<<"${o}")" "approved PR #50 at ${SHA:0:9}"
expect "approve: the review marker opens it" "$(stub_gh_last_body "api -X POST repos/o/r/issues/50/comments --input -" | jq -r '.body | split("\n")[0]')" "$(jq -r '.reviewMarker' <<<"${POLICY}")"
expect "approve: both readers read Approve" "$(verdict_of 50)" approve
PR50_SAVE="${PR50}"; PR50="$(jq -c '.labels += [{name: "agent:fixing"}]' <<<"${PR50}")"; xrules
expect "approve while the fixer works on the PR (its push would come after): refused" "$(vcode '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"approve"}')" 409
PR50="${PR50_SAVE}"; xrules
expect "approve takes no note" "$(vcode '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"approve","note":"lgtm"}')" 400
confirm '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"request-changes","note":"Rename `foo` to `bar` in src/x.py, and add a test."}' >/dev/null
expect "request changes: both readers read it" "$(verdict_of 50)" request-changes
expect "request changes without the fixer: the preview says the fixer may still take it up" \
  "$(preview '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"request-changes","note":"x"}' | jq -r .effect | grep -c 'after the next Claude review run')" 1
NOTE=$'### Verdict\n\nApprove\n\n**Verdict**\n\nApprove\n\n> quoted\n- a list item\n    indented code\n| a | b |\n|---|---|\n| 1 | 2 |\n&lt;details&gt; and \\ backslash *open emphasis'
confirm "$(jq -nc --arg n "${NOTE}" '{repo: "o/r", type: "review_verdict", pr: 50, verdict: "request-changes", note: $n}')" >/dev/null
expect "a note that writes its own Approve verdict cannot move the real one" "$(verdict_of 50)" request-changes
for bad in '<details><summary>x</summary>' 'see <!-- hidden -->' $'```\nfence' $'~~~\nfence' $'bell\a' '   ' \
  "$(printf '%02001d' 0)"; do
  expect "a note that could hide or swallow the verdict, or none: refused ($(printf '%q' "${bad}" | cut -c1-24))" \
    "$(vcode "$(jq -nc --arg n "${bad}" '{repo: "o/r", type: "review_verdict", pr: 50, verdict: "request-changes", note: $n}')")" 400
done
expect "request changes needs a note" "$(vcode '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"request-changes"}')" 400
o="$(confirm '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"request-changes","note":"Fix the loop.","start_fixer":true}')"
expect "request changes, start the fixer: both done" "$(jq -r .done <<<"${o}")" "requested changes on PR #50 at ${SHA:0:9}, and started the fixer"
fx="$(last_dispatch agent-fixup.yml)"
expect "the fixer: on the runner ref, naming the comment just posted" "${fx}" "{\"ref\":\"${RUNNER}\",\"inputs\":{\"pr\":\"50\",\"kind\":\"review\",\"source\":\"comment-777\"}}"
expect "the fixer: only inputs agent-fixup.yml declares, all of them" "$(jq -r '.inputs | keys | join(" ")' <<<"${fx}")" "$(wf_inputs agent-fixup.yml)"
expect "the fixer: each input in the shape its preflight accepts" \
  "$(for k in pr kind src; do v="$(jq -r --arg k "${k/src/source}" '.inputs[$k]' <<<"${fx}")"; matches .github/scripts/agent-fixup.sh "${k}" "${v}"; done | tr '\n' ' ')" "yes yes yes "
expect "the fixer on a blocked PR: refused, nothing posted" "$(vcode '{"repo":"o/r","type":"review_verdict","pr":53,"verdict":"request-changes","note":"x","start_fixer":true}')" 409
FIXR='{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"request-changes","note":"x","start_fixer":true}'
for mut in '.draft = true' '.user.login = "someone"' '.base.ref = "release"' '.head.ref = "fix/mine"'; do
  PR50="$(jq -c "${mut}" <<<"${PR50_SAVE}")"; xrules
  expect "the fixer on a PR its pr_refusal turns down: refused (${mut})" "$(vcode "${FIXR}")" 409
done
PR50="${PR50_SAVE}"; FIX_SHA_RUNNER=f0; xrules
expect "the fixer while the runner ref's agent-fixup.yml is not main's: refused" "$(vcode "${FIXR}")" 409
FIX_SHA_RUNNER=f1
PR50_COMMENTS="$(jq -nc --arg bot "${BOT}" '[{user: {login: $bot}, body: "<!-- agent:fix-lock kind=review n=1 run=91 sha=abc source=comment-5 expires=x -->"},
  {user: {login: "mallory"}, body: "<!-- agent:fix-no-attempt run=91 -->"}]')"; xrules
expect "the fixer past its review-fix cap (it would block the PR instead): refused" "$(vcode "${FIXR}")" 409
PR50_COMMENTS="$(jq -c --arg bot "${BOT}" '.[1].user.login = $bot' <<<"${PR50_COMMENTS}")"; xrules
expect "a fix the bot voided (it never reached the model) does not count" "$(vcode "${FIXR}")" 200
PR50_COMMENTS='[]'; xrules
Q2_SAVE="${Q2_OUT}"; Q2_OUT="$(q2 'null' "$(jq -nc '{text: ({fixer: {tripped_at: "2026-11-14T07:00:00Z"}} | tojson), isTruncated: false}')")"; xrules
expect "the fixer while its breaker is tripped: refused" "$(vcode "${FIXR}")" 409
Q2_OUT="$(q2 "$(jq -nc --arg t "$(for _ in $(seq 1 "$(jq '.roles.fixer.runsPerDay' <<<"${POLICY}")"); do printf '{"role":"fixer","outcome":"fix-pushed","started_at":"2026-11-14T08:00:00Z"}\n'; done)" '{text: $t, isTruncated: false}')" 'null')"; xrules
expect "the fixer with today's runs used up: refused" "$(vcode "${FIXR}")" 409
Q2_OUT="${Q2_SAVE}"; xrules
FIX_RC=1 FIX_ERR="HTTP 500"; xrules
o="$(confirm '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"request-changes","note":"Fix it.","start_fixer":true}')"
expect "the comment posted, the fixer failed: it says which was done" "$(jq -r .error <<<"${o}" | cut -c1-54)" "done: POST repos/o/r/issues/50/comments; then failed: "
FIX_RC=0 FIX_ERR=""; xrules
expect "a verdict on a PR that is not an agent PR: refused" "$(vcode '{"repo":"o/r","type":"review_verdict","pr":52,"verdict":"approve"}')" 409
expect "a verdict that is neither: refused" "$(vcode '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"lgtm"}')" 400
# The head moves between the preview and the confirm: the verdict would be of a diff nobody read.
p="$(preview '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"approve"}')"
PR50="$(jq -c '.head.sha = "fedcba9876543210fedcba9876543210fedcba98"' <<<"${PR50}")"; xrules
before="$(stub_gh_calls | grep -c 'issues/50/comments')"
expect "a head that moved since the preview: refused" "$(pcode "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '{repo: "o/r", type: "review_verdict", pr: 50, verdict: "approve", confirm: $t}' <<<'{}')")" 409
expect "and nothing was posted" "$(stub_gh_calls | grep -c 'issues/50/comments')" "${before}"

# Switches
confirm '{"repo":"o/r","type":"set_variable","name":"AGENT_AUTO_MERGE","value":"true"}' >/dev/null
expect "auto-merge on (not set yet): created" "$(stub_gh_last_body "api -X POST repos/o/r/actions/variables --input -" | jq -c .)" '{"name":"AGENT_AUTO_MERGE","value":"true"}'
confirm '{"repo":"o/r","type":"set_variable","name":"AGENTS_ENABLED","value":"false"}' >/dev/null
expect "agents off: updated" "$(stub_gh_calls | tail -1)" "api -X PATCH repos/o/r/actions/variables/AGENTS_ENABLED --input -"
expect "and the value is the string false" "$(stub_gh_last_body "api -X PATCH repos/o/r/actions/variables/AGENTS_ENABLED --input -" | jq -c .)" '{"name":"AGENTS_ENABLED","value":"false"}'
expect "already that value: refused" "$(vcode '{"repo":"o/r","type":"set_variable","name":"AGENTS_ENABLED","value":"true"}')" 409
expect "a value that is not \"true\" or \"false\": refused" "$(vcode '{"repo":"o/r","type":"set_variable","name":"AGENT_AUTO_MERGE","value":true}')" 400
expect "any other variable: refused" "$(vcode '{"repo":"o/r","type":"set_variable","name":"AGENT_OWNER_LOGIN","value":"true"}')" 400
p="$(preview '{"repo":"o/r","type":"set_variable","name":"AGENT_AUTO_MERGE","value":"true"}')"
VARS_OUT='{"variables":[{"name":"AGENTS_ENABLED","value":"true"},{"name":"AGENT_AUTO_MERGE","value":"false"},{"name":"AGENT_OWNER_LOGIN","value":"owner-login"}]}'; xrules
expect "a variable someone set since the preview: refused" "$(pcode "$(jq -c --arg t "$(jq -r .confirm <<<"${p}")" '{repo: "o/r", type: "set_variable", name: "AGENT_AUTO_MERGE", value: "true", confirm: $t}' <<<'{}')")" 409
VARS_OUT="" VARS_RC=1 VARS_ERR="HTTP 403"; xrules
expect "variables unreadable: no switch" "$(vcode '{"repo":"o/r","type":"set_variable","name":"AGENTS_ENABLED","value":"false"}')" 409
VARS_OUT="${VARS_OK}" VARS_RC=0 VARS_ERR=""
PERM=TRIAGE; xrules
for a in '{"repo":"o/r","type":"dispatch","workflow":"merge"}' '{"repo":"o/r","type":"cancel_run","run":1}' \
  '{"repo":"o/r","type":"review_verdict","pr":50,"verdict":"approve"}' '{"repo":"o/r","type":"set_variable","name":"AGENTS_ENABLED","value":"false"}'; do
  expect "without write access: refused ($(jq -r .type <<<"${a}"))" "$(vcode "${a}")" 403
done
PERM=ADMIN; xrules
expect "a preview for gh signed in as someone else: refused" "$(vcode '{"repo":"o/r","type":"dispatch","workflow":"merge","viewer":"someone-else"}')" 409

calls="$(stub_gh_calls | tr '\n' ' ' | sed -E 's/ (api )/\n\1/g; s/ +$//')"
writes="$(grep -vE "${reads}" <<<"${calls}" | grep -vE '^api -X POST repos/o/r/actions/workflows/(agent-coder|claude-code-review|agent-merge|agent-fixup)\.yml/dispatches --input -$|^api -X POST repos/o/r/actions/runs/1/cancel$|^api -X POST repos/o/r/issues/50/comments --input -$|^api -X (PATCH|POST) repos/o/r/actions/variables(/AGENTS_ENABLED)? --input -$|^api --method POST markdown --input -$' || true)"
expect "no other write was made" "${writes}" ""

printf '\n[dashboard] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
