# autopilot

GitHub issues that run themselves, on Claude Code and GitHub Actions. An issue gets labelled, a Claude worker builds it
into a PR, a fresh Claude judge checks the PR against the issue and merges it. The owner is pinged only for what only
they can decide.

```mermaid
flowchart TD
  new["Issue opened by the owner"] --> assigned{"Assigned to someone?"}
  assigned -- yes --> human["Left to that person"]
  assigned -- no --> classify["triage: a model sets title and labels"]
  classify --> kind{"Buildable kind?"}
  kind -- no --> human
  kind -- yes --> slot{"A worker slot free?"}
  slot -- no --> sweep["Waits: the next worker to finish, or the daily sweep"]
  sweep --> slot
  slot -- yes --> worker["claude: a worker builds it<br/>draft PR, proof, self-review, ready"]
  worker -- "money, credentials, hard to undo" --> ask["needs: owner<br/>up to 3 questions"]
  ask -- "owner replies on the issue" --> worker
  worker -- "PR ready" --> judge["judge: asked, only that, safe, small, current<br/>plus the project's own checks"]
  judge -- "FAIL, first or second" --> worker
  judge -- "FAIL, third" --> owner["needs: owner + ping"]
  judge -- "UNSURE" --> vote{"2 of 3 fresh voters merge?"}
  vote -- no --> owner
  judge -- PASS --> merged["Merged, issue closed"]
  vote -- yes --> merged
```

- Each project keeps three thin workflow files that call the reusable workflows here, one settings file, and its label
  list. Everything else (the logic, the prompts) lives here and updates by tag.
- A project changes behaviour through settings, its own `CLAUDE.md`, prompt additions and two command hooks.
- Also included: a daily sweep, auto-merging `BASE` into PRs that a merge left conflicting, a project board kept in
  sync, a review list of what merged without the owner, and releases that start once a locked milestone is done.

**See it run:** [autopilot-example](https://github.com/Leo486597/autopilot-example), a tiny project on this flow.

- [Issue #2](https://github.com/Leo486597/autopilot-example/issues/2) there ran itself.
- The agents built it into [PR #3](https://github.com/Leo486597/autopilot-example/pull/3) and merged it.

**Set up, customize, upgrade:** [AGENTS.md](AGENTS.md). It is written for the coding agent that will do the setup, so
the quickest path is to point yours at it: _"set up https://github.com/Leo486597/autopilot in this repo, following its
AGENTS.md"_.

Needs: a GitHub App for the agents to act as, and a Claude token (`claude setup-token`). [MIT licence](LICENSE).
