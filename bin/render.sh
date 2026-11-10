#!/usr/bin/env bash
# bin/render.sh: install or update the agents in a repository.
#
#   render.sh [--force] <repo>   write the package's files into <repo>
#   render.sh --check <repo>     exit 1 when <repo>'s package files differ from what would be written
#
# Two kinds of files:
#   - YOURS, under <repo>/.github/agents/ (policy.json, protected-paths.txt, project.md, toolchain/,
#     dependencies/, hooks/): copied from defaults/ only when missing, never overwritten. The one
#     exception is hooks/lib.sh.example, the package's reference for the hooks, which is refreshed.
#   - THE PACKAGE'S (workflows, scripts, commands, install-gh, the issue template, the README): rendered
#     from template/ with values from YOUR policy.json, and recorded with their hashes in
#     .github/agents/install.lock.json. A package file whose hash no longer matches the lock was edited
#     by hand; it is not overwritten without --force (put repo-specific behaviour in hooks/ instead).
#
# Needs bash 4+, jq, and sha256sum or shasum. Writes nothing outside <repo>. Commits nothing.
# shellcheck disable=SC2034 # placeholder values are read back by name: "${!k}"
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(jq -r .version "${PKG}/.claude-plugin/plugin.json")"
LOCK_REL=.github/agents/install.lock.json

# The agents' fixed tool lists. tools.allow / tools.deny in policy.json ADD to these; nothing removes
# from them. Deny beats allow in Claude Code, so a project command must not match a deny entry.
BASE_ALLOW=(Read Grep Glob Edit Write TodoWrite
  'Bash(git status:*)' 'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git show:*)' 'Bash(git add:*)'
  'Bash(git commit:*)' 'Bash(git rm:*)' 'Bash(git mv:*)' 'Bash(git restore:*)')
BASE_DENY=('Bash(git push:*)' 'Bash(git remote:*)' 'Bash(git config:*)' 'Bash(git fetch:*)'
  'Bash(git pull:*)' 'Bash(git checkout:*)' 'Bash(git switch:*)' 'Bash(git reset:*)'
  'Bash(git rebase:*)' 'Bash(git merge:*)' 'Bash(git tag:*)'
  'Bash(gh pr create:*)' 'Bash(gh pr merge:*)' 'Bash(gh pr edit:*)' 'Bash(gh pr comment:*)'
  'Bash(gh pr review:*)' 'Bash(gh pr close:*)' 'Bash(gh issue create:*)' 'Bash(gh issue edit:*)'
  'Bash(gh issue comment:*)' 'Bash(gh issue close:*)' 'Bash(gh api:*)' 'Bash(gh workflow:*)'
  'Bash(gh run:*)' 'Bash(gh secret:*)' 'Bash(gh variable:*)' 'Bash(gh auth:*)' 'Bash(gh label:*)'
  'Bash(gh release:*)' 'Bash(gh:*)' 'Bash(curl:*)' 'Bash(wget:*)' 'Bash(ssh:*)' 'Bash(scp:*)'
  'Bash(docker:*)' 'Bash(sudo:*)' WebFetch WebSearch)

die() { printf 'render: %s\n' "$*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

mode=write force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode=check; shift ;;
    --force) force=1; shift ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
