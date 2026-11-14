#!/usr/bin/env bash
# tests/site/site.test.sh: site/, the project site that .github/workflows/pages.yml publishes.
# Pinned, and why:
#   1. Every local href and src resolves to a file in site/. Nothing builds the site, so a renamed
#      page is a dead link until someone clicks it.
#   2. No link starts with "/": Pages serves a project site under /<repository>/, where a
#      root-relative link leaves the site.
#   3. The install commands shown are the README's, line for line: the site and the README are
#      written by hand, and a visitor pastes these.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SITE="${PKG}/site"

pass=0 fail=0
t_pass() { printf '\033[1;32m[site] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[site] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

pages=("${SITE}"/*.html)
if [[ -f "${SITE}/index.html" ]]; then t_pass "site/index.html exists"; else t_fail "site/index.html is missing"; fi

dead=0 rooted=0 links=0
for page in "${pages[@]}"; do
  while IFS= read -r target; do
    case "${target}" in
      http://* | https://* | mailto:* | '#'*) continue ;;
      /*) t_fail "${page##*/}: root-relative link ${target}"; rooted=$((rooted + 1)); continue ;;
    esac
    links=$((links + 1))
    file="${target%%#*}"
    [[ "${file}" == ./ || -z "${file}" ]] && file=index.html
    [[ -f "${SITE}/${file}" ]] || { t_fail "${page##*/}: ${target} is not a file in site/"; dead=$((dead + 1)); }
  done < <(grep -oE '(href|src)="[^"]*"' "${page}" | sed -E 's/^(href|src)="//; s/"$//')
done
[[ "${links}" -gt 0 && "${dead}" -eq 0 ]] && t_pass "all ${links} local links resolve"
[[ "${links}" -gt 0 ]] || t_fail "found no local links to check"
[[ "${rooted}" -eq 0 ]] && t_pass "no root-relative links"

# The README's install block: the first ```text fence.
want="$(awk '/^```text$/ { on = 1; next } /^```$/ { if (on) exit } on' "${PKG}/README.md")"
[[ -n "${want}" ]] || t_fail "README.md has no \`\`\`text install block to compare with"
for page in index.html get-started.html; do
  got="$(awk '/<pre><code>\/plugin / { on = 1 } on { print } /<\/code><\/pre>/ { if (on) exit }' "${SITE}/${page}" \
    | sed -E 's/<\/?(pre|code)>//g')"
  if [[ -n "${want}" && "${got}" == "${want}" ]]; then
    t_pass "${page}: the install commands are the README's"
  else
    t_fail "${page}: the install commands differ from README.md"
    diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") >&2
  fi
done

printf '[site] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
