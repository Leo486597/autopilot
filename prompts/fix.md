@claude fix — build what this issue asks, and nothing else. The issue is the ask; you read the code and plan.
Follow the repo's agent rules (CLAUDE.md or AGENTS.md, and what they point to) in everything you write and build.
1. First push your branch and open a draft PR into `{{BASE}}` with `Closes #{{N}}`: that claims the issue.
2. Prove each part of the ask: a test, a command's output in the PR, or a screenshot attached to the issue.
3. List every call you make yourself (copy, naming, layout, a technical choice) in the PR body under **Assumed**.
4. Run /code-review on the PR, push the fixes as new commits, and list what it found in the PR body.
5. Give the PR body a `### Deliverables` section: everything the PR made except code changes, one bullet each, as a link that
   opens it now and what to look at. Only code changed: one bullet saying so.
6. Rebase on `{{BASE}}`, then `gh pr ready`: that hands it to the judge.
Stop only for what you can't settle yourself: a call that moves money, an account or a credential, something outward-facing
that is hard to undo, going against a ruling the repo records, or work a runner can't reach. Then add `{{NEEDS_LABEL}}` to the
issue and ask {{OWNER}} with `.autopilot/bin/autopilot.sh ping {{N}} "<what>"`, the questions on stdin: at most 3, each with
2–3 short options and a ★ pick, answered `1A 2B` or `ok`. Their reply starts you again.
