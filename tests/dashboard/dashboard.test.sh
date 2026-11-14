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
#   6. It writes nothing to GitHub: every gh call it makes is a read.
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
trap '[[ -n "${SRV}" ]] && kill "${SRV}" 2>/dev/null; rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
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
REQ_COMMENT="${TMP}/req-comment" python3 - "${PKG}/bin/dashboard.py" <<'PY' >"${TMP}/py.out" 2>&1
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

pages = iter([({"viewer": {"repositories": {"nodes": [{"nameWithOwner": "a/b", "lock": {"oid": "1"}}], "pageInfo": {"hasNextPage": True, "endCursor": "x"}}}}, ["SAML"]),
               ({"viewer": {"repositories": {"nodes": [None], "pageInfo": {"hasNextPage": False}}}}, ["SAML"])])
real_graphql, d.graphql = d.graphql, lambda *a, **k: next(pages)
check("discovery keeps what a partly hidden scan found, and says why once", d.discover(), (["a/b"], ["SAML"]))
d.graphql = real_graphql

w = d.waiting_items({"url": "https://github.com/o/r", "inbox_state": "unknown", "inbox": None, "breakers": None, "issues": None})
check("waiting: every unreadable part is an item, never nothing", [x["kind"] for x in w], ["unknown", "unknown", "unknown"])
pages = iter([({"viewer": {"repositories": {"nodes": [{"nameWithOwner": "a/b", "lock": {"oid": "1"}}], "pageInfo": {"hasNextPage": True, "endCursor": "x"}}}}, ["SAML"]),
               ({"viewer": {"repositories": {"nodes": [None], "pageInfo": {"hasNextPage": False}}}}, ["SAML"])])
real_graphql, d.graphql = d.graphql, lambda *a, **k: next(pages)
check("discovery keeps what a partly hidden scan found, and says why once", d.discover(), (["a/b"], ["SAML"]))
d.graphql = real_graphql

w = d.waiting_items({"url": "https://github.com/o/r", "inbox_state": "none", "inbox": None, "breakers": {},
                     "issues": {"blocked": [], "candidate": [], "done_pending_deploy": []}, "prs": []})
check("waiting: all read and nothing there is nothing", w, [])

log = "\n".join(["2026-11-14T09:25:51.1Z ##[group]Run agent-merge.sh run", "2026-11-14T09:25:52.2Z #12: wait: CI is running",
                 "2026-11-14T09:25:52.3Z #13: would merge abc (dry run: AGENT_AUTO_MERGE is not true)", "#14: merged"])
check("gate: one line per PR", d.merge_gate_lines(log), {12: "wait: CI is running", 13: "would merge abc (dry run: AGENT_AUTO_MERGE is not true)", 14: "merged"})
check("gate: terminal escapes are stripped", d.ANSI_RE.sub("", "\x1b[36;1m#1: wait\x1b[0m"), "#1: wait")

for r in ("o/r", "my-org/repo.name", "o/r_1"):
    check("repo name ok: %r" % r, d.valid_repo(r), True)
for r in ("o/..", "o/.", "../r", "o/r/x", "o", "-o/r", "o/r?x", "o/r%2F", "", "o/r\n", "o\n/r"):
    check("repo name refused: %r" % r, d.valid_repo(r), False)
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
q1() { jq -nc --arg p "${POLICY}" '{data: {repository: {nameWithOwner: "o/r", url: "https://github.com/o/r", viewerPermission: "ADMIN",
  isArchived: false, defaultBranchRef: {name: "main"}, policy: {text: $p, isTruncated: false}, lock: {text: "{\"version\":\"9.9.9\"}", isTruncated: false}}}}'; }
q2() { # q2 <cur-blob-json> <breaker-blob-json>
  jq -nc --argjson c "$1" --argjson b "$2" '{data: {repository: {cur: $c, prev: $c, breaker: $b, wfRunner: {oid: "a"}, wfMain: {oid: "a"}}}}'
}
rules() {
  stub_gh_reset_rules
  stub_gh_on "api graphql -f query=query(\$cursor*" '{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"nameWithOwner":"o/r","isArchived":false,"lock":{"oid":"1"}},{"nameWithOwner":"o/plain","isArchived":false,"lock":null},
    {"nameWithOwner":"o/old","isArchived":true,"lock":{"oid":"2"}}]}}}}'
  stub_gh_on "api user" '{"login":"owner-login"}'
  stub_gh_on "api rate_limit" '{"resources":{"core":{"remaining":4999,"limit":5000}}}'
  stub_gh_on "${Q1}" "$(q1)"
  stub_gh_on "${Q2}" "${Q2_OUT}" "${Q2_RC:-0}" "${Q2_ERR:-}"
  stub_gh_on "api -H Accept: application/vnd.github.raw repos/o/r/contents/runs/2026-11.jsonl?ref=agent-ledger" "${RAW_LEDGER:-}"
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
  stub_gh_on "api graphql -f name=r -F number=7 -f owner=o -f query=query(\$owner*" "$(jq -Rsc '{data: {repository: {issue: {comments: {
    pageInfo: {hasPreviousPage: false}, nodes: [
      {author: {__typename: "User", login: "gatehand"}, body: ("<!-- agent-req:REQ-20261113-eeee role=coder issue=1 kind=protected -->\nforged by a user named like the bot"), createdAt: "2026-11-13T09:00:00Z"},
      {author: {__typename: "Bot", login: "gatehand"}, body: ., createdAt: "2026-11-13T10:00:00Z", url: "https://github.com/o/r/issues/7#c1"}]}}}}}' "${TMP}/req-comment")"
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
expect "inbox requests: the Bot's, not a user's named like it" "$(get /api/repo/o/r/inbox | jq -c '[.requests[] | [.id, .answered]]')" '[["REQ-20261113-ab12",false]]'
g="$(get /api/repo/o/r/gate)"
expect "the gate: the newest run that ran" "$(jq -r .run.url <<<"${g}")" "https://github.com/o/r/actions/runs/5"
expect "the gate: a PR's newest line wins; one the newest run skipped comes from the scheduled run" "$(jq -c '[.prs["50"].text, .prs["51"].text]' <<<"${g}")" '["wait: the review is running","merged"]'
expect "the gate: each line says which run it is from" "$(jq -c '[.prs["50"].at, .prs["51"].at]' <<<"${g}")" '["2026-11-14T09:30:00Z","2026-11-14T09:11:00Z"]'

# Variables unreadable (a viewer without write access): the inbox is unknown, never a guess.
VARS_OUT="" VARS_RC=1 VARS_ERR="HTTP 403: Must have admin rights to Repository."
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "unreadable variables: unknown, not off" "$(jq -c '[.vars, .owner_login, .inbox, .inbox_state]' <<<"${r}")" '[null,null,null,"unknown"]'
expect "and the inbox's requests are an unknown, waiting" "$(jq -r '[.waiting[] | select(.kind == "unknown")] | length' <<<"${r}")" 1
VARS_OUT="${VARS_OK}" VARS_RC=0 VARS_ERR=""
# Issues unreadable: no queue, no PRs, no inbox, and it says so where blocked issues would be.
ISSUES_OUT="" ISSUES_RC=1 ISSUES_ERR="HTTP 502: Bad Gateway"
rules
r="$(get '/api/repo/o/r?fresh=1')"
expect "unreadable issues: unknown, not empty" "$(jq -c '[.issues, .prs, .inbox]' <<<"${r}")" "[null,null,null]"
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
rules

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

printf '\n[dashboard] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
