#!/usr/bin/env bash
# .github/scripts/agent-lib.sh
# Shared helpers for the autonomous-agent scripts (.github/scripts/agent-*.sh). SOURCED, never run.
#
# The agents' design (.github/agents/README.md, "Security model") rests on one rule: the model
# only writes files, and plain shell like this decides what reaches GitHub. So everything here is
# deterministic and testable without a model or the network: Gatehand's tests/workflows/agents-*.test.sh
# source this file and drive it against a stub `gh` and throwaway git repos.
#
# Requires bash 4+, git, jq, and `gh` for the functions that talk to GitHub. The runner image has
# git, curl, jq and python3; gh comes from .github/actions/install-gh.

AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_ROOT="${AGENT_ROOT:-$(cd "${AGENT_LIB_DIR}/../.." && pwd)}"
AGENT_POLICY="${AGENT_POLICY:-${AGENT_ROOT}/.github/agents/policy.json}"
AGENT_PROTECTED_FILE="${AGENT_PROTECTED_FILE:-${AGENT_ROOT}/.github/agents/protected-paths.txt}"

agent_log() { printf '[agent] %s\n' "$*" >&2; }

# policy <jq-filter>: one value from policy.json, raw.
policy() { jq -r "$1" "${AGENT_POLICY}"; }

# agent_now_epoch: seconds since the epoch, UTC. AGENT_NOW_EPOCH pins it in tests.
agent_now_epoch() {
  if [[ -n "${AGENT_NOW_EPOCH:-}" ]]; then printf '%s\n' "${AGENT_NOW_EPOCH}"; else date -u +%s; fi
}
# agent_iso [epoch]: ISO-8601 UTC. jq, not `date -d`/`date -r`, because GNU and BSD date disagree
# on how to format an arbitrary epoch and these scripts are tested on both.
agent_iso() { jq -rn --argjson e "${1:-$(agent_now_epoch)}" '$e | todate'; }

# output <key> <value>: a step output when running in Actions, stdout otherwise. The value is
# flattened to ONE line: GITHUB_OUTPUT is `key=value` lines and a later line wins, so a newline in
# a value that carries agent text (a refusal reason quoting pr.json) could otherwise add or override
# outputs such as `outcome=` or `pr_url=`.
output() {
  local v
  v="$(printf '%s' "$2" | tr '\r\n' '  ')"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "${v}" >>"${GITHUB_OUTPUT}"
  else
    printf '%s=%s\n' "$1" "${v}"
  fi
}

# agent_oneline <max>: stdin -> one sanitised line of about <max> bytes. For text that quotes the
# agent or an issue and is then posted as the bot (refusal reasons, the inbox checklist). Cut BEFORE
# sanitising, never after (see agent_sanitize), so the result can run a few bytes over <max>.
agent_oneline() { tr '\r\n' '  ' | head -c "$1" | agent_sanitize; }

# --- text from the model or from issues --------------------------------------------------------------

# GitHub's closing keywords (docs: "Linking a pull request to an issue"), in the forms it accepts:
# `fixes #12`, `Fixes: #12`, `closes owner/repo#12` and `resolves https://github.com/o/r/issues/12`.
# House rule: agent PRs say `Refs #N`, never these. A merge is not a deploy, and the owner closes
# issues themselves after checking production.
AGENT_CLOSING_RE='(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]+(([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+|https?://github\.com/[^[:space:]]+/(issues|pull)/[0-9]+)'

# has_closing_keyword: reads stdin, exit 0 when a closing keyword is present. ALL of stdin is read
# before matching: `producer | grep -q` under pipefail reports FALSE when grep exits on an early match
# and the producer dies of SIGPIPE, so `Fixes #7` followed by 64 KB of padding would pass.
has_closing_keyword() {
  local text
  text="$(cat)"
  grep -Eiq -- "${AGENT_CLOSING_RE}" <<<"${text}"
}

