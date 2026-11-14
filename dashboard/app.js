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

async function api(path, opts = {}) {
  const res = await fetch(path, {
    method: opts.method || "GET",
    headers: Object.assign({ "X-Gatehand-Token": state.token }, opts.body ? { "Content-Type": "application/json" } : {}),
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    cache: "no-store",
  });
  let data = null;
  try { data = await res.json(); } catch (_) { /* not JSON */ }
  if (!res.ok) throw new Error((data && data.error) || `HTTP ${res.status}`);
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

// --- rendering ---------------------------------------------------------------------------------------
function renderTotals() {
  const all = Object.values(state.repos).filter((d) => d && !d.loading);
  const t = { unknown: new Set() };
  for (const one of all.map(totals)) {
    for (const k of KEYS) t[k] = (t[k] || 0) + (one[k] || 0);
    one.unknown.forEach((k) => t.unknown.add(k));
  }
  const tile = (label, key, fmt, kind) => h("div", { class: `tile ${kind || ""}`, title: t.unknown.has(key) ? "? : part of this could not be read" : null },
    h("div", { class: "num" }, shown(t, key, fmt)), h("div", { class: "label" }, label));
  replace($("totals"),
    h("div", { class: "tile" }, h("div", { class: "num" }, String(state.session ? state.session.repos.length : 0)), h("div", { class: "label" }, "repositories")),
    tile("waiting for you", "waiting", null, t.waiting || t.unknown.has("waiting") ? "attn" : ""),
    tile("open agent PRs", "prs"),
    tile("queued issues", "queue"),
    tile("running now", "active"),
    tile("runs, 7 days", "runs"),
    tile("cost, 7 days", "cost", usd));
}

function renderWaiting() {
  const blocks = [];
  let gaps = false;
  for (const repo of state.session ? state.session.repos : []) {
    const d = state.repos[repo];
    if (d && d.failed) {
      gaps = true;
      blocks.push(h("div", { class: "group" }, h("h3", {}, repo),
        h("ul", { class: "items" }, h("li", {}, pill("unknown", "warn"), ` Could not read this repository: ${d.failed}`))));
      continue;
    }
    if (d && !d.loading && !Array.isArray(d.waiting)) gaps = true;
    if (!d || d.loading || !(d.waiting || []).length) continue;
    if (d.waiting.some((w) => w.kind === "unknown")) gaps = true;
    // Merged issues to close once live are bookkeeping, not decisions: one folded line for all of them.
    const line = (w) => h("li", { class: `w-${w.kind}` },
      pill(w.kind, w.kind === "request" || w.kind === "breaker" ? "attn" : (w.kind === "unknown" ? "warn" : "")), " ", link(w.url, w.text));
    const now = d.waiting.filter((w) => w.kind !== "deploy");
    const later = d.waiting.filter((w) => w.kind === "deploy");
    blocks.push(h("div", { class: "group" },
      h("h3", {}, h("button", { type: "button", class: "linkish", onclick: () => select(repo) }, repo)),
      h("ul", { class: "items" }, now.map(line),
        later.length ? h("li", {}, h("details", {}, h("summary", {}, pill("deploy"), ` ${later.length} merged issue(s) to close once the fix is live`),
          h("ul", { class: "items" }, later.map(line)))) : null)));
  }
  const loading = Object.values(state.repos).some((d) => d && d.loading);
  replace($("waiting"), blocks.length ? blocks
    : empty(loading ? "Loading…" : (gaps ? "Nothing that could be read; see the repositories below." : "Nothing. Every agent is either working or idle.")));
}

function renderRepos() {
  const repos = state.session ? state.session.repos : [];
  const head = h("thead", {}, h("tr", {},
    ["Repository", "Version", "Agents", "Auto-merge", "Waiting", "PRs", "Queue", "Running", "Coder today", "Fixer today", "Cost 7 d", "Breakers", "Health", ""]
      .map((c) => h("th", {}, c))));
  const rows = repos.map((repo) => {
    const d = state.repos[repo];
    const sel = repo === state.selected ? "selected" : "";
    if (!d || d.loading) {
      return h("tr", { class: sel }, h("td", {}, repo), h("td", { colspan: 13, class: "muted" }, "loading…"));
    }
    if (d.failed) {
      return h("tr", { class: sel }, h("td", {}, repo), h("td", { colspan: 12, class: "bad" }, d.failed), h("td", {}, removeBtn(repo)));
    }
    const t = totals(d);
    return h("tr", { class: `click ${sel}`, onclick: () => select(repo) },
      h("td", {}, h("button", { type: "button", class: "linkish", onclick: (e) => { e.stopPropagation(); select(repo); } }, repo)),
      h("td", {}, d.version || "?"),
      h("td", {}, onOff(d.vars, "AGENTS_ENABLED")),
      h("td", {}, d.vars ? (d.vars.AGENT_AUTO_MERGE === "true" ? pill("live", "ok") : pill("dry run", "off")) : pill("unknown", "warn")),
      h("td", { class: "n" }, t.waiting || t.unknown.has("waiting") ? pill(shown(t, "waiting"), t.unknown.has("waiting") ? "warn" : "attn") : "0"),
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
  replace($("repos"), head, h("tbody", {}, rows.length ? rows : h("tr", {}, h("td", { colspan: 14, class: "muted" },
    "No repositories with Gatehand found. Add one below, or Find repositories again."))));
  const ex = state.session ? state.session.excluded : [];
  $("excluded").textContent = ex.length ? `Hidden: ${ex.join(", ")}` : "";
}

function removeBtn(repo) {
  return h("button", {
    type: "button", class: "quiet small", title: `Hide ${repo} from this dashboard`,
    onclick: async (e) => {
      e.stopPropagation();
      try { applySession(await api("/api/repos", { method: "POST", body: { op: "remove", repo } })); }
      catch (err) { notice(err.message); }
      if (state.selected === repo) { state.selected = ""; $("detail").hidden = true; }
      renderAll();
    },
  }, "Hide");
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
  if (!window.confirm(question)) return null;
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
    if (!window.confirm(text)) { if (btn) btn.disabled = false; return null; }
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
  if (state.selected === repo) renderDetail();
}

// After any inbox command: re-read the inbox every 10 s for two minutes, until the bot has replied
// (awaiting_reply off), which also re-enables the other answer buttons.
function watchAnswer(repo, req) {
  let left = 12;
  const tick = async () => {
    left -= 1;
    await loadInbox(repo, true); // the inbox only: the merge gate's logs are not worth re-reading every 10 s
    const got = state.inbox[repo];
    if (got && got.requests && !got.awaiting_reply) {
      const r = req && got.requests.find((x) => x.id === req);
      notice(req && r && !r.answered
        ? `The Agent inbox workflow replied but did not record ${req} as answered: read its reply on the inbox.`
        : "The Agent inbox workflow has replied; see the inbox for what was done.");
      await loadRepo(repo, true);
      return;
    }
    if (left > 0) setTimeout(tick, 10000);
    else notice("No reply from the Agent inbox workflow after two minutes; check its runs on GitHub.");
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
    const reason = window.prompt(`Reject ${r.id}. Reason (optional, one line of at most 300 characters):`, "");
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
      renderDetail();
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
    if (done) { delete state.drafts[key]; renderDetail(); }
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
      if (!window.confirm(`Remove ${stuck.join(" and ")} from PR #${p.number} as ${state.session.viewer}?\n\nDo this once you have fixed the PR yourself: the merge gate and the fixer pick it up again.`)) return;
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

function renderDetail() {
  const repo = state.selected;
  const el = $("detail");
  const d = state.repos[repo];
  if (!repo || !d || d.loading || d.failed) { el.hidden = true; return; }
  el.hidden = false;
  const i = d.issues;
  replace(el,
    h("div", { class: "detail-head" }, h("h2", {}, link(d.url, repo)),
      h("span", { class: "muted" }, ` Gatehand ${d.version || "?"} · you have ${String(d.viewer_permission || "?").toLowerCase()} access · read ${ago(d.fetched_at)}`),
      h("button", { type: "button", class: "quiet small", onclick: () => { state.selected = ""; renderDetail(); renderRepos(); } }, "Close")),
    (d.errors || []).length ? h("div", { class: "notice" }, h("strong", {}, "Could not read everything:"),
      h("ul", {}, d.errors.map((e) => h("li", {}, e)))) : null,
    h("h3", {}, "Switches"), switchesBlock(repo, d),
    h("h3", {}, "Inbox requests"), inboxBlock(repo, d),
    h("h3", {}, "Agent PRs"), prBlock(repo, d),
    h("h3", {}, "Running now"), runsTable(d.active_runs, cancelBtn(repo, d)),
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
    h("h3", {}, "Merged, to close once live"), issueList(i && i.done_pending_deploy, "None."),
    h("h3", {}, "Agent runs, last seven days"), ledgerTables(d),
    h("h3", {}, "Breakers"), breakerList(repo, d),
    h("h3", {}, "Recent finished runs"), runsTable(d.recent_runs));
}

function renderAll() { renderTotals(); renderWaiting(); renderRepos(); renderDetail(); }

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
  if (repo === state.selected) loadExtras(repo, fresh);
}

async function loadExtras(repo, fresh) {
  const d = state.repos[repo];
  if (!d || d.failed) return;
  const q = fresh ? "?fresh=1" : "";
  const jobs = [];
  if (d.inbox) {
    jobs.push(api(`/api/repo/${repo}/inbox${q}`).then((r) => { state.inbox[repo] = r; }, (e) => { state.inbox[repo] = { error: e.message }; }));
  }
  if ((d.prs || []).length) {
    jobs.push(api(`/api/repo/${repo}/gate${q}`).then((r) => { state.gate[repo] = r; }, (e) => { state.gate[repo] = { error: e.message }; }));
  }
  await Promise.all(jobs);
  if (state.selected === repo) renderDetail();
}

function select(repo) {
  state.selected = repo;
  renderRepos();
  renderDetail();
  loadExtras(repo, false);
  $("detail").scrollIntoView({ behavior: "smooth", block: "start" });
}

async function refresh(fresh) {
  if (!state.token) {
    notice("This page needs the address the dashboard opened in your browser (it carries the session secret). Start it again with `python3 bin/dashboard.py`.");
    return;
  }
  $("refresh").disabled = true;
  try {
    applySession(await api(`/api/session${fresh ? "?fresh=1" : ""}`));
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
refresh(false);
