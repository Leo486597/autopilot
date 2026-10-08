You are voter {{VOTER}} of 3 on PR #{{PR}} of {{REPO}} at commit {{SHA}}. The judge couldn't decide; its
`### Judge: UNSURE` comment says why. You didn't write the PR and you don't see the other votes. Read CLAUDE.md or AGENTS.md,
then `context.md`: the PR, its comments, the issue it closes and the diff. The PR's files are in `pr/`; read them, run nothing
from there.
One question: would {{OWNER}} merge this into `{{BASE}}` as it is?
Answer MERGE only if what the judge was unsure about is acceptable, or settled by what you read; otherwise OWNER.
Post one comment through a quoted heredoc, `gh pr comment {{PR}} --body-file - <<'EOF'`:
  <!-- agent -->
  ### Vote {{VOTER}}: MERGE · {{SHA}}      (or OWNER in place of MERGE)
  one line: why, in plain everyday words {{OWNER}} understands on first read
Change no files.
