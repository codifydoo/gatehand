#!/usr/bin/env python3
"""bin/dashboard.py: a local dashboard for every repository where Gatehand is installed.

    python3 bin/dashboard.py [--port N] [--no-open] [--print-url] [--idle-minutes M] [--ready-file F]

Serves one page on 127.0.0.1 and reads GitHub through the `gh` CLI, so it sees exactly what your own
`gh` login sees. Nothing it shows is computed by an agent: the numbers come from each repository's
ledger branch, its issues and PRs, its Actions runs and variables, read the way the agents' own
scripts read them (agent-digest.sh, agent-state.sh, agent-lib.sh).

Reading writes nothing. Its writes to GitHub are the page's buttons, each a fixed shape built here
and done with your own login after you confirm: an inbox command posted on the inbox issue, or one of
a few agent label changes (see "actions" below). Locally it writes only its list of repositories, in
${XDG_CONFIG_HOME:-~/.config}/gatehand/dashboard.json.

Security (docs/dashboard.md): it listens on 127.0.0.1 only; every /api/ request must carry the
per-launch secret, which travels in the URL fragment and is never printed unless --print-url; the
Host header must name this server (DNS rebinding); a POST must be same-origin JSON (CSRF). The page is
static, under a CSP that allows only its own script and style, and renders every GitHub text as text.
The gh token never enters this process: every call is a `gh` subprocess with an argv list.
"""
import argparse
import hmac
import http.server
import json
import os
import re
import secrets
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import webbrowser
from datetime import datetime, timedelta, timezone

PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATIC_DIR = os.path.join(PKG, "dashboard")
STATIC = {  # path -> (file, content type); nothing else is served from disk
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; "
       "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")

LOCK_PATH = ".github/agents/install.lock.json"
POLICY_PATH = ".github/agents/policy.json"
# The workflows Gatehand installs (template/.github/workflows): a run of any other workflow is not shown.
WORKFLOWS = {
    ".github/workflows/agent-coder.yml": "coder",
    ".github/workflows/agent-fixup.yml": "fixer",
    ".github/workflows/claude-code-review.yml": "review",
    ".github/workflows/agent-merge.yml": "merge gate",
    ".github/workflows/agent-pr-guard.yml": "PR guard",
    ".github/workflows/agent-sweep.yml": "sweep",
    ".github/workflows/agent-inbox.yml": "inbox",
    ".github/workflows/agent-digest.yml": "digest",
    ".github/workflows/agent-triage.yml": "triage",
}
VARIABLES = ("AGENTS_ENABLED", "AGENT_AUTO_MERGE", "AGENT_OWNER_LOGIN", "AGENT_INBOX_ISSUE")
OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
REQ_MARK_RE = re.compile(r"<!-- agent-req:(REQ-[0-9]{8}-[0-9a-f]{4}) role=([a-z]+) issue=([0-9]+) kind=([a-z]+) -->")
ANSWER_RE = re.compile(r"<!-- agent-answer:(REQ-[0-9]{8}-[0-9a-f]{4}) -->")
PRIORITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
MAX_ISSUE_PAGES = 5  # 500 open issues, as agent-digest.sh's `gh issue list --limit 500`
MAX_DISCOVERY_PAGES = 30
CACHE_TTL = 60
GH_TIMEOUT = 60

# --- gh ---------------------------------------------------------------------------------------------


class GhError(Exception):
    def __init__(self, args, rc, err):
        self.not_found = "HTTP 404" in err
        self.forbidden = "HTTP 403" in err
        super().__init__("gh %s: %s" % (" ".join(args[:3]), (err.strip() or "exit %d" % rc)[:300]))


GH_SLOTS = threading.BoundedSemaphore(8)


