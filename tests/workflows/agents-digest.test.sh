#!/usr/bin/env bash
# tests/workflows/agents-digest.test.sh
# .github/scripts/agent-digest.sh (the weekly digest) against the stub gh, on a fixed week
# (2026-11-02 06:30Z to 2026-11-09 06:30Z, ISO week 2026-W46):
#   - each section from one fixture: waiting items (unticked inbox requests only, a tripped breaker,
#     blocked issues, merged fixes to close, where only the bot's merge note counts), agent PRs
#     (window, state, CI on the first push, the FIRST review by the review bot only, fix runs, the
#     summary counts), runs per role (window, malformed lines, totals), the queue by priority, and
#     the repo's own sections from agent_hook_digest_sections (.github/agents/hooks/lib.sh);
#   - every read that fails says so in its section and makes render exit 1, while a 404 (a branch or
#     file not there yet) is "nothing yet", never a failure;
#   - run: the marker is the first line and added after sanitising; a new week posts, the same week
#     edits only a github-actions comment whose FIRST line is the marker, an identical body is left
#     alone, an unreadable comment list posts nothing, and a failed section still posts but exits 1;
#   - inbox_find (agent-lib.sh) never creates the inbox, and inbox_issue still does;
#   - the workflow: GITHUB_TOKEN only, the CI runner, issues: write.
# shellcheck disable=SC2016 # `…` in single quotes is markdown to match, never shell
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
DIGEST="${REPO_ROOT}/.github/scripts/agent-digest.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/agents-gh-stub.sh"

pass=0
fail=0
t_pass() { printf '\033[1;32m[agents-digest] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[agents-digest] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
expect() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1: expected '$3', got '$2'"; fi; }
has() { if grep -Fq -- "$2" <<<"$3"; then t_pass "$1"; else t_fail "$1: no '$2' in:"$'\n'"$3"; fi; }
hasnt() { if grep -Fq -- "$2" <<<"$3"; then t_fail "$1: unexpected '$2'"; else t_pass "$1"; fi; }
called() { if stub_gh_calls | grep -Fq -- "$2"; then t_pass "$1"; else t_fail "$1: no gh call with '$2'"; fi; }
not_called() { if stub_gh_calls | grep -Fq -- "$2"; then t_fail "$1: a gh call with '$2'"; else t_pass "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" "${STUB_DIR:-}"' EXIT
export GH_REPO=o/r AGENT_INBOX_ISSUE=45 AGENT_OWNER_LOGIN=owner AGENTS_ENABLED=true AGENT_AUTO_MERGE=true
AGENT_NOW_EPOCH="$(jq -n '"2026-11-09T06:30:00Z" | fromdateiso8601')"
export AGENT_NOW_EPOCH
NOT_FOUND='gh: Not Found (HTTP 404)'
BOOM='gh: Server Error (HTTP 500)'
LEDGER='api -H * repos/o/r/contents/runs/2026-11.jsonl?ref=agent-ledger'
BREAKER='api -H * repos/o/r/contents/state/breaker.json?ref=agent-ledger'

# --- fixtures ------------------------------------------------------------------------------------------

row() { jq -cn --arg r "$1" --arg o "$2" --arg s "$3" --argjson pr "${4:-null}" --argjson t "${5:-null}" --argjson ms "${6:-null}" --argjson c "${7:-null}" \
  '{v: 1, role: $r, outcome: $o, started_at: $s, ended_at: $s, pr: $pr, turns: $t, duration_ms: $ms, cost_usd: $c}'; }
LEDGER_ROWS="$(
  row coder pr-opened 2026-11-03T08:00:00Z 101 50 600000 1.5
  row coder blocked 2026-11-04T08:00:00Z null 10 60000 0.25
  row coder pr-opened 2026-11-01T08:00:00Z 90 99 999999 9
  echo '{not json'
  row fixer fix-pushed 2026-11-03T10:00:00Z 101 20 120000 0.05
  row fixer fix-pushed 2026-11-02T06:00:00Z 101
  row merger merged 2026-11-03T12:16:00Z 101
)"
BREAKER_JSON='{"coder": {"consecutive": 3, "tripped_at": "2026-11-08T10:00:00Z", "reason": "3 runs in a row without a PR"}, "fixer": {"consecutive": 0, "tripped_at": null}}'

INBOX_BODY="$(cat <<'EOF'
<!-- agent-inbox -->
Requests land here.
- [ ] REQ-20261101-dead · coder · #1 · above the open list, not a request
## Open requests
<!-- agent-inbox:open:start -->
- [x] REQ-20261103-aaaa · coder · #5 · blocked: answered · rejected
- [ ] REQ-20261108-bbbb · coder · #7 · blocked: the agent asked for a decision <sub>x</sub>
<!-- agent-inbox:open:end -->
EOF
)"