[[ $# -eq 1 ]] || die "usage: render.sh [--check|--force] <repo>"
REPO="$(cd "$1" && pwd)" || die "no such directory: $1"
[[ -d "${REPO}/.git" || -f "${REPO}/.git" ]] || die "${REPO} is not a git repository"

# guard_path <rel>: die unless <rel> is a path the package may touch (under .github/ or .claude/, no
# `.` or `..` segment) with no symlink anywhere on the way, so neither a crafted install.lock.json key
# nor a symlinked directory committed to the repo can make a write or a delete land outside it.
guard_path() {
  local rel="$1" cur="${REPO}" part parts
  [[ "${rel}" =~ ^\.(github|claude)/[A-Za-z0-9._/-]+$ && "/${rel}/" != *"/../"* && "/${rel}/" != *"/./"* && "${rel}" != *//* ]] \
    || die "refusing the path '${rel}': the package only touches files under .github/ and .claude/"
  IFS=/ read -ra parts <<<"${rel}"
  for part in "${parts[@]}"; do
    cur+="/${part}"
    [[ -L "${cur}" ]] && die "refusing to go through the symlink ${cur#"${REPO}/"}"
  done
  return 0
}

# --- the adopter's files: create when missing ----------------------------------------------------------
if [[ "${mode}" == write ]]; then
  while IFS= read -r rel; do
    dst="${REPO}/.github/agents/${rel}"
    guard_path ".github/agents/${rel}"
    if [[ "${rel}" == hooks/lib.sh.example ]]; then
      # The package's reference for the hooks, never sourced: refreshed wherever it is, so an update
      # documents new hooks, but not created once the repo has its own hooks/lib.sh.
      if [[ -f "${dst}" ]]; then
        if ! cmp -s "${PKG}/defaults/${rel}" "${dst}"; then
          cp "${PKG}/defaults/${rel}" "${dst}"
          printf 'updated %s (the package'"'"'s reference for the hooks)\n' ".github/agents/${rel}"
        fi
      elif [[ ! -e "${dst}" && ! -e "${REPO}/.github/agents/hooks/lib.sh" ]]; then
        mkdir -p "$(dirname "${dst}")"
        cp "${PKG}/defaults/${rel}" "${dst}"
        printf 'created %s (the package'"'"'s reference for the hooks, refreshed on update)\n' ".github/agents/${rel}"
      fi
      continue
    fi
    if [[ ! -e "${dst}" ]]; then
      mkdir -p "$(dirname "${dst}")"
      cp "${PKG}/defaults/${rel}" "${dst}"
      printf 'created %s (yours to edit)\n' ".github/agents/${rel}"
    fi
  done < <(cd "${PKG}/defaults" && find . -type f | sed 's#^\./##' | sort)
fi
POLICY="${REPO}/.github/agents/policy.json"
[[ -f "${POLICY}" ]] || die "no ${POLICY}; run without --check first"
jq -e 'type == "object"' "${POLICY}" >/dev/null 2>&1 || die "${POLICY} is not a JSON object"
# Values come from the repo's policy over the package defaults (objects merged key by key, arrays and
# scalars replaced), so a key a newer version added renders with its default until the repo sets it.
EFFECTIVE="$(jq -s '.[0] * .[1]' "${PKG}/defaults/policy.json" "${POLICY}")"
p() { jq -r "$1" <<<"${EFFECTIVE}"; }

# --- values, validated: they land in YAML and in shell ----------------------------------------------
want() { # want <name> <value> <ERE>
  [[ "$2" != null && "$2" =~ $3 ]] || die "policy.json: $1 is '$2', which does not match $3"
  printf '%s' "$2"
}
runner() { # a label string, or an array of labels rendered as a YAML flow sequence
  local v
  v="$(jq -c ".runners.$1 // \"ubuntu-latest\"" <<<"${EFFECTIVE}")"
  if jq -e 'type == "array"' <<<"${v}" >/dev/null; then
    jq -e 'all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"))' <<<"${v}" >/dev/null \
      || die "policy.json: runners.$1 has a label with characters other than letters, digits, . _ -"
    jq -r 'map(tojson) | "[" + join(", ") + "]"' <<<"${v}"
  else
    want "runners.$1" "$(jq -r . <<<"${v}")" '^[A-Za-z0-9._-]+$'
  fi
}
tools_of() { # tools_of <allow|deny>: the policy additions, one per line, validated
  local t
  while IFS= read -r t; do
    [[ -z "${t}" ]] && continue
    # A strict set inside the parentheses: the entry lands in claude_args (where `${{` would be
    # evaluated by Actions) and in YAML frontmatter (where `#` or `: ` would end or split it).
    [[ "${t}" =~ ^[A-Za-z][A-Za-z0-9_]*(\([A-Za-z0-9\ _.:*/=+~-]+\))?$ && "${t}" != *": "* ]] \
      || die "policy.json: tools.$1 entry '${t}' must look like Tool or Tool(pattern), the pattern made of letters, digits, spaces and _ . : * / = + ~ - (no ': ')"
    printf '%s\n' "${t}"
  done < <(p "(.tools.$1 // [])[]")
}
join_by() { local sep="$1" out="" x; shift; for x in "$@"; do out+="${out:+${sep}}${x}"; done; printf '%s' "${out}"; }

# Every value is computed by a PLAIN assignment, never inside an array literal or a process
# substitution: `set -e` stops the script only when an assignment's own command substitution fails,
# so `die` in a validator would otherwise exit a subshell and leave an empty value behind.
# The values are read back by name (${!k}) below, which shellcheck cannot follow (SC2034 is off).
BOT_LOGIN="$(p .botLogin)"
BOT_SLUG="$(want botLogin "${BOT_LOGIN%\[bot\]}" '^[a-z0-9][a-z0-9-]*$')"
[[ "${BOT_LOGIN}" == "${BOT_SLUG}[bot]" ]] || die "policy.json: botLogin must be '<app-slug>[bot]'"
EXTRA_ALLOW="$(tools_of allow)"
EXTRA_DENY="$(tools_of deny)"
mapfile -t ALLOW < <(printf '%s\n' "${BASE_ALLOW[@]}"; [[ -z "${EXTRA_ALLOW}" ]] || printf '%s\n' "${EXTRA_ALLOW}")
mapfile -t DENY < <(printf '%s\n' "${BASE_DENY[@]}"; [[ -z "${EXTRA_DENY}" ]] || printf '%s\n' "${EXTRA_DENY}")
for a in "${ALLOW[@]}"; do
  for d in "${DENY[@]}"; do
    [[ "${a}" == "${d}" ]] && die "policy.json: '${a}' is both allowed and denied"
  done
done
# Literal GitHub expressions, written into the workflows as they are.
# shellcheck disable=SC2016
case "$(p '.claude.auth // "oauth"')" in
  oauth) CLAUDE_AUTH='claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}' ;;
  api-key) CLAUDE_AUTH='anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}' ;;
  *) die "policy.json: claude.auth must be oauth or api-key" ;;
esac
# The review workflow and /verify-pr emit this exact marker; the scripts look for policy.json's.
# The RAW file, not the merged view: the scripts read policy.json itself at run time.
[[ "$(jq -r .reviewMarker "${POLICY}")" == '<!-- verify-pr-review -->' ]] || die "policy.json: reviewMarker must be '<!-- verify-pr-review -->'"
jq -e '(.requiredChecks // []) | type == "array" and all(.[]; type == "string" and length > 0)' "${POLICY}" >/dev/null \
  || die "policy.json: requiredChecks must be a list of check names"
MODEL_RE='^[a-z0-9][a-z0-9.-]*$' NUM_RE='^[1-9][0-9]*$' CRON_RE='^[0-9*/,-]+( [0-9*/,-]+){4}$'
CI_NAME="$(want ci.workflowName "$(p '.ci.workflowName // "CI"')" '^[A-Za-z0-9 ._()-]+$')"
CI_FILE="$(want ci.workflowFile "$(p '.ci.workflowFile // "ci.yml"')" '^[A-Za-z0-9._-]+\.ya?ml$')"
RUNS_ON_AGENT="$(runner agent)"
RUNS_ON_CI="$(runner ci)"
RUNS_ON_REVIEW="$(runner review)"
REVIEW_BOT_LOGIN="$(want reviewBotLogin "$(p .reviewBotLogin)" '^[A-Za-z0-9-]+(\[bot\])?$')"
BASE_BRANCH="$(want baseBranch "$(p .baseBranch)" '^[A-Za-z0-9._/-]+$')"
CODER_MODEL="$(want roles.coder.model "$(p .roles.coder.model)" "${MODEL_RE}")"
CODER_MAX_TURNS="$(want roles.coder.maxTurns "$(p .roles.coder.maxTurns)" "${NUM_RE}")"
CODER_TIMEOUT="$(want roles.coder.timeoutMinutes "$(p .roles.coder.timeoutMinutes)" "${NUM_RE}")"
FIXER_MODEL="$(want roles.fixer.model "$(p .roles.fixer.model)" "${MODEL_RE}")"
FIXER_MAX_TURNS="$(want roles.fixer.maxTurns "$(p .roles.fixer.maxTurns)" "${NUM_RE}")"
FIXER_TIMEOUT="$(want roles.fixer.timeoutMinutes "$(p .roles.fixer.timeoutMinutes)" "${NUM_RE}")"
REVIEW_MODEL="$(want review.model "$(p .review.model)" "${MODEL_RE}")"
CRON_CODER="$(want schedules.coder "$(p .schedules.coder)" "${CRON_RE}")"
CRON_SWEEP="$(want schedules.sweep "$(p .schedules.sweep)" "${CRON_RE}")"
CRON_MERGE="$(want schedules.merge "$(p .schedules.merge)" "${CRON_RE}")"
CRON_TRIAGE="$(want schedules.triage "$(p .schedules.triage)" "${CRON_RE}")"
CRON_DIGEST="$(want schedules.digest "$(p .schedules.digest)" "${CRON_RE}")"
CI_WORKFLOW_NAME="$(jq -rn --arg n "${CI_NAME}" '$n | tojson')"
AGENT_ALLOWED_TOOLS="$(join_by , "${ALLOW[@]}")"
AGENT_ALLOWED_TOOLS_FM="$(join_by ', ' "${ALLOW[@]}")"
AGENT_DISALLOWED_TOOLS="$(join_by , "${DENY[@]}")"
: "${CI_FILE}" # validated only: the scripts read ci.workflowFile from policy.json themselves

PLACEHOLDERS=(RUNS_ON_AGENT RUNS_ON_CI RUNS_ON_REVIEW BOT_SLUG REVIEW_BOT_LOGIN BASE_BRANCH CLAUDE_AUTH
  CI_WORKFLOW_NAME CODER_MODEL CODER_MAX_TURNS CODER_TIMEOUT FIXER_MODEL FIXER_MAX_TURNS FIXER_TIMEOUT
  REVIEW_MODEL CRON_CODER CRON_SWEEP CRON_MERGE CRON_TRIAGE CRON_DIGEST AGENT_ALLOWED_TOOLS
  AGENT_ALLOWED_TOOLS_FM AGENT_DISALLOWED_TOOLS)
declare -A V=()
for k in "${PLACEHOLDERS[@]}"; do
  [[ -n "${!k}" ]] || die "internal: no value for ${k}"
  V[${k}]="${!k}"
done
MAP="$(for k in "${!V[@]}"; do jq -n --arg k "$k" --arg v "${V[$k]}" '{($k): $v}'; done | jq -s add)"

# --- the package's files: render into a staging tree -----------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
triage="$(p '.workflows.triage // false')"
while IFS= read -r rel; do
  [[ "${rel}" == .github/workflows/agent-triage.yml && "${triage}" != true ]] && continue
  mkdir -p "$(dirname "${STAGE}/${rel}")"
  jq -Rjs --argjson m "${MAP}" \
    'reduce ($m | to_entries[]) as $e (.; gsub("@@" + $e.key + "@@"; $e.value; "g"))' \
    <"${PKG}/template/${rel}" >"${STAGE}/${rel}"
  if left="$(grep -oE '@@[A-Z_]+@@' "${STAGE}/${rel}" | sort -u | tr '\n' ' ')" && [[ -n "${left}" ]]; then
    die "${rel}: no value for ${left}"
  fi
  [[ -x "${PKG}/template/${rel}" ]] && chmod +x "${STAGE}/${rel}"
done < <(cd "${PKG}/template" && find . -type f | sed 's#^\./##' | sort)
mkdir -p "${STAGE}/.github/agents"
cp "${PKG}/docs/README.md" "${STAGE}/.github/agents/README.md"

files_json() { # the staged files and their hashes
  (cd "${STAGE}" && find . -type f | sed 's#^\./##' | sort) | while IFS= read -r rel; do
    jq -n --arg f "${rel}" --arg h "$(sha "${STAGE}/${rel}")" '{($f): $h}'
  done | jq -s 'add // {}'
}
NEW="$(files_json)"
OLD='{}'
[[ -f "${REPO}/${LOCK_REL}" ]] && OLD="$(jq '.files // {}' "${REPO}/${LOCK_REL}")"
# The lock is a file in the repo, so anyone who can change the repo can change it: every key is
# checked before it is read, compared, or deleted.
while IFS= read -r rel; do guard_path "${rel}"; done < <(jq -r 'keys[]' <<<"${OLD}")
# And every destination, before the first read or write, so a symlinked directory stops the run
# before any file is touched (and --check never reads through one either).
while IFS= read -r rel; do guard_path "${rel}"; done < <(jq -r 'keys[]' <<<"${NEW}")
guard_path "${LOCK_REL}"

if [[ "${mode}" == check ]]; then
  rc=0
  while IFS= read -r rel; do
    if [[ ! -f "${REPO}/${rel}" ]]; then echo "missing: ${rel}"; rc=1
    elif ! cmp -s "${STAGE}/${rel}" "${REPO}/${rel}"; then echo "differs: ${rel}"; rc=1; fi
  done < <(jq -r 'keys[]' <<<"${NEW}")
  while IFS= read -r rel; do
    [[ -f "${REPO}/${rel}" ]] && { echo "no longer part of the package: ${rel}"; rc=1; }
  done < <(jq -r --argjson n "${NEW}" 'keys[] | select($n[.] == null)' <<<"${OLD}")
  [[ "${rc}" == 0 ]] && echo "up to date with repo-agents ${VERSION}"
  exit "${rc}"
fi

# A file the lock knows whose content no longer matches the lock was edited in the repo.
edited=()
while IFS= read -r rel; do
  [[ -f "${REPO}/${rel}" ]] || continue
  [[ "$(sha "${REPO}/${rel}")" == "$(jq -r --arg f "${rel}" '.[$f]' <<<"${OLD}")" ]] || edited+=("${rel}")
done < <(jq -r 'keys[]' <<<"${OLD}")
# A file the lock does not know but that exists (a first install over an older copy) is the same.
while IFS= read -r rel; do
  [[ -f "${REPO}/${rel}" ]] && ! cmp -s "${STAGE}/${rel}" "${REPO}/${rel}" && edited+=("${rel}")
done < <(jq -r --argjson o "${OLD}" 'keys[] | select($o[.] == null)' <<<"${NEW}")
if [[ "${#edited[@]}" -gt 0 && "${force}" != 1 ]]; then
  printf 'render: these package files were changed in the repo and would be overwritten:\n' >&2
  printf '  %s\n' "${edited[@]}" >&2
  die "move the change into .github/agents/ (policy.json, project.md, hooks/) and re-run, or pass --force"
fi

changed=0
while IFS= read -r rel; do
  guard_path "${rel}"
  if ! cmp -s "${STAGE}/${rel}" "${REPO}/${rel}" 2>/dev/null; then
    mkdir -p "$(dirname "${REPO}/${rel}")"
    cp -p "${STAGE}/${rel}" "${REPO}/${rel}"
    printf 'wrote %s\n' "${rel}"
    changed=1
  fi
done < <(jq -r 'keys[]' <<<"${NEW}")
while IFS= read -r rel; do
  if [[ -f "${REPO}/${rel}" ]]; then rm -f "${REPO}/${rel}"; printf 'removed %s\n' "${rel}"; changed=1; fi
done < <(jq -r --argjson n "${NEW}" 'keys[] | select($n[.] == null)' <<<"${OLD}")
# Built in the staging directory, never beside the lock: a name created in the repo is a name a
# committed symlink could already hold. The destination itself was guarded above.
jq -n --arg v "${VERSION}" --argjson f "${NEW}" \
  '{"$comment": "Written by repo-agents bin/render.sh. Hashes of the package files as rendered; do not edit.", version: $v, files: $f}' \
  >"${STAGE}/install.lock.json"
if ! cmp -s "${STAGE}/install.lock.json" "${REPO}/${LOCK_REL}" 2>/dev/null; then
  cp "${STAGE}/install.lock.json" "${REPO}/${LOCK_REL}"
  changed=1
fi
if [[ "${changed}" == 1 ]]; then echo "repo-agents ${VERSION} rendered into ${REPO}"; else echo "already up to date with repo-agents ${VERSION}"; fi
