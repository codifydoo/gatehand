---
name: update
description: Update the Gatehand files in the current repository to the installed package version, or re-render them after a policy.json change. Use when the user asks to update or upgrade Gatehand, or changed .github/agents/policy.json.
---

# Update Gatehand in this repository

The package root is two directories above this file (`<root>/skills/update/SKILL.md`).

1. Check: a clean working tree, `.github/agents/install.lock.json` exists (else use the install
   skill), and note its `version` against `<root>/.claude-plugin/plugin.json`.
2. On a new branch `chore/update-gatehand`, run `bash <root>/bin/render.sh .`.
   - If it refuses because package files were edited in the repo, show the user `git diff` of those
     files against the lock's version (`git log -p` on them helps). Move each change to where it
     belongs (`policy.json`, `project.md`, the setup actions or `hooks/lib.sh`), restore the file,
     and re-run. Use `--force` only when the user agrees the local edit can go.
   - If `policy.json` gained keys in the new version's `<root>/defaults/policy.json`, tell the user
     and add the defaults (render.sh reads missing keys with their defaults, but write them out).
3. `bash <root>/bin/render.sh --check .` must pass. Summarise what changed (the package's
   `CHANGELOG.md` for the version range, and the diff), then commit on the user's go-ahead.
4. Tell the user: once this merges, if `agent-coder.yml` or `agent-fixup.yml` changed, fast-forward
   the runner ref or every run stops with `runner-ref-stale`:

   ```bash
   git fetch origin <default> && git push origin origin/<default>:agent-runner
   ```