# agent_sanitize: stdin -> stdout. Makes model- or issue-authored text safe to post as the bot:
#   - `<!--` becomes `&lt;!--` everywhere, code included, so the text can neither hide content nor
#     forge the HTML-comment markers (`<!-- agent:lock …`, `<!-- agent-req:…`) that these scripts
#     find by searching the RAW text;
#   - `@name` becomes `@-name` wherever GitHub could link it (after a space, `.`, `-`, `_`, a
#     backtick or any other character that is not an ASCII letter or digit: `_@name_` renders as
#     italics around a live mention, and `é@name` is a live mention too), so it pings nobody and
#     cannot summon a bot. An email address keeps its `@` because a letter or digit precedes it.
#
# EXCEPT INSIDE CODE, where GitHub links no mention: `pnpm --filter @acme/db` in a code span or
# a plain fenced block stays as written (rewriting it there turns a package name into `@-acme/db`). A span this code
# took for code and GitHub did not would leave a live mention, so the exemption has two locks and
# falls back to rewriting everything:
#   1. A conservative parser (AGENT_SANITIZE_PY) offers it only where it and GitHub should agree:
#      - nothing when the text has a control character (a carriage return, \f, \v, NUL) or a BOM, or,
#        outside fenced blocks and code spans, any
#        `<` (raw HTML, and autolinks in angle brackets, outrank code spans), any `$` (GitHub's math
#        turns `` $`a` `@x` `b`$ `` into one math run with a LIVE mention), an inline link (`](`:
#        its destination or title can hold a backtick), or a bare URL or `www.` running into a
#        backtick (GitHub's extended autolinks swallow backticks). Inside code these are code.
#        This parser only keeps the common cases predictable; it is not the guarantee: markdown
#        has more ways to pair a backtick differently (a footnote label holding one, say), and
#        those are what lock 2 is for;
#      - fenced blocks only when every fence line in the text starts in column 0 (an indented one can
#        belong to a list item that ends early), and only with no info string or a language from
#        AGENT_CODE_LANGS (```math renders as math and ```mermaid as a diagram, mentions live in both);
#      - code spans only when every backtick run outside fenced blocks closes on its own line (a span
#        may cross lines, and then pairing line by line is wrong), and never on a line with a `|`,
#        which a table splits into cells before it looks for spans.
#   2. GitHub's own renderer (POST /markdown, the comment flavour, in this repo's context) must link
#      exactly one mention: a control `@octocat` (AGENT_MENTION_CONTROL) put before the text, which
#      proves that this token's renderings link mentions at all. Anything else, an error or an unset
#      GH_REPO included, means everything is rewritten.
# Inside code, `@claude`, `@codex`, `@copilot`, `@cursor` and `@dependabot` are rewritten anyway:
# those bots act on the raw text, whatever it renders as (claude.yml starts on any body containing
# "@claude"; the Cursor and Claude apps are installed and read issue comments). Add a name here when
# a bot that reads raw text is installed.
#
# CAP FIRST, THEN SANITISE. Cutting sanitised text can cut a code span open (`` `pnpm @x `` with no
# closing backtick), and the kept mention is then live. Text the scripts add after a blank line (a
# footer, a marker) does not change how the sanitised part renders.
# AGENT_PYTHON overrides the interpreter; when it cannot run, sed rewrites everything, as before.
AGENT_CODE_LANGS='bash sh shell console text txt diff go ts typescript tsx js javascript jsx json jsonc yaml yml toml ini sql prisma dockerfile makefile caddyfile python py html css xml markdown md log'
AGENT_SANITIZE_PY="$(
  cat <<'PY'
import bisect, os, re, sys