def gh(args, stdin=None):
    """Run `gh <args>` and return stdout. Raises GhError on failure. argv only, never a shell."""
    with GH_SLOTS:
        try:
            p = subprocess.run(["gh"] + list(args), input=stdin, capture_output=True, text=True, timeout=GH_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise GhError(args, -1, str(e))
    if p.returncode != 0:
        e = GhError(args, p.returncode, p.stderr)
        e.stdout = p.stdout  # gh api graphql prints the partial data of a response with errors
        raise e
    return p.stdout


def gh_json(args, stdin=None):
    out = gh(args, stdin)
    try:
        return json.loads(out) if out.strip() else None
    except ValueError:
        raise GhError(args, 0, "not JSON: " + out[:100])


def gh_or_404(args):
    """The parsed response; None on a 404 (not there yet). Any other failure raises, so "unreadable"
    never reads as "empty" (agent-digest.sh gh_or_404)."""
    try:
        return gh_json(args)
    except GhError as e:
        if e.not_found:
            return None
        raise


def graphql(query, partial=False, **variables):
    """The response's data. Any GraphQL error raises, unless partial: then (data, [messages]) for a
    response that still carries data (one node a SAML-protected organisation hides, say)."""
    # Variables first, then the query: the order the test stub's globs expect. -f only: -F would
    # read a value starting with @ as a file.
    # An int goes as -F (typed): digits cannot start with @.
    args = ["api", "graphql"]
    for k in sorted(variables):
        v = variables[k]
        args += ["-F", "%s=%d" % (k, v)] if isinstance(v, int) else ["-f", "%s=%s" % (k, v)]
    args += ["-f", "query=" + query]
    try:
        data = gh_json(args) or {}
    except GhError as e:
        try:
            data = json.loads(getattr(e, "stdout", "") or "null")
        except ValueError:
            data = None
        if not (partial and isinstance(data, dict) and data.get("data")):
            raise
    errors = [str(x.get("message")) for x in data.get("errors") or [] if isinstance(x, dict)]
    if errors and not (partial and data.get("data")):
        raise GhError(args, 0, "; ".join(errors))
    return (data.get("data") or {}, errors) if partial else (data.get("data") or {})


def rest_pages(path, max_pages):
    """Every item of a paged REST list (per_page=100), at most max_pages pages."""
    items = []
    sep = "&" if "?" in path else "?"
    for page in range(1, max_pages + 1):
        chunk = gh_json(["api", "%s%sper_page=100&page=%d" % (path, sep, page)]) or []
        items.extend(chunk)
        if len(chunk) < 100:
            return items, False
    return items, True


# --- time --------------------------------------------------------------------------------------------


def now_utc():
    e = os.environ.get("AGENT_NOW_EPOCH")  # tests, as the agents' scripts
    return datetime.fromtimestamp(int(e), timezone.utc) if e else datetime.now(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# --- what the agents' scripts compute, ported ---------------------------------------------------------


def parse_ledger(text, since):
    """agent-digest.sh load: rows whose started_at (else ended_at) is at or after `since`. One
    malformed line costs that line, not the ledger."""
    rows = []
    for line in (text or "").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and str(row.get("started_at") or row.get("ended_at") or "") >= since:
            rows.append(row)
    return rows


def role_stats(rows, roles, today):
    """agent-digest.sh section_runs per role, plus agent-state.sh cmd_gate's runs-today count (a row
    with counted == false never reached the model and is not a run for the cap)."""
    def total(vals):
        nums = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
        return sum(nums) if nums else None

    out = {}
    names = sorted({str(r.get("role") or "?") for r in rows} | set(roles))
    for role in names:
        mine = [r for r in rows if str(r.get("role") or "?") == role]
        outcomes = {}
        for r in mine:
            o = str(r.get("outcome") or "none")
            outcomes[o] = outcomes.get(o, 0) + 1
        cfg = roles.get(role) or {}
        out[role] = {
            "runs": len(mine),
            "outcomes": sorted(outcomes.items(), key=lambda kv: (-kv[1], kv[0])),
            "not_counted": sum(1 for r in mine if r.get("counted") is False),
            "turns": total(r.get("turns") for r in mine),
            "duration_ms": total(r.get("duration_ms") for r in mine),
            "cost_usd": total(r.get("cost_usd") for r in mine),
            "today": sum(1 for r in mine if r.get("counted") is not False
                         and str(r.get("started_at") or "").startswith(today)),
            "cap": cfg.get("runsPerDay") if isinstance(cfg, dict) else None,
            "max_open_prs": cfg.get("maxOpenPrs") if isinstance(cfg, dict) else None,
        }
    return out


def inbox_checklist(body):
    """The unticked lines of the inbox body's "Open requests" list (agent-digest.sh section_waiting):
    `- [ ] REQ · role · #N · summary`."""
    out, on = [], False
    for line in (body or "").replace("\r", "").split("\n"):
        if "<!-- agent-inbox:open:start -->" in line:
            on = True
            continue
        if "<!-- agent-inbox:open:end -->" in line:
            on = False
        if on and line.startswith("- [ ] REQ-"):
            parts = line[len("- [ ] "):].split(" · ", 3)
            issue = parts[2].lstrip("#") if len(parts) > 2 else ""
            out.append({
                "id": parts[0],
                "role": parts[1] if len(parts) > 1 else "",
                "issue": int(issue) if issue.isdigit() else None,
                "summary": parts[3] if len(parts) > 3 else "",
            })
    return out


def inbox_requests(comments, bot):
    """Requests the agent bot filed on the inbox, newest first, each marked answered or not
    (agent-inbox.sh find_request / answered). Only the bot's own comments count: anyone can paste a
    marker."""
    mine = [c for c in comments if (c.get("user") or {}).get("login") == bot]
    answered = set()
    for c in mine:
        answered.update(ANSWER_RE.findall(c.get("body") or ""))
    out, seen = [], set()
    for c in mine:
        body = (c.get("body") or "").replace("\r", "")
        first = body.split("\n", 1)[0]
        m = REQ_MARK_RE.fullmatch(first.strip())
        if not m or m.group(1) in seen:
            continue
        seen.add(m.group(1))
        rest = body.split("\n", 1)[1] if "\n" in body else ""
        if rest.lstrip().startswith("### "):  # the `### REQ · role · #N` heading repeats the marker
            rest = rest.lstrip().split("\n", 1)[1] if "\n" in rest.lstrip() else ""
        out.append({
            "id": m.group(1), "role": m.group(2), "issue": int(m.group(3)), "kind": m.group(4),
            "answered": m.group(1) in answered, "created_at": c.get("created_at"),
            "url": c.get("html_url"), "body": rest.strip()[:6000],
        })
    out.sort(key=lambda r: r["created_at"] or "", reverse=True)
    return out


def find_inbox(issues, marker, bot, owner):
    """agent-lib.sh inbox_find, without AGENT_INBOX_ISSUE (the caller checks that first): the
    lowest-numbered open issue whose body carries the marker and whose author is the agent bot or
    AGENT_OWNER_LOGIN."""
    ok = {bot} | ({owner} if owner else set())
    hits = [i for i in issues if "pull_request" not in i and marker in (i.get("body") or "")
            and (i.get("user") or {}).get("login") in ok]
    return min(hits, key=lambda i: i["number"]) if hits else None


def merge_gate_lines(log):
    """`#N: …` lines of an Agent merge job log (agent-merge.sh cmd_run's report), by PR, last wins."""
    out = {}
    for line in (log or "").splitlines():
        m = re.match(r"^(?:\S+Z )?#([0-9]+): (.+)$", line.rstrip("\r"))
        if m:
            out[int(m.group(1))] = m.group(2)[:500]
    return out


def waiting_items(d):
    """agent-digest.sh section_waiting, as data: what in this repository waits for a person. A part
    that could not be read is an item of its own (kind "unknown"), as the digest's "Could not …"
    lines are, so an outage never reads as "nothing waits"."""
    items = []
    unknown = lambda text: items.append({"kind": "unknown", "text": text, "url": d["url"]})
    if d.get("inbox_state") == "unknown":
        unknown("Could not tell which issue is the inbox, so its open requests are not listed.")
    if d.get("breakers") is None:
        unknown("Could not read the breaker state on the ledger branch, so a stopped role would not show here.")
    if d.get("issues") is None:
        unknown("Could not list the open issues, so blocked ones are not listed.")
    if d.get("inbox") is not None:
        for r in d["inbox"]["checklist"]:
            items.append({"kind": "request", "text": "%s · %s · #%s · %s" % (r["id"], r["role"], r["issue"], r["summary"]),
                          "url": d["inbox"]["url"]})
    for role, b in sorted((d.get("breakers") or {}).items()):
        if isinstance(b, dict) and b.get("tripped_at") is not None:
            items.append({"kind": "breaker", "text": "The %s is stopped since %s UTC: %s." % (
                role, str(b["tripped_at"])[:16].replace("T", " "), b.get("reason") or "no reason recorded"),
                "url": d["inbox"]["url"] if d.get("inbox") else d["url"]})
    issues = d.get("issues")
    if issues is not None:
        for i in issues["blocked"]:
            items.append({"kind": "blocked", "text": "#%d %s: %s." % (i["number"], i["title"], ", ".join(
                l for l in i["labels"] if l in ("agent:blocked", "agent:needs-human"))), "url": i["url"]})
        for p in d.get("prs") or []:
            stuck = [l for l in p["labels"] if l in ("agent:blocked", "agent:needs-human")]
            if stuck:
                items.append({"kind": "blocked", "text": "PR #%d %s: %s." % (p["number"], p["title"], ", ".join(stuck)),
                              "url": p["url"]})
        if issues["candidate"]:
            items.append({"kind": "candidate", "text": "%d agent:candidate issue(s) to queue (add agent:ready) or close." % len(issues["candidate"]),
                          "url": d["url"] + "/issues?q=is%3Aopen+label%3Aagent%3Acandidate"})
        for i in issues["done_pending_deploy"]:
            items.append({"kind": "deploy", "text": "#%d %s: merged. Close it once the fix is live." % (i["number"], i["title"]),
                          "url": i["url"]})
    return items


# --- reading one repository ---------------------------------------------------------------------------

REPO_Q1 = """query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
nameWithOwner url viewerPermission isArchived defaultBranchRef{name}
policy:object(expression:"HEAD:.github/agents/policy.json"){...on Blob{text isTruncated}}
lock:object(expression:"HEAD:.github/agents/install.lock.json"){...on Blob{text isTruncated}}}}"""

REPO_Q2 = """query($owner:String!,$name:String!,$cur:String!,$prev:String!,$breaker:String!,$wfRunner:String!,$wfMain:String!){
repository(owner:$owner,name:$name){
cur:object(expression:$cur){...on Blob{text isTruncated}}
prev:object(expression:$prev){...on Blob{text isTruncated}}
breaker:object(expression:$breaker){...on Blob{text isTruncated}}
wfRunner:object(expression:$wfRunner){oid}
wfMain:object(expression:$wfMain){oid}}}"""


def blob_text(repo, blob, ref, path):
    """A GraphQL blob's text; the REST raw contents when GraphQL truncated it; None when absent."""
    if blob is None:
        return None
    if not blob.get("isTruncated"):
        return blob.get("text") or ""
    try:
        return gh(["api", "-H", "Accept: application/vnd.github.raw",
                   "repos/%s/contents/%s?ref=%s" % (repo, path, urllib.parse.quote(ref, safe=""))])
    except GhError as e:
        if e.not_found:
            return None
        raise


def item_issue(i):
    labels = [l.get("name") for l in i.get("labels") or [] if isinstance(l, dict)]
    pri = next((l[len("priority: "):] for l in labels if l and l.startswith("priority: ")), None)
    return {"number": i["number"], "title": i.get("title") or "", "url": i.get("html_url"), "labels": labels,
            "priority": pri, "created_at": i.get("created_at"), "updated_at": i.get("updated_at")}


def read_repo(repo):
    owner, name = repo.split("/", 1)
    d = {"repo": repo, "url": "https://github.com/" + repo, "errors": [], "fetched_at": iso(now_utc())}
    now = now_utc()
    since = iso(now - timedelta(days=7))
    today = now.strftime("%Y-%m-%d")

    # 1. The repository, its policy and the installed version.
    try:
        r = (graphql(REPO_Q1, owner=owner, name=name) or {}).get("repository")
    except GhError as e:
        d["errors"].append("repository: %s" % e)
        r = None
    if not r:
        if not d["errors"]:
            d["errors"].append("repository: not found, or your gh login cannot see it")
        # Nothing else can be read either: everything that could wait for you is unknown.
        d["waiting"] = [{"kind": "unknown", "text": "Could not read this repository, so nothing in it is listed.", "url": d["url"]}]
        return d
    d["url"] = r.get("url") or d["url"]
    d["viewer_permission"] = r.get("viewerPermission")
    d["archived"] = bool(r.get("isArchived"))
    default = (r.get("defaultBranchRef") or {}).get("name") or "main"
    d["default_branch"] = default
    policy, policy_ok = {}, False
    try:
        text = blob_text(repo, r.get("policy"), default, POLICY_PATH)
        if text is None:
            raise ValueError("not on %s" % default)
        policy = json.loads(text)
        if not isinstance(policy, dict):
            raise ValueError("not an object")
        policy_ok = True
    except (GhError, ValueError) as e:
        d["errors"].append("policy.json: %s; the defaults are assumed, and the inbox is not looked for" % e)
        policy = {}
    try:
        lock = json.loads(blob_text(repo, r.get("lock"), default, LOCK_PATH) or "null")
        d["version"] = lock.get("version") if isinstance(lock, dict) else None
    except (GhError, ValueError) as e:
        d["errors"].append("install.lock.json: %s" % e)
        d["version"] = None
    if r.get("lock") is None:
        d["errors"].append("no %s on %s: Gatehand is not installed here" % (LOCK_PATH, default))
    d["policy_ok"] = policy_ok
    bot = policy.get("botLogin") or "gatehand[bot]"
    roles = policy.get("roles") if isinstance(policy.get("roles"), dict) else {}
    ledger = policy.get("ledgerBranch") or "agent-ledger"
    runner = policy.get("runnerRef") or "agent-runner"
    d["policy"] = {
        "botLogin": bot, "baseBranch": policy.get("baseBranch") or default, "ledgerBranch": ledger,
        "runnerRef": runner, "inboxMarker": policy.get("inboxMarker") or "<!-- agent-inbox -->",
        "roles": {k: {"runsPerDay": v.get("runsPerDay"), "maxOpenPrs": v.get("maxOpenPrs")}
                  for k, v in roles.items() if isinstance(v, dict)},
        "requiredChecks": policy.get("requiredChecks") if isinstance(policy.get("requiredChecks"), list) else None,
    }

    # 2. The ledger (this month and last, enough for seven days), the breaker, the runner ref.
    months = sorted({now.strftime("%Y-%m"), (now - timedelta(days=7)).strftime("%Y-%m")})
    try:
        q = (graphql(REPO_Q2, owner=owner, name=name,
                     cur="%s:runs/%s.jsonl" % (ledger, months[-1]), prev="%s:runs/%s.jsonl" % (ledger, months[0]),
                     breaker="%s:state/breaker.json" % ledger,
                     wfRunner="%s:.github/workflows/agent-coder.yml" % runner,
                     wfMain="%s:.github/workflows/agent-coder.yml" % default) or {}).get("repository") or {}
    except GhError as e:
        d["errors"].append("ledger: %s" % e)
        q = None
    d["runs"] = d["stats"] = d["breakers"] = d["runner_ref"] = None
    if q is not None:
        try:
            text = ""
            for key, month in (("prev", months[0]), ("cur", months[-1])) if len(months) > 1 else (("cur", months[0]),):
                text += (blob_text(repo, q.get(key), ledger, "runs/%s.jsonl" % month) or "") + "\n"
            rows = parse_ledger(text, since)
            rows.sort(key=lambda x: str(x.get("started_at") or x.get("ended_at") or ""), reverse=True)
            d["runs"] = rows
            d["stats"] = role_stats(rows, roles, today)
        except GhError as e:
            d["errors"].append("ledger runs: %s" % e)
        try:  # read apart from the runs, as the digest does: one unreadable file costs only its own part
            btext = blob_text(repo, q.get("breaker"), ledger, "state/breaker.json")
            b = json.loads(btext) if btext and btext.strip() else {}
            if not isinstance(b, dict):
                raise ValueError("not an object")
            d["breakers"] = b
        except (GhError, ValueError) as e:
            d["errors"].append("ledger breaker.json: %s" % e)
        wr, wm = q.get("wfRunner"), q.get("wfMain")
        d["runner_ref"] = "missing" if wr is None else ("ok" if wm and wr.get("oid") == wm.get("oid") else "stale")

    # 3. Repository variables: readable with write access on most repos; unknown, not "off", when not.
    try:
        v = gh_json(["api", "repos/%s/actions/variables?per_page=100" % repo]) or {}
        have = {x.get("name"): x.get("value") for x in v.get("variables") or []}
        d["vars"] = {k: have.get(k) for k in VARIABLES}
    except GhError as e:
        d["vars"] = None
        d["errors"].append("variables: %s" % ("your login cannot read this repository's Actions variables"
                                              if e.forbidden or e.not_found else e))
    owner_login = (d["vars"] or {}).get("AGENT_OWNER_LOGIN") or ""
    d["owner_login"] = owner_login if d["vars"] is not None else None

    # 4. Open issues and PRs (one REST list: the issues endpoint carries PRs too), and the inbox.
    try:
        items, truncated = rest_pages("repos/%s/issues?state=open" % repo, MAX_ISSUE_PAGES)
        if truncated:
            d["errors"].append("issues: more than %d open, only the newest are counted" % (MAX_ISSUE_PAGES * 100))
        issues = [i for i in items if "pull_request" not in i]
        has = lambda i, l: any((x or {}).get("name") == l for x in i.get("labels") or [])
        cat = {
            "ready": [i for i in issues if has(i, "agent:ready")],
            "in_progress": [i for i in issues if has(i, "agent:in-progress")],
            "pr_open": [i for i in issues if has(i, "agent:pr-open")],
            "blocked": [i for i in issues if has(i, "agent:blocked") or has(i, "agent:needs-human")],
            "candidate": [i for i in issues if has(i, "agent:candidate")],
            "done_pending_deploy": [i for i in issues if has(i, "agent:done-pending-deploy")],
            "hold": [i for i in issues if has(i, "agent:hold")],
        }
        d["issues"] = {k: sorted((item_issue(i) for i in v), key=lambda x: x["number"]) for k, v in cat.items()}
        d["issues"]["ready"].sort(key=lambda x: (PRIORITY_ORDER.get(x["priority"], 4), x["number"]))
        d["prs"] = sorted((item_issue(i) for i in items if "pull_request" in i and has(i, "agent:pr")),
                          key=lambda x: x["number"])
        # Which issue is the inbox depends on AGENT_INBOX_ISSUE, AGENT_OWNER_LOGIN and the bot's login:
        # without the variables or the policy, any answer would be a guess, so it is "unknown".
        inbox = None
        if d["vars"] is None or not policy_ok:
            d["inbox_state"] = "unknown"
            d["errors"].append("inbox: cannot tell which issue it is without %s" % (
                "the repository variables (AGENT_INBOX_ISSUE, AGENT_OWNER_LOGIN)" if d["vars"] is None else "policy.json's botLogin"))
        else:
            want = d["vars"].get("AGENT_INBOX_ISSUE") or ""
            if want.isdigit():  # the repo variable is trusted outright (agent-lib.sh inbox_find)
                inbox = next((i for i in issues if i["number"] == int(want)), None)
                if inbox is None:
                    inbox = gh_or_404(["api", "repos/%s/issues/%s" % (repo, want)])
            else:
                inbox = find_inbox(issues, d["policy"]["inboxMarker"], bot, owner_login)
            d["inbox_state"] = "ok" if inbox else "none"
            if not inbox:
                d["errors"].append("inbox: no open inbox issue found")
        d["inbox"] = None if not inbox else {
            "number": inbox["number"], "url": inbox.get("html_url"), "checklist": inbox_checklist(inbox.get("body")),
        }
    except GhError as e:
        d["errors"].append("issues: %s" % e)
        d["issues"] = d["prs"] = d["inbox"] = None
        d["inbox_state"] = "unknown"

    # 5. Gatehand's Actions runs: what is running now (asked by status, so a long coder run is not lost
    # behind the many short runs every CI completion starts), and the latest finished ones.
    def mine(status, n):
        runs = (gh_json(["api", "repos/%s/actions/runs?status=%s&per_page=%d" % (repo, status, n)]) or {}).get("workflow_runs") or []
        return [{
            "id": x.get("id"), "name": x.get("display_title") or x.get("name"), "agent": WORKFLOWS[x.get("path")],
            "status": x.get("status"), "conclusion": x.get("conclusion"), "event": x.get("event"),
            "url": x.get("html_url"), "created_at": x.get("created_at"), "updated_at": x.get("updated_at"),
        } for x in runs if isinstance(x, dict) and x.get("path") in WORKFLOWS]
    try:
        # Every state agent-state.sh counts as active: a dispatch waiting behind its concurrency group
        # is "pending", not "queued".
        active = [x for st in ("in_progress", "queued", "pending", "waiting", "requested") for x in mine(st, 100)]
        d["active_runs"] = sorted({x["id"]: x for x in active}.values(), key=lambda x: x["created_at"] or "", reverse=True)
        d["recent_runs"] = [x for x in mine("completed", 50) if x["conclusion"] != "skipped"][:15]
    except GhError as e:
        d["errors"].append("runs: %s" % e)
        d["active_runs"] = d["recent_runs"] = None

    d["waiting"] = waiting_items(d)
    return d


INBOX_Q = """query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){
issue(number:$number){comments(last:100,before:$cursor){pageInfo{hasPreviousPage startCursor}
nodes{author{__typename login} body createdAt url}}}}}"""
MAX_INBOX_PAGES = 10


AWAIT_SECONDS = 600


def read_inbox(repo, number, bot, owner_login=""):
    """The inbox's requests, from its newest comments back (a long-lived inbox has thousands; the
    newest are the ones that matter, and an answer always comes after its request). Also whether a
    command of the owner's is still waiting for the inbox workflow: the bot replies to every comment
    that carries commands, so an owner's command newer than the bot's last comment (and under ten
    minutes old: a workflow that never ran must not block forever) is not applied yet."""
    owner, name = repo.split("/", 1)
    comments, cursor, truncated = [], None, False
    for page in range(MAX_INBOX_PAGES):
        kw = {"cursor": cursor} if cursor else {}
        c = ((((graphql(INBOX_Q, owner=owner, name=name, number=number, **kw) or {}).get("repository") or {})
              .get("issue") or {}).get("comments") or {})
        for n in c.get("nodes") or []:
            a = (n or {}).get("author") or {}
            # GraphQL spells an App's login without "[bot]", and a person could own that bare name;
            # only a Bot author gets the suffix, so the comparison below is the REST one.
            login = (a.get("login") or "") + ("[bot]" if a.get("__typename") == "Bot" else "")
            comments.append({"user": {"login": login}, "body": n.get("body"), "created_at": n.get("createdAt"),
                             "html_url": n.get("url")})
        info = c.get("pageInfo") or {}
        if not info.get("hasPreviousPage"):
            break
        cursor = info.get("startCursor")
        truncated = page == MAX_INBOX_PAGES - 1
    requests = inbox_requests(comments, bot)
    # The bot's last REPLY: its request comments (the merge gate, the fixer, the coder file them at
    # any time) say nothing about whether the owner's command has been applied.
    last_bot = max((c["created_at"] or "" for c in comments if c["user"]["login"] == bot
                    and not REQ_MARK_RE.fullmatch(((c["body"] or "").replace("\r", "").split("\n", 1)[0]).strip())), default="")
    floor = iso(now_utc() - timedelta(seconds=AWAIT_SECONDS))
    waiting = [c for c in comments if owner_login and c["user"]["login"] == owner_login
               and (c["created_at"] or "") > max(last_bot, floor) and (c["body"] or "").startswith("/")]  # as agent-inbox.yml tests it
    pending = {m for c in waiting for m in re.findall(r"(?m)^/(?:approve|reject)[ \t]+(REQ-[0-9]{8}-[0-9a-f]{4})", c["body"] or "")}
    for r in requests:
        r["pending"] = r["id"] in pending and not r["answered"]
    return {"requests": requests, "truncated": truncated, "awaiting_reply": bool(waiting)}


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def job_log(repo, job_id):
    """A job's log as plain text. gh refuses to print a log with terminal escapes unless told to; this
    output never reaches a terminal, and the escapes are stripped before anything reads it."""
    args = ["api", "repos/%s/actions/jobs/%d/logs" % (repo, job_id)]
    try:
        out = gh(args[:1] + ["--allow-escape-sequences"] + args[1:])
    except GhError as e:
        if "unknown flag" not in str(e):  # a gh older than the flag never refuses either
            raise
        out = gh(args)
    return ANSI_RE.sub("", out)


GATE_RUNS = 3


def read_gate(repo):
    """The merge gate's last word on each PR: the `#N: …` lines of the newest Agent merge runs that
    ran, newest first. Most runs are skipped (the workflow starts on every CI and review run), and a
    run dispatched for one PR reports only that PR, so the hourly scheduled runs are asked for too
    and up to GATE_RUNS runs are read; a PR's newest line wins."""
    base = "repos/%s/actions/workflows/agent-merge.yml/runs?status=completed" % repo
    runs = {}
    for q in ("&per_page=30", "&event=schedule&per_page=5"):
        for r in (gh_json(["api", base + q]) or {}).get("workflow_runs") or []:
            if isinstance(r, dict) and r.get("conclusion") in ("success", "failure"):
                runs[r["id"]] = r
    ran = sorted(runs.values(), key=lambda r: r.get("created_at") or "", reverse=True)[:GATE_RUNS]
    if not ran:
        return {"run": None, "prs": {}, "note": "no Agent merge run that ran among the newest 30, nor a scheduled one"}
    lines = {}
    for run in ran:
        jobs = (gh_json(["api", "repos/%s/actions/runs/%d/jobs" % (repo, run["id"])]) or {}).get("jobs") or []
        for j in jobs:
            if j.get("conclusion") not in ("success", "failure"):
                continue
            try:
                for pr, line in merge_gate_lines(job_log(repo, j["id"])).items():
                    lines.setdefault(pr, {"text": line, "url": run.get("html_url"), "at": run.get("created_at")})
            except GhError as e:
                if not e.not_found:  # an expired log reads as no report, anything else is an error
                    raise
    run = ran[0]
    return {"run": {"id": run["id"], "url": run.get("html_url"), "created_at": run.get("created_at"),
                    "conclusion": run.get("conclusion")}, "prs": {str(k): v for k, v in lines.items()}}


# --- actions: writes, as the signed-in user ----------------------------------------------------------
#
# Every action is something the user could do by hand on GitHub, done with their own gh login, so
# every guard the agents apply to a person applies unchanged. The checks below only refuse early,
# with a reason, what the agents would ignore anyway (a command by someone other than
# AGENT_OWNER_LOGIN, a label by someone without write access), and what this page should never send.

REQ_ID_RE = re.compile(r"REQ-[0-9]{8}-[0-9a-f]{4}")
INBOX_LITERAL = "<!-- agent-inbox -->"  # agent-inbox.yml checks this literal, not policy.inboxMarker
WRITERS = ("WRITE", "MAINTAIN", "ADMIN")
# (op, label) -> what it may be put on or taken off: "issue", "pr" or both.
LABEL_ACTIONS = {
    # No ("add", "agent:ready"): that label vouches for the issue's text as it stands (the agents trust
    # everything written before a writer applied it), and this page does not show that text. Queueing
    # stays on GitHub, next to the text.
    ("remove", "agent:ready"): {"issue"},
    ("add", "agent:hold"): {"issue", "pr"},     # agents never touch it
    ("remove", "agent:hold"): {"issue", "pr"},
    ("remove", "agent:blocked"): {"pr"},        # a person fixed the PR: back to the merge gate
    ("remove", "agent:needs-human"): {"pr"},
}


def one_line(s, n):
    """A reason as agent-inbox.sh takes it: one line of printable text, at most n characters."""
    s = re.sub(r"[\x00-\x1f\x7f]+", " ", str(s or "")).strip()
    return s[:n].rstrip()


def inbox_command_line(cmd, body, roles):
    """The one command line to post, in exactly the grammar agent-inbox.sh parse_commands accepts;
    ApiError for anything else."""
    if cmd in ("approve", "reject"):
        req = body.get("req")
        if not isinstance(req, str) or not REQ_ID_RE.fullmatch(req):
            raise ApiError(400, "req must be REQ-YYYYMMDD-xxxx")
        if cmd == "approve":
            return "/approve %s" % req
        reason = one_line(body.get("reason"), 300)
        return ("/reject %s %s" % (req, reason)).rstrip()
    if cmd == "rerun":
        n = body.get("issue")
        if not isinstance(n, int) or isinstance(n, bool) or n <= 0:
            raise ApiError(400, "issue must be a positive number")
        return "/rerun coder #%d" % n
    if cmd in ("pause", "resume"):
        role = body.get("role")
        if role not in roles:
            raise ApiError(400, "role must be one of the policy.json roles: %s" % (", ".join(sorted(roles)) or "none"))
        return "/%s %s" % (cmd, role)
    raise ApiError(400, "command must be approve, reject, rerun, pause or resume")


INBOX_LOCKS = {}
INBOX_LOCKS_GUARD = threading.Lock()


def do_inbox_command(repo, d, viewer, body):
    """Post one inbox command as the viewer, after the checks agent-inbox.yml and agent-inbox.sh make.
    One at a time per repository, from the read to the post: two clicks (or two tabs) must not both
    find no command waiting and both post."""
    with INBOX_LOCKS_GUARD:
        lock = INBOX_LOCKS.setdefault(repo.lower(), threading.Lock())
    with lock:
        return _do_inbox_command(repo, d, viewer, body)


def _do_inbox_command(repo, d, viewer, body):
    if d.get("vars") is None:
        raise ApiError(409, "cannot read this repository's variables, so cannot tell who may answer")
    owner = d["vars"].get("AGENT_OWNER_LOGIN") or ""
    if not owner:
        raise ApiError(409, "AGENT_OWNER_LOGIN is not set in %s: nobody's commands are applied" % repo)
    if viewer != owner:  # exact: agent-inbox.sh compares case-sensitively
        raise ApiError(403, "only %s (AGENT_OWNER_LOGIN) can answer in %s; you are %s" % (owner, repo, viewer))
    if not d.get("policy_ok"):
        raise ApiError(409, "cannot read policy.json in %s" % repo)
    if not d.get("inbox"):
        raise ApiError(409, "no inbox issue found in %s" % repo)
    line = inbox_command_line(body.get("command"), body, set(d["policy"]["roles"]))
    number = d["inbox"]["number"]
    # The issue as the workflow will see it: open, an issue, the literal marker, opened by the bot or the owner.
    issue = gh_json(["api", "repos/%s/issues/%d" % (repo, number)]) or {}
    if issue.get("state") != "open" or "pull_request" in issue:
        raise ApiError(409, "#%d is not an open issue" % number)
    if INBOX_LITERAL not in (issue.get("body") or ""):
        raise ApiError(409, "#%d does not carry %s, so the inbox workflow would not run" % (number, INBOX_LITERAL))
    if (issue.get("user") or {}).get("login") not in (d["policy"]["botLogin"], owner):
        raise ApiError(409, "#%d was not opened by the agent bot or %s, so the inbox workflow would not run" % (number, owner))
    got = read_inbox(repo, number, d["policy"]["botLogin"], owner)
    if got["awaiting_reply"]:
        # Two inbox runs at once each read the bot's comments before either replies, so both would
        # apply: an Approve sent twice, or an Approve and a Reject, would both happen.
        raise ApiError(409, "your last command on #%d has no answer from the Agent inbox workflow yet; wait for it" % number)
    if body.get("command") in ("approve", "reject"):
        reqs = got["requests"]
        r = next((x for x in reqs if x["id"] == body["req"]), None)
        if r is None:
            raise ApiError(404, "%s is not a request the agent made in #%d" % (body["req"], number))
        if r["answered"]:
            raise ApiError(409, "%s is already answered" % body["req"])
    out = gh_json(["api", "repos/%s/issues/%d/comments" % (repo, number), "--input", "-"],
                  stdin=json.dumps({"body": line})) or {}
    return {"posted": line, "url": out.get("html_url"), "inbox": number}


def do_label(repo, d, body):
    """Add or take off one agent label as the viewer, who must have write access (a label by anyone
    else is ignored by the agents)."""
    if d.get("viewer_permission") not in WRITERS:
        raise ApiError(403, "labels count only from people with write access to %s; you have %s"
                       % (repo, str(d.get("viewer_permission") or "unknown").lower()))
    op, label, n = body.get("op"), body.get("label"), body.get("number")
    where = LABEL_ACTIONS.get((op, label))
    if where is None:
        raise ApiError(400, "not a label change this page makes: %s %s" % (op, label))
    if not isinstance(n, int) or isinstance(n, bool) or n <= 0:
        raise ApiError(400, "number must be a positive number")
    # The inbox is not work for the agents (held or unqueued, it means nothing; queued, the coder would
    # take it). While it cannot be told which issue the inbox is, no issue can be ruled out.
    if d.get("inbox_state") == "unknown":
        raise ApiError(409, "cannot tell which issue is the inbox in %s, so no label is changed" % repo)
    if d.get("inbox") and d["inbox"]["number"] == n:
        raise ApiError(409, "#%d is the agent inbox" % n)
    item = gh_json(["api", "repos/%s/issues/%d" % (repo, n)]) or {}
    kind = "pr" if "pull_request" in item else "issue"
    if item.get("state") != "open":
        raise ApiError(409, "#%d is not open" % n)
    if kind not in where:
        raise ApiError(400, "%s %s is for %s only, and #%d is %s" % (
            op, label, " or ".join("a PR" if w == "pr" else "an issue" for w in sorted(where)), n, "a PR" if kind == "pr" else "an issue"))
    if op == "add":
        gh_json(["api", "repos/%s/issues/%d/labels" % (repo, n), "--input", "-"], stdin=json.dumps({"labels": [label]}))
    else:
        try:
            gh(["api", "-X", "DELETE", "repos/%s/issues/%d/labels/%s" % (repo, n, urllib.parse.quote(label, safe=""))])
        except GhError as e:
            if not e.not_found:  # not there: already off
                raise
    return {"done": "%s %s %s #%d" % ("added" if op == "add" else "removed", label, "on" if op == "add" else "from", n)}


# --- discovery and the repository list ---------------------------------------------------------------

DISCOVER_Q = """query($cursor:String){viewer{repositories(first:100,after:$cursor,
affiliations:[OWNER,COLLABORATOR,ORGANIZATION_MEMBER],ownerAffiliations:[OWNER,COLLABORATOR,ORGANIZATION_MEMBER]){
pageInfo{hasNextPage endCursor}
nodes{nameWithOwner isArchived lock:object(expression:"HEAD:.github/agents/install.lock.json"){oid}}}}}"""


def discover():
    """Every repository your login can see that has Gatehand's lock file on its default branch, and
    notes on what the scan could not see (an organisation that hides its repositories from this token,
    a scan cut short)."""
    found, notes, cursor = [], [], None
    for page_no in range(MAX_DISCOVERY_PAGES):
        kw = {"cursor": cursor} if cursor else {}
        data, errors = graphql(DISCOVER_Q, partial=True, **kw)
        notes += [e for e in errors[:3] if e not in notes]
        page = (data.get("viewer") or {}).get("repositories") or {}
        found += [n["nameWithOwner"] for n in page.get("nodes") or []
                  if n and n.get("lock") and not n.get("isArchived") and valid_repo(n.get("nameWithOwner", ""))]
        info = page.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        cursor = info.get("endCursor")
        if page_no == MAX_DISCOVERY_PAGES - 1:
            notes.append("stopped after %d repositories; add the others by hand" % (MAX_DISCOVERY_PAGES * 100))
    return sorted(set(found), key=str.lower), notes


def valid_repo(s):
    if not isinstance(s, str) or s.count("/") != 1:
        return False
    o, n = s.split("/")
    # fullmatch: `$` alone would let a trailing newline through.
    return bool(OWNER_RE.fullmatch(o)) and bool(NAME_RE.fullmatch(n)) and n not in (".", "..")


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "gatehand", "dashboard.json")


class Config:
    """discovered (the last scan), added (by hand), excluded (removed by hand; a rescan keeps them out)."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {"discovered": [], "added": [], "excluded": [], "scanned_at": None}
        try:
            with open(path) as f:
                got = json.load(f)
            for k in ("discovered", "added", "excluded"):
                if isinstance(got.get(k), list):
                    self.data[k] = [r for r in got[k] if valid_repo(r)]
            self.data["scanned_at"] = got.get("scanned_at") if isinstance(got.get("scanned_at"), str) else None
            notes = got.get("scan_notes")
            self.data["scan_notes"] = [str(n)[:300] for n in notes] if isinstance(notes, list) else []
        except (OSError, ValueError, AttributeError):
            pass

    def repos(self):
        with self.lock:
            ex = {r.lower() for r in self.data["excluded"]}
            seen, out = set(), []
            for r in self.data["discovered"] + self.data["added"]:
                if r.lower() not in ex and r.lower() not in seen:
                    seen.add(r.lower())
                    out.append(r)
            return sorted(out, key=str.lower)

    def has(self, repo):
        return repo.lower() in {r.lower() for r in self.repos()}

    def update(self, fn):
        with self.lock:
            fn(self.data)
            os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path), prefix=".dashboard.")
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w") as f:
                    json.dump(self.data, f, indent=2)
                os.replace(tmp, self.path)
            except BaseException:
                if os.path.exists(tmp):
                    os.unlink(tmp)
                raise


# --- cache -------------------------------------------------------------------------------------------


class Cache:
    """Values for CACHE_TTL seconds; one computation per key at a time, so a burst of page loads costs
    one set of API calls."""

    def __init__(self):
        self.lock = threading.Lock()
        self.vals = {}
        self.key_locks = {}

    def get(self, key, fn, fresh=False, ttl=CACHE_TTL):
        with self.lock:
            kl = self.key_locks.setdefault(key, threading.Lock())
        with kl:
            hit = self.vals.get(key)
            if hit and not fresh and hit[0] > time.monotonic():
                return hit[1]
            val = fn()
            self.vals[key] = (time.monotonic() + ttl, val)
            return val

    def drop(self, prefix):
        with self.lock:
            for k in [k for k in self.vals if k.startswith(prefix)]:
                del self.vals[k]


# --- HTTP --------------------------------------------------------------------------------------------


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, addr, token, config):
        super().__init__(addr, Handler)
        self.token = token
        self.config = config
        self.cache = Cache()
        self.last_seen = time.monotonic()
        self.hosts = {"127.0.0.1:%d" % self.server_address[1], "localhost:%d" % self.server_address[1]}


class ApiError(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "gatehand-dashboard"
    sys_version = ""

    def log_message(self, fmt, *args):  # quiet: the request line can carry nothing secret, but it is noise
        if os.environ.get("GATEHAND_DASHBOARD_DEBUG"):
            sys.stderr.write("dashboard: " + (fmt % args) + "\n")

    def send(self, status, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def check_host(self):
        # DNS rebinding: a page on evil.example resolved to 127.0.0.1 still sends its own Host.
        if self.headers.get("Host", "") not in self.server.hosts:
            raise ApiError(421, "wrong Host")

    def check_token(self):
        got = self.headers.get("X-Gatehand-Token", "")
        if not hmac.compare_digest(got.encode(), self.server.token.encode()):
            raise ApiError(401, "missing or wrong session token: open the URL the dashboard printed or opened")

    def check_post(self):
        # CSRF: a cross-site form or fetch either sends a foreign Origin or cannot send JSON without a
        # preflight, which this server never answers.
        if self.headers.get("Origin", "") != "http://" + self.headers.get("Host", ""):
            raise ApiError(403, "cross-origin request refused")
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            raise ApiError(415, "JSON only")

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 65536:
            raise ApiError(413, "too large")
        try:
            v = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            raise ApiError(400, "not JSON")
        if not isinstance(v, dict):
            raise ApiError(400, "not an object")
        return v

    def handle_errors(self, fn):
        try:
            self.check_host()
            fn()
        except ApiError as e:
            self.send(e.status, {"error": str(e)})
        except GhError as e:
            self.send(502, {"error": str(e)})
        except Exception as e:  # never a traceback to the page
            sys.stderr.write("dashboard: %s: %r\n" % (self.path.split("?")[0], e))
            self.send(500, {"error": "internal error, see the dashboard's terminal"})

    def do_GET(self):
        self.handle_errors(self.get)

    def do_HEAD(self):
        self.handle_errors(self.get)

    def do_POST(self):
        self.handle_errors(self.post)

    def do_PUT(self):
        self.send(405, {"error": "method not allowed"})

    do_DELETE = do_PATCH = do_OPTIONS = do_PUT

    def route(self):
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query)
        return u.path, q

    def repo_from(self, owner, name):
        repo = "%s/%s" % (urllib.parse.unquote(owner), urllib.parse.unquote(name))
        if not valid_repo(repo) or not self.server.config.has(repo):
            raise ApiError(404, "not a repository on this dashboard")
        return next(r for r in self.server.config.repos() if r.lower() == repo.lower())

    def get(self):
        path, q = self.route()
        if path in STATIC:
            fname, ctype = STATIC[path]
            with open(os.path.join(STATIC_DIR, fname), "rb") as f:
                return self.send(200, f.read(), ctype)
        if not path.startswith("/api/"):
            raise ApiError(404, "not found")
        self.check_token()
        self.server.last_seen = time.monotonic()
        fresh = q.get("fresh") == ["1"]
        cache = self.server.cache
        if path == "/api/ping":  # the page says it is open, even in a background tab; no GitHub call
            return self.send(200, {"ok": True})
        if path == "/api/session":
            cfg = self.server.config
            scan_error = None
            if cfg.data["scanned_at"] is None:
                try:
                    self.rescan()
                except GhError as e:  # the page still loads, with the list it has and why
                    scan_error = str(e)
            user = cache.get("user", lambda: gh_json(["api", "user"]) or {}, ttl=3600)
            rate = cache.get("rate", lambda: ((gh_json(["api", "rate_limit"]) or {}).get("resources") or {}), fresh=fresh)
            return self.send(200, dict(self.repo_list(), viewer=user.get("login"), scan_error=scan_error,
                                       rate={k: rate.get(k) for k in ("core", "graphql")}, now=iso(now_utc())))
        m = re.fullmatch(r"/api/repo/([^/]+)/([^/]+)(/inbox|/gate)?", path)
        if not m:
            raise ApiError(404, "not found")
        repo = self.repo_from(m.group(1), m.group(2))
        if m.group(3) is None:
            return self.send(200, cache.get("repo:" + repo, lambda: read_repo(repo), fresh))
        if m.group(3) == "/gate":
            return self.send(200, cache.get("gate:" + repo, lambda: read_gate(repo), fresh))
        d = cache.get("repo:" + repo, lambda: read_repo(repo))
        if not d.get("inbox"):
            raise ApiError(404, "no inbox issue in %s" % repo)
        bot = d["policy"]["botLogin"]
        owner = (d.get("vars") or {}).get("AGENT_OWNER_LOGIN") or ""
        got = cache.get("inbox:" + repo, lambda: read_inbox(repo, d["inbox"]["number"], bot, owner), fresh)
        return self.send(200, dict(got, inbox=d["inbox"]))

    def action(self, body):
        repo = body.get("repo")
        if not valid_repo(repo) or not self.server.config.has(repo):
            raise ApiError(404, "not a repository on this dashboard")
        repo = next(r for r in self.server.config.repos() if r.lower() == repo.lower())
        cache = self.server.cache
        # Decide on fresh state, and on the login gh will post as now (gh auth switch mid-session).
        viewer = (cache.get("user", lambda: gh_json(["api", "user"]) or {}, fresh=True, ttl=3600) or {}).get("login") or ""
        d = cache.get("repo:" + repo, lambda: read_repo(repo), fresh=True)
        if body.get("viewer") != viewer:  # the page's confirm named the login it will act as
            raise ApiError(409, "gh is now signed in as %s, not %s as this page says: reload the page" % (viewer, body.get("viewer")))
        kind = body.get("type")
        if kind == "inbox_command":
            out = do_inbox_command(repo, d, viewer, body)
        elif kind == "label":
            out = do_label(repo, d, body)
        else:
            raise ApiError(400, "type must be inbox_command or label")
        for k in ("repo:", "inbox:", "gate:"):
            cache.drop(k + repo)
        sys.stderr.write("dashboard: %s %s: %s\n" % (viewer, repo, out.get("posted") or out.get("done")))
        self.send(200, dict(out, ok=True))

    def repo_list(self):
        c = self.server.config
        return {"repos": c.repos(), "excluded": list(c.data["excluded"]), "scanned_at": c.data["scanned_at"],
                "scan_notes": list(c.data.get("scan_notes") or [])}

    def rescan(self):
        found, notes = discover()
        def apply(c):
            if notes:  # a scan that could not see everything keeps what earlier scans found
                found_l = {r.lower() for r in found}
                kept = [r for r in c["discovered"] if r.lower() not in found_l]
                if kept:
                    notes.append("kept %d repositories found by an earlier scan" % len(kept))
                c["discovered"] = sorted(found + kept, key=str.lower)
            else:
                c["discovered"] = found
            c["scan_notes"] = notes
            c["scanned_at"] = iso(now_utc())
        self.server.config.update(apply)

    def post(self):
        path, _ = self.route()
        if not path.startswith("/api/"):
            raise ApiError(404, "not found")
        self.check_token()
        self.check_post()
        self.server.last_seen = time.monotonic()
        body = self.body_json()
        if path == "/api/action":
            return self.action(body)
        if path != "/api/repos":
            raise ApiError(404, "not found")
        op, repo = body.get("op"), body.get("repo")
        cfg = self.server.config
        if op == "rescan":
            self.rescan()
        elif op in ("add", "remove"):
            if not valid_repo(repo):
                raise ApiError(400, "repo must be owner/name")
            if op == "add":
                got = (graphql(REPO_Q1, owner=repo.split("/")[0], name=repo.split("/")[1]) or {}).get("repository")
                if not got:
                    raise ApiError(404, "%s: not found, or your gh login cannot see it" % repo)
                if not got.get("lock"):
                    raise ApiError(400, "%s has no %s on its default branch" % (repo, LOCK_PATH))
                repo = got["nameWithOwner"]
                def add(c):
                    c["excluded"] = [r for r in c["excluded"] if r.lower() != repo.lower()]
                    if repo.lower() not in {r.lower() for r in c["added"]}:
                        c["added"].append(repo)
                cfg.update(add)
            else:
                def remove(c):
                    c["added"] = [r for r in c["added"] if r.lower() != repo.lower()]
                    if repo.lower() not in {r.lower() for r in c["excluded"]}:
                        c["excluded"].append(repo)
                cfg.update(remove)
                self.server.cache.drop("repo:" + repo)
        else:
            raise ApiError(400, "op must be add, remove or rescan")
        self.send(200, self.repo_list())


def main(argv=None):
    ap = argparse.ArgumentParser(description="Gatehand dashboard: every repository with Gatehand, on one local page.")
    ap.add_argument("--port", type=int, default=0, help="port on 127.0.0.1 (default: a free one)")
    ap.add_argument("--no-open", action="store_true", help="do not open a browser (prints the URL instead)")
    ap.add_argument("--print-url", action="store_true", help="print the URL with its session secret")
    ap.add_argument("--idle-minutes", type=int, default=120, help="stop after this long with no page open (0: never)")
    ap.add_argument("--ready-file", help="write {port, token} here (mode 0600) once listening; for scripts and tests")
    ap.add_argument("--config", help="the repository list (default: %s)" % config_path())
    a = ap.parse_args(argv)

    token = secrets.token_urlsafe(32)
    srv = Server(("127.0.0.1", a.port), token, Config(a.config or config_path()))
    port = srv.server_address[1]
    base = "http://127.0.0.1:%d/" % port
    url = base + "#t=" + token
    if a.ready_file:
        # A fresh file only: an existing one (another user's, or a symlink) would keep its own owner
        # and mode, so it is removed first and the open refuses anything that reappears.
        try:
            os.unlink(a.ready_file)
        except FileNotFoundError:
            pass
        fd = os.open(a.ready_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"port": port, "token": token}, f)
    launcher = None
    if a.print_url or a.no_open:
        print("Gatehand dashboard: %s" % url, flush=True)
    else:
        print("Gatehand dashboard on %s (opening your browser; the address there carries this session's secret)" % base,
              flush=True)
        # Not the address itself: the browser's command line (xdg-open, firefox) is readable by every
        # local user. A private file that redirects to it is opened instead, as Jupyter does.
        launcher = tempfile.mkdtemp(prefix="gatehand-dashboard-")
        page = os.path.join(launcher, "open.html")
        fd = os.open(page, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write('<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer">'
                    '<meta http-equiv="refresh" content="0;url=%s"><title>Gatehand dashboard</title>'
                    '<p><a href="%s">Open the Gatehand dashboard</a></p>' % (url, url))
        if not webbrowser.open("file://" + urllib.parse.quote(page)):
            print("Gatehand dashboard: no browser could be started; stop this and run it again with --print-url", flush=True)
        else:
            print("  (no page? a sandboxed browser may not read %s: run again with --print-url)" % launcher, flush=True)

        def forget():  # the browser has read it by then; the token must not outlive the need on disk
            time.sleep(120)
            shutil.rmtree(launcher, ignore_errors=True)
        threading.Thread(target=forget, daemon=True).start()

    if a.idle_minutes > 0:
        def idle():
            while True:
                time.sleep(30)
                if time.monotonic() - srv.last_seen > a.idle_minutes * 60:
                    print("Gatehand dashboard: no page open for %d min, stopping" % a.idle_minutes, flush=True)
                    srv.shutdown()
                    return
        threading.Thread(target=idle, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
        if launcher:
            shutil.rmtree(launcher, ignore_errors=True)


if __name__ == "__main__":
    main()
