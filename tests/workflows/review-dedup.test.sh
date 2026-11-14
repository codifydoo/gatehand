#!/usr/bin/env bash
# tests/workflows/review-dedup.test.sh
# Drives the REAL `run:` block out of claude-code-review.yml's baseline step against a stubbed `gh`,
# rather than grepping the workflow for strings. The step's job is to decide whether a review has
# already happened, and a string-level test would pass on a filter that decides it wrongly.
#
# Why this gate exists: the code-review plugin this workflow replaced suppressed a review when the
# PR already carried a Claude comment. /verify-pr has no equivalent, so a PR toggled
# draft -> ready -> draft -> ready got two full reviews, and a dispatch after an automatic run added
# a third.
#
# Asserts:
#   1. no comments at all            -> already_reviewed=false  (the common first-review case)
#   2. a marker comment present      -> already_reviewed=true
#   3. marker + newer plain comments -> already_reviewed=true    (order must not matter)
#   4. marker only on an EARLIER page-> already_reviewed=true    (pagination must be honoured)
#   5. non-marker comments only      -> already_reviewed=false   (a human comment is not a review)
#   6. the watermark still works     -> id= is the highest comment id, unchanged behaviour
#   7. both gated steps share one condition (a gate on the review but not the assert makes the
#      assert fail on a skipped review)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AGENTS_ROOT:?run through tests/run.sh, which renders the package into a scratch repo}"
WORKFLOW="${REPO_ROOT}/.github/workflows/claude-code-review.yml"
MARKER='<!-- verify-pr-review -->'

pass=0
fail=0
t_pass() { printf '\033[1;32m[review-dedup] PASS:\033[0m %s\n' "$*"; pass=$((pass + 1)); }
t_fail() { printf '\033[1;31m[review-dedup] FAIL:\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

[[ -f "${WORKFLOW}" ]] || { t_fail "claude-code-review.yml is missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Lift the baseline step's run: block out of the YAML, so this drives the shipped code.
#
# awk, not python+yaml: the runner image ships python3 but NOT PyYAML (bare Ubuntu container --
# the same reason it ships no `gh`). A test that needs a pip install is a test that reddens CI on
# a machine where it passes locally, which is exactly what happened before this was rewritten.
# Steps sit at 6 spaces, their keys at 8, and a `run: |` block body at 10.
extract_run_block() { # <file> <id>
  awk -v want="$2" '
    $0 ~ "^        id: " want "$" { in_step = 1; next }
    in_step && /^      - / { exit }                       # next step, give up
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 == "") { print ""; next }                    # blank lines belong to the block
      if ($0 !~ /^          /) { exit }                   # dedent ends the block
      sub(/^          /, ""); print
    }
  ' "$1"
}
# ${{ }} expressions are resolved by Actions, not bash; the harness supplies the values it needs.
extract_run_block "${WORKFLOW}" baseline \
  | sed 's|\${{ github\.repository }}|acme/repo|g' >"${TMP}/baseline.sh"
[[ -s "${TMP}/baseline.sh" ]] || { t_fail "could not extract the baseline step's run block"; exit 1; }