data = sys.stdin.buffer.read().replace(b"<!--", b"&lt;!--")
MENTION = re.compile(rb"(?<![A-Za-z0-9])@(?=[A-Za-z0-9])")
ALWAYS = re.compile(rb"(?i)(claude|codex|copilot|cursor|dependabot)")
LANGS = set(os.environ.get("AGENT_CODE_LANGS", "").encode().split())
PUNCT = set(b"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
RISKY = re.compile(rb"<|\$|\]\(|(?i:://|www\.|mailto:|xmpp:)[^\s<]*`")
BT = 0x60


def spans_of(line):
    """The code spans on one line, CommonMark style, and whether every backtick run closed."""
    spans, i, n, closed = [], 0, len(line), True
    while i < n:
        c = line[i]
        if c == 0x5C and i + 1 < n and line[i + 1] in PUNCT:
            i += 2
            continue
        if c != BT:
            i += 1
            continue
        j = i
        while j < n and line[j] == BT:
            j += 1
        k, end = j, None
        while k < n:
            if line[k] != BT:
                k += 1
                continue
            m = k
            while m < n and line[m] == BT:
                m += 1
            if m - k == j - i:
                end = m
                break
            k = m
        if end is None:
            closed = False
            i = j
        else:
            spans.append((i, end))
            i = end
    return spans, closed


def exempt(data):
    # A control character or a BOM anywhere: a bare \r ends a line for GitHub, and a BOM (cmark
    # skips one at the start of a document), \f, \v or a NUL can parse differently where the text
    # is posted than in the check below, which renders it after the control mention.
    if len(sys.argv) > 1 and sys.argv[1] == "plain" or re.search(rb"[\x00-\x08\x0b-\x1f\x7f]|\xef\xbb\xbf", data):
        return []
    lines, offs, pos = data.split(b"\n"), [], 0
    for line in lines:
        offs.append(pos)
        pos += len(line) + 1
    fences = not any(re.match(rb"[ \t]+(`{3,}|~{3,})", l) for l in lines)
    ranges, outside, fence = [], [], None
    for idx, line in enumerate(lines):
        if fences and fence is None:
            m = re.match(rb"(`{3,})([^`]*)$", line) or re.match(rb"(~{3,})(.*)$", line)
            if m:
                info = m.group(2).split()
                fence = (m.group(1)[:1], len(m.group(1)), not info or info[0] in LANGS)
                continue
        elif fences:
            m = re.match(rb"(`{3,}|~{3,})[ \t]*$", line)
            if m and m.group(1)[:1] == fence[0] and len(m.group(1)) >= fence[1]:
                fence = None
            elif fence[2]:
                ranges.append((offs[idx], offs[idx] + len(line)))
            continue
        outside.append(idx)
    inline, balanced, masked = [], True, []
    for idx in outside:
        line = lines[idx]
        spans, closed = spans_of(line)
        balanced = balanced and closed
        if b"|" not in line:
            inline += [(offs[idx] + a, offs[idx] + b) for a, b in spans]
        # The risky constructs are looked for OUTSIDE the spans found: a URL or a `<` inside a code
        # span is code on GitHub too, as long as nothing before it stole a backtick, and that thief
        # would itself be outside. With an unclosed run the spans are not trusted, so nothing is
        # masked then.
        out = bytearray(line)
        for a, b in spans:
            n = 0
            while line[a + n] == BT:
                n += 1
            out[a + n:b - n] = b"x" * (b - a - 2 * n)
        masked.append(bytes(out))
    if RISKY.search(b"\n".join(masked if balanced else [lines[i] for i in outside])):
        return []
    return sorted(ranges + (inline if balanced else []))


RANGES = exempt(data)
STARTS = [a for a, _ in RANGES]


def defang(m):
    p = m.start()
    k = bisect.bisect_right(STARTS, p) - 1
    if k >= 0 and p < RANGES[k][1] and not ALWAYS.match(data, p + 1):
        return b"@"
    return b"@-"


sys.stdout.buffer.write(MENTION.sub(defang, data))
PY
)"

# _agent_sanitize_py [plain] <in >out: the parser above; `plain` rewrites every mention.
_agent_sanitize_py() { AGENT_CODE_LANGS="${AGENT_CODE_LANGS}" "${AGENT_PYTHON:-python3}" -I -c "${AGENT_SANITIZE_PY}" "$@" 2>/dev/null; }

# renders_without_mentions <file>: exit 0 only when GitHub renders the control mention, a blank line
# and <file>, as a comment in GH_REPO, with exactly one linked user or team mention, the control's.
# Anything else (no GH_REPO, an API error, an empty answer, a rendering that links nothing) is 1.
AGENT_MENTION_CONTROL=octocat
renders_without_mentions() {
  local html links
  [[ -n "${GH_REPO:-}" ]] || return 1
  html="$({ printf '@%s\n\n' "${AGENT_MENTION_CONTROL}"; cat "$1"; } \
    | jq -Rs --arg c "${GH_REPO}" '{text: ., mode: "gfm", context: $c}' \
    | gh api -X POST markdown --input - 2>/dev/null)" || return 1
  links="$(grep -oE '<a [^>]*class="[^"]*(user|team)-mention[^>]*>' <<<"${html}")"
  [[ "$(grep -c . <<<"${links}")" -eq 1 ]] && grep -Fq "href=\"https://github.com/${AGENT_MENTION_CONTROL}\"" <<<"${links}"
}

agent_sanitize() {
  local in all code
  in="$(mktemp)" all="$(mktemp)" code="$(mktemp)"
  cat >"${in}"
  if ! _agent_sanitize_py plain <"${in}" >"${all}"; then
    agent_log "agent_sanitize: ${AGENT_PYTHON:-python3} did not run; rewriting every mention with sed"
    LC_ALL=C sed -E \
      -e 's/<!--/\&lt;!--/g' \
      -e 's/(^|[^[:alnum:]])@([[:alnum:]][[:alnum:]-]*)/\1@-\2/g' <"${in}" >"${all}"
  elif _agent_sanitize_py <"${in}" >"${code}" && ! cmp -s "${code}" "${all}" \
    && renders_without_mentions "${code}"; then
    cp "${code}" "${all}"
  fi
  cat "${all}"
  rm -f "${in}" "${all}" "${code}"
}

# agent_cap <bytes>: stdin -> stdout, truncated to at most <bytes>, with a note when it was.
agent_cap() {
  local max="$1" tmp
  tmp="$(mktemp)"
  cat >"${tmp}"
  if [[ "$(wc -c <"${tmp}")" -gt "${max}" ]]; then
    head -c "${max}" "${tmp}"
    printf '\n\n_(truncated at %s bytes)_\n' "${max}"
  else
    cat "${tmp}"
  fi
  rm -f "${tmp}"
}

# --- protected paths ---------------------------------------------------------------------------------

# glob_to_ere <glob>: `**` crosses `/`, `*` and `?` do not. Anchored both ends.
glob_to_ere() {
  local g="$1" out="" i c
  for ((i = 0; i < ${#g}; i++)); do
    c="${g:i:1}"
    case "${c}" in
      '*')
        if [[ "${g:i+1:1}" == '*' ]]; then
          out+='.*'
          i=$((i + 1))
        else
          out+='[^/]*'
        fi
        ;;
      '?') out+='[^/]' ;;
      '.' | '+' | '(' | ')' | '[' | ']' | '{' | '}' | '^' | '$' | '|' | \\) out+="\\${c}" ;;
      *) out+="${c}" ;;
    esac
  done
  printf '^%s$' "${out}"
}

