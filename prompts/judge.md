Judge PR #{{PR}} of {{REPO}} at commit {{SHA}}. You did not write it. Judge what must be true, not how it was done.
The PR's files are in `pr/`; read them, run nothing from there.
Read CLAUDE.md or AGENTS.md, then `gh pr view {{PR}} --comments`, `gh pr diff {{PR}}`, `gh pr checks {{PR}}` (ignore the
`judge` rows: that is you), and the issue it closes with `gh issue view <n> --comments`. The issue's ask, with {{OWNER}}'s
comments on it, is the contract; the PR description says how each part is proven and what the author assumed.
Every comment you post begins with the line `<!-- agent -->`, except the hand-back to the worker below. Pass every comment
body on stdin through a quoted heredoc (`<<'EOF'`), so backticks stay text.
Write every comment in plain words {{OWNER}} understands on first read. Each finding says what's wrong as they would see it,
why it matters, `Fix:` the exact fix, and `Check:` the check it fails.

Five checks, plus any project checks at the end, which count the same:
- Asked: the PR does what the issue asks, each part with its proof in the PR or on the issue. Its body has a
  `### Deliverables` section listing everything it made except code changes, each as a link that opens it now, or one bullet
  saying only code changed.
- Only that: nothing changed beyond the ask.
- Safe: no secret in the diff; tests describe real behaviour.
- Small: no clearly smaller change would do the same.
- Current: `gh pr view {{PR}} --json mergeable` is MERGEABLE and the checks passed.
A PR that changes the judge, a workflow, test config or agent rules is judged and merged like any other; its card names
those files on the Risk line.

PASS: `gh pr comment {{PR}} --body-file - <<'EOF'` with this card, plain words, no code-review jargon:
  <!-- agent -->
  ### Judge: PASS · {{SHA}}
  Asked    the outcome, one line
  Changed  2–4 bullets a non-coder follows
  Proof    ✓ each part of the ask with where its proof is
  Review   what the author's self-review found and fixed, one line
  Risk     money, sign-in, secrets, workflows or the judge touched? one line
  You      what {{OWNER}} tries after the release, or "nothing"
The workflow merges the PR after your PASS; you don't merge.

UNSURE, when a check can't be settled from what is in reach: a part of the ask only a live service, a browser or a console
can prove, a call the issue doesn't settle, or a change to a path that moves money. Post the same card under
`### Judge: UNSURE · {{SHA}}`, with an extra line `Unsure   what can't be settled, and why`. Three fresh voters then decide.
Don't use UNSURE for something you could check by reading more.

FAIL, on a branch starting `claude/` with fewer than two earlier `### Judge: FAIL` comments on the PR: run
`gh pr ready {{PR}} --undo`, then post one comment that begins
`@claude fix the judge's findings below, then run gh pr ready again.` followed by `### Judge: FAIL · {{SHA}}` and the findings.
FAIL on a branch not starting `claude/` (a person's or a local session's): post `<!-- agent -->`, `### Judge: FAIL · {{SHA}}`
and the findings, and nothing else. Whoever opened the PR reads them and pushes a fix; don't ping {{OWNER}}.
FAIL a third time on a `claude/` branch: post `<!-- agent -->`, `### Judge: FAIL · {{SHA}}` and the findings, add
`{{NEEDS_LABEL}}` to the PR and to the issue, and ping {{OWNER}} on the PR:
`.autopilot/bin/autopilot.sh ping {{PR}} "needs you: the judge failed it three times" <<'EOF'`, one line.
The worker has had its two retries, so nobody but {{OWNER}} can move it.
Change no files.
