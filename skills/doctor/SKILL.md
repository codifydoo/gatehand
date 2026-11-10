---
name: doctor
description: Check that the repo-agents setup in the current repository is complete and consistent (files, secrets, variables, the GitHub App, the runner ref, labels, Actions settings, required checks). Use when the user asks whether the agents are set up right, or when a run fails with a setup error.
---

# Check the repo-agents setup

The package root is two directories above this file (`<root>/skills/doctor/SKILL.md`).

Run `bash <root>/bin/doctor.sh .` from the repository root. It is read-only. For each `FAIL` and
`WARN`, tell the user what it means and the exact fix (the runbook, `.github/agents/README.md`,
"Setup" and "When something is stuck", has them). Do not apply a fix that changes GitHub settings,
secrets, variables or branches without their go-ahead.

If the user reports a failed run, also read that run's log (`gh run view <id> --log-failed`) and
match it against "When something is stuck".