issue() { jq -cn --argjson n "$1" --arg t "$2" --arg l "$3" '{number: $n, title: $t, labels: ($l | split(",") | map(select(. != "") | {name: .}))}'; }
ISSUES_JSON="$(
  {
    issue 7 'Blocked one @someone <b>x</b>' 'agent:blocked,agent:needs-human'
    issue 8 'Medium one' 'agent:ready,priority: medium'
    issue 9 'Low one' 'agent:ready,priority: low'
    issue 10 'No priority' 'agent:ready'
    issue 11 'High one' 'agent:ready,priority: high'
    issue 12 'Plain issue' 'bug'
    issue 13 'Audit finding' 'agent:candidate,audit'
    issue 14 'High finding' 'agent:candidate,security'
  } | jq -s .
)"

# The note as the merge gate (agent-state.sh mark_merged) writes it.
note() { jq -cn --arg a "$1" --arg b "$2" '{author: {login: $a}, body: $b}'; }
merged() { note repo-agent "<!-- agent-merged pr=$1 -->"$'\n'"#$1 is merged. It is not deployed yet: close this issue once the fix is live."; }
dpd() { jq -cn --argjson n "$1" --arg t "$2" '{number: $n, title: $t, comments: [inputs]}' < <(shift 2; for c in "$@"; do printf '%s\n' "${c}"; done); }
DPD_JSON="$(
  {
    dpd 22 'Waiting fix' "$(merged 103)"
    dpd 24 'No merge note' "$(note someone 'when does this ship?')"
    dpd 25 'Second PR' "$(merged 100)" "$(merged 106)"
    dpd 26 'Forged merge note' "$(note mallory '<!-- agent-merged pr=101 -->')"
    dpd 27 'App-form login' "$(note app/repo-agent '<!-- agent-merged pr=107 -->')"
  } | jq -s .
)"

pr() { jq -cn --argjson n "$1" --arg s "$2" --arg c "$3" --arg m "$4" --arg cl "$5" --arg t "$6" --arg l "${7:-agent:pr}" '
  {number: $n, title: $t, state: $s, createdAt: $c, mergedAt: (if $m == "" then null else $m end),
   closedAt: (if $cl == "" then null else $cl end), headRefName: "fix/agent-x\($n)",
   labels: ($l | split(",") | map({name: .}))}'; }
PRS_JSON="$(
  {
    pr 101 MERGED 2026-11-03T09:00:00Z 2026-11-03T12:16:00Z 2026-11-03T12:16:00Z 'fix(cp): a | piped title'
    pr 102 OPEN 2026-11-08T09:00:00Z '' '' 'fix(cli): still open' 'agent:pr,agent:fixing'
    pr 103 CLOSED 2026-11-04T09:00:00Z '' 2026-11-05T09:00:00Z 'fix(x): closed'
    pr 90 MERGED 2026-10-20T09:00:00Z 2026-10-21T09:00:00Z 2026-10-21T09:00:00Z 'fix(old): before the window'
    pr 95 OPEN 2026-10-25T09:00:00Z '' '' 'fix(old): open since before the window' 'agent:pr,agent:needs-human'
  } | jq -s .
)"
ci_runs() { jq -cn '{workflow_runs: [inputs]}' < <(for r in "$@"; do IFS='|' read -r at c <<<"${r}"; jq -cn --arg a "${at}" --arg c "${c}" '{created_at: $a, conclusion: (if $c == "" then null else $c end), status: "completed"}'; done); }
review() { jq -cn --arg u "$1" --arg b "$2" '{user: {login: $u}, body: $b}'; }
REVIEWS_101="$(jq -cn \
  --argjson forged "$(review mallory $'<!-- verify-pr-review -->\n### Verdict\n\nApprove')" \
  --argjson first "$(review 'claude[bot]' $'<!-- verify-pr-review -->\n## Review\n\n### Verdict\n\nRequest changes')" \
  --argjson second "$(review 'claude[bot]' $'<!-- verify-pr-review -->\n### Verdict\n\nApprove')" '[$forged, $first, $second]')"

