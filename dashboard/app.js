// dashboard/app.js: the Gatehand dashboard page. Everything from GitHub is untrusted text (issue
// titles, request bodies the agents wrote from model output): it is only ever set with textContent,
// never as HTML, and only https://github.com/ links become hrefs.
"use strict";

const state = { token: "", session: null, repos: {}, selected: "", gate: {}, inbox: {}, drafts: {} };
const $ = (id) => document.getElementById(id);

// --- session secret: from the URL fragment once, then from this tab's sessionStorage -----------------
(function takeToken() {
  const m = /(?:^#|&)t=([A-Za-z0-9_-]+)/.exec(location.hash);
  try {
    if (m) sessionStorage.setItem("gatehand-token", m[1]);
    state.token = (m && m[1]) || sessionStorage.getItem("gatehand-token") || "";
  } catch (_) {
    state.token = (m && m[1]) || "";
  }
  if (m) history.replaceState(null, "", location.pathname);
})();
// The view is in the address after the secret is taken out of it; no view named means Needs you.
state.route = parseRoute();
if (!/^#\//.test(location.hash)) history.replaceState(null, "", `${location.pathname}#/needs`);

async function api(path, opts = {}) {
  const res = await fetch(path, {
    method: opts.method || "GET",
    headers: Object.assign({ "X-Gatehand-Token": state.token }, opts.body ? { "Content-Type": "application/json" } : {}),
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    cache: "no-store",
  });
  let data = null;
  try { data = await res.json(); } catch (_) { /* not JSON */ }
  if (!res.ok) {
    const err = new Error((data && data.error) || `HTTP ${res.status}`);
    err.status = res.status; // 4xx: refused before anything was done; 5xx: it may or may not have been
    throw err;
  }
  return data;
}

// --- DOM helpers: text only ---------------------------------------------------------------------------
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "href") { if (safeUrl(v)) { el.href = v; el.target = "_blank"; el.rel = "noopener noreferrer"; } }
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid === null || kid === undefined || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
const safeUrl = (u) => typeof u === "string" && /^https:\/\/github\.com\//.test(u);
const link = (url, text) => (safeUrl(url) ? h("a", { href: url }, text) : h("span", {}, text));
const pill = (text, kind) => h("span", { class: `pill ${kind || ""}` }, text);
const empty = (text) => h("p", { class: "muted" }, text);
function replace(el, ...kids) { el.replaceChildren(...kids.flat(Infinity).filter((k) => k !== null && k !== undefined && k !== false)); }

// --- asking you: a dialog in the page, never window.confirm or window.prompt --------------------------
// Some browsers (an app's or an editor's built-in one) suppress native dialogs and answer them
// "Cancel" without showing anything, which would make every button silently do nothing. Resolves
// null for Cancel or Esc; for OK, true, or the text typed when `input` (its starting value) is given.
// One dialog at a time, as native ones were: a preview that arrives while another question is open
// waits for it, so an Enter meant for one never answers the other.
let asking = Promise.resolve();
function ask(text, input) {
  const shown = asking.then(() => new Promise((resolve) => {
    const field = input === undefined ? null : h("input", { type: "text", "aria-label": "Reason", autocomplete: "off" });
    if (field) field.value = input;
    // Plain buttons, not a <form method="dialog">: nothing here depends on form submission being allowed.
    const ok = h("button", { type: "button", onclick: () => dlg.close("ok") }, "OK");
    const cancel = h("button", { type: "button", class: "quiet", onclick: () => dlg.close("") }, "Cancel");
    // Enter in the field is OK, except while an input method is composing (keyCode 229 is Safari's commit).
    if (field) field.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); dlg.close("ok"); } });
    const dlg = h("dialog", { class: "ask" }, h("div", { class: "ask-text" }, text), field, h("div", { class: "actions" }, ok, cancel));
    dlg.addEventListener("close", () => {
      dlg.remove();
      resolve(dlg.returnValue === "ok" ? (field ? field.value : true) : null);
    });
    document.body.append(dlg);
    dlg.showModal();
    (field || ok).focus();
  }));
  asking = shown.catch(() => {}); // one dialog that fails must not stop every later one
  return shown;
}

const usd = (n) => (typeof n === "number" ? `$${n.toFixed(2)}` : "–");
const mins = (ms) => (typeof ms === "number" ? `${Math.round(ms / 60000)} min` : "–");
function ago(iso) {
  if (!iso) return "";
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (!isFinite(s)) return "";
  if (s < 90) return "just now";
  if (s < 5400) return `${Math.round(s / 60)} min ago`;
  if (s < 129600) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}
const short = (repo) => repo.split("/")[1];

// --- derived numbers ---------------------------------------------------------------------------------
function onOff(vars, name) {
  if (!vars) return pill("unknown", "warn");
  return vars[name] === "true" ? pill("on", "ok") : pill("off", "off");
}
// Each total, and which ones could not be read (a failed repository makes every one unknown): an
// unknown part is shown as "?", never as 0.
const KEYS = ["waiting", "prs", "queue", "active", "runs", "cost"];
function totals(d) {
  if (!d || d.failed) return { unknown: new Set(KEYS) };
  const s = d.stats || {};
  const unknown = new Set();
  if (!Array.isArray(d.waiting) || d.waiting.some((w) => w.kind === "unknown")) unknown.add("waiting");
  if (!d.prs) unknown.add("prs");
  if (!d.issues) unknown.add("queue");
  if (!d.active_runs) unknown.add("active");
  if (!d.stats) { unknown.add("runs"); unknown.add("cost"); }
  return {
    waiting: (d.waiting || []).filter((w) => w.kind !== "unknown").length,
    prs: (d.prs || []).length,
    queue: d.issues ? d.issues.ready.length : 0,
    active: (d.active_runs || []).length,
    runs: Object.values(s).reduce((a, r) => a + (r.runs || 0), 0),
    cost: Object.values(s).reduce((a, r) => a + (typeof r.cost_usd === "number" ? r.cost_usd : 0), 0),
    unknown,
  };
}
const shown = (t, key, fmt) => `${(fmt || String)(t[key] || 0)}${t.unknown.has(key) ? " ?" : ""}`;
function breakerCell(d) {
  if (d.breakers === null || d.breakers === undefined) return pill("unknown", "warn");
  const tripped = Object.entries(d.breakers).filter(([, b]) => b && b.tripped_at);
  return tripped.length ? tripped.map(([r]) => pill(`${r} stopped`, "bad")) : pill("closed", "ok");
}
function capCell(d, role) {
  const s = d.stats && d.stats[role];
  if (!s) return d.stats ? "–" : "?";
  return `${s.today}/${s.cap ?? "?"}`;
}
function health(d) {
  const out = [];
  if (d.runner_ref === "stale") out.push(pill("runner ref stale", "bad"));
  if (d.runner_ref === "missing") out.push(pill("no runner ref", "bad"));
  if ((d.errors || []).length) out.push(pill(`${d.errors.length} unreadable`, "warn"));
  return out.length ? out : pill("ok", "ok");
}

// --- routes: the address holds the view, so a reload or a shared link lands on the same screen -------
const TABS = [["pipeline", "Pipeline"], ["agents", "Agents"], ["runs", "Runs and spend"], ["settings", "Settings"]];
function parseRoute() {
  const p = location.hash.replace(/^#/, "");
  const m = /^\/r\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)(?:\/(pipeline|agents|runs|settings))?$/.exec(p);
  if (m) return { view: "repo", repo: `${m[1]}/${m[2]}`, tab: m[3] || "pipeline" };
  // Needs you: an optional chip (kind) and the open item (open, a row's key). A key can hold text the
  // repository wrote (a role name, a breaker's time); it goes into the address only encoded, after the
  // "#", and coming back it is only compared with the keys of the rows on screen, never shown.
  const n = /^\/needs(?:\?(.*))?$/.exec(p);
  if (n) {
    let q;
    try { q = new URLSearchParams(n[1] || ""); } catch (_) { q = new URLSearchParams(); }
    const kind = q.get("kind") || "";
    return { view: "needs", kind: /^(request|role|pr|issue|merge|close)$/.test(kind) ? kind : "", open: q.get("open") || "" };
  }
  const v = /^\/(activity|week|repos)$/.exec(p);
  return v ? { view: v[1] } : { view: "needs", kind: "", open: "" };
}
const repoRoute = (repo, tab) => `/r/${repo}${tab && tab !== "pipeline" ? `/${tab}` : ""}`;
function needsRoute(kind, open) {
  const q = new URLSearchParams();
  if (kind) q.set("kind", kind);
  if (open) q.set("open", open);
  const s = q.toString();
  return s ? `/needs?${s}` : "/needs";
}
// An in-page link. Its route is built here from fixed names and repository names the server already
// checked against owner/name; the one exception, a row's key in Needs you, is URL-encoded (needsRoute).
function routeLink(route, attrs, ...kids) {
  const el = h("a", attrs, ...kids);
  el.setAttribute("href", `#${route}`);
  return el;
}
const go = (route) => { location.hash = route; };
// The repository the address names, spelled as the dashboard's list spells it; "" if it is not on it.
function routeRepo() {
  if (state.route.view !== "repo" || !state.session) return "";
  return state.session.repos.find((r) => r.toLowerCase() === state.route.repo.toLowerCase()) || "";
}

// --- Needs you: one row per thing you act on ---------------------------------------------------------
// The counting rule. A row's kind is the pane it will open. A request about a PR (the fixer stopped,
// the merge gate cannot update it, its review never posted) is that PR's row; a stopped role and its
// breaker request are one row; a blocked issue with an open request is the request's row. The folded
// groups count too: "to merge" (passed the gate while auto-merge is a dry run) and "to close" (merged,
// to close once the fix is live). Suggested issues are not here: queueing one is done on GitHub,
// next to its text, from the Pipeline tab.
const CHIPS = [["request", "Requests"], ["role", "Stopped"], ["pr", "PRs"], ["issue", "Issues"], ["merge", "To merge"], ["close", "To close"]];
const KIND_LABEL = { request: "Request", role: "Role", pr: "PR", issue: "Issue", merge: "To merge", close: "To close" };
const FOLDED = { merge: (n) => `${n} ${n === 1 ? "PR" : "PRs"} to merge · passed the gate, auto-merge is a dry run`,
  close: (n) => `${n} merged ${n === 1 ? "issue" : "issues"} to close once live` };
const KIND_VERB = { blocked: "blocked on", failed: "failed on", protected: "needs protected paths for", untrusted: "stopped: changed text on" };
const STUCK = ["agent:blocked", "agent:needs-human"];
const roleName = (r) => (r ? r[0].toUpperCase() + r.slice(1) : "Agent");
const dryRun = (d) => !(d.vars && d.vars.AGENT_AUTO_MERGE === "true");
// What else is read for Needs you. The inbox, when its checklist lists open requests: a request's kind
// is only in its comment. The merge gate's report, when an agent PR could be waiting to be merged by hand.
const needsInbox = (d) => !!(d.inbox && d.inbox.checklist.length);
const needsGate = (d) => (d.prs || []).length > 0 && dryRun(d);