# The floor: paths no agent PR may ever touch, whatever the repo's protected-paths.txt says. It is
# the package's, not the repo's, so deleting a `!` line from that file cannot open what the agents'
# own trust rests on: .github/ (the scripts, hooks and setup actions that run with the App token),
# .claude/ and every instructions file Claude Code loads, and the fixer's .agents-main scratch path.
AGENT_NEVER_FLOOR=('.github/**' '.claude/**' '**/CLAUDE.md' 'CLAUDE.local.md' '**/CLAUDE.local.md'
  '**/.claude/**' '.mcp.json' '.agents-main' '.agents-main/**')
# And a protected floor: the root CLAUDE.md steers every agent run and the review, so it always needs
# a writer's agent:allow-protected (which also keeps the PR from auto-merging), whatever the file says.
AGENT_PROTECTED_FLOOR=('CLAUDE.md')

# protected_patterns: the floor, then every glob in the protected-paths file (a leading `!` dropped),
# comments and blanks removed. never_patterns: the floor and the file's `!` lines, which
# `agent:allow-protected` cannot unlock.
protected_patterns() {
  printf '%s\n' "${AGENT_NEVER_FLOOR[@]}" "${AGENT_PROTECTED_FLOOR[@]}"
  sed -e 's/[[:space:]]*$//' -e 's/^!//' "${AGENT_PROTECTED_FILE}" | grep -v -e '^#' -e '^$'
}
never_patterns() {
  printf '%s\n' "${AGENT_NEVER_FLOOR[@]}"
  sed -e 's/[[:space:]]*$//' "${AGENT_PROTECTED_FILE}" | grep '^!' | sed 's/^!//'
}

# _matches_any <path> <pattern-function>: exit 0 when <path> matches a glob the function prints.
_matches_any() {
  local p="$1" glob re
  while IFS= read -r glob; do
    re="$(glob_to_ere "${glob}")"
    [[ "${p}" =~ ${re} ]] && return 0
  done < <("$2")
  return 1
}

# is_protected <path> / is_never <path>
is_protected() { _matches_any "$1" protected_patterns; }
is_never() { _matches_any "$1" never_patterns; }

# never_hits: stdin is one path per line; prints those that no label can unlock.
never_hits() {
  local p
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    if is_never "${p}"; then printf '%s\n' "${p}"; fi
  done
}

# protected_hits: stdin is one path per line; prints the protected ones.
protected_hits() {
  local p
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    if is_protected "${p}"; then printf '%s\n' "${p}"; fi
  done
}

# --- who is trusted ----------------------------------------------------------------------------------

# The agent bot, as the different APIs spell it.
AGENT_BOT_SLUG="$(policy '.botLogin')"
AGENT_BOT_SLUG="${AGENT_BOT_SLUG%\[bot\]}"
is_agent_bot() { case "$1" in "${AGENT_BOT_SLUG}" | "${AGENT_BOT_SLUG}[bot]" | "app/${AGENT_BOT_SLUG}") return 0 ;; esac; return 1; }

# actor_trusted <login>: exit 0 for the agent bot or anyone with write access or more, 1 for anyone
# else, 2 when the lookup failed (not cached, so a later call asks again). Every caller that only
# needs a yes treats 2 as no; one that must not skip a writer by mistake (newest_review: a writer's
# newer verdict) checks for it. Write access, never author_association: COLLABORATOR and MEMBER
# include read-only and triage accounts.
declare -A AGENT_TRUST_CACHE=()
actor_trusted() {
  local who="$1" perm err
  [[ -n "${who}" ]] || return 1
  is_agent_bot "${who}" && return 0
  if [[ -z "${AGENT_TRUST_CACHE[${who}]:-}" ]]; then
    err="$(mktemp)"
    if ! perm="$(gh api "repos/${GH_REPO}/collaborators/${who}/permission" --jq '.permission' 2>"${err}")"; then
      # A 404 is an answer (no such user, or not a collaborator); anything else is not.
      if ! grep -q 'HTTP 404' "${err}"; then rm -f "${err}"; return 2; fi
      perm=none
    fi
    rm -f "${err}"
    case "${perm}" in admin | maintain | write) AGENT_TRUST_CACHE[${who}]=yes ;; *) AGENT_TRUST_CACHE[${who}]=no ;; esac
  fi
  [[ "${AGENT_TRUST_CACHE[${who}]}" == yes ]]
}