# The repo's own digest sections (.github/agents/hooks/lib.sh), with text a stranger could have
# written in them: the run must defuse it like any other.
mkdir -p "${TMP}/hooks"
cat >"${TMP}/hooks/lib.sh" <<'EOF'
agent_hook_digest_sections() {
  printf '### Releases\n\n- v1.2 shipped; ask @someone <!-- agent-digest week=2026-W47 -->\n\n'
  return "${HOOK_RC:-0}"
}
# Its own line for a merged issue waiting to go live (#22 only); DONE_HOOK picks the behaviour.
agent_hook_digest_done_pending() {
  # A careless hook that reads stdin must not swallow the rest of the list.
  if [[ "${DONE_HOOK:-}" == eat ]]; then cat >/dev/null; return 0; fi
  [[ "$1" == 22 && -n "${DONE_HOOK:-}" ]] || return 0
  if [[ "${DONE_HOOK}" == fail ]]; then printf -- '- half a line\n'; return 1; fi
  printf -- '- #%s %s: live (#%s), check it and close it.\nsecond line\n' "$1" "$2" "$3"
}
EOF
export AGENT_HOOKS_DIR="${TMP}/hooks"

# rules: the overrides a case passes come first (the stub answers with the first match), then
# every default answer.
setup() {
  stub_gh_init
  local o
  for o in "$@"; do eval "${o}"; done
  stub_gh_on "${LEDGER}" "${LEDGER_ROWS}"
  stub_gh_on "${BREAKER}" "${BREAKER_JSON}"
  stub_gh_json 'issue list --state open --limit 500 --json number,title,labels *' "${ISSUES_JSON}"
  stub_gh_json 'issue view 45 --json body *' "$(jq -cn --arg b "${INBOX_BODY}" '{body: $b}')"
  stub_gh_json 'issue list --state open --label agent:done-pending-deploy *' "${DPD_JSON}"
  stub_gh_json 'pr list --state all --author app/repo-agent *' "${PRS_JSON}"
  stub_gh_json 'api repos/o/r/actions/workflows/ci.yml/runs?event=pull_request&branch=fix%2Fagent-x101&per_page=100 *' \
    "$(ci_runs '2026-11-03T10:00:00Z|failure' '2026-11-03T09:00:05Z|success' '2026-11-03T08:59:00Z|failure')"
  stub_gh_json 'api repos/o/r/actions/workflows/ci.yml/runs?event=pull_request&branch=fix%2Fagent-x102&per_page=100 *' \
    "$(ci_runs '2026-11-08T09:00:05Z|failure')"
  stub_gh_json 'api repos/o/r/actions/workflows/ci.yml/runs?event=pull_request&branch=fix%2Fagent-x103&per_page=100 *' '{"workflow_runs": []}'
  stub_gh_json 'api --paginate repos/o/r/issues/101/comments?per_page=100 *' "${REVIEWS_101}"
  stub_gh_json 'api --paginate repos/o/r/issues/102/comments?per_page=100 *' '[]'
  stub_gh_json 'api --paginate repos/o/r/issues/103/comments?per_page=100 *' '[]'
  stub_gh_json 'api --paginate repos/o/r/issues/95/comments?per_page=100 *' '[]'
  stub_gh_json 'api --paginate repos/o/r/issues/45/comments?per_page=100 *' "${INBOX_COMMENTS:-[]}"
}

render() { bash "${DIGEST}" render 2>"${TMP}/err"; }

# --- the full week ---------------------------------------------------------------------------------------

setup
out="$(render)"
expect "render: exit 0 when every read works" "$?" 0
has "header: the window" '## Weekly digest: 2026-11-02 to 2026-11-09' "${out}"
has "header: agents and auto-merge on" 'Agents: on. Auto-merge: on.' "${out}"

