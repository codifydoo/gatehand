#!/usr/bin/env bash
# tests/render/render.test.sh: bin/render.sh itself. It writes into repositories it does not own, so
# what is pinned is what keeps it from damaging one:
#   1. The repo's own files are created once and never overwritten; package files are rewritten.
#   2. Every value that lands in YAML or shell is validated, and a bad one renders nothing.
#   3. A package file edited in the repo is not overwritten without --force; --check sees drift.
#   4. Optional workflows come and go with policy.json, and keys missing from an older policy.json
#      render with the package defaults.
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="${PKG}/bin/render.sh"
pass=0 fail=0
t_pass() { printf '\033[1;32m[render] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[render] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }
check() { local label="$1"; shift; if "$@"; then t_pass "${label}"; else t_fail "${label}"; fi; }
refuses() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then t_fail "${label}: it rendered"; else t_pass "${label}"; fi; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fresh() { rm -rf "${TMP}/r" && mkdir -p "${TMP}/r" && git -C "${TMP}/r" init -q -b main; }
pol() { jq "$1" "${TMP}/r/.github/agents/policy.json" >"${TMP}/p" && mv "${TMP}/p" "${TMP}/r/.github/agents/policy.json"; }
WF="${TMP}/r/.github/workflows"

# --- 1 -----------------------------------------------------------------------------------------------
fresh
check "a first render succeeds" "${R}" "${TMP}/r"
check "it writes the repo's files" test -f "${TMP}/r/.github/agents/project.md"
check "and the package's" test -f "${WF}/agent-coder.yml"
check "and the lock" test -f "${TMP}/r/.github/agents/install.lock.json"
check "nothing is left unrendered" bash -c "! grep -rqE '@@[A-Z_]+@@' '${TMP}/r/.github' '${TMP}/r/.claude'"
check "a file with no placeholders renders byte for byte" cmp -s "${PKG}/template/.github/scripts/agent-lib.sh" "${TMP}/r/.github/scripts/agent-lib.sh"
check "the scripts stay executable" test -x "${TMP}/r/.github/scripts/agent-lib.sh" -o ! -x "${PKG}/template/.github/scripts/agent-lib.sh"
echo "my rules" >"${TMP}/r/.github/agents/project.md"
"${R}" "${TMP}/r" >/dev/null
check "a second render keeps the repo's own project.md" grep -qx 'my rules' "${TMP}/r/.github/agents/project.md"
check "--check passes right after a render" "${R}" --check "${TMP}/r"
check "a non-repo is refused" bash -c "! '${R}' '${TMP}' 2>/dev/null"
# The one exception: hooks/lib.sh.example is the package's reference, so an update refreshes it.
EX="${TMP}/r/.github/agents/hooks/lib.sh.example"
echo "# an older package's example" >"${EX}"
"${R}" "${TMP}/r" >/dev/null
check "a render refreshes a stale hooks/lib.sh.example" cmp -s "${PKG}/defaults/hooks/lib.sh.example" "${EX}"
echo "# mine" >"${TMP}/r/.github/agents/hooks/lib.sh"
"${R}" "${TMP}/r" >/dev/null
check "...and leaves the repo's own hooks/lib.sh alone" grep -qx '# mine' "${TMP}/r/.github/agents/hooks/lib.sh"
rm -f "${EX}"
"${R}" "${TMP}/r" >/dev/null
check "...and does not bring the example back once hooks/lib.sh exists" test ! -e "${EX}"

# --- 2 -----------------------------------------------------------------------------------------------
for bad in '.botLogin = "Evil Bot[bot]"' '.botLogin = "nobot"' '.roles.coder.model = "opus; rm -rf /"' \
  '.roles.coder.maxTurns = "5\n- run: x"' '.schedules.coder = "* * *"' '.runners.agent = "ubuntu latest"' \
  '.runners.agent = ["self-hosted", "a b"]' '.tools.allow = ["Bash(npm test:*)\", \"x"]' '.tools.allow = ["Bash(a,b)"]' \
  '.tools.allow = ["WebFetch"]' '.claude.auth = "token"' '.ci.workflowName = "CI\"]\n  evil: ["' \
  '.ci.workflowFile = "../x.yml"' '.baseBranch = "main;x"' '.baseBranch = null' \
  '.tools.allow = ["Bash(echo ${{ secrets.AGENT_APP_PRIVATE_KEY }})"]' '.tools.allow = ["Bash(make test #x)"]' \
  '.tools.allow = ["Bash(npm run: x)"]' '.tools.deny = ["Bash(@@BOT_SLUG@@)"]' \
  '.reviewMarker = "<!-- my-review -->"' 'del(.reviewMarker)' '.requiredChecks = "CI"' '.requiredChecks = [1]'; do
  fresh
  "${R}" "${TMP}/r" >/dev/null
  cp "${WF}/agent-coder.yml" "${TMP}/before"
  pol "${bad}"
  refuses "refused: ${bad}" "${R}" "${TMP}/r"
  check "  and nothing changed" cmp -s "${TMP}/before" "${WF}/agent-coder.yml"
done
fresh
"${R}" "${TMP}/r" >/dev/null
pol '.runners.agent = ["self-hosted", "repo-agent"] | .tools.allow = ["Bash(npm test:*)"] | .claude.auth = "api-key" | .ci.workflowName = "Build and test"'
"${R}" "${TMP}/r" >/dev/null
check "a runner array renders as a flow sequence" grep -qx '    runs-on: \["self-hosted", "repo-agent"\]' "${WF}/agent-coder.yml"
check "tools.allow reaches the workflow" grep -q 'Bash(npm test:\*)' "${WF}/agent-coder.yml"
check "and the command's frontmatter" grep -q '^allowed-tools: .*Bash(npm test:\*)' "${TMP}/r/.claude/commands/agent-implement.md"
check "api-key auth" grep -q 'anthropic_api_key: \${{ secrets.ANTHROPIC_API_KEY }}' "${WF}/agent-coder.yml"
check "no oauth token left" bash -c "! grep -rq CLAUDE_CODE_OAUTH_TOKEN '${WF}'"
check "the CI workflow name is quoted in the triggers" grep -qx '    workflows: \["Build and test", Claude Code Review\]' "${WF}/agent-fixup.yml"

# --- 3 -----------------------------------------------------------------------------------------------
fresh
"${R}" "${TMP}/r" >/dev/null
echo "# local edit" >>"${WF}/agent-merge.yml"
check "--check sees a hand edit" bash -c "! '${R}' --check '${TMP}/r' >/dev/null"
refuses "an edited package file is not overwritten" "${R}" "${TMP}/r"
check "  and it is still the edited one" grep -q '^# local edit$' "${WF}/agent-merge.yml"
check "--force overwrites it" "${R}" --force "${TMP}/r"
check "  with the package's copy" bash -c "! grep -q '^# local edit$' '${WF}/agent-merge.yml'"
fresh
mkdir -p "${WF}" && echo "old" >"${WF}/agent-coder.yml"
refuses "a first install over a different file of the same name is refused" "${R}" "${TMP}/r"

# A crafted lock key, or a symlink committed to the repo, must not move a write or a delete outside.
fresh
"${R}" "${TMP}/r" >/dev/null
mkdir -p "${TMP}/outside" && echo keep >"${TMP}/outside/victim.txt"
h="$(shasum -a 256 "${TMP}/outside/victim.txt" 2>/dev/null | cut -d' ' -f1 || sha256sum "${TMP}/outside/victim.txt" | cut -d' ' -f1)"
for key in '../outside/victim.txt' '.github/../../outside/victim.txt' "${TMP}/outside/victim.txt"; do
  jq --arg k "${key}" --arg h "${h}" '.files[$k] = $h' "${TMP}/r/.github/agents/install.lock.json" >"${TMP}/l"
  cp "${TMP}/l" "${TMP}/r/.github/agents/install.lock.json"
  refuses "a lock key outside the package's directories is refused: ${key}" "${R}" --force "${TMP}/r"
  check "  and the file outside is still there" test -f "${TMP}/outside/victim.txt"
  jq --arg k "${key}" 'del(.files[$k])' "${TMP}/r/.github/agents/install.lock.json" >"${TMP}/l"
  cp "${TMP}/l" "${TMP}/r/.github/agents/install.lock.json"
done
fresh
mkdir -p "${TMP}/r/.github" "${TMP}/elsewhere"
ln -s "${TMP}/elsewhere" "${TMP}/r/.github/scripts"
refuses "a symlinked package directory is refused" "${R}" "${TMP}/r"
check "  and nothing was written through it" test -z "$(ls -A "${TMP}/elsewhere")"
rm -f "${TMP}/r/.github/scripts"
fresh
mkdir -p "${TMP}/r/.github" "${TMP}/elsewhere2"
ln -s "${TMP}/elsewhere2" "${TMP}/r/.github/workflows"
refuses "a symlink is found before ANY file is written" "${R}" "${TMP}/r"
check "  so not even the files that sort first were written" test ! -e "${TMP}/r/.github/ISSUE_TEMPLATE/agent-task.yml"
fresh
"${R}" "${TMP}/r" >/dev/null
echo keep >"${TMP}/outside/victim2.txt"
ln -s "${TMP}/outside/victim2.txt" "${TMP}/r/.github/agents/install.lock.json.new"
"${R}" "${TMP}/r" >/dev/null 2>&1
check "a symlink where a temporary lock file would go is never written through" grep -qx keep "${TMP}/outside/victim2.txt"
rm -f "${TMP}/r/.github/agents/install.lock.json.new" "${TMP}/r/.github/agents/install.lock.json"
ln -s "${TMP}/outside/victim2.txt" "${TMP}/r/.github/agents/install.lock.json"
refuses "a symlinked lock is refused" "${R}" "${TMP}/r"
check "  and not written through" grep -qx keep "${TMP}/outside/victim2.txt"

# --- 4 -----------------------------------------------------------------------------------------------
fresh
"${R}" "${TMP}/r" >/dev/null
check "triage is off by default" test ! -e "${WF}/agent-triage.yml"
pol '.workflows.triage = true'
"${R}" "${TMP}/r" >/dev/null
check "turning it on renders it" test -f "${WF}/agent-triage.yml"
pol '.workflows.triage = false'
"${R}" "${TMP}/r" >/dev/null
check "turning it off removes it" test ! -e "${WF}/agent-triage.yml"
fresh
"${R}" "${TMP}/r" >/dev/null
pol 'del(.schedules) | del(.review)'
check "an older policy.json without newer keys still renders" "${R}" "${TMP}/r"
check "  with the default schedule" grep -qF "    - cron: \"$(jq -r .schedules.coder "${PKG}/defaults/policy.json")\"" "${WF}/agent-coder.yml"

printf '\n[render] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