# pr_allow_protected <pr>: exit 0 when agent:allow-protected is on the PR and the agent bot put it
# there (the outbox does, at creation, only when a writer allowed it on the issue); 1 when not; 2
# when the labels or the timeline cannot be read, so a caller can tell a refusal from an outage.
pr_allow_protected() {
  local labels who
  labels="$(gh api "repos/${GH_REPO}/issues/$1/labels?per_page=100" --jq '.[].name')" || return 2
  grep -Fxq agent:allow-protected <<<"${labels}" || return 1
  who="$(gh api --paginate "repos/${GH_REPO}/issues/$1/timeline?per_page=100" \
    --jq '.[] | select(.event == "labeled" and .label.name == "agent:allow-protected") | .actor.login')" || return 2
  is_agent_bot "$(tail -1 <<<"${who}")"
}

# label_applier <issue-or-pr> <label>: who applied <label> most recently, from the timeline.
label_applier() {
  gh api --paginate "repos/${GH_REPO}/issues/$1/timeline?per_page=100" \
    --jq ".[] | select(.event == \"labeled\" and .label.name == \"$2\") | .actor.login" | tail -1
}

# merged_prs_referencing <issue>: the numbers of MERGED pull requests in this repository whose BODY
# says `Refs #N` or closes it (`Fixes`, `Closes`, `Resolves` in GitHub's forms, `#N`, `owner/repo#N`
# or the issue URL, alone or in a list: `Fixes #979, #980 and #981`), from its timeline's
# cross-referenced events, one per line, oldest first. A PR
# that only mentions the issue elsewhere (a review comment naming a follow-up)
# does not count, nor does one in another repository or an unmerged one. Exit 1 when the timeline
# cannot be read.
merged_prs_referencing() {
  local tl
  tl="$(gh api --paginate "repos/${GH_REPO}/issues/$1/timeline?per_page=100")" || return 1
  jq -rs --arg repo "${GH_REPO}" --arg n "$1" '
    ($repo | ascii_downcase) as $r
    | ($r | gsub("(?<c>[.\\\\^$|?*+()\\[\\]{}-])"; "\\\(.c)")) as $re
    | ("(" + $re + "#|https?://github\\.com/" + $re + "/issues/|#)") as $ref
    | ("(^|[^a-z0-9_])(refs?|references|close[sd]?|fix(e[sd])?|resolve[sd]?)\\s*:?\\s+("
        + $ref + "[0-9]+(\\s*,\\s*(and\\s+)?|\\s+and\\s+|\\s+))*" + $ref + $n + "([^0-9]|$)") as $pat
    | (add // []) | .[]
    | select(.event == "cross-referenced" and .source.type == "issue"
        and (.source.issue.pull_request.merged_at // null) != null
        and ((.source.issue.repository.full_name // "") | ascii_downcase) == $r
        and ((.source.issue.body // "") | ascii_downcase | test($pat)))
    | .source.issue.number' <<<"${tl}"
}

# --- labels ------------------------------------------------------------------------------------------

# name|color|description. The one list: the workflows create what is missing on first use, and
# .github/scripts/agent-labels.sh creates all of them up front.
AGENT_LABELS=(
  "agent:ready|0e8a16|Queued for the coder agent"
  "agent:in-progress|fbca04|Locked: a coder run is working on this"
  "agent:pr-open|1d76db|An open agent PR references this issue"
  "agent:done-pending-deploy|0e8a16|Its agent PR merged; close it once the fix is live"
  "agent:candidate|c5def5|Triage thinks an agent could take it; a person decides (add agent:ready)"
  "agent:blocked|b60205|The agent stopped; its last comment says why"
  "agent:needs-human|d93f0b|Waiting on an answer in the agent inbox"
  "agent:hold|000000|Agents never touch this"
  "agent:allow-protected|5319e7|A person allowed the agent to touch protected paths"
  "agent:pr|1d76db|Pull request opened by the coder agent"
  "agent:fixing|fbca04|Locked: the fixer agent is working on this PR"
  "size: S|c2e0c6|Small: one function or file"
  "size: M|bfd4f2|Medium: a few files in one area"
  "size: L|f9d0c4|Large: not for the agent"
)

# Repo-specific labels from policy.json `extraLabels` (same name|color|description shape), so a repo's
# own workflows can share ensure_labels and agent-labels.sh without editing this file.
while IFS= read -r _extra; do
  [[ -n "${_extra}" ]] && AGENT_LABELS+=("${_extra}")
done < <(policy '(.extraLabels // [])[]')
unset _extra

# ensure_labels: create any agent label the repo does not have yet. One list call, then one create
# per missing label, so a steady-state run costs a single API request.
ensure_labels() {
  local existing entry name color desc
  existing="$(gh label list --limit 300 --json name --jq '.[].name')" || return 1
  for entry in "${AGENT_LABELS[@]}"; do
    IFS='|' read -r name color desc <<<"${entry}"
    grep -Fxq -- "${name}" <<<"${existing}" && continue
    gh label create "${name}" --color "${color}" --description "${desc}" >/dev/null || return 1
  done
}

# --- the inbox issue ---------------------------------------------------------------------------------

# inbox_issue: the number of the open issue carrying the inbox marker; creates it when there is none
# (the owner pins it by hand: pinning is not part of the App's grant). Only an issue authored by
# the agent bot or by AGENT_OWNER_LOGIN counts, so anyone who can open an issue cannot paste the marker
# into one and receive every later request. AGENT_INBOX_ISSUE (the repo variable), when set, is
# trusted outright and skips the search. inbox_find is the same lookup without the create, for a
# caller that must not open an inbox (the digest posts with a token the lookup would not trust).
inbox_find() {
  local marker bot
  if [[ -n "${AGENT_INBOX_ISSUE:-}" ]]; then printf '%s\n' "${AGENT_INBOX_ISSUE}"; return 0; fi
  marker="$(policy '.inboxMarker')"
  bot="$(policy '.botLogin')"
  # gh prints an App author as `app/<slug>`; accept the REST spelling too.
  gh issue list --state open --limit 300 --json number,body,author --jq "
    [.[] | select((.body | contains(\"${marker}\"))
      and ((.author.login == \"app/${bot%\[bot\]}\") or (.author.login == \"${bot}\")
           or (.author.login == \"${AGENT_OWNER_LOGIN:-}\" and \"${AGENT_OWNER_LOGIN:-}\" != \"\")))]
    | sort_by(.number) | .[0].number // empty"
}

inbox_issue() {
  local marker num body
  num="$(inbox_find)" || return 1
  if [[ -n "${num}" ]]; then printf '%s\n' "${num}"; return 0; fi
  marker="$(policy '.inboxMarker')"
  body="$(mktemp)"
  cat >"${body}" <<EOF
${marker}
Requests from the autonomous agents land here as comments. Answer by commenting on this issue:

| Command | Effect |
|---|---|
| \`/approve REQ-…\` | do what the request proposes |
| \`/reject REQ-… [reason]\` | leave it as it is |
| \`/rerun coder #N\` | put issue #N back in the queue and start the coder on it |
| \`/pause coder\` · \`/resume coder\` | stop or restart the coder (also resets its circuit breaker) |

Only the owner's commands are applied. Runbook: \`.github/agents/README.md\`.

## Open requests
<!-- agent-inbox:open:start -->
<!-- agent-inbox:open:end -->
EOF
  gh issue create --title "Needs a human (agent inbox)" --body-file "${body}" | grep -oE '[0-9]+$'
  rm -f "${body}"
}

# inbox_add_line <issue> <line> / inbox_tick_line <issue> <REQ-id> <note>: keep the "Open requests"
# checklist in the inbox body current. Best effort by design: the request comments are the record and
# this list is the at-a-glance view, so a lost update between two writers costs a stale line, not a
# lost request. That is also why no concurrency group serialises the writers: a third queued job in
# a group CANCELS the pending second one, which would lose a ledger row or a label change instead.
inbox_add_line() {
  local issue="$1" line="$2" body
  body="$(mktemp)"
  gh issue view "${issue}" --json body --jq '.body' >"${body}" || { rm -f "${body}"; return 1; }
  # The line goes through the environment, not `awk -v`, which decodes backslash escapes and would
  # turn a sanitised `\074!--` back into a live `<!--`.
  if grep -q '<!-- agent-inbox:open:end -->' "${body}"; then
    L="${line}" awk '/<!-- agent-inbox:open:end -->/ { print ENVIRON["L"] } { print }' "${body}" >"${body}.new"
  else
    { cat "${body}"; printf '\n%s\n' "${line}"; } >"${body}.new"
  fi
  gh issue edit "${issue}" --body-file "${body}.new" >/dev/null
  rm -f "${body}" "${body}.new"
}

# inbox_request <kind> <role> <issue> <one-line summary> <body-file>: post one request on the inbox
# issue and list it as open. Prints the request id. The marker line is what agent-inbox.sh looks up
# when the owner answers, so its shape is a contract: `<!-- agent-req:ID role=R issue=N kind=K -->`.
# new_req_id: REQ-YYYYMMDD-xxxx, short enough to type in a reply.
new_req_id() {
  printf 'REQ-%s-%s\n' "$(jq -rn --argjson e "$(agent_now_epoch)" '$e | strftime("%Y%m%d")')" \
    "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
}

inbox_request() {
  local kind="$1" role="$2" issue="$3" summary="$4" bodyfile="$5" inbox req comment
  inbox="$(inbox_issue)" || return 1
  req="${AGENT_REQ_ID:-$(new_req_id)}"
  comment="$(mktemp)"
  {
    printf '<!-- agent-req:%s role=%s issue=%s kind=%s -->\n' "${req}" "${role}" "${issue}" "${kind}"
    printf '### %s · %s · #%s\n\n' "${req}" "${role}" "${issue}"
    cat "${bodyfile}"
  } >"${comment}"
  if ! gh issue comment "${inbox}" --body-file "${comment}" >/dev/null; then
    rm -f "${comment}"
    return 1
  fi
  rm -f "${comment}"
  inbox_add_line "${inbox}" "- [ ] ${req} · ${role} · #${issue} · ${summary}" \
    || agent_log "inbox checklist not updated; the request comment itself is posted"
  printf '%s\n' "${req}"
}

inbox_tick_line() {
  local issue="$1" req="$2" note="$3" body
  body="$(mktemp)"
  gh issue view "${issue}" --json body --jq '.body' >"${body}" || { rm -f "${body}"; return 1; }
  R="${req}" N="${note}" awk '
    index($0, "- [ ] " ENVIRON["R"] " ") == 1 { sub(/^- \[ \] /, "- [x] "); $0 = $0 " · " ENVIRON["N"] }
    { print }' "${body}" >"${body}.new"
  gh issue edit "${issue}" --body-file "${body}.new" >/dev/null
  rm -f "${body}" "${body}.new"
}

# --- infrastructure failures: runs that never reached the model ---------------------------------------
#
# A run whose code job failed BEFORE the model step (a 504 on a toolchain download, an apt mirror
# outage) did no agent work, so it should cost the issue no attempt, the day no run and the breaker
# no step. These helpers decide that from the run's
# jobs API (finalize, in the publish job: main's scripts, the App token, a fresh container).
#
# TRUST: once the model runs it controls its job, including the Actions runtime token, so in
# principle it could rewrite how its own steps are reported. That would let it pass a real failure
# off as an infrastructure one. So the jobs-API evidence is only accepted
# roles.<role>.infraGracePerDay times per role per UTC day (infra_grace_left); past that the run is
# counted as before, which is what makes a lasting outage still trip the breaker.

# The steps that run before the model and none of the agent's code, as anchored EREs over GitHub's
# step names (a `name:` if the step has one, else "Run <uses>", which carries the action's SHA). An
# action's ref is matched as ref characters only, never `.+`: the name ends up in a bot comment, and
# a forged one must not be able to carry markup (a marker) into it.
# NEVER here: `drop sudo` (a security failure must step the breaker), `prepare the work branch`,
# and for the fixer `project dependencies`, which runs the PR head's code (install scripts).
# Gatehand's tests/workflows/agents-workflows.test.sh keeps these equal to the workflows' own steps.
# shellcheck disable=SC2034 # read by agent-state.sh and agent-fixup.sh, which source this file
CODER_PRE_AGENT_STEPS=(
  'Set up job' 'Run actions/checkout@[A-Za-z0-9._-]+' 'agent directory' 'project system packages' 'project toolchain'
  'project dependencies' 'Run actions/download-artifact@[A-Za-z0-9._-]+'
)
# shellcheck disable=SC2034
FIXER_PRE_AGENT_STEPS=(
  'Set up job' "main's system setup" 'project system packages' 'Run actions/checkout@[A-Za-z0-9._-]+' 'agent directory'
  "main's agent setup" "exclude main's agent setup from git" 'project toolchain'
)

# pre_agent_failure <jobs-json> <job-name> <agent-step> <allowed-ere>...: pure. Prints the name of
# the step that failed and exits 0 when ALL of these hold for the one job called <job-name>: its
# <agent-step> exists and was skipped, exactly one of its steps concluded `failure`, every step
# before that one succeeded, and the failed step's name matches one of the EREs. Anything else,
# including JSON it cannot read, exits 1: the run is then counted as before.
pre_agent_failure() {
  local jobs="$1" job="$2" agent="$3" allow
  shift 3
  allow="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  jq -re --arg job "${job}" --arg agent "${agent}" --argjson allow "${allow}" '
    [.jobs[]? | select(.name == $job)] as $j
    | if ($j | length) != 1 then empty else ($j[0].steps // [] | sort_by(.number)) end
    | . as $steps
    | [$steps[] | select(.name == $agent)] as $a
    | [$steps | to_entries[] | select(.value.conclusion == "failure")] as $failed
    | if ($a | length) == 1 and $a[0].conclusion == "skipped" and ($failed | length) == 1 then
        $failed[0].key as $i
        | $failed[0].value.name as $name
        | if ([$steps[0:$i][] | .conclusion == "success"] | all)
             and ([$allow[] | . as $re | $name | test("^(" + $re + ")$")] | any)
          then $name else empty end
      else empty end' <<<"${jobs}" 2>/dev/null
}

# infra_grace_left <role> <runs-jsonl> <day>: pure. Exit 0 when today's ledger rows for <role> hold
# fewer `counted: false` rows than roles.<role>.infraGracePerDay (0 when unset).
infra_grace_left() {
  local role="$1" runs="$2" day="$3" grace used
  grace="$(policy ".roles[\"${role}\"].infraGracePerDay // 0")"
  used="$(printf '%s\n' "${runs}" | jq -s --arg d "${day}" --arg r "${role}" \
    '[.[] | select(type == "object" and .role == $r and .counted == false and ((.started_at // "") | startswith($d)))] | length')" || return 1
  [[ "${grace}" =~ ^[0-9]+$ && "${used}" =~ ^[0-9]+$ && "${used}" -lt "${grace}" ]]
}

# infra_failure <role> <job-name> <agent-step> <allowed-ere>...: prints "<evidence>|<step>" and exits
# 0 when this run (RUN_ID) failed before its model step and may go uncounted. Exits 2, printing
# "grace-used|<step>", when it did but the role's grace for today is spent; 1 otherwise.
#   preflight   PREFLIGHT_RESULT is failure, CODE_RESULT is skipped and the task snapshot did not fail
#               (SNAPSHOT_RESULT; a failed snapshot is an untrusted-change refusal, never a free run):
#               only main's code ran, so no budget applies (the coder only; the fixer's preflight
#               failures keep their own path)
#   step        CODE_RESULT is failure and the jobs API shows a pre-model failure (pre_agent_failure),
#               within the role's daily grace
# Fails closed: an unreadable jobs API or ledger means the run counts.
infra_failure() {
  local role="$1" job="$2" agent="$3" jobs month day runs step
  shift 3
  if [[ "${PREFLIGHT_RESULT:-}" == failure && "${CODE_RESULT:-}" == skipped && "${SNAPSHOT_RESULT:-}" != failure ]]; then
    echo "preflight|preflight"
    return 0
  fi
  [[ "${CODE_RESULT:-}" == failure && -n "${RUN_ID:-}" && "${RUN_ID}" != local ]] || return 1
  jobs="$(gh api "repos/${GH_REPO}/actions/runs/${RUN_ID}/jobs?per_page=100")" || { agent_log "infra: the run's jobs are unreadable; counted"; return 1; }
  step="$(pre_agent_failure "${jobs}" "${job}" "${agent}" "$@")" || return 1
  step="$(printf '%s' "${step}" | agent_oneline 120)"
  month="$(jq -rn --argjson e "$(agent_now_epoch)" '$e | strftime("%Y-%m")')"
  day="$(jq -rn --argjson e "$(agent_now_epoch)" '$e | strftime("%Y-%m-%d")')"
  # ledger_file comes from agent-state.sh, which both callers source.
  runs="$(ledger_file "runs/${month}.jsonl")" || { agent_log "infra: the ledger is unreadable; counted"; return 1; }
  if ! infra_grace_left "${role}" "${runs}" "${day}"; then
    agent_log "infra: '${step}' failed before the agent started, but today's grace for ${role} is used; counted"
    echo "grace-used|${step}"
    return 2
  fi
  echo "step|${step}"
}

# --- repo-local extensions ----------------------------------------------------------------------------
#
# .github/agents/hooks/lib.sh, when present, is sourced last. It is the adopter's file, never the
# package's: it may add functions the scripts call when defined (agent_hook_pr_guard <labels>
# <paths-file>, agent_hook_inbox_<kind>, agent_hook_digest_sections, agent_hook_digest_done_pending,
# agent_hook_labeler_trusted) or extend AGENT_LABELS. It lives
# under .github/, which AGENT_NEVER_FLOOR keeps out of every agent PR, and every script that sources
# this file runs from the default branch's checkout.
AGENT_HOOKS_DIR="${AGENT_HOOKS_DIR:-${AGENT_ROOT}/.github/agents/hooks}"
if [[ -f "${AGENT_HOOKS_DIR}/lib.sh" ]]; then
  # shellcheck source=/dev/null
  source "${AGENT_HOOKS_DIR}/lib.sh"
fi
