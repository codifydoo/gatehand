#!/usr/bin/env bash
# release-download.sh <owner/repo> <tag> <asset name> <out file>
#
# Downloads one asset of a public GitHub release: the release link first, then the same asset through
# the REST API. On 2026-11-08 the github.com/…/releases/download links answered 504 for over an hour
# while the API served the identical bytes (install-gh has the same fallback). The API calls
# carry GH_TOKEN when it is set (the job's own token is enough for a public repo): later that day
# GitHub's timeouts hit unauthenticated callers only, which took the anonymous API route down too.
# The token goes to curl as config on stdin, never in argv. The CALLER checks the pinned checksum,
# which decides whichever route served the file.
set -euo pipefail
[[ $# -eq 4 ]] || { echo "usage: release-download.sh <owner/repo> <tag> <asset name> <out file>" >&2; exit 2; }
repo="$1" tag="$2" name="$3" out="$4"
# Transient errors only (timeouts, 408/429/5xx), with curl's backoff: 1, 2, 4, 8, 16 s.
retry=(--retry 5 --retry-max-time 120)
# The link fails fast, since the API route is behind it: each try is capped at 60 s, two retries. On
# 2026-11-08 uncapped tries hung for minutes on a dying CDN and ran the 10-minute shell job out of time.
link_retry=(--connect-timeout 10 --max-time 60 --retry 2)
# curl drops a custom Authorization header on the redirect to the storage host, so it stays on api.github.com.
api() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}" | curl -K - "$@"
  else
    curl "$@"
  fi
}
if curl -fsSL "${link_retry[@]}" -o "${out}" "https://github.com/${repo}/releases/download/${tag}/${name}"; then
  exit 0
fi
echo "::warning::release-download: the link for ${repo} ${tag} ${name} failed; fetching it through the GitHub API"
id="$(api -fsSL "${retry[@]}" "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
  | jq -r --arg n "${name}" '.assets[] | select(.name == $n) | .id')"
[[ "${id}" =~ ^[0-9]+$ ]] || { echo "::error::release-download: ${repo} ${tag} has no asset ${name}"; exit 1; }
api -fsSL "${retry[@]}" -H 'Accept: application/octet-stream' -o "${out}" \
  "https://api.github.com/repos/${repo}/releases/assets/${id}"
