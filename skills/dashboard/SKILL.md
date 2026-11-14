---
name: dashboard
description: Open the Gatehand dashboard, a local page showing every repository where the Gatehand agents are installed - what they are doing, open inbox requests, blocked issues, agent PRs and why the merge gate holds them, the queue, runs, cost and breakers - with buttons to answer inbox requests, rerun, pause or resume, hold and unqueue, start or cancel agent runs, approve or request changes on agent PRs, and turn the agents or auto-merge on and off. Use when the user asks for an overview of their agents, what is waiting for them, agent activity across repositories, or to answer the agents without typing comments.
---

# Open the Gatehand dashboard

The package root is two directories above this file (`<root>/skills/dashboard/SKILL.md`).

1. Check `gh auth status` works and `python3 --version` is 3.9 or later. The dashboard sees exactly
   what the user's `gh` login sees.
2. Start it in the background (it keeps serving until stopped, or after two hours with no page
   open): `python3 <root>/bin/dashboard.py`. It opens the user's browser on a 127.0.0.1 address
   that carries a per-launch secret.
3. Never pass `--print-url` or `--no-open`, and never read or repeat the address from the browser:
   the secret in it lets anything holding it read the user's repositories through their login.
   If no browser opened, tell the user to run the command themselves in a terminal, where it can
   print the address with `--print-url`.
4. Tell the user it is open, and that "Find repositories" rescans their repositories for
   `.github/agents/install.lock.json`. Its buttons (answer an inbox request, rerun, pause or resume
   a role, unqueue, hold, hand a PR back) act as the user with their own login after they confirm
   each one in the page; never drive them yourself.

Its list of repositories is kept in `${XDG_CONFIG_HOME:-~/.config}/gatehand/dashboard.json`. The
security model is in `<root>/docs/dashboard.md`.
