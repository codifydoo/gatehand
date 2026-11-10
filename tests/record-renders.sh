#!/usr/bin/env bash
# tests/record-renders.sh: re-record tests/workflows/render-fixtures.jsonl, the GitHub renders the gh
# stub answers `gh api --method POST markdown` with. Runs every suite with each render sent to the
# real API (gh must be signed in), then keeps one render per text, so a text no test sends any more
# drops out. Commit the result with the tests that needed it.
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "${out}"' EXIT
AGENTS_RENDER_RECORD="${out}" bash "${PKG}/tests/run.sh"
rc=$?
jq -sc 'unique_by(.text)[]' "${out}" >"${PKG}/tests/workflows/render-fixtures.jsonl"
echo "recorded $(wc -l <"${PKG}/tests/workflows/render-fixtures.jsonl" | tr -d ' ') renders (suites exit ${rc})"
exit "${rc}"