has "waiting: the unticked inbox request" '- Inbox request REQ-20261108-bbbb · coder · #7 · blocked: the agent asked for a decision &lt;sub>x&lt;/sub>: answer it on #45.' "${out}"
hasnt "waiting: a ticked request is not listed" 'REQ-20261103-aaaa' "${out}"
hasnt "waiting: a request line outside the open list is not listed" 'REQ-20261101-dead' "${out}"
has "waiting: the tripped breaker" '- The coder is stopped since 2026-11-08 10:00 UTC: 3 runs in a row without a PR. `/resume coder` on the inbox starts it again.' "${out}"
hasnt "waiting: a closed breaker is not listed" 'The fixer is stopped' "${out}"
has "waiting: the blocked issue, HTML in its title escaped" '- #7 Blocked one @someone &lt;b>x&lt;/b>: agent:blocked, agent:needs-human.' "${out}"
has "waiting: candidates to queue or close" '- 2 `agent:candidate` issue(s) to queue (add `agent:ready`) or close: #13, #14.' "${out}"
has "waiting: a merged fix to close once live" '- #22 Waiting fix: #103 is merged. Close it once the fix is live.' "${out}"
has "waiting: the bot's merge note in gh's app/ form counts too" '- #27 App-form login: #107 is merged.' "${out}"
has "waiting: no merge note from the bot" '- #24 No merge note: merged, but with no merge note. Check it is live, then close it.' "${out}"
has "waiting: the last merged PR is the one named" '- #25 Second PR: #106 is merged.' "${out}"
has "waiting: a person's merge note is not the bot's" '- #26 Forged merge note: merged, but with no merge note' "${out}"

has "PRs: the summary" 'Opened 3, merged 1, closed unmerged 1; 2 open now. Of the 3 opened, CI passed on the first push for 1 and the first Claude review approved 0.' "${out}"
has "PRs: merged, first CI run after opening, FIRST review by the bot, one fix" '| #101 fix(cp): a \| piped title | merged after 3 h 16 min | passed | request-changes | 1 |' "${out}"
has "PRs: open with its state label" '| #102 fix(cli): still open | open (agent:fixing) | failed | none | 0 |' "${out}"
has "PRs: closed unmerged, no CI run" '| #103 fix(x): closed | closed unmerged | none | none | 0 |' "${out}"
hasnt "PRs: one merged before the window is not listed" '#90 ' "${out}"
has "PRs: one open since before the window is listed" '| #95 fix(old): open since before the window | open (agent:needs-human) | none | none | 0 |' "${out}"

has "runs: coder totals, window only, malformed line skipped" '| coder | 2 | 1 blocked, 1 pr-opened | 60 | 11 min | $1.75 |' "${out}"
has "runs: fixer" '| fixer | 1 | 1 fix-pushed | 20 | 2 min | $0.05 |' "${out}"
has "runs: merger with no metrics" '| merger | 1 | 1 merged | – | – | – |' "${out}"

# The rate is policy.json's, so raising the coder's cap there does not leave this test behind.
coder_cap="$(jq -r '.roles.coder.runsPerDay' "${REPO_ROOT}/.github/agents/policy.json")"
has "queue: by priority, in order" "4 issue(s) queued for the coder: 1 high, 1 medium, 1 low, 1 no priority. At ${coder_cap} coder runs a day, that is about $(((4 + coder_cap - 1) / coder_cap)) day(s)." "${out}"

has "repo sections: the hook's section renders" '### Releases' "${out}"
has "repo sections: as written (sanitised only when posted)" '- v1.2 shipped; ask @someone' "${out}"

# Section order: what needs the owner first.
order="$(grep -E '^### ' <<<"${out}" | cut -c5-12 | paste -sd'|' -)"
expect "sections: agenda order, the repo's last" "${order}" 'Waiting |Agent PR|Agent ru|Queue|Releases'

# --- reads that fail, and 404s that are just "nothing yet" ------------------------------------------------