# Stub `gh`: emit the fixture the case set up, ignoring flags. --paginate is simulated by the
# fixture already containing every page's comments concatenated, which is what gh yields.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
jq_expr=""
while [[ $# -gt 0 ]]; do
  case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac
done
[[ -n "${jq_expr}" ]] || { echo "stub gh: no --jq given" >&2; exit 1; }
jq -r "${jq_expr}" "${GH_FIXTURE}"
STUB
chmod +x "${TMP}/bin/gh"

# Run the extracted step against one fixture; echo "<already_reviewed>|<id>".
run_step() {
  local fixture="$1" out="${TMP}/gh_output"
  : >"${out}"
  GH_FIXTURE="${fixture}" PR=1 GITHUB_OUTPUT="${out}" PATH="${TMP}/bin:${PATH}" \
    REVIEW_MARKER="${MARKER}" REVIEW_BOT='claude[bot]' \
    bash "${TMP}/baseline.sh" >/dev/null 2>&1
  printf '%s|%s' \
    "$(grep -E '^already_reviewed=' "${out}" | tail -1 | cut -d= -f2)" \
    "$(grep -E '^id=' "${out}" | tail -1 | cut -d= -f2)"
}

mk() { printf '%s\n' "$1" >"${TMP}/$2.json"; }

mk '[]' empty
BOT='"user":{"login":"claude[bot]"}'
ANYONE='"user":{"login":"mallory"}'
mk "[{\"id\":10,${BOT},\"body\":\"${MARKER}\\n\\n### Summary\\nlgtm\"}]" marker
mk "[{\"id\":10,${BOT},\"body\":\"${MARKER}\\n\\nreview\"},{\"id\":99,${ANYONE},\"body\":\"thanks!\"}]" marker_then_chat
mk "[{\"id\":10,${BOT},\"body\":\"${MARKER}\\n\\nreview\"},{\"id\":250,${ANYONE},\"body\":\"page two\"}]" paginated
mk "[{\"id\":10,${ANYONE},\"body\":\"looks fine to me\"},{\"id\":11,${ANYONE},\"body\":\"@claude what is the status here?\"}]" humans
mk "[{\"id\":12,${ANYONE},\"body\":\"${MARKER}\\n\\nApprove\"}]" pasted

expect() { # fixture  want_flag  want_id  label
  local got; got="$(run_step "${TMP}/$1.json")"
  if [[ "${got}" == "$2|$3" ]]; then
    t_pass "$4 (already_reviewed=$2, id=$3)"
  else
    t_fail "$4 — expected 'already_reviewed=$2, id=$3' but the step emitted '${got//|/, id=}'"
  fi
}

expect empty            false 0   "Case 1: a PR with no comments is not already reviewed"
expect marker           true  10  "Case 2: a marker-bearing comment counts as a review"
expect marker_then_chat true  99  "Case 3: chatter after the review does not hide it"
expect paginated        true  250 "Case 4: a marker on an earlier page is still found"
expect humans           false 11  "Case 5: human comments alone are not a review"
expect pasted           false 12  "Case 5b: a marker pasted by someone else does not suppress the review"

# Case 6/7: the two steps that must not run on a re-review have to share ONE condition. Gating the
# review but not the assertion leaves the assertion demanding a comment that was never going to be
# posted — a red job on a PR that was correctly skipped.
# The `if:` sits directly under the step's identifying line, at 8 spaces. Same awk-only reason.
gate_after() { # <file> <anchor-regex>
  awk -v anchor="$2" '
    $0 ~ anchor { found = 1; next }
    found && /^        if: / { sub(/^        if: /, ""); print; exit }
    found && /^      - / { exit }
  ' "$1"
}
# Since #1147 the de-dup gate sits on the probe, the first step of the review proper; the review
# step runs only when the probe says it can be posted, so it inherits the gate.
gate_review="$(gate_after "${WORKFLOW}" '^        id: probe$')"
gate_model="$(gate_after "${WORKFLOW}" '^        id: claude-review$')"
if [[ "${gate_model}" == "steps.probe.outputs.valid == 'true'" ]]; then
  t_pass "the review step runs only after the probe, so it inherits the probe's gate"
else
  t_fail "the review step's if: is '${gate_model}', not the probe's verdict"
fi
gate_assert="$(gate_after "${WORKFLOW}" '^      - name: assert the review actually posted a comment$')"
if [[ -n "${gate_review}" && "${gate_review}" == "${gate_assert}" ]]; then
  t_pass "the probe and assert steps share one identical gate"
else
  t_fail "probe gate and assert gate differ — probe:'${gate_review}' assert:'${gate_assert}'"
fi
if [[ "${gate_review}" == *"workflow_dispatch"* && "${gate_review}" == *"already_reviewed"* ]]; then
  t_pass "the gate skips on a prior review but always honours an explicit dispatch"
else
  t_fail "the gate must key on already_reviewed AND exempt workflow_dispatch — a dispatch is a human asking for a re-review"
fi

# Case 8: the marker is defined ONCE. It used to appear twice in this file — inline in the
# baseline step's jq and again in the assert step — each separately pinned but never compared to
# each other, so changing one and not the other left de-dup silently never firing while every
# test stayed green.
defs="$(grep -c -- "${MARKER}" "${WORKFLOW}")"
if [[ "${defs}" -eq 1 ]]; then
  t_pass "the marker literal appears exactly once in the workflow"
else
  t_fail "the marker literal appears ${defs} times in the workflow — it must have ONE definition that every step reads"
fi

printf '\n[review-dedup] %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
