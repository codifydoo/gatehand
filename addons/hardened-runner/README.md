# Hardened runner (optional)

The agents run on GitHub-hosted runners by default (`runners.agent: "ubuntu-latest"` in
`.github/agents/policy.json`): a fresh VM per job, which is the isolation the design needs. This
add-on is for running the agent jobs on your own machines instead.

## What a self-hosted agent pool must give you

The security model (`docs/README.md`, "Security model") assumes these. A pool that lacks one is
weaker than a hosted runner, not stronger.

1. **A pool of its own.** Every job that mints the App token runs on `runners.agent`. CI runs PR
   code, an agent PR's included, so a runner CI can reach must never be the one that holds the App
   key. Give the agent pool a label nothing else uses, and register it to this one repository.
2. **One job per runner, then gone.** Ephemeral (`--ephemeral` or just-in-time registration) in a
   container or VM destroyed after the job, so nothing one run writes is there for the next.
3. **No host Docker socket**, no privileged container, no host mounts. The model runs code it wrote;
   the workflow drops passwordless sudo before it starts, which only helps if nothing else is root.
4. **Optional: an egress allowlist.** `egress/allow-base.txt` and `egress/allow-regex.txt` list what
   the agent jobs need (GitHub, Claude, common toolchains) in Squid syntax. Run in an audit mode
   first and add what your toolchain fetches.

Then set `runners.agent` to the pool's labels, for example `["self-hosted", "gatehand"]`, and
re-render. If you lint workflows with actionlint, declare the label in `.github/actionlint.yaml`.

## Timers that dispatch on time (`agent-kick.sh`)

GitHub's scheduler can fire crons late or skip them on busy days. `agent-kick.sh` installs one
systemd timer per scheduled agent workflow, on an always-on box, that dispatches it through the API
on time. The workflows keep their own crons as a backup, and every gate re-checks the kill switch
and caps, so a doubled run is harmless.

1. Create a fine-grained PAT with access to the one repository and **Actions: Read and write** only.
2. As root on the box:

   ```bash
   install -d -m 0700 /etc/gatehand-kick
   (umask 077; cat > /etc/gatehand-kick/token)   # paste the token, then Ctrl-D
   AGENT_KICK_REPO=<owner>/<repo> bash agent-kick.sh install   # add AGENT_KICK_TRIAGE=true if workflows.triage is on
   ```

The calendars in `agent-kick.sh` are the policy's default schedules. If you change
`schedules.*` in `policy.json`, change `job_calendar` to match and re-run `install`.