setup "stub_gh_on '${LEDGER}' '' 1 '${BOOM}'"
out="$(render)"
expect "ledger unreadable: render exits 1" "$?" 1
has "ledger unreadable: runs says so" 'Could not read the ledger.' "${out}"
hasnt "ledger unreadable: the breaker is read on its own" 'Could not read the breaker state' "${out}"
has "ledger unreadable: the breaker still shows" 'The coder is stopped since' "${out}"
has "ledger unreadable: fix runs are unknown, not zero" '| failed | none | ? |' "${out}"

setup "stub_gh_on '${LEDGER}' '' 1 '${NOT_FOUND}'" "stub_gh_on '${BREAKER}' '' 1 '${NOT_FOUND}'"
out="$(render)"
expect "ledger not there yet: render exits 0" "$?" 0
has "ledger not there yet: no runs" 'No runs in these seven days.' "${out}"
hasnt "ledger not there yet: no stopped role" 'is stopped since' "${out}"

setup "stub_gh_on '${BREAKER}' '' 1 '${BOOM}'"
out="$(render)"
expect "breaker unreadable: render exits 1" "$?" 1
has "breaker unreadable: says so" 'Could not read the breaker state on the ledger branch' "${out}"

for bad in '{not json' '[]'; do
  setup "stub_gh_on '${BREAKER}' '${bad}'"
  out="$(render)"
  expect "breaker '${bad}': render exits 1" "$?" 1
  has "breaker '${bad}': says so, never 'nothing stopped'" 'Could not read the breaker state on the ledger branch' "${out}"
done

setup "stub_gh_on 'pr list --state all --author app/repo-agent *' '' 1 '${BOOM}'"
out="$(render)"
expect "PR list unreadable: render exits 1" "$?" 1
has "PR list unreadable: says so" 'Could not list the agent PRs.' "${out}"
has "PR list unreadable: later sections still render" '### Releases' "${out}"

setup "stub_gh_on 'api repos/o/r/actions/workflows/ci.yml/runs?event=pull_request&branch=fix%2Fagent-x101&per_page=100 *' '' 1 '${BOOM}'"
out="$(render)"
expect "a CI lookup fails: render exits 1" "$?" 1
has "a CI lookup fails: that cell is ?" '| merged after 3 h 16 min | ? | request-changes |' "${out}"

setup "stub_gh_on 'api --paginate repos/o/r/issues/101/comments?per_page=100 *' '' 1 '${BOOM}'"
out="$(render)"
expect "a review lookup fails: render exits 1" "$?" 1
has "a review lookup fails: that cell is ?" '| passed | ? | 1 |' "${out}"

setup "stub_gh_on 'issue list --state open --label agent:done-pending-deploy *' '' 1 '${BOOM}'"
out="$(render)"
expect "pending-deploy list unreadable: render exits 1" "$?" 1
has "pending-deploy list unreadable: says so" 'Could not list the `agent:done-pending-deploy` issues.' "${out}"

setup "stub_gh_on 'issue list --state open --limit 500 --json number,title,labels *' '' 1 '${BOOM}'"
out="$(render)"
expect "issue list unreadable: render exits 1" "$?" 1
has "issue list unreadable: waiting says so" 'Could not list the open issues, so blocked ones' "${out}"
has "issue list unreadable: queue says so" 'Could not list the open issues.' "${out}"

setup "stub_gh_on 'issue view 45 --json body *' '' 1 '${BOOM}'"
out="$(render)"
expect "inbox unreadable: render exits 1" "$?" 1
has "inbox unreadable: says so" 'Could not read the inbox issue #45' "${out}"

setup
out="$(HOOK_RC=1 render)"
expect "a repo section that fails: render exits 1" "$?" 1
has "a repo section that fails: what it printed still renders" '### Releases' "${out}"
has "a repo section that fails: the core sections still render" '### Queue' "${out}"
out="$(AGENT_HOOKS_DIR="${TMP}/no-hooks" render)"
expect "no hooks file: render exits 0" "$?" 0
hasnt "no hooks file: no repo section" '### Releases' "${out}"

