# Project rules for the agents

The coder and fixer read this file before every run (`.claude/commands/agent-implement.md`, step 1).
It is yours: the package never overwrites it. Keep it short and concrete.

## Standing rules

Rules a change must never break. The agent stops and asks (`blocked.md`) rather than break one.

- (example) Never change a database migration that has already shipped; add a new one.
- (example) No new runtime dependency without a line in the PR body saying why.

## Checks

The commands CI runs, per area. The agent runs those for every area it touched before it commits.
Every command here must also be allowed in `.github/agents/policy.json` `tools.allow`
(`Bash(<command prefix>:*)`), or the agent cannot run it.

- (example) Everything: `npm test`
- (example) TypeScript: `npm run typecheck`, `npm run lint`
