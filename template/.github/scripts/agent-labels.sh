#!/usr/bin/env bash
# .github/scripts/agent-labels.sh
# Creates every label the autonomous agents use (the list lives in agent-lib.sh, AGENT_LABELS), so
# the owner can mark issues `agent:ready` before any agent has run. Idempotent: existing labels
# are left alone. The workflows also create missing labels on first use.
#
# Usage: GH_REPO=<owner>/<repo> bash .github/scripts/agent-labels.sh
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/agent-lib.sh"
ensure_labels && echo "agent labels present in ${GH_REPO:-the current repo}"