function needRows(repo) {
  const d = state.repos[repo];
  const out = { rows: [], notes: [], loading: false, unknown: false };
  if (!d || d.loading) { out.loading = true; return out; }
  if (d.failed) { out.unknown = true; out.notes.push(`Could not read this repository: ${d.failed}`); return out; }
  for (const w of d.waiting || []) if (w.kind === "unknown") { out.unknown = true; out.notes.push(w.text); }
  const issues = d.issues || {};
  const findIssue = (n) => Object.values(issues).flat().find((i) => i && i.number === n) || null;
  const add = (r) => out.rows.push(Object.assign({ repo }, r));
  // The open requests are the inbox checklist's unticked lines, the same list for every repository
  // whether it is on screen or not; the agents tick a line when its request is answered. A request's
  // kind and time come from its comment. Until the comments are read the requests wait (loading); if
  // they cannot be read, or a line's comment is not among the newest 1,000, the kind is told from the
  // line: the fixer's, merger's and review's start "#<PR>:", a breaker's is "circuit breaker tripped".
  const lines = needsInbox(d) ? d.inbox.checklist : [];
  const got = state.inbox[repo];
  const comments = got && got.requests ? got.requests : null;
  if (lines.length && !comments) {
    if (got && got.error) { out.unknown = true; out.notes.push(`Inbox requests: ${got.error}`); }
    else out.loading = true;
  }
  const guess = (l) => (/^#\d+:/.test(l.summary) ? "fixer" : (/^circuit breaker tripped/.test(l.summary) ? "breaker" : ""));
  const asRequest = (l) => {
    const c = comments ? comments.find((r) => r.id === l.id) : null;
    return { id: l.id, role: c ? c.role : l.role, issue: c ? c.issue : l.issue, kind: c ? c.kind : guess(l),
      created_at: c ? c.created_at : "", summary: l.summary };
  };
  const onPr = (r) => (["fixer", "merger", "review"].includes(r.kind) ? /^#(\d+):/.exec(r.summary) : null);
  // Ticking a line is best effort, so a line whose comment says answered is dropped once that is known.
  const reqs = out.loading ? [] : lines.filter((l) => !(comments && comments.some((r) => r.id === l.id && r.answered))).map(asRequest);
  // While loading, a PR a line names waits for its PR row, so it does not show as "to merge" first.
  const linePr = new Set(out.loading ? lines.map((l) => /^#(\d+):/.exec(l.summary)).filter(Boolean).map((m) => Number(m[1])) : []);
  const prRows = new Map();
  const prRow = (n) => {
    if (!prRows.has(n)) {
      const p = (d.prs || []).find((x) => x.number === n) || null;
      prRows.set(n, { n, p, reqs: [], at: p ? p.updated_at || p.created_at || "" : "" });
    }
    return prRows.get(n);
  };
  const roleReq = {};
  // An issue an open request is about is that request's row, not a blocked issue of its own; decided
  // from the lines even while the comments load, so no row shows as one kind and then moves.
  const issueReq = new Set((out.loading ? lines.map((l) => Object.assign(asRequest(l), { kind: guess(l) })) : reqs)
    .filter((r) => r.issue && r.kind !== "breaker" && !onPr(r)).map((r) => r.issue));
  for (const r of reqs) {
    const pr = onPr(r);
    if (pr) {
      const x = prRow(Number(pr[1]));
      x.reqs.push(r);
      if ((r.created_at || "") > x.at) x.at = r.created_at;
      continue;
    }
    if (r.kind === "breaker") { roleReq[r.role] = r; continue; } // lines are oldest first: the newest wins
    const i = r.issue ? findIssue(r.issue) : null;
    add({ kind: "request", key: `${repo}|req|${r.id}`, at: r.created_at || "", req: r,
      title: `${roleName(r.role)} ${KIND_VERB[r.kind] || (r.kind ? `${r.kind} request` : "request")}${r.issue ? `${KIND_VERB[r.kind] ? "" : " on"} #${r.issue}` : ""}`,
      text: i ? i.title : r.summary || r.id,
      hint: r.kind === "blocked" || r.kind === "failed" ? `Answer on #${r.issue}, then Requeue and rerun` : (KIND_APPROVE[r.kind] || ["Answer it"])[0],
      route: repoRoute(repo) });
  }

  // Stopped roles, each with its breaker request when there is one. "Reset the breaker" answers the
  // request and is on the Pipeline tab; Resume, for a role stopped with no request, is on Agents.
  const known = !!d.breakers; // breaker.json unread: the role's state is not claimed either way
  const breakers = d.breakers || {};
  const roles = new Set([...Object.keys(breakers).filter((r) => breakers[r] && breakers[r].tripped_at), ...Object.keys(roleReq)]);
  for (const role of roles) {
    const b = breakers[role] || {};
    const r = roleReq[role] || null;
    // /resume resets a breaker without answering its request, so a request can outlive the stop.
    const stopped = !!b.tripped_at;
    // The Pipeline tab has "Reset the breaker" only for a request whose comment it read.
    const viaReq = !!(r && comments && comments.some((c) => c.id === r.id));
    add({ kind: "role", role, key: `${repo}|role|${role}|${b.tripped_at || (r && r.id)}`, at: b.tripped_at || (r ? r.created_at : "") || "", req: r,
      title: stopped ? `${roleName(role)} stopped` : `${roleName(role)}: breaker request ${known ? "still open" : "open"}`,
      text: stopped ? b.reason || (r ? r.summary : "") : (known ? "the role runs again" : "could not read whether it is stopped"),
      hint: stopped ? `No ${role} runs until it is reset · ${viaReq ? "Reset the breaker" : "Resume"}`
        : (viaReq ? "Reset the breaker answers the request" : "Answer it on the inbox issue"),
      route: viaReq || !stopped ? repoRoute(repo) : repoRoute(repo, "agents") });
  }

  // Agent PRs held for a person, with any request about them.
  for (const p of d.prs || []) if (p.labels.some((l) => STUCK.includes(l))) prRow(p.number);
  for (const x of prRows.values()) {
    const kinds = x.reqs.map((r) => r.kind);
    const held = x.p && x.p.labels.some((l) => STUCK.includes(l));
    add({ kind: "pr", key: `${repo}|pr|${x.n}`, at: x.at, pr: x.n, reqs: x.reqs,
      title: `PR #${x.n} ${kinds.includes("merger") ? "can't be updated from its base" : (kinds.includes("review") ? "has no Claude review" : (held ? "held for a person" : "needs you"))}`,
      text: x.p ? x.p.title : x.reqs[0].summary,
      hint: kinds.includes("merger") ? "Merge the base in yourself, then Hand back"
        : (kinds.includes("review") ? "Run the review once it can" : "Fix it on GitHub, then Hand back"),
      route: repoRoute(repo) });
  }

  // Blocked issues with no open request.
  for (const i of issues.blocked || []) {
    if (issueReq.has(i.number)) continue;
    add({ kind: "issue", key: `${repo}|issue|${i.number}`, at: i.updated_at || "", issue: i.number,
      title: `#${i.number} blocked`, text: i.title, hint: "No open request · Rerun coder", route: repoRoute(repo) });
  }

  // To merge: the merge gate's last word on a PR nobody holds is "would merge" (a dry run). A PR put on
  // hold or being fixed since keeps that line until the gate runs again, so it is left out.
  const gate = state.gate[repo];
  if (needsGate(d)) {
    if (gate && gate.error) { out.unknown = true; out.notes.push(`Merge gate report: ${gate.error}`); }
    else if (!gate) out.loading = true;
    else {
      for (const p of d.prs) {
        const g = gate.prs && gate.prs[String(p.number)];
        if (prRows.has(p.number) || linePr.has(p.number) || !g || !/^would merge /.test(g.text)
          || p.labels.some((l) => l === "agent:hold" || l === "agent:fixing")) continue;
        add({ kind: "merge", key: `${repo}|merge|${p.number}|${g.text.split(" ")[2] || ""}`, at: g.at || "", pr: p.number,
          title: `PR #${p.number} passed the gate`, text: p.title, hint: "Merge it on GitHub, or turn auto-merge on in Settings", href: p.url });
      }
    }
  }

  // To close: merged, closed by a person once the fix is live.
  for (const i of issues.done_pending_deploy || []) {
    add({ kind: "close", key: `${repo}|close|${i.number}`, at: i.updated_at || "", issue: i.number,
      title: `#${i.number} merged`, text: i.title, hint: "Close it on GitHub once the fix is live", href: i.url });
  }
  return out;
}
// One repository's Needs you count, as text: "n", "n+" (still loading or partly unread), "?" or "".
function needText(x) {
  const n = x.rows.length;
  if (x.loading && !n) return "…";
  return n ? `${n}${x.loading || x.unknown ? "+" : ""}` : (x.unknown ? "?" : "");
}

// NEW: what was not on Needs you the last time you looked at it. Kept in this browser for this
// address (the dashboard's port), so a dashboard started on another port starts over.
const SEEN_KEY = "gatehand-seen";
function loadSeen() {
  try { return JSON.parse(localStorage.getItem(SEEN_KEY) || "{}") || {}; } catch (_) { return {}; }
}
function rememberSeen(rows) {
  try {
    const seen = loadSeen();
    const now = Date.now();
    for (const r of rows) seen[r.key] = now;
    for (const [k, t] of Object.entries(seen)) if (now - t > 30 * 864e5) delete seen[k]; // not seen for 30 days
    localStorage.setItem(SEEN_KEY, JSON.stringify(seen));
  } catch (_) { /* no storage: everything stays NEW */ }
}
function lookAgain() { state.seenBefore = new Set(Object.keys(loadSeen())); }

// --- counts: shown once, in the sidebar and the tab title --------------------------------------------
// A repository still loading, or a part that could not be read, makes a count "n+" (at least n), or
// "?" when nothing else is known: never a clean number that leaves something out.
function counts() {
  const repos = state.session ? state.session.repos : [];
  const c = { needs: 0, needsRepos: 0, needsUnknown: false, needsLoading: false, unread: [], loading: false,
    running: 0, runningUnknown: false, cost: 0, costSeen: false, costFloor: false };
  for (const repo of repos) {
    const x = needRows(repo);
    c.needs += x.rows.length;
    if (x.rows.length) c.needsRepos += 1;
    if (x.loading) c.needsLoading = true;
    if (x.unknown) { c.needsUnknown = true; c.unread.push(repo); }
    const d = state.repos[repo];
    if (!d || d.loading) { c.loading = true; continue; }
    if (d.failed) { c.runningUnknown = c.costFloor = true; continue; }
    const t = totals(d);
    c.running += t.active;
    if (t.unknown.has("active")) c.runningUnknown = true;
    if (d.stats) {
      c.costSeen = true;
      c.cost += t.cost;
      if ((d.runs || []).some((r) => typeof r.cost_usd !== "number")) c.costFloor = true;
    } else c.costFloor = true;
  }
  const n = (v, unknown, loading) => (unknown && !v && !loading ? "?" : `${v}${loading || unknown ? "+" : ""}`);
  c.needsText = n(c.needs, c.needsUnknown, c.needsLoading);
  c.runningText = c.loading || c.running || c.runningUnknown ? `${n(c.running, c.runningUnknown, c.loading)} running` : "none running";
  // A floor: runs with no cost recorded count for nothing, and Claude review runs are not in the ledger.
  c.costText = c.costSeen || !repos.length ? `${usd(c.cost)}${c.costFloor || c.loading ? "+" : ""}` : (c.loading ? "…" : "?");
  return c;
}
function repoBadge(repo) {
  const d = state.repos[repo];
  const x = needRows(repo);
  const text = needText(x);
  if (d && d.breakers && Object.values(d.breakers).some((b) => b && b.tripped_at)) return [text ? `stopped · ${text}` : "stopped", "bad"];
  return [text, x.unknown ? "warn" : ""];
}

// --- rendering ---------------------------------------------------------------------------------------
function renderSide() {
  const c = counts();
  const r = state.route;
  const repos = state.session ? state.session.repos : [];
  const ex = state.session ? state.session.excluded : [];
  // Short names, unless two repositories share one.
  const label = (repo) => (repos.filter((x) => short(x) === short(repo)).length > 1 ? repo : short(repo));
  const item = (route, on, text, badge, badgeKind, cls, title) => routeLink(route,
    { class: `${cls || "side-item"}${on ? " on" : ""}`, "aria-current": on ? "page" : null, title: title || null },
    h("span", { class: "side-label" }, text), badge ? h("span", { class: `badge ${badgeKind || ""}` }, badge) : null);
  replace($("side"),
    item("/needs", r.view === "needs", "Needs you", c.needsText, c.needs ? "attn" : (c.needsUnknown ? "warn" : "")),
    item("/activity", r.view === "activity", "Activity", c.runningText),
    item("/week", r.view === "week", "Week", c.costText),
    item("/repos", r.view === "repos", `Repositories · ${repos.length}`, null, null, "side-head"),
    repos.map((repo) => {
      const [badge, kind] = repoBadge(repo);
      return item(repoRoute(repo), r.view === "repo" && repo === routeRepo(), label(repo), badge, kind, "side-item repo", repo);
    }),
    // Already on #/repos the address does not change, so the link goes to the form itself.
    item("/repos", false, `Find · add${ex.length ? ` · ${ex.length} hidden` : ""}`, null, null, "side-foot"));
  $("side").lastChild.addEventListener("click", () => { if (state.route.view === "repos") $("add-repo").focus(); });
  document.title = c.needsText === "0" ? "Gatehand" : `(${c.needsText}) Gatehand`;
}

function viewHead(title, ...rest) {
  return h("div", { class: "view-head" }, h("h2", {}, title), rest.length ? h("span", { class: "muted" }, ...rest) : null);
}
function repoHeading(repo) {
  return h("h3", {}, routeLink(repoRoute(repo), {}, repo));
}

// A row of Needs you. It opens the item pane beside the list; the address keeps the chip.
function needRow(r, isNew, on) {
  const kids = [
    h("div", { class: "lmeta" }, h("span", { class: `dot${isNew ? "" : " old"}`, "aria-hidden": "true" }),
      `${short(r.repo)} · ${KIND_LABEL[r.kind]}${r.at ? ` · ${ago(r.at)}` : ""}`, isNew ? h("span", { class: "new" }, "NEW") : null),
    h("div", { class: "ltitle" }, h("strong", {}, r.title), r.text ? ` ${r.text}` : ""),
    h("div", { class: "lhint" }, r.hint)];
  return routeLink(needsRoute(state.route.kind, r.key), { class: `lrow${on ? " on" : ""}`, title: r.repo,
    "aria-current": on ? "true" : null }, kids);
}

function needsView() {
  const repos = state.session ? state.session.repos : [];
  const per = repos.map((repo) => [repo, needRows(repo)]);
  const rows = per.flatMap(([, x]) => x.rows).sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  const isNew = (r) => !state.seenBefore.has(r.key);
  const c = counts();
  const kind = state.route.kind || "";
  const of = (k) => rows.filter((r) => r.kind === k);
  rememberSeen(kind ? of(kind) : rows); // only what is on screen counts as looked at
  // A kind's count, like the total, is a floor while something is loading or could not be read.
  const more = c.needsLoading || c.needsUnknown ? "+" : "";
  const chip = (k, label, count) => routeLink(needsRoute(k),
    { class: `chip${kind === k ? " on" : ""}`, "aria-current": kind === k ? "page" : null }, `${label} ${count}`);
  const chips = h("div", { class: "chips" }, chip("", "All", c.needsText),
    CHIPS.filter(([k]) => of(k).length || kind === k).map(([k, label]) => chip(k, label, `${of(k).length}${more}`)));
  const newCount = rows.filter(isNew).length;
  const summary = [
    `${c.needsText} in ${c.needsRepos} ${c.needsRepos === 1 ? "repository" : "repositories"}`,
    newCount ? ` · ${newCount} new` : "",
    c.needsLoading ? " · still loading" : "",
    c.unread.length ? ` · could not read all of ${c.unread.map(short).join(", ")}` : ""];

  // The open item: the one the address names, else the first row as listed (the landing opens the top
  // item). Rows in a folded group come after the others, as they are shown.
  const shownRows = kind ? of(kind) : [...rows.filter((r) => !FOLDED[r.kind]), ...Object.keys(FOLDED).flatMap(of)];
  const want = state.route.open;
  const sel = want ? shownRows.find((r) => r.key === want) || null : shownRows[0] || null;
  // The top row, once open, is pinned in the address: a newer row arriving does not take the pane
  // from under you, and once it is answered the pane says what happened instead of moving on.
  // Only while the address itself still says Needs you with nothing open: a navigation not yet handled wins.
  const said = parseRoute();
  if (!want && sel && said.view === "needs" && !said.open) {
    state.route.open = sel.key;
    history.replaceState(null, "", `${location.pathname}#${needsRoute(kind, sel.key)}`);
  }
  const row = (r) => needRow(r, isNew(r), sel === r);
  let list;
  if (kind) {
    list = of(kind).map(row);
  } else {
    list = [rows.filter((r) => !FOLDED[r.kind]).map(row),
      Object.keys(FOLDED).map((k) => (of(k).length ? h("details", { class: "fold", open: of(k).includes(sel) },
        h("summary", {}, FOLDED[k](of(k).length), of(k).some(isNew) ? h("span", { class: "new" }, "NEW") : null),
        of(k).map(row)) : null))];
  }
  // What could not be read: named, never counted.
  const unread = per.filter(([, x]) => x.notes.length).map(([repo, x]) => h("div", { class: "lrow unread" },
    h("div", { class: "lmeta" }, `${short(repo)} · could not read · not counted`),
    x.notes.map((n) => h("div", {}, n)),
    routeLink(repoRoute(repo), {}, `Open ${repo}`)));
  const any = rows.length && (!kind || of(kind).length);
  const pane = sel ? itemPane(sel) : (want ? gonePane(want, c) : null);
  return [viewHead("Needs you", ...summary), chips,
    h("div", { class: `needs-split${pane ? "" : " no-pane"}` },
      h("div", { class: "needs-list" }, any ? list
        : empty(c.needsLoading && !rows.length ? "Loading…"
          : (kind ? "None of these." : (c.unread.length ? "Nothing that could be read needs you." : "Nothing needs you."))),
      kind ? null : unread),
      pane ? h("section", { class: "pane card", id: "pane", "aria-label": "Item" }, pane) : null)];
}

// --- the item pane: the one place to act on a row ------------------------------------------------------
// Every pane: a header line and the title; then, as its kind has them, a stage track, why it is stuck
// and what happens next, the text the agent wrote (as text), a step on GitHub first, one primary action
// with the last seven days beside it, the confirm opening under the button, a timeline, and GitHub
// detail folded. What the pane is doing (a confirm open, a command posted) is kept per row in
// state.pane / state.paneMsg, so a re-render while data arrives leaves it as it was.
state.pane = { key: "", confirm: "", text: "", fixer: true, preview: null };
state.paneMsg = {};
const kv = (label, ...v) => h("div", { class: "kv" }, h("span", { class: "k" }, label), h("span", {}, ...v));
const hhmm = (t) => new Date(t).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const cap1 = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);

function itemPane(r) {
  if (state.pane.key !== r.key) state.pane = { key: r.key, confirm: "", text: "", fixer: true, preview: null };
  const pane = { request: requestPane, role: rolePane, pr: prPane, issue: issuePane, merge: mergePane, close: closePane }[r.kind] || framePane;
  return pane(r);
}

// A row of a kind with no pane of its own: what the row says, and where to act on it.
function framePane(r) {
  const tab = r.route && /\/agents$/.test(r.route) ? "Agents" : "Pipeline";
  return [h("div", { class: "pane-head" }, [r.repo, KIND_LABEL[r.kind], r.at ? ago(r.at) : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    kv("What to do", r.hint),
    h("p", {}, r.route ? routeLink(r.route, {}, `Act on it on ${short(r.repo)}'s ${tab} tab`) : link(r.href, "Open it on GitHub ↗"))];
}

// The selected row is gone: answered, or no longer read as waiting. Says what was done here, if
// anything; if its repository is loading or could not be read, it says that rather than guess.
function gonePane(key, c) {
  const msg = state.paneMsg[key];
  const repo = (state.session ? state.session.repos : []).find((r) => key.startsWith(`${r}|`)) || "";
  const top = h("p", {}, routeLink(needsRoute(state.route.kind), {}, "Open the top item"));
  // Still loading what the row is made of (the repository, its inbox, the merge gate's report).
  if (!msg && (repo ? needRows(repo).loading : c.needsLoading)) return empty("Loading…");
  if (repo && c.unread.includes(repo)) {
    return [h("p", {}, `${repo} could not be read just now, so it is not known whether this still waits for you.`), msg ? paneState(msg) : null, top];
  }
  return [h("p", {}, "This no longer waits for you."), msg ? paneState(msg) : null, top];
}

// What each kind of inbox request means, in the words of the request the agent filed
// (agent-state.sh request_body), and the step on GitHub that comes before answering.
const REQ_PANE = {
  blocked: {
    why: (n) => `The coder stopped on #${n} and needs a decision.`,
    next: (n) => `Nothing until you answer. The next run on #${n} reads what you wrote there.`,
    step: (n, url) => [h("strong", {}, "Answer on the issue. "), link(url, `Comment on #${n} on GitHub ↗`),
      h("div", { class: "muted" }, `On #${n} itself, not the inbox. The next run reads comments from people with write access; others are left out.`)],
  },
  failed: {
    why: (n) => `The coder failed #${n} on its last allowed attempt.`,
    next: () => "Nothing until you answer.",
    step: (n, url) => [h("strong", {}, "If the issue was unclear, "), link(url, `edit #${n} on GitHub ↗`), " first.",
      h("div", { class: "muted" }, "The next run reads the issue again, with comments from people with write access.")],
  },
  protected: {
    why: (n) => `The coder's change for #${n} touches protected paths, so it was not pushed.`,
    next: () => "Nothing until you answer. Allowing it is for one attempt; the PR says so, and a person merges it.",
    step: null,
  },
  untrusted: {
    why: (n) => `Someone without write access changed #${n} after the label the run trusts, or its trust check failed, so nothing reached the agent.`,
    next: (n) => `Nothing runs on #${n} until a person with write access vouches for its text.`,
    step: (n, url) => [h("strong", {}, "Read the change, then re-apply agent:ready yourself "), link(url, `on #${n} on GitHub ↗`),
      h("div", { class: "muted" }, "Only your own label vouches for the text. Then Acknowledge here, which ticks the request and changes nothing, and rerun the coder from the Pipeline tab.")],
  },
};
const REQUEUE = new Set(["blocked", "failed", "protected"]);

function requestActs(r, d, full) {
  const q = r.req;
  const n = q.issue;
  const [text, effect] = KIND_APPROVE[q.kind] || ["Approve", "the repository's own hook for this kind of request runs"];
  const off = inboxOff(d, full, state.paneMsg[r.key], true);
  const s = d.stats && d.stats[q.role];
  const expect = ["Its reply on the inbox within a minute or two."];
  if (REQUEUE.has(q.kind)) {
    expect.push("A run named for an issue skips the attempt cap.");
    if (s) expect.push(s.cap === null || s.cap === undefined ? `${s.today} ${q.role} runs today.` : `Today ${s.today} of ${s.cap} ${q.role} runs are used.`);
    if (d.vars && d.vars.AGENTS_ENABLED !== "true") expect.push("The agents are off in this repository, so the run does not start until they are on.");
  }
  const acts = [inboxAct(r, { id: "approve", text, title: `${text}${n ? ` #${n}` : ""}?`, off, req: q.id,
    cmd: () => `/approve ${q.id}`, payload: () => ({ command: "approve", req: q.id }), then: effect, expect: expect.join(" ") })];
  if (!SEEN_ONLY.has(q.kind)) {
    acts.push(rejectAct(r, q, off, KIND_APPROVE[q.kind] ? `#${n} stays as it is, gets the reason as a comment, and loses agent:needs-human`
      : "the repository's own hook for this kind of request decides"));
  }
  return acts;
}

function requestPane(r) {
  const repo = r.repo;
  const d = state.repos[repo];
  const q = r.req;
  const got = state.inbox[repo];
  const full = got && got.requests ? got.requests.find((x) => x.id === q.id) || null : null;
  const n = q.issue || null;
  const issueUrl = n ? `${d.url}/issues/${n}` : null;
  const kindText = REQ_PANE[q.kind];
  const issue = n ? Object.values(d.issues || {}).flat().find((i) => i && i.number === n) : null;
  // The ledger rows (the last seven days) about this issue: the timeline, and the runs and cost beside the action.
  const runs = n && d.runs ? d.runs.filter((x) => x.issue === n) : [];
  const mine = runs.filter((x) => x.role === q.role && x.counted !== false);
  const noCost = mine.filter((x) => typeof x.cost_usd !== "number").length;
  const spent = mine.reduce((a, x) => a + (typeof x.cost_usd === "number" ? x.cost_usd : 0), 0);
  const beside = !n ? null : (d.runs ? `Last 7 days on #${n}: ${mine.length} ${q.role} ${mine.length === 1 ? "run" : "runs"} · ${usd(spent)}${noCost ? `+ (${noCost} without a cost)` : ""}`
    : `Last 7 days on #${n}: the ledger could not be read`);
  const events = [...runs.map((x) => ({ at: x.started_at || x.ended_at || "", text: `${roleName(x.role)} run · ${x.outcome || "?"}${typeof x.cost_usd === "number" ? ` · ${usd(x.cost_usd)}` : ""}`, url: x.run_url })),
    { at: q.created_at || (full && full.created_at) || "", text: `Request ${q.id} filed`, url: full && full.url }]
    .filter((e) => e.at).sort((a, b) => (a.at < b.at ? -1 : 1));

  return [
    h("div", { class: "pane-head" }, [repo, `Inbox request ${q.id}`, q.kind ? `kind ${cap1(q.kind)}` : "kind unknown", q.role, q.created_at ? ago(q.created_at) : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    REQUEUE.has(q.kind) || q.kind === "untrusted" ? track(1, `Coder · ${q.kind}`) : null,
    kv("Why it's stuck", kindText && n ? kindText.why(n) : `The ${q.role} filed ${q.kind ? `a ${q.kind}` : "a"} request${n ? ` on #${n}` : ""}.`),
    kv("What happens next", kindText && n ? kindText.next(n) : "Nothing until you answer."),
    h("div", { class: "said" }, h("div", { class: "muted" }, "What the agent wrote (plain text from GitHub)"),
      h("pre", { class: "body" }, full ? full.body : q.summary)),
    kindText && kindText.step && n ? h("div", { class: "step" }, h("span", { class: "num" }, "1"), h("div", {}, kindText.step(n, issueUrl))) : null,
    h("div", { class: "step" }, kindText && kindText.step && n ? h("span", { class: "num" }, "2") : null,
      h("div", {}, paneActions(r, requestActs(r, d, full), beside))),
    events.length ? h("details", fold("timeline"), h("summary", {}, `Timeline${n ? ` #${n}` : ""} · ${events.length} ${events.length === 1 ? "event" : "events"} (last 7 days)`),
      h("ul", { class: "items" }, events.map((e) => h("li", {}, h("span", { class: "muted" }, `${String(e.at).slice(5, 16).replace("T", " ")} `),
        e.url ? link(e.url, `${e.text} ↗`) : e.text)))) : null,
    h("details", fold("gh"), h("summary", {}, "GitHub detail"),
      h("div", {}, issue ? `labels: ${issue.labels.join(", ") || "none"} · ` : "",
        d.inbox ? link(d.inbox.url, `inbox #${d.inbox.number}`) : "no inbox",
        d.vars ? ` · AGENT_OWNER_LOGIN=${d.vars.AGENT_OWNER_LOGIN || "(not set)"}` : "",
        full && full.url ? [" · ", link(full.url, "the request comment ↗")] : null))];
}

// A fold in the pane stays open or shut as you left it while data arriving re-draws the pane.
state.folds = {};
const fold = (name) => ({ class: name, open: !!state.folds[name], ontoggle: (e) => { state.folds[name] = e.currentTarget.open; } });

// The stages of an issue and its PR, one of them marked. Only drawn where the stage is known from
// the row itself.
function track(at, label) {
  const stages = ["Queued", "Coder", "In review", "Merge gate", "Merged"];
  stages[at] = label;
  return h("ol", { class: "track", "aria-label": "Stage" }, stages.map((s, i) => h("li", { class: i === at ? "on" : (i < at ? "past" : null),
    "aria-current": i === at ? "step" : null }, s)));
}

// --- actions in a pane ---------------------------------------------------------------------------------
// Every pane acts through paneActions: one primary button and quieter ones, each opening its confirm in
// the pane under the buttons, and in its place afterwards one of three states: disabled with the reason,
// refused (nothing was done), or waiting for the answer. An action:
//   { id, text, off (why it is disabled, or ""), title (the confirm's question),
//     field: { id, label, placeholder, max, note } (a reject reason, or a verdict's note),
//     cmd: (text) => the inbox line it posts, shown as it is typed,
//     lines: [[label, value], ...] what else the confirm says,
//     extra: (pane) => more controls (the verdict's "start the fixer"),
//     preview: (pane) => payload, for runs and verdicts: the server's preview is the confirm,
//     go: async (pane) => the message to show after; throws an error with the HTTP status if refused,
//     verb: "posted" or "done", postText: the confirm button's text }
// A post in flight is kept per row (state.posting), so opening another item meanwhile neither
// re-enables these buttons nor loses that item's own confirm.
state.posting = new Set();
const NOT_READ = "This request's comment was not read (the inbox could not be read, or it is older than the newest 1,000 comments), so it is not answered from here: answer it on the inbox.";
const POSTED = "Your answer is posted; waiting for the Agent inbox workflow to apply it.";
function inboxOff(d, full, msg, needFull) {
  if (needFull && !full) return NOT_READ;
  if ((full && full.pending) || (msg && msg.kind === "waiting")) return POSTED;
  return answerBlock(d);
}

function paneActions(r, acts, beside, opts) {
  const quiet = !!(opts && opts.quiet); // no primary here: the main step is a link to GitHub
  const p = state.pane;
  // An outcome older than the row's latest change (a PR stuck again since) is old news.
  if (state.paneMsg[r.key] && r.at && Date.parse(r.at) > (state.paneMsg[r.key].at || Infinity) + 60000) delete state.paneMsg[r.key]; // a minute for clocks
  const msg = state.paneMsg[r.key];
  const busy = state.posting.has(r.key);
  const d = state.repos[r.repo];
  const open = (a) => () => {
    if (msg && msg.kind !== "waiting") delete state.paneMsg[r.key]; // trying again: the last outcome is old news
    state.pane = { key: r.key, confirm: a.id, text: "", fixer: true, preview: null };
    state.focusId = a.field ? a.field.id : "confirm-post";
    renderView();
    if (a.preview && !a.field) fetchPreview(r, a);
  };
  const buttons = h("div", { class: "actions" },
    acts.map((a, i) => h("button", { type: "button", class: i || quiet ? "quiet" : null, disabled: !!a.off || busy, title: a.off || null, onclick: open(a) }, a.text)),
    beside ? h("span", { class: "muted beside" }, beside) : null);
  const a = acts.find((x) => x.id === p.confirm);
  const first = acts[0];
  let below = null;
  if (a && (busy || !a.off)) below = paneConfirm(r, a, busy);
  else if (busy) below = h("div", { class: "state waiting" }, "Working…");
  else if (msg) below = paneState(msg);
  else if (first && first.off && !quiet) {
    below = h("div", { class: `state ${first.off === POSTED ? "waiting" : "off"}` }, first.off,
      first.off === NOT_READ && d.inbox ? [" ", link(d.inbox.url, `Inbox #${d.inbox.number} ↗`)] : null);
  }
  return [buttons, below];
}

function paneConfirm(r, a, busy) {
  const p = state.pane;
  const d = state.repos[r.repo];
  const code = a.cmd ? h("code", {}, a.cmd(p.text)) : null;
  const go = () => runAct(r, a);
  let field = null;
  if (a.field) {
    field = h(a.field.note ? "textarea" : "input", { id: a.field.id, "aria-label": a.field.label, placeholder: a.field.placeholder,
      maxlength: a.field.max, autocomplete: "off", disabled: busy, rows: a.field.note ? 4 : null, type: a.field.note ? null : "text",
      oninput: (e) => { p.text = e.target.value; if (code) code.textContent = a.cmd(p.text); },
      onkeydown: a.field.note ? null : (e) => { if (e.key === "Enter" && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); go(); } } });
    field.value = p.text;
  }
  const pv = p.preview;
  const stale = a.preview && pv && pv.forKey !== JSON.stringify(a.preview(p));
  let shown = null;
  if (a.preview && pv && !stale) {
    if (pv.loading) shown = h("div", { class: "muted" }, "Asking the server what it would do…");
    else if (pv.error) shown = h("div", { class: "state refused" }, `Nothing was done: ${pv.error}.`);
    else {
      shown = [kv("It will", cap1(pv.summary)), kv("Then", `${cap1(pv.effect)}.`),
        pv.warnings.map((w) => kv("Note", `${cap1(w)}.`)),
        kv("GitHub calls", h("div", {}, pv.calls.map((c) => h("div", {}, h("code", {}, c))))),
        pv.comment ? [h("div", { class: "muted" }, "The comment"), h("pre", { class: "body" }, pv.comment)] : null];
    }
  }
  const ready = !a.preview || (pv && !stale && pv.confirm);
  const cancel = () => { state.pane = { key: r.key, confirm: "", text: "", fixer: true, preview: null }; renderView(); };
  return h("div", { class: "confirm", role: "group", "aria-label": "Confirm" },
    h("strong", {}, a.title),
    kv("Acts as", state.session.viewer),
    field, a.extra ? a.extra(p) : null,
    code ? kv("Posts on", link(d.inbox.url, `inbox #${d.inbox.number}`), ": ", code) : null,
    (a.lines || []).map(([k, v]) => kv(k, v)),
    shown,
    h("div", { class: "actions" },
      ready
        ? h("button", { type: "button", id: "confirm-post", disabled: busy, onclick: go }, busy ? "Working…" : (a.postText || "Post the command"))
        : h("button", { type: "button", id: "confirm-post", disabled: busy || (pv && pv.loading && !stale), onclick: () => fetchPreview(r, a) },
          a.field ? "Preview" : "Ask again"),
      h("button", { type: "button", class: "quiet", disabled: busy, onclick: cancel }, "Cancel")));
}

// Runs, verdicts and switches: the server says exactly what it would do and hands back a one-time
// token; the action is done only with that token, and only if nothing changed in between.
async function fetchPreview(r, a) {
  const payload = a.preview(state.pane);
  const forKey = JSON.stringify(payload);
  state.pane.preview = { loading: true, forKey };
  renderView();
  let pv;
  try { pv = Object.assign(await api("/api/action/preview", { method: "POST", body: Object.assign({ repo: r.repo, viewer: state.session.viewer }, payload) }), { forKey }); }
  catch (e) { pv = { error: e.message, forKey }; }
  if (state.pane.key === r.key && state.pane.confirm === a.id) { state.pane.preview = pv; renderView(); }
}

async function runAct(r, a) {
  const p = state.pane;
  if (state.posting.has(r.key)) return; // one action per row at a time: Enter held down, or a second click
  if (a.preview && !(p.preview && p.preview.confirm && p.preview.forKey === JSON.stringify(a.preview(p)))) { fetchPreview(r, a); return; }
  state.posting.add(r.key);
  renderView();
  try {
    const out = await a.go(p);
    state.paneMsg[r.key] = Object.assign({ at: Date.now() }, out);
  } catch (e) {
    // A 4xx is the server refusing before it acts (who may do it, already answered, a command still
    // waiting, the PR moved since the preview). A 5xx, or no answer from the dashboard at all, may
    // come after it acted.
    const verb = a.verb || "done";
    state.paneMsg[r.key] = Object.assign({ at: Date.now() }, e.partial ? { kind: "note", text: `Partly done: ${e.message}.` }
      : (e.status >= 400 && e.status < 500 ? { kind: "refused", text: `Nothing was ${verb}: ${e.message}.` }
        : { kind: "unknown", text: `It is not known whether anything was ${verb} (${e.message}): look on GitHub before trying again.` }));
  }
  state.posting.delete(r.key);
  if (state.pane.key === r.key) state.pane = { key: r.key, confirm: "", text: "", fixer: true, preview: null };
  renderView();
  await loadRepo(r.repo, true);
}

function paneState(msg) {
  if (msg.kind === "waiting") {
    return h("div", { class: "state waiting" }, `Posted ${hhmm(msg.at)} `, msg.url ? link(msg.url, `${msg.line} ↗`) : h("code", {}, msg.line),
      " · waiting for the Agent inbox workflow · checking every 10 s for 2 min");
  }
  return h("div", { class: `state ${{ refused: "refused", done: "done" }[msg.kind] || "note"}` }, msg.text);
}

// The kinds of action. An inbox command, as the inbox workflow reads it from AGENT_OWNER_LOGIN.
function inboxAct(r, o) {
  return { id: o.id, text: o.text, title: o.title, field: o.field, cmd: o.cmd, off: o.off, verb: "posted",
    lines: [["Then", `${cap1(o.then)}.`], ["Expect", o.expect]],
    go: async (p) => {
      const out = await api("/api/action", { method: "POST", body: Object.assign({ repo: r.repo, viewer: state.session.viewer, type: "inbox_command" }, o.payload(p.text)) });
      watchAnswer(r.repo, o.req || "", r.key);
      return { kind: "waiting", line: out.posted, url: out.url, at: Date.now() };
    } };
}
function rejectAct(r, q, off, effect) {
  return inboxAct(r, { id: "reject", text: "Reject…", title: `Reject ${q.id}?`, off, req: q.id,
    field: { id: "reject-reason", label: "Reason", placeholder: "Reason (optional, one line)", max: 300 },
    cmd: (t) => `/reject ${q.id} ${oneLine(t, 300)}`.trimEnd(), payload: (t) => ({ command: "reject", req: q.id, reason: t }),
    then: effect, expect: "Its reply on the inbox within a minute or two." });
}
// Labels, one GitHub call each, as a person with write access.
function labelAct(r, o) {
  const n = o.number;
  return { id: o.id, text: o.text, title: o.title, off: o.off, postText: o.postText, lines: o.lines,
    go: async () => {
      const done = [];
      for (const [op, label] of o.labels) {
        try { await api("/api/action", { method: "POST", body: { repo: r.repo, viewer: state.session.viewer, type: "label", op, label, number: n } }); }
        catch (e) {
          if (done.length) { e.partial = true; e.message = `${done.join(" and ")} done on #${n}, then: ${e.message}`; }
          throw e;
        }
        done.push(`${op === "add" ? "added" : "took off"} ${label}`);
      }
      return { kind: "done", text: o.doneText };
    } };
}
// A run or a verdict: previewed by the server, then done with its one-time token.
function previewAct2(r, o) {
  return { id: o.id, text: o.text, title: o.title, off: o.off, field: o.field, extra: o.extra, preview: o.payload, postText: "Confirm",
    go: async (p) => {
      const out = await api("/api/action", { method: "POST", body: Object.assign({ repo: r.repo, viewer: state.session.viewer }, o.payload(p), { confirm: p.preview.confirm }) });
      return { kind: "done", text: `Done: ${out.done}.` };
    } };
}

// The last seven days of ledger rows: how many runs, and what they cost (a floor: a run with no cost
// recorded adds nothing).
function runsCost(rows) {
  const noCost = rows.filter((x) => typeof x.cost_usd !== "number").length;
  const spent = rows.reduce((a, x) => a + (typeof x.cost_usd === "number" ? x.cost_usd : 0), 0);
  return `${usd(spent)}${noCost ? ` + ${noCost} with no cost recorded` : ""}`;
}
const runEvent = (x) => ({ at: x.started_at || x.ended_at || "", url: x.run_url,
  text: `${roleName(x.role)} run${x.pr ? ` on PR #${x.pr}` : (x.issue ? ` on #${x.issue}` : "")} · ${x.outcome || "?"}${typeof x.cost_usd === "number" ? ` · ${usd(x.cost_usd)}` : ""}` });
function timeline(label, events) {
  const ev = events.filter((e) => e.at).sort((a, b) => (a.at < b.at ? -1 : 1));
  if (!ev.length) return null;
  return h("details", fold("timeline"), h("summary", {}, `Timeline ${label} · ${ev.length} ${ev.length === 1 ? "event" : "events"} (last 7 days)`),
    h("ul", { class: "items" }, ev.map((e) => h("li", {}, h("span", { class: "muted" }, `${String(e.at).slice(5, 16).replace("T", " ")} `),
      e.url ? link(e.url, `${e.text} ↗`) : e.text))));
}
const step = (num, ...kids) => h("div", { class: "step" }, num ? h("span", { class: "num" }, num) : null, h("div", {}, ...kids));
const utc = (iso) => `${String(iso).slice(0, 16).replace("T", " ")} UTC`;

// --- the role pane: a stopped role, or a breaker request still open -------------------------------------
// A role is not on the pipeline, so its run streak stands where the stages would.
function rolePane(r) {
  const repo = r.repo;
  const d = state.repos[repo];
  const role = r.role;
  const known = !!d.breakers;
  const b = (d.breakers && d.breakers[role]) || {};
  const stopped = !!b.tripped_at;
  const q = r.req;
  const got = state.inbox[repo];
  const full = q && got && got.requests ? got.requests.find((x) => x.id === q.id) || null : null;
  const msg = state.paneMsg[r.key];
  const s = d.stats && d.stats[role];
  const inPolicy = !!(d.policy && d.policy.roles && d.policy.roles[role]);
  // The newest ledger rows of this role, as many as the breaker counts in a row (the ledger keeps seven days).
  const count = typeof b.consecutive === "number" ? b.consecutive : 0;
  const streak = d.runs ? d.runs.filter((x) => x.role === role && x.counted !== false)
    .sort((x, y) => ((x.started_at || "") < (y.started_at || "") ? 1 : -1)).slice(0, count).reverse() : null;
  const queued = d.issues ? d.issues.ready.length : null;
  const today = s ? ` · today ${s.today}${s.cap === null || s.cap === undefined ? "" : ` of ${s.cap}`}` : "";
  // /pause trips the breaker with this reason and keeps the count (agent-ledger.sh): not a failure streak.
  const paused = b.reason === "paused by the owner";
  const expect = `Its reply on the inbox within a minute or two. Nothing starts now: ${role === "coder"
    ? "the next scheduled coder run picks from the queue."
    : (role === "fixer" ? "the fixer runs again the next time CI fails or a review asks for changes on an agent PR." : `the ${role} runs again when it is next started.`)}`;

  const acts = [];
  if (q && full) {
    const off = inboxOff(d, full, msg, true);
    acts.push(inboxAct(r, { id: "approve", text: KIND_APPROVE.breaker[0], title: `Reset the ${role}'s breaker in ${repo}?`, off, req: q.id,
      cmd: () => `/approve ${q.id}`, payload: () => ({ command: "approve", req: q.id }), then: KIND_APPROVE.breaker[1], expect }));
    acts.push(rejectAct(r, q, off, stopped ? `the ${role} stays stopped` : `the ${role}'s breaker stays as it is`));
  } else if (stopped) {
    const off = !d.policy_ok ? "policy.json could not be read, so it is not known whether /resume applies to this role."
      : (!inPolicy ? `${role} is not a role in this repository's policy.json, so /resume is not offered.` : inboxOff(d, null, msg, false));
    acts.push(inboxAct(r, { id: "resume", text: "Resume", title: `Resume the ${role} in ${repo}?`, off,
      cmd: () => `/resume ${role}`, payload: () => ({ command: "resume", role }), then: `the ${role} is resumed and its circuit breaker reset`,
      expect: `${expect}${q ? ` Its breaker request ${q.id} stays open until it is answered on the inbox.` : ""}` }));
  }

  return [
    h("div", { class: "pane-head" }, [repo, "Role", role, stopped ? `stopped since ${utc(b.tripped_at)}` : (known ? "running" : "state unknown"),
      q ? `request ${q.id}` : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    paused ? h("ol", { class: "track", "aria-label": "State" }, h("li", { class: "on" }, "Paused by the owner"))
      : (streak && streak.length ? h("ol", { class: "track", "aria-label": "Run streak" },
        streak.map((x) => h("li", { class: "past" }, `run · ${x.outcome || "?"}`)),
        stopped ? h("li", { class: "on" }, `Stopped after ${count} in a row`) : null) : null),
    kv("Why it's stopped", !known ? "The breaker state (state/breaker.json) could not be read."
      : (stopped ? `${b.reason || "Its breaker tripped."}` : "Its breaker was reset, but its breaker request is still open.")),
    kv("What happens next", stopped
      ? `No ${role} runs in ${short(repo)} until it is reset${role === "coder" && queued !== null ? `; ${queued} queued ${queued === 1 ? "issue waits" : "issues wait"}` : ""}. No agent PR merges either: the merge gate stops on any tripped breaker.`
      : (known ? `The ${role} runs. Answering the request ticks it.` : "Not known.")),
    full ? h("div", { class: "said" }, h("div", { class: "muted" }, "What the agent wrote (plain text from GitHub)"), h("pre", { class: "body" }, full.body)) : null,
    !paused && streak && streak.length ? h("div", {}, h("div", { class: "muted" }, `The last ${streak.length} ${role} runs in the ledger`),
      h("ul", { class: "items" }, streak.map((x) => { const e = runEvent(x); return h("li", {}, h("span", { class: "muted" }, `${String(e.at).slice(5, 16).replace("T", " ")} `), e.url ? link(e.url, `${e.text} ↗`) : e.text); }))) : null,
    acts.length ? step(null, paneActions(r, acts, !paused && streak && streak.length ? `These ${streak.length} runs: ${runsCost(streak)}${today}` : (today ? today.slice(3) : null)))
      : h("div", { class: "state off" }, q && !full ? NOT_READ : "Nothing to do here.", q && !full && d.inbox ? [" ", link(d.inbox.url, `Inbox #${d.inbox.number} ↗`)] : null),
    h("details", fold("gh"), h("summary", {}, "GitHub detail"),
      h("div", {}, `agent-ledger: state/breaker.json · ${role}.consecutive=${known ? (b.consecutive ?? 0) : "?"} · tripped_at ${b.tripped_at || "–"} · `,
        d.inbox ? link(d.inbox.url, `inbox #${d.inbox.number}`) : "no inbox",
        full && full.url ? [" · ", link(full.url, "the request comment ↗")] : null))];
}

// The quieter actions on an open agent PR: Hold or Release, Run review, Run merge gate, and the
// verdicts (Approve… only where it can still matter).
function prSideActs(r, d, p, o) {
  const n = p.number;
  const writer = writerBlock(d);
  const held = p.labels.includes("agent:hold");
  return [
    labelAct(r, { id: "hold", number: n, text: held ? "Release" : "Hold", title: `${held ? "Release" : "Hold"} PR #${n}?`, off: labelBlock(d),
      labels: [[held ? "remove" : "add", "agent:hold"]], postText: held ? "Take agent:hold off" : "Add agent:hold",
      lines: [["Then", held ? "The fixer and the merge gate pick it up again." : HOLD]], doneText: `Done: ${held ? "took agent:hold off" : "added agent:hold to"} PR #${n}.` }),
    previewAct2(r, { id: "review", text: "Run review", title: `Run the Claude review of PR #${n}?`, off: writer, payload: () => ({ type: "dispatch", workflow: "review", pr: n }) }),
    previewAct2(r, { id: "gate", text: "Run merge gate", title: `Run the merge gate on PR #${n}?`, off: writer, payload: () => ({ type: "dispatch", workflow: "merge", pr: n }) }),
    o.approve ? previewAct2(r, { id: "verdict-approve", text: "Approve…", title: `Approve PR #${n}?`, off: writer,
      payload: () => ({ type: "review_verdict", pr: n, verdict: "approve" }) }) : null,
    previewAct2(r, { id: "verdict-changes", text: "Request changes…", title: `Request changes on PR #${n}?`, off: writer,
      field: { id: "verdict-note", label: "What to change", note: true, max: 2000,
        placeholder: "What to change (plain text: no HTML, no ``` fences). The fixer works from this." },
      extra: (pane) => { const box = h("input", { type: "checkbox", onchange: (e) => { pane.fixer = e.target.checked; } }); box.checked = pane.fixer; return h("label", {}, box, " Start the fixer on it"); },
      payload: (pane) => ({ type: "review_verdict", pr: n, verdict: "request-changes", note: pane.text, start_fixer: pane.fixer }) }),
  ].filter(Boolean);
}

// The merge gate's report for a repository, read for a pane if Needs you did not need it; once a pane
// has shown it, it is read again on each refresh (loadExtras), not only when Needs you needs it.
function gateFor(repo) {
  const gate = state.gate[repo];
  const asked = state.gateAsked.has(repo);
  state.gateAsked.add(repo);
  if (!gate && !asked) {
    api(`/api/repo/${repo}/gate`).then((x) => { state.gate[repo] = x; }, (e) => { state.gate[repo] = { error: e.message }; }).then(renderAll);
  }
  return gate;
}
const gateWord = (gate, g) => kv("Gate's last word", g ? [g.text, " · ", link(g.url, `${ago(g.at)} ↗`)]
  : (gate && gate.error ? `could not read the merge gate's report: ${gate.error}` : (gate ? "none in its newest runs" : "reading…")));
// Runs per role over the last seven days, for the line beside a pane's buttons.
function runsBeside(rows, prefix, noReviews) {
  if (!rows) return `${prefix}: the ledger could not be read`;
  const byRole = {};
  for (const x of rows) if (x.counted !== false) (byRole[x.role] = byRole[x.role] || []).push(x);
  return `${prefix}: ${Object.entries(byRole).map(([role, xs]) => `${role} ${xs.length} ${xs.length === 1 ? "run" : "runs"} ${runsCost(xs)}`).join(" · ") || "no runs"}${noReviews ? "" : " · reviews not recorded"}`;
}

// --- the PR pane: an agent PR held for a person, or with a request about it -----------------------------
state.gateAsked = new Set();
function prPane(r) {
  const repo = r.repo;
  const d = state.repos[repo];
  const n = r.pr;
  const p = (d.prs || []).find((x) => x.number === n) || null;
  const reqs = r.reqs || [];
  const got = state.inbox[repo];
  const fullOf = (q) => (got && got.requests ? got.requests.find((x) => x.id === q.id) || null : null);
  const msg = state.paneMsg[r.key];
  // A request's kind is only known from its comment; without it, it is not used to say why.
  const kindOf = (q) => (fullOf(q) ? q.kind : "");
  const kinds = reqs.map(kindOf);
  const stuck = p ? p.labels.filter((l) => STUCK.includes(l)) : [];
  const issueN = (reqs.find((q) => q.issue) || {}).issue || null;
  const gate = gateFor(repo);
  const g = gate && gate.prs && gate.prs[String(n)];
  const fixerReq = reqs.find((q) => kindOf(q) === "fixer");
  const why = kinds.includes("merger") ? "The merge gate cannot bring it up to date with its base branch."
    : (kinds.includes("review") ? "Its Claude review never posted, so the merge gate has nothing to go on."
      : (fixerReq ? `The fixer stopped and asked for a person: ${fixerReq.summary.replace(/^#\d+:\s*/, "")}.`
        : (stuck.length ? `It carries ${stuck.join(" and ")}, so the agents leave it to a person.`
          : (reqs.length ? `A request about it is open${kinds.some(Boolean) ? "" : " (its kind is not known: its comment was not read)"}.` : "Not known."))));
  const missing = !p ? (d.prs ? `PR #${n} is not among the open agent PRs just read: it may have been merged or closed.` : "The agent PRs could not be read.") : "";
  const next = missing ? "Not known."
    : (kinds.includes("review") ? "Nothing until the review runs."
      : (stuck.length ? "Nothing until someone fixes it and hands it back. The merge gate then checks it on its next run."
        : "It is back with the merge gate. The request stays open until you mark it as seen."));
  const acts = [];
  if (stuck.length) {
    acts.push(labelAct(r, { id: "handback", number: n, text: "Hand back to the merge gate", title: `Hand PR #${n} back to the merge gate?`, off: labelBlock(d),
      labels: stuck.map((l) => ["remove", l]), postText: stuck.length > 1 ? "Take the labels off" : "Take the label off",
      lines: [["Changes", `takes ${stuck.join(" and ")} off PR #${n} · ${stuck.length} GitHub ${stuck.length === 1 ? "call" : "calls"}`],
        ["Expect", `Do this once you have fixed the PR yourself. The merge gate and the fixer pick it up again; the gate looks at it on its next run, or sooner with Run merge gate.${reqs.length ? " The request stays open until you mark it as seen." : ""}`]],
      doneText: `Done: PR #${n} is back with the merge gate.` }));
  }
  for (const q of reqs) {
    const full = fullOf(q);
    const [text, effect] = KIND_APPROVE[q.kind] || ["Approve", "the repository's own hook for this kind of request runs"];
    acts.push(inboxAct(r, { id: `seen-${q.id}`, text: reqs.length > 1 ? `${text} (${q.id})` : (q.kind && SEEN_ONLY.has(q.kind) ? "Mark request as seen" : text),
      title: `${SEEN_ONLY.has(q.kind) ? "Mark" : "Answer"} ${q.id} ${SEEN_ONLY.has(q.kind) ? "as seen" : ""}?`.replace(" ?", "?"),
      off: inboxOff(d, full, msg, true), req: q.id, cmd: () => `/approve ${q.id}`, payload: () => ({ command: "approve", req: q.id }),
      then: effect, expect: "Its reply on the inbox within a minute or two." }));
  }
  if (p) acts.push(...prSideActs(r, d, p, { approve: true }));
  // Ledger rows about the PR, and the coder's on the issue it is for.
  const rows = d.runs ? d.runs.filter((x) => x.pr === n || (issueN && x.issue === issueN && x.role === "coder")) : null;
  const beside = runsBeside(rows, "Last 7 days");
  const stage = missing ? null : kinds.includes("merger") ? track(3, "Merge gate · can't update") : (kinds.includes("review") ? track(2, "In review · no review") : track(2, "In review · held"));
  const fulls = reqs.map(fullOf).filter(Boolean);

  return [
    h("div", { class: "pane-head" }, [repo, `PR #${n}${issueN ? ` for #${issueN}` : ""}`, ...reqs.map((q) => `request ${q.id} (${kindOf(q) || "kind not known"})`),
      r.at ? ago(r.at) : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    stage,
    kv("Why it's stuck", why),
    kv("What happens next", next),
    gateWord(gate, g),
    fulls.length ? h("div", { class: "said" }, h("div", { class: "muted" }, "What the agent wrote (plain text from GitHub)"),
      fulls.map((f) => h("pre", { class: "body" }, f.body))) : null,
    stuck.length && p ? step("1", h("strong", {}, kinds.includes("merger") ? "Merge its base branch into it yourself. " : "Fix the PR yourself. "),
      link(p.url, `Open PR #${n} on GitHub ↗`)) : null,
    missing ? h("div", { class: "state off" }, missing) : null,
    acts.length ? step(stuck.length && p ? "2" : null, paneActions(r, acts, beside)) : null,
    timeline(`PR #${n}`, [...(rows || []).map(runEvent),
      ...reqs.map((q) => { const f = fullOf(q); return { at: q.created_at || (f && f.created_at) || "", text: `Request ${q.id} filed`, url: f && f.url }; }),
      ...(g ? [{ at: g.at, text: `Merge gate: ${g.text}`, url: g.url }] : [])]),
    h("details", fold("gh"), h("summary", {}, "GitHub detail"),
      h("div", {}, p ? [`labels: ${p.labels.join(", ") || "none"} · `, link(p.url, `PR #${n}`), " · "] : "",
        d.inbox ? link(d.inbox.url, `inbox #${d.inbox.number}`) : "no inbox"))];
}

// --- the issue pane: a blocked issue with no open request -----------------------------------------------
function issuePane(r) {
  const repo = r.repo;
  const d = state.repos[repo];
  const n = r.issue;
  const issue = Object.values(d.issues || {}).flat().find((i) => i && i.number === n) || null;
  const got = state.inbox[repo];
  // An `untrusted` request the checklist missed: /rerun re-labels as the bot, which vouches for
  // nothing, so the run would be refused again (as rerunBtn says on the Pipeline tab).
  const untrusted = got && got.requests && got.requests.some((x) => x.kind === "untrusted" && !x.answered && x.issue === n);
  const s = d.stats && d.stats.coder;
  const expect = ["Its reply on the inbox within a minute or two."];
  if (s) expect.push(s.cap === null || s.cap === undefined ? `${s.today} coder runs today.` : `Today ${s.today} of ${s.cap} coder runs are used.`);
  if (d.vars && d.vars.AGENTS_ENABLED !== "true") expect.push("The agents are off in this repository, so the run does not start until they are on.");
  const acts = [
    inboxAct(r, { id: "rerun", text: "Rerun coder", title: `Rerun the coder on #${n}?`,
      off: issue && issue.labels.includes("agent:hold")
        ? `#${n} carries agent:hold: Release it first. A run named for it would not take a held issue.`
        : untrusted ? `#${n}'s text was changed by someone without write access: read it on GitHub and re-apply agent:ready there, then Acknowledge its untrusted request; a rerun before that would be refused.`
        : inboxOff(d, null, state.paneMsg[r.key], false),
      cmd: () => `/rerun coder #${n}`, payload: () => ({ command: "rerun", issue: n }),
      then: `#${n} goes back in the queue (agent:blocked and agent:needs-human come off) and the coder starts on it`, expect: expect.join(" ") }),
  ];
  if (issue) {
    const held = issue.labels.includes("agent:hold");
    acts.push(labelAct(r, { id: "hold", number: n, text: held ? "Release" : "Hold", title: `${held ? "Release" : "Hold"} #${n}?`, off: labelBlock(d),
      labels: [[held ? "remove" : "add", "agent:hold"]], postText: held ? "Take agent:hold off" : "Add agent:hold",
      lines: [["Then", held ? "The agents may pick it up again." : HOLD]], doneText: `Done: ${held ? "took agent:hold off" : "added agent:hold to"} #${n}.` }));
  }
  const rows = d.runs ? d.runs.filter((x) => x.issue === n) : null;
  const coder = (rows || []).filter((x) => x.role === "coder" && x.counted !== false);
  const beside = rows ? `Last 7 days on #${n}: ${coder.length} coder ${coder.length === 1 ? "run" : "runs"} · ${runsCost(coder)}` : `Last 7 days on #${n}: the ledger could not be read`;
  return [
    h("div", { class: "pane-head" }, [repo, `Issue #${n}`, "blocked", r.at ? ago(r.at) : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    track(1, "Coder · blocked"),
    kv("Why it's stuck", [issue ? `It carries ${issue.labels.filter((l) => STUCK.includes(l)).join(" and ") || "a blocking label"}` : "It is blocked",
      d.inbox ? ", and no inbox request about it is open: it was answered, or never filed."
        : (d.inbox_state === "none" ? ". There is no inbox issue, so no request about it is open."
          : ". Which issue is the inbox could not be told, so it is not known whether a request about it is open.")]),
    // Held first: the coder never picks a held issue, even one that also carries agent:ready.
    kv("What happens next", issue && issue.labels.includes("agent:hold") ? "Nothing while it carries agent:hold: the agents leave it alone."
      : (issue && issue.labels.includes("agent:ready")
        ? "It also carries agent:ready, so the coder may take it on its next scheduled run (the lock then takes agent:blocked off)."
        : "Nothing. The coder picks only issues labelled agent:ready, and this one is not. It moves when you rerun it, or when it is queued again on GitHub.")),
    step(null, paneActions(r, acts, beside), h("p", {}, issue ? link(issue.url, `Open #${n} on GitHub ↗`) : null)),
    timeline(`#${n}`, (rows || []).map(runEvent)),
    h("details", fold("gh"), h("summary", {}, "GitHub detail"),
      h("div", {}, issue ? `labels: ${issue.labels.join(", ") || "none"} · ` : "", d.inbox ? link(d.inbox.url, `inbox #${d.inbox.number}`) : "no inbox"))];
}

// --- the link-only panes: to merge, to close. The page merges nothing and closes nothing. ----------------
function mergePane(r) {
  const repo = r.repo;
  const d = state.repos[repo];
  const n = r.pr;
  const p = (d.prs || []).find((x) => x.number === n) || null;
  const gate = gateFor(repo);
  const g = gate && gate.prs && gate.prs[String(n)];
  const rows = d.runs ? d.runs.filter((x) => x.pr === n) : null;
  return [
    h("div", { class: "pane-head" }, [repo, `PR #${n}`, "to merge", r.at ? ago(r.at) : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    track(3, "Merge gate · would merge"),
    kv("Why it's waiting", d.vars ? `The merge gate's last run found nothing in its way. Auto-merge is a dry run in ${short(repo)} (AGENT_AUTO_MERGE is not true), so the gate only says it would merge.`
      : "The merge gate's last run found nothing in its way and was a dry run; this repository's variables could not be read, so whether auto-merge is on now is not known."),
    kv("What happens next", "Nothing until a person merges it, or auto-merge is turned on. The gate checks it again on its next run."),
    gateWord(gate, g),
    step(null, h("div", { class: "actions" }, h("a", { href: r.href, class: "cta" }, "Merge on GitHub ↗"), " ",
      routeLink(repoRoute(repo, "settings"), { class: "cta quiet" }, "Turn auto-merge on in Settings →")),
      h("div", { class: "muted" }, "The page has no merge action.")),
    p ? h("div", {}, h("div", { class: "muted" }, "Or first"), paneActions(r, prSideActs(r, d, p, { approve: false }), runsBeside(rows, "Last 7 days"), { quiet: true })) : null,
    timeline(`PR #${n}`, [...(rows || []).map(runEvent), ...(g ? [{ at: g.at, text: `Merge gate: ${g.text}`, url: g.url }] : [])]),
    h("details", fold("gh"), h("summary", {}, "GitHub detail"),
      h("div", {}, p ? `labels: ${p.labels.join(", ") || "none"}` : "", d.vars ? ` · AGENT_AUTO_MERGE=${d.vars.AGENT_AUTO_MERGE || "(not set)"}` : ""))];
}

function closePane(r) {
  const repo = r.repo;
  const d = state.repos[repo];
  const n = r.issue;
  const issue = (d.issues && d.issues.done_pending_deploy || []).find((i) => i.number === n) || null;
  const rows = d.runs ? d.runs.filter((x) => x.issue === n) : null;
  return [
    h("div", { class: "pane-head" }, [repo, `Issue #${n}`, "merged", "to close once live", r.at ? ago(r.at) : ""].filter(Boolean).join(" · ")),
    h("h2", {}, r.title, r.text ? h("span", { class: "muted" }, ` ${r.text}`) : null),
    track(4, "Merged · not closed"),
    kv("Why it's here", "Its PR merged and it carries agent:done-pending-deploy. A merge is not a deploy: the agents never close an issue; you do, once the fix is live."),
    kv("What happens next", "Nothing. It stays in this group until it is closed."),
    step(null, h("div", { class: "actions" }, h("a", { href: r.href, class: "cta" }, "Close on GitHub ↗")),
      h("div", { class: "muted" }, "The page has no close action."), h("div", { class: "muted beside" }, runsBeside(rows, "Last 7 days", true))),
    timeline(`#${n}`, (rows || []).map(runEvent)),
    h("details", fold("gh"), h("summary", {}, "GitHub detail"), h("div", {}, issue ? `labels: ${issue.labels.join(", ") || "none"}` : "not among the open issues just read"))];
}

function activityView() {
  const c = counts();
  const blocks = (state.session ? state.session.repos : []).map((repo) => {
    const d = state.repos[repo];
    if (!d || d.loading) return null;
    if (d.failed) return h("div", { class: "group" }, repoHeading(repo), empty(`Could not read this repository: ${d.failed}`));
    if (d.active_runs && !d.active_runs.length) return null;
    return h("div", { class: "group" }, repoHeading(repo), runsTable(d.active_runs, cancelBtn(repo, d)));
  }).filter(Boolean);
  return [viewHead("Activity", `Gatehand's runs that are running or waiting to start · ${c.runningText}`),
    blocks.length ? blocks : empty(c.loading ? "Loading…" : "Nothing is running.")];
}

function weekView() {
  const c = counts();
  const blocks = (state.session ? state.session.repos : []).map((repo) => {
    const d = state.repos[repo];
    if (!d || d.loading) return null;
    if (d.failed) return h("div", { class: "group" }, repoHeading(repo), empty(`Could not read this repository: ${d.failed}`));
    return h("div", { class: "group" }, repoHeading(repo), ledgerTables(d));
  }).filter(Boolean);
  return [viewHead("Week", `${c.costText} over the last seven days`,
    c.costFloor ? " · at least: runs with no cost recorded count for nothing, and Claude review runs are not in the ledger" : ""),
    blocks.length ? blocks : empty(c.loading ? "Loading…" : "No repositories.")];
}

function reposView() {
  const repos = state.session ? state.session.repos : [];
  const head = h("thead", {}, h("tr", {},
    ["Repository", "Version", "Agents", "Auto-merge", "Waiting", "PRs", "Queue", "Running", "Coder today", "Fixer today", "Cost 7 d", "Breakers", "Health", ""]
      .map((c) => h("th", {}, c))));
  const rows = repos.map((repo) => {
    const d = state.repos[repo];
    if (!d || d.loading) {
      return h("tr", {}, h("td", {}, repo), h("td", { colspan: 13, class: "muted" }, "loading…"));
    }
    if (d.failed) {
      return h("tr", {}, h("td", {}, repo), h("td", { colspan: 12, class: "bad" }, d.failed), h("td", {}, removeBtn(repo)));
    }
    const t = totals(d);
    return h("tr", { class: "click", onclick: () => go(repoRoute(repo)) },
      h("td", {}, routeLink(repoRoute(repo), { onclick: (e) => e.stopPropagation() }, repo)),
      h("td", {}, d.version || "?"),
      h("td", {}, onOff(d.vars, "AGENTS_ENABLED")),
      h("td", {}, d.vars ? (d.vars.AGENT_AUTO_MERGE === "true" ? pill("live", "ok") : pill("dry run", "off")) : pill("unknown", "warn")),
      h("td", { class: "n" }, ((x, text) => (text && text !== "…" ? pill(text, x.unknown ? "warn" : "attn") : (text || "0")))(needRows(repo), needText(needRows(repo)))),
      h("td", { class: "n" }, d.prs ? t.prs : "?"),
      h("td", { class: "n" }, d.issues ? t.queue : "?"),
      h("td", { class: "n" }, d.active_runs ? t.active : "?"),
      h("td", { class: "n" }, capCell(d, "coder")),
      h("td", { class: "n" }, capCell(d, "fixer")),
      h("td", { class: "n" }, d.stats ? usd(t.cost) : "?"),
      h("td", {}, breakerCell(d)),
      h("td", {}, health(d)),
      h("td", {}, removeBtn(repo)));
  });
  return [viewHead("Repositories", `${repos.length} on this dashboard`),
    h("div", { class: "scroll" }, h("table", { class: "grid" }, head, h("tbody", {}, rows.length ? rows : h("tr", {}, h("td", { colspan: 14, class: "muted" },
      "No repositories with Gatehand found. Add one below, or Find repositories again.")))))];
}

function removeBtn(repo, text) {
  return h("button", {
    type: "button", class: "quiet small", title: `Hide ${repo} from this dashboard`,
    onclick: async (e) => {
      e.stopPropagation();
      try { applySession(await api("/api/repos", { method: "POST", body: { op: "remove", repo } })); }
      catch (err) { notice(err.message); }
      if (state.selected === repo) { state.selected = ""; go("/repos"); }
      renderAll();
    },
  }, text || "Hide");
}

// --- actions: every write is done by the server with your own gh login, after a confirm -------------
// Who may do what is the agents' rule, not this page's: inbox commands count only from
// AGENT_OWNER_LOGIN, labels only from people with write access. A button that would be ignored is
// shown disabled with the reason; the server checks again.
function answerBlock(d) {
  if (!d.vars) return "Cannot read this repository's variables, so cannot tell who may answer.";
  const owner = d.vars.AGENT_OWNER_LOGIN;
  if (!owner) return "AGENT_OWNER_LOGIN is not set: nobody's commands are applied.";
  const me = state.session && state.session.viewer;
  if (me !== owner) return `Only ${owner} (AGENT_OWNER_LOGIN) can answer; you are ${me}.`;
  if (!d.inbox) return "No inbox issue found.";
  const got = state.inbox[d.repo];
  // Two inbox runs at once would both apply: one command at a time, until the bot has answered.
  if (got && got.awaiting_reply) return "Your last command has no answer from the Agent inbox workflow yet.";
  return "";
}
// The server's one_line, exactly: control characters to one space, trimmed, at most n characters.
// Cut by code points, as Python does, not UTF-16 units.
const oneLine = (s, n) => Array.from(String(s || "").replace(/[\x00-\x1f\x7f]+/g, " ").trim()).slice(0, n).join("").trimEnd();
function labelBlock(d) {
  if (d.inbox_state === "unknown") return "Cannot tell which issue is the inbox, so no label is changed from here.";
  return ["WRITE", "MAINTAIN", "ADMIN"].includes(d.viewer_permission) ? ""
    : `Labels count only from people with write access; you have ${String(d.viewer_permission || "unknown").toLowerCase()}.`;
}
function actBtn(text, blocked, onclick, kind) {
  return h("button", { type: "button", class: `small ${kind || "quiet"}`, disabled: !!blocked, title: blocked || null,
    onclick: (e) => { e.preventDefault(); e.stopPropagation(); onclick(e.currentTarget); } }, text);
}

async function act(repo, payload, question, btn) {
  if (!(await ask(question))) return null;
  if (btn) btn.disabled = true;
  try {
    const out = await api("/api/action", { method: "POST", body: Object.assign({ repo, viewer: state.session.viewer }, payload) });
    if (out.posted) watchAnswer(repo, payload.req);
    notice(out.posted
      ? `Posted “${out.posted}” on the inbox (#${out.inbox}). The Agent inbox workflow applies it within a minute or two; this page checks back.`
      : `Done: ${out.done}.`);
    await loadRepo(repo, true);
    return out;
  } catch (e) {
    notice(`Not done: ${e.message}`);
    if (btn) btn.disabled = false;
    loadRepo(repo, true);
    return null;
  }
}

// Runs, verdicts and switches: the server first says exactly what it would do (the GitHub calls, the
// comment, what to expect, anything in the way) and hands back a one-time token; the action is done
// only with that token, and only if nothing changed in between.
const writerBlock = (d) => (["WRITE", "MAINTAIN", "ADMIN"].includes(d.viewer_permission) ? ""
  : `Needs write access; you have ${String(d.viewer_permission || "unknown").toLowerCase()}.`);
async function previewAct(repo, payload, btn) {
  if (btn) btn.disabled = true;
  const body = Object.assign({ repo, viewer: state.session.viewer }, payload);
  try {
    const p = await api("/api/action/preview", { method: "POST", body });
    const text = [`${p.summary}?`, "", `What happens: ${p.effect}.`,
      ...(p.warnings.length ? ["", ...p.warnings.map((w) => `Note: ${w}.`)] : []),
      "", `GitHub calls, as ${state.session.viewer}:`, ...p.calls.map((c) => `  ${c}`),
      ...(p.comment ? ["", "The comment:", "", p.comment] : [])].join("\n");
    if (!(await ask(text))) { if (btn) btn.disabled = false; return null; }
    const out = await api("/api/action", { method: "POST", body: Object.assign(body, { confirm: p.confirm }) });
    notice(`Done: ${out.done}.`);
    await loadRepo(repo, true);
    return out;
  } catch (e) {
    notice(`Not done: ${e.message}`);
    if (btn) btn.disabled = false;
    loadRepo(repo, true);
    return null;
  }
}

async function loadInbox(repo, fresh) {
  try { state.inbox[repo] = await api(`/api/repo/${repo}/inbox${fresh ? "?fresh=1" : ""}`); }
  catch (e) { state.inbox[repo] = { error: e.message }; }
  renderAll(); // the requests change Needs you and the sidebar counts, not only this repository's page
}

// After any inbox command: re-read the inbox every 10 s for two minutes, until the bot has replied
// (awaiting_reply off), which also re-enables the other answer buttons. Posted from an item pane
// (key), the outcome is said in that pane; otherwise in the notice line.
function watchAnswer(repo, req, key) {
  let left = 12;
  const say = (text, kind) => {
    if (key) { state.paneMsg[key] = { kind, text, at: Date.now() }; renderView(); } else notice(text);
  };
  const tick = async () => {
    left -= 1;
    await loadInbox(repo, true); // the inbox only: the merge gate's logs are not worth re-reading every 10 s
    const got = state.inbox[repo];
    if (got && got.requests && !got.awaiting_reply) {
      const r = req && got.requests.find((x) => x.id === req);
      if (req && r && !r.answered) say(`The Agent inbox workflow replied but did not record ${req} as answered: read its reply on the inbox.`, "note");
      else if (key && r) say(`The Agent inbox workflow replied and recorded ${req} as answered.`, "done");
      else say("The Agent inbox workflow has replied; see the inbox for what was done.", "note");
      await loadRepo(repo, true);
      return;
    }
    if (left > 0) setTimeout(tick, 10000);
    else say("No reply from the Agent inbox workflow after two minutes; check its runs on GitHub. Until it replies, or for ten minutes, no other inbox command is sent in this repository.", "note");
  };
  setTimeout(tick, 10000);
}

const KIND_APPROVE = {
  protected: ["Allow protected paths once and rerun", "the issue goes back in the queue with agent:allow-protected for one attempt, and the coder starts on it"],
  blocked: ["Requeue and rerun", "the issue goes back in the queue and the coder starts on it"],
  failed: ["Requeue and rerun", "the issue goes back in the queue and the coder starts on it"],
  breaker: ["Reset the breaker", "the role's circuit breaker is reset and it runs again"],
  untrusted: ["Acknowledge", "nothing changes: re-apply agent:ready on the issue yourself, then rerun it"],
  fixer: ["Mark as seen", "nothing changes: fix the PR yourself and hand it back, or close it"],
  merger: ["Mark as seen", "nothing changes: merge main into the PR yourself, or close it"],
  review: ["Mark as seen", "nothing changes: run the review yourself once it can, or close the PR"],
};
const SEEN_ONLY = new Set(["fixer", "merger", "review"]);

function requestActions(repo, d, r) {
  if (r.answered) return null;
  const blocked = r.pending ? "Your answer is posted; waiting for the Agent inbox workflow to apply it." : answerBlock(d);
  const [text, effect] = KIND_APPROVE[r.kind] || ["Approve", "the repository's own hook for this kind of request runs"];
  const approve = actBtn(text, blocked, async (b) => {
    await act(repo, { type: "inbox_command", command: "approve", req: r.id },
      `Post “/approve ${r.id}” on the inbox as ${state.session.viewer}?\n\nWhat happens: ${effect}.`, b);
  }, "primary");
  if (SEEN_ONLY.has(r.kind)) return h("div", { class: "actions" }, approve);
  const rejectEffect = r.kind === "breaker" ? `the ${r.role} stays stopped`
    : KIND_APPROVE[r.kind] ? `#${r.issue} stays as it is, gets the reason as a comment, and loses agent:needs-human`
      : "the repository's own hook for this kind of request decides";
  const reject = actBtn("Reject…", blocked, async (b) => {
    const reason = await ask(`Reject ${r.id}. Reason (optional, one line of at most 300 characters):`, "");
    if (reason === null) return;
    const line = `/reject ${r.id} ${oneLine(reason, 300)}`.trimEnd();
    await act(repo, { type: "inbox_command", command: "reject", req: r.id, reason },
      `Post “${line}” on the inbox as ${state.session.viewer}?\n\nWhat happens: ${rejectEffect}.`, b);
  });
  return h("div", { class: "actions" }, approve, reject);
}

function labelBtn(repo, d, n, op, label, text, why) {
  return actBtn(text, labelBlock(d), (b) => act(repo, { type: "label", op, label, number: n },
    `${op === "add" ? "Add" : "Remove"} ${label} ${op === "add" ? "to" : "from"} #${n} as ${state.session.viewer}?\n\n${why}`, b));
}
function rerunBtn(repo, d, n) {
  // An `untrusted` request: someone without write access changed the issue's text since a person
  // queued it. /rerun re-labels as the bot, which vouches for nothing, so the run would be refused
  // again: a person reads the issue and re-applies agent:ready on GitHub first.
  const got = state.inbox[repo];
  const untrusted = got && got.requests && got.requests.some((r) => r.kind === "untrusted" && !r.answered && r.issue === n);
  return actBtn("Rerun coder", untrusted
    ? `#${n}'s text was changed by someone without write access: read it on GitHub and re-apply agent:ready there, then Acknowledge its untrusted request; a rerun before that would be refused.`
    : answerBlock(d), (b) => act(repo, { type: "inbox_command", command: "rerun", issue: n },
    `Post “/rerun coder #${n}” on the inbox as ${state.session.viewer}?\n\nWhat happens: #${n} goes back in the queue (agent:blocked and agent:needs-human come off) and the coder starts on it.`, b));
}
const HOLD = "Agents never touch an issue or PR while it carries agent:hold.";

function issueList(list, emptyText, actions) {
  if (!list) return empty("Could not read the issues.");
  if (!list.length) return empty(emptyText);
  return h("ul", { class: "items" }, list.map((i) => h("li", {},
    link(i.url, `#${i.number} ${i.title}`), " ",
    i.priority ? pill(i.priority) : null,
    i.labels.filter((l) => l.startsWith("agent:") && !["agent:ready", "agent:pr"].includes(l)).map((l) => pill(l, "label")),
    h("span", { class: "muted" }, ` · updated ${ago(i.updated_at)}`),
    actions ? h("span", { class: "actions inline" }, actions(i)) : null)));
}

function runsTable(list, cancel) {
  if (!list) return empty("Could not read the Actions runs.");
  if (!list.length) return empty("None.");
  return h("div", { class: "scroll" }, h("table", { class: "grid" },
    h("thead", {}, h("tr", {}, ["Agent", "Run", "Event", "State", "Started", cancel ? "" : null].filter((c) => c !== null).map((c) => h("th", {}, c)))),
    h("tbody", {}, list.map((r) => h("tr", {},
      h("td", {}, r.agent), h("td", {}, link(r.url, r.name || String(r.id))), h("td", {}, r.event),
      h("td", {}, r.status === "completed" ? pill(r.conclusion || "done", r.conclusion === "success" ? "ok" : (r.conclusion === "failure" ? "bad" : "")) : pill(r.status, "attn")),
      h("td", { class: "muted" }, ago(r.created_at)),
      cancel ? h("td", {}, cancel(r)) : null)))));
}

function switchesBlock(repo, d) {
  const why = d.vars ? writerBlock(d) : "Cannot read this repository's variables.";
  const row = (name, label, on, offText, onText) => {
    const cur = d.vars ? d.vars[name] : undefined;
    const isOn = cur === "true";
    return h("li", {}, h("strong", {}, label), " ",
      !d.vars ? pill("unknown", "warn") : (isOn ? pill(on, "ok") : pill(offText, "off")),
      h("span", { class: "muted" }, ` ${name} = ${cur === undefined ? "?" : (cur === null ? "not set" : cur)}`),
      h("span", { class: "actions inline" }, actBtn(isOn ? `Turn ${label.toLowerCase()} off` : `Turn ${label.toLowerCase()} on`, why,
        (b) => previewAct(repo, { type: "set_variable", name, value: isOn ? "false" : "true" }, b), isOn ? "quiet" : "primary")),
      h("div", { class: "gate" }, onText));
  };
  return h("ul", { class: "items" },
    row("AGENTS_ENABLED", "Agents", "on", "off", "Off stops the coder, fixer, merge gate, sweep and triage; the inbox, the Claude review of new PRs, the PR guard and the digest still run."),
    row("AGENT_AUTO_MERGE", "Auto-merge", "live", "dry run", "Off, the merge gate only reports what it would merge."));
}

function cancelBtn(repo, d) {
  return (r) => actBtn("Cancel", writerBlock(d), (b) => previewAct(repo, { type: "cancel_run", run: r.id }, b));
}

// A verdict on an agent PR, as the merge gate and the fixer read one from a person with write access.
// Request changes needs a note, kept as a draft across re-renders.
function verdictActions(repo, d, p) {
  const key = `${repo}#${p.number}`;
  const draft = state.drafts[key];
  const why = writerBlock(d);
  return [
    actBtn("Approve…", why, (b) => previewAct(repo, { type: "review_verdict", pr: p.number, verdict: "approve" }, b), "primary"),
    actBtn(draft ? "Close the note" : "Request changes…", why, () => {
      if (draft) delete state.drafts[key]; else state.drafts[key] = { note: "", fixer: true };
      renderView();
    }),
    actBtn("Run review", why, (b) => previewAct(repo, { type: "dispatch", workflow: "review", pr: p.number }, b)),
    actBtn("Run merge gate", why, (b) => previewAct(repo, { type: "dispatch", workflow: "merge", pr: p.number }, b)),
  ];
}
function verdictForm(repo, p) {
  const key = `${repo}#${p.number}`;
  const draft = state.drafts[key];
  if (!draft) return null;
  const note = h("textarea", { rows: 4, maxlength: 2000, placeholder: "What to change (plain text: no HTML, no ``` fences). The fixer works from this.",
    oninput: (e) => { draft.note = e.target.value; } });
  note.value = draft.note;
  const fixer = h("input", { type: "checkbox", onchange: (e) => { draft.fixer = e.target.checked; } });
  fixer.checked = draft.fixer;
  return h("form", { class: "verdict", onsubmit: async (e) => {
    e.preventDefault();
    const done = await previewAct(repo, { type: "review_verdict", pr: p.number, verdict: "request-changes", note: draft.note, start_fixer: draft.fixer },
      e.currentTarget.querySelector("button"));
    if (done) { delete state.drafts[key]; renderView(); }
  } }, note, h("label", {}, fixer, " Start the fixer on it"), h("button", { type: "submit", class: "small" }, "Request changes…"));
}

function ledgerTables(d) {
  if (!d.stats) return empty("Could not read the ledger branch.");
  const roles = Object.entries(d.stats).filter(([, s]) => s.runs || s.cap !== undefined);
  const summary = h("table", { class: "grid" },
    h("thead", {}, h("tr", {}, ["Role", "Runs", "Outcomes", "Today / cap", "Turns", "Time", "Cost"].map((c) => h("th", {}, c)))),
    h("tbody", {}, roles.map(([role, s]) => h("tr", {},
      h("td", {}, role), h("td", { class: "n" }, s.runs),
      h("td", {}, s.outcomes.map(([o, n]) => `${n} ${o}`).join(", ") + (s.not_counted ? ` (${s.not_counted} never reached the agent)` : "")),
      h("td", { class: "n" }, s.cap === null || s.cap === undefined ? `${s.today}` : `${s.today}/${s.cap}`),
      h("td", { class: "n" }, s.turns ?? "–"), h("td", { class: "n" }, mins(s.duration_ms)), h("td", { class: "n" }, usd(s.cost_usd))))));
  const rows = (d.runs || []).slice(0, 40);
  const detail = rows.length ? h("details", {}, h("summary", {}, `The last ${rows.length} ledger rows`),
    h("div", { class: "scroll" }, h("table", { class: "grid" },
      h("thead", {}, h("tr", {}, ["Started", "Role", "Target", "Outcome", "Reason", "Turns", "Cost"].map((c) => h("th", {}, c)))),
      h("tbody", {}, rows.map((r) => h("tr", {},
        h("td", { class: "muted" }, String(r.started_at || r.ended_at || "").slice(0, 16).replace("T", " ")),
        h("td", {}, r.role || "?"),
        h("td", {}, r.pr ? link(`${d.url}/pull/${r.pr}`, `PR #${r.pr}`) : (r.issue ? link(`${d.url}/issues/${r.issue}`, `#${r.issue}`) : "–")),
        h("td", {}, r.run_url ? link(r.run_url, r.outcome || "?") : (r.outcome || "?")),
        h("td", { class: "muted" }, String(r.reason || "").slice(0, 160)),
        h("td", { class: "n" }, r.turns ?? "–"), h("td", { class: "n" }, usd(r.cost_usd)))))))) : empty("No runs in the last seven days.");
  return [h("div", { class: "scroll" }, summary), detail];
}

function breakerList(repo, d) {
  if (d.breakers === null || d.breakers === undefined) return empty("Could not read the breaker state.");
  // Every role in policy.json, with its breaker if it has stepped.
  const roles = [...new Set([...Object.keys((d.policy && d.policy.roles) || {}), ...Object.keys(d.breakers)])].sort();
  if (!roles.length) return empty("No roles.");
  return h("ul", { class: "items" }, roles.map((role) => {
    const b = d.breakers[role] && typeof d.breakers[role] === "object" ? d.breakers[role] : {};
    const stopped = !!b.tripped_at;
    const cmd = stopped ? "resume" : "pause";
    return h("li", {},
      h("strong", {}, role), " ",
      stopped ? pill(`stopped since ${String(b.tripped_at).slice(0, 16).replace("T", " ")} UTC`, "bad") : pill("running", "ok"),
      ` ${b.consecutive || 0} failure(s) in a row`,
      b.reason ? h("span", { class: "muted" }, ` · ${b.reason}`) : null,
      b.last_outcome ? h("span", { class: "muted" }, ` · last: ${b.last_outcome}`) : null,
      d.policy && d.policy.roles && d.policy.roles[role] ? h("span", { class: "actions inline" },
        actBtn(stopped ? "Resume" : "Pause", answerBlock(d), (btn) => act(repo, { type: "inbox_command", command: cmd, role },
          `Post “/${cmd} ${role}” on the inbox as ${state.session.viewer}?\n\nWhat happens: ${stopped
            ? `the ${role}'s circuit breaker is reset and it runs again.` : `the ${role} stops until someone sends /resume ${role}.`}`, btn))) : null);
  }));
}

function inboxBlock(repo, d) {
  if (!d.inbox) return d.inbox_state === "unknown" ? h("p", { class: "warn" }, "Could not tell which issue is the inbox; see above.") : empty("No inbox issue found.");
  const got = state.inbox[repo];
  const head = h("p", {}, link(d.inbox.url, `Inbox issue #${d.inbox.number}`),
    d.owner_login ? h("span", { class: "muted" }, ` · answered only by ${d.owner_login}`) : null);
  if (!got) return [head, empty("Loading requests…")];
  if (got.error) return [head, h("p", { class: "bad" }, got.error)];
  const open = got.requests.filter((r) => !r.answered);
  const done = got.requests.filter((r) => r.answered).slice(0, 10);
  const one = (r) => h("div", { class: "req" }, h("details", {},
    h("summary", {}, h("code", {}, r.id), " ", pill(r.kind), " ", `${r.role} · `,
      r.issue ? link(`${d.url}/issues/${r.issue}`, `#${r.issue}`) : "no issue", h("span", { class: "muted" }, ` · ${ago(r.created_at)}`)),
    h("pre", { class: "body" }, r.body),
    h("p", {}, link(r.url, "The request on GitHub"))),
    requestActions(repo, d, r));
  const why = answerBlock(d);
  return [head,
    open.length && why ? h("p", { class: "muted" }, why) : null,
    got.truncated ? h("p", { class: "warn" }, "Only the newest 1,000 inbox comments were read.") : null,
    open.length ? open.map(one) : empty("No open requests."),
    done.length ? h("details", {}, h("summary", { class: "muted" }, `${done.length} recently answered`), done.map(one)) : null];
}

function prBlock(repo, d) {
  if (!d.prs) return empty("Could not read the PRs.");
  if (!d.prs.length) return empty("No open agent PRs.");
  const gate = state.gate[repo];
  return [
    gate && gate.run ? h("p", { class: "muted" }, "Merge gate, newest run that ran ", link(gate.run.url, ago(gate.run.created_at)),
      "; each PR's line is from the newest run that reported it.") : null,
    gate && gate.error ? h("p", { class: "warn" }, `Merge gate report unreadable: ${gate.error}`) : null,
    gate && gate.note ? h("p", { class: "muted" }, `Merge gate: ${gate.note}.`) : null,
    h("div", { class: "actions" }, actBtn("Run the merge gate on every agent PR", writerBlock(d),
      (b) => previewAct(repo, { type: "dispatch", workflow: "merge" }, b))),
    h("ul", { class: "items" }, d.prs.map((p) => h("li", {},
      link(p.url, `PR #${p.number} ${p.title}`), " ",
      p.labels.filter((l) => l.startsWith("agent:") && l !== "agent:pr").map((l) => pill(l, "label")),
      h("span", { class: "muted" }, ` · opened ${ago(p.created_at)}`),
      h("span", { class: "actions inline" }, prActions(repo, d, p)),
      gateLine(gate, p.number),
      verdictForm(repo, p))))];
}

function prActions(repo, d, p) {
  const stuck = p.labels.filter((l) => l === "agent:blocked" || l === "agent:needs-human");
  const out = [];
  if (stuck.length) {
    out.push(actBtn("Hand back to the merge gate", labelBlock(d), async (b) => {
      if (!(await ask(`Remove ${stuck.join(" and ")} from PR #${p.number} as ${state.session.viewer}?\n\nDo this once you have fixed the PR yourself: the merge gate and the fixer pick it up again.`))) return;
      b.disabled = true;
      for (const label of stuck) {
        try { await api("/api/action", { method: "POST", body: { repo, viewer: state.session.viewer, type: "label", op: "remove", label, number: p.number } }); }
        catch (e) { notice(`Not done: ${e.message}`); b.disabled = false; loadRepo(repo, true); return; }
      }
      notice(`Done: PR #${p.number} is back with the merge gate.`);
      loadRepo(repo, true);
    }));
  }
  out.push(p.labels.includes("agent:hold")
    ? labelBtn(repo, d, p.number, "remove", "agent:hold", "Release", "The fixer and the merge gate pick it up again.")
    : labelBtn(repo, d, p.number, "add", "agent:hold", "Hold", HOLD));
  return out.concat(verdictActions(repo, d, p));
}

function gateLine(gate, n) {
  const g = gate && gate.prs && gate.prs[String(n)];
  if (!g) return null;
  return h("div", { class: "gate" }, "Gate ", link(g.url, ago(g.at)), `: ${g.text}`);
}

// A repository's four tabs. Every list and button the page had is on one of them.
function pipelineTab(repo, d) {
  const i = d.issues;
  return [
    h("h3", {}, "Inbox requests"), inboxBlock(repo, d),
    h("h3", {}, "Agent PRs"), prBlock(repo, d),
    h("h3", {}, "Queue"),
    i && i.ready && i.ready.length ? h("div", { class: "actions" }, actBtn("Start the coder on the next one", writerBlock(d),
      (b) => previewAct(repo, { type: "dispatch", workflow: "coder" }, b))) : null,
    issueList(i && i.ready, "Nothing is queued for the coder.", (x) => [
      labelBtn(repo, d, x.number, "remove", "agent:ready", "Unqueue", "The coder no longer picks it."),
      x.labels.includes("agent:hold") ? null : labelBtn(repo, d, x.number, "add", "agent:hold", "Hold", HOLD)]),
    h("h3", {}, "In progress"), issueList(i && i.in_progress, "Nothing."),
    h("h3", {}, "Blocked or waiting on a person"), issueList(i && i.blocked, "Nothing.", (x) => [rerunBtn(repo, d, x.number),
      x.labels.includes("agent:hold") ? null : labelBtn(repo, d, x.number, "add", "agent:hold", "Hold", HOLD)]),
    // Queueing is done on GitHub, next to the issue's text: agent:ready vouches for that text as it
    // stands, and this page does not show it.
    h("h3", {}, "Candidates"), issueList(i && i.candidate, "None.", (x) => x.labels.includes("agent:ready") ? null
      : h("a", { href: x.url, class: "button-link", title: "agent:ready makes the agents trust the issue's text as it is now: read it, then add the label there." }, "Read and queue on GitHub")),
    h("h3", {}, "On hold"), issueList(i && i.hold, "None.", (x) => labelBtn(repo, d, x.number, "remove", "agent:hold", "Release", "The agents may work on it again.")),
    h("h3", {}, "Merged, to close once live"), issueList(i && i.done_pending_deploy, "None.")];
}
function agentsTab(repo, d) {
  return [h("h3", {}, "Breakers"), breakerList(repo, d),
    h("h3", {}, "Running now"), runsTable(d.active_runs, cancelBtn(repo, d))];
}
function runsTab(repo, d) {
  return [h("h3", {}, "Agent runs, last seven days"), ledgerTables(d),
    h("h3", {}, "Recent finished runs"), runsTable(d.recent_runs)];
}
function settingsTab(repo, d) {
  const v = d.vars;
  const def = d.default_branch || "the default branch";
  const ref = { ok: pill(`matches ${def}`, "ok"), stale: pill(`differs from ${def}`, "bad"), missing: pill("missing", "bad") }[d.runner_ref] || pill("unknown", "warn");
  return [h("h3", {}, "Switches"), switchesBlock(repo, d),
    h("h3", {}, "Set up"),
    h("ul", { class: "items" },
      h("li", {}, h("strong", {}, "Who can answer "), v ? (v.AGENT_OWNER_LOGIN || pill("not set", "warn")) : pill("unknown", "warn"),
        h("span", { class: "muted" }, " AGENT_OWNER_LOGIN")),
      h("li", {}, h("strong", {}, "Inbox "), d.inbox ? link(d.inbox.url, `#${d.inbox.number}`) : (d.inbox_state === "unknown" ? pill("unknown", "warn") : "none found")),
      h("li", {}, h("strong", {}, "Version "), d.version || "?"),
      h("li", {}, h("strong", {}, "Runner branch "), ref, h("span", { class: "muted" }, ` ${(d.policy && d.policy.runnerRef) || ""}`)),
      h("li", {}, h("strong", {}, "Limits and schedules "),
        link(`${d.url}/blob/${d.default_branch || "main"}/.github/agents/policy.json`, "policy.json on GitHub"),
        h("span", { class: "muted" }, " · changed there, not here"))),
    h("h3", {}, "This dashboard"),
    h("p", {}, removeBtn(repo, "Hide this repository"), h("span", { class: "muted" }, " Keeps it out of the list and later scans. Changes nothing on GitHub."))];
}

function repoView() {
  if (!state.session) return empty("Loading…");
  const repo = routeRepo();
  if (!repo) {
    return [viewHead(state.route.repo), empty("This repository is not on this dashboard."), routeLink("/repos", {}, "Add it under Repositories")];
  }
  const d = state.repos[repo];
  const head = h("div", { class: "detail-head" }, h("h2", {}, link(`https://github.com/${repo}`, repo)),
    d && !d.loading && !d.failed ? [
      d.vars ? pill(d.vars.AGENTS_ENABLED === "true" ? "Agents on" : "Agents off", d.vars.AGENTS_ENABLED === "true" ? "ok" : "off") : pill("Agents ?", "warn"),
      d.vars ? pill(d.vars.AGENT_AUTO_MERGE === "true" ? "Auto-merge on" : "Auto-merge: dry run", d.vars.AGENT_AUTO_MERGE === "true" ? "ok" : "off") : pill("Auto-merge ?", "warn"),
      h("span", { class: "muted" }, ` Gatehand ${d.version || "?"} · you have ${String(d.viewer_permission || "?").toLowerCase()} access · read ${ago(d.fetched_at)}`)] : null);
  if (!d || d.loading) return [head, empty("Loading…")];
  if (d.failed) return [head, h("p", { class: "bad" }, d.failed), removeBtn(repo, "Hide this repository")];
  const tab = state.route.tab;
  return [head,
    (d.errors || []).length ? h("div", { class: "notice" }, h("strong", {}, "Could not read everything:"),
      h("ul", {}, d.errors.map((e) => h("li", {}, e)))) : null,
    h("nav", { class: "tabs", "aria-label": repo }, TABS.map(([k, text]) =>
      routeLink(repoRoute(repo, k), { class: k === tab ? "on" : null, "aria-current": k === tab ? "page" : null }, text))),
    { pipeline: pipelineTab, agents: agentsTab, runs: runsTab, settings: settingsTab }[tab](repo, d)];
}

function renderView() {
  const v = state.route.view;
  // Data arriving re-draws the view: a field you are typing in (the reject reason) keeps its focus and caret.
  const a = document.activeElement;
  const keep = a && a.id && $("view").contains(a) ? [a.id, a.selectionStart, a.selectionEnd] : null;
  replace($("view"), { needs: needsView, activity: activityView, week: weekView, repos: reposView, repo: repoView }[v]());
  const focus = state.focusId || (keep && keep[0]);
  const el = focus && $(focus);
  if (el) {
    el.focus({ preventScroll: !state.focusId }); // a re-render keeps focus without moving the page
    if (!state.focusId && keep && typeof keep[1] === "number") { try { el.setSelectionRange(keep[1], keep[2]); } catch (_) { /* not a text field */ } }
  }
  state.focusId = "";
  // Adding and finding repositories is a static form, so a re-render while you type keeps your text.
  $("repo-tools").hidden = v !== "repos";
  const ex = state.session ? state.session.excluded : [];
  $("excluded").textContent = ex.length ? `Hidden: ${ex.join(", ")}` : "";
}

function renderAll() { renderSide(); renderView(); }

function notice(text) {
  const n = $("notice");
  n.hidden = !text;
  n.textContent = text || "";
}

// --- loading -----------------------------------------------------------------------------------------
function applySession(s) {
  state.session = Object.assign(state.session || {}, s);
  for (const r of Object.keys(state.repos)) if (!state.session.repos.includes(r)) delete state.repos[r];
}

async function loadRepo(repo, fresh) {
  if (!state.repos[repo]) state.repos[repo] = { loading: true };
  try {
    state.repos[repo] = await api(`/api/repo/${repo}${fresh ? "?fresh=1" : ""}`);
  } catch (e) {
    state.repos[repo] = { failed: e.message };
  }
  renderAll();
  loadExtras(repo, fresh);
}

// The inbox and the merge gate's report: always for the repository on screen, and for any other when
// Needs you needs them (needsInbox, needsGate).
async function loadExtras(repo, fresh) {
  const d = state.repos[repo];
  if (!d || d.failed || d.loading) return;
  const q = fresh ? "?fresh=1" : "";
  const open = repo === state.selected;
  const part = (name) => api(`/api/repo/${repo}/${name}${q}`)
    .then((r) => { state[name][repo] = r; }, (e) => { state[name][repo] = { error: e.message }; })
    .then(renderAll);
  const jobs = [];
  if (d.inbox && (open || needsInbox(d))) jobs.push(part("inbox"));
  if ((d.prs || []).length && (open || needsGate(d) || state.gateAsked.has(repo))) jobs.push(part("gate"));
  await Promise.all(jobs);
}

// The address changed (a link, Back, a typed URL): show that view, and read the inbox and the merge
// gate of a repository when it is the one opened.
function onRoute() {
  const was = state.route.view;
  const wasOpen = state.route.open;
  state.route = parseRoute();
  // Another item opened: a confirm left open on the last one closes; what was posted from it stays.
  if (state.route.open !== wasOpen) state.pane = { key: "", confirm: "", text: "", fixer: true, preview: null };
  const named = state.route.open; // the item the address named, before the render pins the top one
  if (state.route.view === "needs" && was !== "needs") lookAgain();
  const repo = routeRepo();
  const opened = repo && repo !== state.selected;
  state.selected = repo;
  renderAll();
  if (opened) loadExtras(repo, false);
  // Opening an item keeps the list where it is; where the pane sits under the list, it is brought into view.
  if (state.route.view === "needs" && was === "needs") {
    const pane = $("pane");
    if (pane && named && getComputedStyle(pane.parentNode).gridTemplateColumns.split(" ").length < 2) {
      window.scrollTo(0, pane.getBoundingClientRect().top + window.scrollY - document.querySelector(".bar").offsetHeight - 8);
    }
  } else window.scrollTo(0, 0);
}

async function refresh(fresh) {
  if (!state.token) {
    notice("This page needs the address the dashboard opened in your browser (it carries the session secret). Start it again with `python3 bin/dashboard.py`.");
    return;
  }
  $("refresh").disabled = true;
  try {
    applySession(await api(`/api/session${fresh ? "?fresh=1" : ""}`));
    state.selected = routeRepo();
    const scan = [state.session.scan_error && `Finding repositories failed: ${state.session.scan_error}`,
      ...(state.session.scan_notes || []).map((n) => `Finding repositories: ${n}`)].filter(Boolean);
    notice(scan.join(" · "));
    $("viewer").textContent = state.session.viewer ? `as ${state.session.viewer}` : "";
    const core = state.session.rate && state.session.rate.core;
    $("rate").textContent = core ? `API ${core.remaining}/${core.limit}` : "";
    renderAll();
    await Promise.all(state.session.repos.map((r) => loadRepo(r, fresh)));
    $("updated").textContent = `updated ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
  } catch (e) {
    notice(e.message);
  } finally {
    $("refresh").disabled = false;
  }
}

window.addEventListener("hashchange", onRoute);
$("refresh").addEventListener("click", () => refresh(true));
$("rescan").addEventListener("click", async () => {
  $("rescan").disabled = true;
  try { applySession(await api("/api/repos", { method: "POST", body: { op: "rescan" } })); await refresh(false); }
  catch (e) { notice(e.message); }
  finally { $("rescan").disabled = false; }
});
$("add").addEventListener("submit", async (e) => {
  e.preventDefault();
  const repo = $("add-repo").value.trim();
  try {
    applySession(await api("/api/repos", { method: "POST", body: { op: "add", repo } }));
    $("add-repo").value = "";
    renderAll();
    loadRepo(state.session.repos.find((r) => r.toLowerCase() === repo.toLowerCase()) || repo, true);
  } catch (err) { notice(err.message); }
});
// Every five minutes while the tab is visible; the server caches each repository for a minute.
setInterval(() => { if (document.visibilityState === "visible") refresh(false); }, 5 * 60 * 1000);
// The server stops after a while with no page open; a background tab still counts as open.
setInterval(() => { if (state.token) api("/api/ping").catch(() => {}); }, 60 * 1000);
// What Needs you showed when you last looked, read now that everything above is defined.
lookAgain();
refresh(false);
