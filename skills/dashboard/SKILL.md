---
name: dashboard
description: Open the Gatehand dashboard, a local page showing every repository where the Gatehand agents are installed - what they are doing, open inbox requests, blocked issues, agent PRs and why the merge gate holds them, the queue, runs, cost and breakers. Use when the user asks for an overview of their agents, what is waiting for them, or to see agent activity across repositories.
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
4. Tell the user it is open, that "Find repositories" rescans their repositories for
   `.github/agents/install.lock.json`, and that the page is read-only: answering a request still
   happens on the inbox issue (each request links there).

Its list of repositories is kept in `${XDG_CONFIG_HOME:-~/.config}/gatehand/dashboard.json`. The
security model is in `<root>/docs/dashboard.md`.
