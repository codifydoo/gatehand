#!/usr/bin/env bash
# tests/workflows/agents-gh-stub.sh
# A fake `gh` for the agents-*.test.sh suites. SOURCED by them; not a test itself (the CI loop runs
# only `*.test.sh`, and shellcheck still lints this file).
#
#   stub_gh_init                         fresh stub dir, its bin/ first on PATH
#   stub_gh_on <glob> [stdout] [rc] [stderr]
#                                        the first rule whose glob matches "$*" (the args joined by
#                                        spaces) answers; no match = exit 0 with no output
#   stub_gh_json <glob> <raw-api-json>   like stub_gh_on, but the output is the RAW API response and
#                                        the stub applies the call's own `--jq` program to it, the
#                                        way gh does, so the scripts' jq filters are exercised too
#   STUB_AFTER=<glob> stub_gh_on|json …  the rule answers only once an EARLIER call matched <glob>
#                                        (state that changes during a run, e.g. main after a merge)
#   stub_gh_calls                        every call so far, one per line
#   stub_gh_body <n>                     the --body-file content (or `--input -` stdin) of call n
#   stub_gh_last_body <glob>             the --body-file content of the last call matching <glob>
#   A render (`gh api --method POST markdown`) that no rule answers gets GitHub's recorded output for
#   that text from render-fixtures.jsonl (tests/record-renders.sh records them), so review verdicts
#   are read from real GitHub HTML; a text never recorded fails the call.

stub_gh_init() {
  STUB_DIR="$(mktemp -d)"
  mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/out" "${STUB_DIR}/bodies"
  : >"${STUB_DIR}/rules"
  : >"${STUB_DIR}/calls"
  cat >"${STUB_DIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
n=$(($(wc -l <"${dir}/calls") + 1))
printf '%s\n' "$*" >>"${dir}/calls"
prev=""
jqexpr=""
for a in "$@"; do
  [[ "${prev}" == "--body-file" && -f "${a}" ]] && cp "${a}" "${dir}/bodies/${n}"
  # `--input -` is a request body on stdin (gh api); keep it like a --body-file.
  [[ "${prev}" == "--input" && "${a}" == "-" ]] && cat >"${dir}/bodies/${n}"
  [[ "${prev}" == "--jq" ]] && jqexpr="${a}"
  prev="${a}"
done
while IFS=$'\x1f' read -r pat out rc err mode after; do
  # shellcheck disable=SC2053 # the rule IS a glob
  if [[ "$*" == ${pat} ]]; then
    if [[ -n "${after}" ]]; then
      # shellcheck disable=SC2053
      seen=0; while IFS= read -r c; do [[ "${c}" == ${after} ]] && { seen=1; break; }; done < <(head -n "$((n - 1))" "${dir}/calls")
      [[ "${seen}" == 1 ]] || continue
    fi
    if [[ "${mode}" == json && -n "${jqexpr}" ]]; then
      jq -r "${jqexpr}" "${dir}/out/${out}"
    elif [[ -n "${out}" ]]; then
      cat "${dir}/out/${out}"
    fi
    [[ -n "${err}" ]] && cat "${dir}/out/${err}" >&2
    exit "${rc:-0}"
  fi
done <"${dir}/rules"
# A render (POST /markdown) no rule answered: GitHub's real output for that exact text, recorded in
# render-fixtures.jsonl. AGENTS_RENDER_RECORD=<file> asks GitHub instead and appends each answer to
# <file> (tests/record-renders.sh); a text with no recording fails the call, loudly.
if [[ "$*" == *" markdown --input -"* ]]; then
  key="$(jq -c .text "${dir}/bodies/${n}")"
  if [[ -n "${AGENTS_RENDER_RECORD:-}" ]]; then
    html="$("${STUB_REAL_GH}" api --method POST markdown --input "${dir}/bodies/${n}")" || exit 1
    jq -nc --argjson t "${key}" --arg h "${html}" '{text: $t, html: $h}' >>"${AGENTS_RENDER_RECORD}"
    printf '%s\n' "${html}"
    exit 0
  fi
  jq -ner --argjson t "${key}" 'first(inputs | select(.text == $t) | .html)' "${STUB_RENDER_FIXTURES}" && exit 0
  echo "stub gh: no recorded render of ${key}; run tests/record-renders.sh" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "${STUB_DIR}/bin/gh"
  # The real gh, found before any stub is on PATH (an earlier init's would shadow it).
  STUB_REAL_GH="${STUB_REAL_GH:-$(command -v gh || true)}"
  STUB_RENDER_FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/render-fixtures.jsonl"
  PATH="${STUB_DIR}/bin:${PATH}"
  export PATH STUB_DIR STUB_REAL_GH STUB_RENDER_FIXTURES
}

stub_gh_on() {
  local pat="$1" out="${2:-}" rc="${3:-0}" err="${4:-}" k ofile="" efile=""
  k="$(wc -l <"${STUB_DIR}/rules" | tr -d ' ')"
  if [[ -n "${out}" ]]; then ofile="o${k}"; printf '%s\n' "${out}" >"${STUB_DIR}/out/${ofile}"; fi
  if [[ -n "${err}" ]]; then efile="e${k}"; printf '%s\n' "${err}" >"${STUB_DIR}/out/${efile}"; fi
  # Unit separator, not a tab: IFS collapses runs of whitespace, so an empty column would shift.
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${pat}" "${ofile}" "${rc}" "${efile}" "${STUB_MODE:-}" "${STUB_AFTER:-}" >>"${STUB_DIR}/rules"
}

stub_gh_json() { STUB_MODE=json stub_gh_on "$1" "$2" 0; }

stub_gh_calls() { cat "${STUB_DIR}/calls"; }

stub_gh_body() { cat "${STUB_DIR}/bodies/$1" 2>/dev/null; }

stub_gh_last_body() {
  local pat="$1" i=0 last="" line
  while IFS= read -r line; do
    i=$((i + 1))
    # shellcheck disable=SC2053
    [[ "${line}" == ${pat} ]] && last="${i}"
  done <"${STUB_DIR}/calls"
  [[ -n "${last}" ]] && stub_gh_body "${last}"
}

# stub_gh_any_body <needle>: exit 0 when any --body-file passed so far contains <needle>.
stub_gh_any_body() { grep -rFq -- "$1" "${STUB_DIR}/bodies" 2>/dev/null; }

stub_gh_reset_calls() { : >"${STUB_DIR}/calls"; rm -f "${STUB_DIR}/bodies/"*; }
stub_gh_reset_rules() { : >"${STUB_DIR}/rules"; }