setup
out="$(DONE_HOOK=live render)"
has "done-pending hook: its line replaces the default" '- #22 Waiting fix: live (#103), check it and close it.' "${out}"
hasnt "done-pending hook: only its first line is kept" 'second line' "${out}"
hasnt "done-pending hook: the default line for that issue is gone" '- #22 Waiting fix: #103 is merged.' "${out}"
has "done-pending hook: no output keeps the default for the others" '- #24 No merge note: merged, but with no merge note.' "${out}"
out="$(DONE_HOOK=eat render)"
has "done-pending hook that reads stdin: the later issues are still listed" '- #27 App-form login: #107 is merged.' "${out}"
out="$(DONE_HOOK=fail render)"
has "done-pending hook that fails: the default line stays" '- #22 Waiting fix: #103 is merged. Close it once the fix is live.' "${out}"
hasnt "done-pending hook that fails: what it printed is dropped" 'half a line' "${out}"

# --- the window across a month boundary, and the flags off --------------------------------------------------

setup "stub_gh_on 'api -H * repos/o/r/contents/runs/2026-12.jsonl?ref=agent-ledger' '$(row coder no-op 2026-12-02T08:00:00Z)'" \
  "stub_gh_on 'api -H * repos/o/r/contents/runs/2026-11.jsonl?ref=agent-ledger' '$(row coder failed 2026-11-29T08:00:00Z)'"
out="$(AGENT_NOW_EPOCH="$(jq -n '"2026-12-03T06:30:00Z" | fromdateiso8601')" AGENTS_ENABLED='' AGENT_AUTO_MERGE=false render)"
has "month boundary: rows from both months" '| coder | 2 | 1 failed, 1 no-op |' "${out}"
has "flags off: both said" 'Agents: **off** (`AGENTS_ENABLED` is not `true`). Auto-merge: **off**' "${out}"
setup "stub_gh_on 'api -H * repos/o/r/contents/runs/2026-11.jsonl?ref=agent-ledger' '$(row coder failed 2026-11-04T08:00:00Z | jq -c '.counted = false')
$(row coder failed 2026-11-04T09:00:00Z)'"
out="$(render)"
has "runs: a run that never reached the agent is called out" '| coder | 2 | 2 failed (1 never reached the agent, not counted) |' "${out}"

# --- run: post, edit, leave alone ---------------------------------------------------------------------------

MARKER='<!-- agent-digest week=2026-W46 -->'
run_digest() { bash "${DIGEST}" run >"${TMP}/out" 2>"${TMP}/err"; }

setup
run_digest
expect "run, new week: exit 0" "$?" 0
called "run, new week: posts on the inbox" 'issue comment 45 --body-file'
not_called "run, new week: edits nothing" 'PATCH'
body="$(stub_gh_last_body 'issue comment 45 *')"
expect "run: the marker is the first line" "$(head -1 <<<"${body}")" "${MARKER}"
expect "run: and appears once" "$(grep -cF '<!-- agent-digest' <<<"${body}")" 1
has "run: a mention from a repo section is defused" 'ask @-someone' "${body}"
has "run: a marker from a repo section is defused" '&lt;!-- agent-digest week=2026-W47' "${body}"
has "run: an issue title's mention is defused" 'Blocked one @-someone' "${body}"
has "run: the body is the render" '| #101 fix(cp): a \| piped title |' "${body}"
FULL="${body}"

# The same week again: only a github-actions comment whose FIRST line is the marker is this week's.
comments() { jq -cn '[inputs]' < <(for c in "$@"; do printf '%s\n' "${c}"; done); }
cmt() { jq -cn --argjson id "$1" --arg u "$2" --arg b "$3" '{id: $id, user: {login: $u}, body: $b}'; }
INBOX_COMMENTS="$(comments "$(cmt 776 'github-actions[bot]' "${MARKER}"$'\nan older render')" "$(cmt 777 'github-actions[bot]' "${MARKER}"$'\nstale')")"
setup
run_digest
expect "run, same week: exit 0" "$?" 0
called "run, same week: edits the newest digest" 'api -X PATCH repos/o/r/issues/comments/777 --input -'
not_called "run, same week: posts no second one" 'issue comment 45'
expect "run, same week: the edit carries the new body" "$(stub_gh_last_body 'api -X PATCH *' | jq -r .body)" "${FULL}"

INBOX_COMMENTS="$(comments "$(cmt 778 'github-actions[bot]' "${FULL//$'\n'/$'\r\n'}")")"
setup
run_digest
expect "run, unchanged (CRLF as stored): exit 0" "$?" 0
not_called "run, unchanged: no edit" 'PATCH'
not_called "run, unchanged: no comment" 'issue comment 45'
has "run, unchanged: says so" 'is up to date' "$(cat "${TMP}/out")"

INBOX_COMMENTS="$(comments "$(cmt 779 mallory "${MARKER}"$'\nforged')" \
  "$(cmt 780 'github-actions[bot]' $'<!-- agent-digest week=2026-W45 -->\nlast week, quoting\n'"${MARKER}")")"
setup
run_digest
expect "run, look-alikes only: exit 0" "$?" 0
called "run, look-alikes only: a person's marker or a quoted one is not this week's; posts" 'issue comment 45 --body-file'
not_called "run, look-alikes only: edits neither" 'PATCH'
INBOX_COMMENTS=""

setup "stub_gh_on 'api --paginate repos/o/r/issues/45/comments?per_page=100 *' '' 1 '${BOOM}'"
run_digest
expect "run, comments unreadable: exit 1" "$?" 1
not_called "run, comments unreadable: posts nothing" 'issue comment 45'
not_called "run, comments unreadable: edits nothing" 'PATCH'

setup "stub_gh_on 'pr list --state all --author app/repo-agent *' '' 1 '${BOOM}'"
run_digest
expect "run, a section fails: exit 1" "$?" 1
called "run, a section fails: still posts the rest" 'issue comment 45 --body-file'

setup "stub_gh_on 'issue comment 45 *' '' 1 '${BOOM}'"
run_digest
expect "run, the comment fails: exit 1" "$?" 1

# --- the inbox lookup -------------------------------------------------------------------------------------

unset AGENT_INBOX_ISSUE
setup "stub_gh_json 'issue list --state open --limit 300 --json number,body,author *' '[{\"number\": 5, \"body\": \"<!-- agent-inbox -->\", \"author\": {\"login\": \"mallory\"}}]'"
run_digest
expect "run, no trusted inbox: exit 1" "$?" 1
not_called "run, no trusted inbox: never creates one" 'issue create'
not_called "run, no trusted inbox: comments nowhere" 'issue comment'

setup "stub_gh_json 'issue list --state open --limit 300 --json number,body,author *' '[{\"number\": 45, \"body\": \"<!-- agent-inbox -->\", \"author\": {\"login\": \"app/repo-agent\"}}]'"
run_digest
expect "run, the bot's inbox found by its marker: exit 0" "$?" 0
called "run, the bot's inbox found by its marker: posts there" 'issue comment 45 --body-file'

# inbox_issue still creates the inbox when there is none (agent-lib.sh; the digest never calls it).
setup "stub_gh_json 'issue list --state open --limit 300 --json number,body,author *' '[]'" \
  "stub_gh_on 'issue create *' 'https://github.com/o/r/issues/99'"
got="$(bash -c 'source "$1"; inbox_issue' _ "${REPO_ROOT}/.github/scripts/agent-lib.sh" 2>/dev/null)"
expect "inbox_issue: creates one when none exists" "${got}" 99
export AGENT_INBOX_ISSUE=45

# --- the workflow -----------------------------------------------------------------------------------------

WF="$(cat "${REPO_ROOT}/.github/workflows/agent-digest.yml")"
has "workflow: runs the script's run command" 'run: bash .github/scripts/agent-digest.sh run' "${WF}"
has "workflow: writes issues only" 'issues: write' "${WF}"
if grep -Eq '^ +[a-z-]+: write' <<<"$(grep -v 'issues: write' <<<"${WF}")"; then t_fail "workflow: a write permission besides issues"; else t_pass "workflow: no write permission besides issues"; fi
hasnt "workflow: no App token" 'create-github-app-token' "${WF}"
hasnt "workflow: no Claude credential" 'CLAUDE_CODE_OAUTH_TOKEN' "${WF}"
has "workflow: on the CI runner (policy.json runners.ci)" "runs-on: $(jq -r .runners.ci "${REPO_ROOT}/.github/agents/policy.json")" "${WF}"

printf '\n[agents-digest] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
