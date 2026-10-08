# Autopilot — guide for the agent setting it up

You are in a project that wants its GitHub issues to run themselves: an issue gets labelled, a Claude worker builds it
into a PR, a fresh Claude judge checks the PR against the issue and merges it, and the owner is pinged only for what
only they can decide. `README.md` draws the flow.

Pick your branch:

- **Set up** — the project has no issue agents yet → § Set up
- **Customize** — the project runs autopilot and wants it to behave differently → § Customize
- **Upstream** — a customization would help every project → § Move a customization into the package
- **Migrate** — the project already runs its own hand-made copy of this flow → § Migrate a hand-made flow
- **Update** — a new package version is out, or you are releasing one → § Versions and updates

## What lives where

- This package (`Leo486597/autopilot`), shared by every project
  - `.github/workflows/autopilot-{triage,worker,judge}.yml` — reusable workflows (`on: workflow_call`) holding all the logic
  - `bin/autopilot.sh` — the plain steps with no model: dispatch, merge, vote count, board, release lock. `--help`-style
    usage is its header
  - `prompts/*.md` — what each agent is told; `{{KEY}}` is filled from the environment
  - `template/` — the starter files `autopilot.sh init` copies into a project
- The project, owned by the project
  - `.github/workflows/{triage,claude,judge}.yml` — thin callers: triggers, then `uses: Leo486597/autopilot/…@v1`
  - `.github/autopilot.env` — settings; every one and its default is listed at the top of `bin/autopilot.sh`
  - `.github/labels.yml` — the only labels the classifier may use
  - `.github/autopilot/<prompt>.md` — optional, appended to the package's prompt of that name
  - `CLAUDE.md` or `AGENTS.md` — the project's rules; the worker, the judge and the voters all read it first

Keep the three caller files named `triage.yml`, `claude.yml`, `judge.yml` with `name: triage|claude|judge`: the script
counts running workers by `claude.yml`, re-runs the classifier through `triage.yml`, and leaves the `judge` check out of
the "are all checks green" test.

## Set up

Run from the project's root, with `gh` signed in as the owner.

1. Copy the starter files:
   `git clone --depth 1 https://github.com/Leo486597/autopilot /tmp/autopilot && /tmp/autopilot/bin/autopilot.sh init`
   - it never overwrites; a file that already exists is left as it was, so merge it by hand
2. Fill in the starter files
   - in all three workflows: `bot:` is the GitHub App's slug (step 4); in `triage.yml` and `judge.yml`, the `branches:`
     list is the branch PRs go into
   - `.github/autopilot.env`: `BASE` the same branch; `CHECKS_WORKFLOW` the project's CI file, if it has one
   - `.github/labels.yml`: keep `kind:` and `priority: P0–P3` (the script ranks and sweeps by them); add the project's own
     families. `NEEDS_LABEL` must be one of them
   - the owner isn't the repo owner (an org repo): add `owner: <login>` under `with:` in all three workflows
3. Create the labels: `/tmp/autopilot/bin/autopilot.sh labels`
4. The GitHub App the agents act as. **This is the one step that needs the owner's clicks**; ask them for it, with this list
   - https://github.com/settings/apps/new (or the org's): any name, no webhook
   - repository permissions: Contents, Issues, Pull requests, Workflows — Read and write; Actions, Checks, Commit
     statuses — Read
   - create it, generate a private key, install it on the project's repo
   - then you: `gh variable set AGENT_APP_ID --body <app id>` and `gh secret set AGENT_APP_KEY < <key.pem>`
5. The model's token: `claude setup-token` (opens the owner's browser, valid a year), then
   `gh secret set CLAUDE_CODE_OAUTH_TOKEN` with what it printed. Never write it to a file in the repo
6. Optional
   - a project board: give it a single-select field `Stage` with options `New`, `Needs you`, `Local`, `Ready`, `Working`,
     `In review`; set `BOARD_PROJECTS`; `gh secret set PROJECT_TOKEN` with the owner's token carrying the `project` scope
     (a GitHub App can't reach a user-owned project)
   - a review list: an issue whose body holds the line `<!-- review-list -->`; its number in `REVIEW_LIST`
   - auto-release: the project's release workflow listens for `repository_dispatch` of type `release`
7. Commit on a branch, open a PR, merge it into `BASE`

**Done when** an issue opened by the owner (say "Docs: add a line to the README saying hello") gets labelled within a few
minutes, gets an `@claude fix` comment from the app, then a draft PR that turns ready, then a `### Judge:` card, and
merges. Watch it under the repo's Actions tab. If a step stalls, its run log says why.

## Customize

Reach for the first rung that does the job; each later rung costs more to keep:

1. **A setting** in `.github/autopilot.env` (the list is the top of `bin/autopilot.sh`), or an input on a caller:
   `node-version`, `effort` (worker), `skip-branch-prefix` (judge), `owner` (all)
2. **The project's rules** in its `CLAUDE.md` / `AGENTS.md`: how to test, what counts as safe, writing style. Every agent
   reads them
3. **A prompt addition**: `.github/autopilot/classify.md`, `fix.md`, `judge.md` or `vote.md`, appended under the
   package's prompt. Same `{{KEY}}` filling (`{{REPO}}`, `{{OWNER}}`, `{{BASE}}`, `{{NEEDS_LABEL}}`, `{{N}}`, `{{PR}}`,
   `{{SHA}}`). Examples
   - `classify.md`: which milestone a P0/P1 goes in, and where the version is read from
   - `judge.md`: a project check, written like the five built-in ones ("Works for the user: …"); it counts the same
   - `fix.md`: extra steps for the worker, such as "a UI change adds before | after screenshots"
   - the worker's system prompt (`system`) takes no addition: put that in `CLAUDE.md`
4. **A command hook** in `.github/autopilot.env`
   - `JUDGE_PREPARE`: runs from `BASE` before the judge, with the PR's files in `pr/`; it can write files the judge
     prompt then tells the judge to read (a scan's output, screenshots). It runs with the app's token: never run code
     from `pr/` in it
   - `WORKER_SETUP`: runs before the worker starts (e.g. `corepack enable`)

Whatever none of these can do is a package change: § Move a customization into the package.

Try a change before merging it: run the script by hand from the project root with `DRY=1`, which prints every write
instead of doing it, e.g. `DRY=1 /tmp/autopilot/bin/autopilot.sh dispatch`, or
`/tmp/autopilot/bin/autopilot.sh prompt judge PR=1 SHA=abc` to read the judge's full prompt with the project's addition.
(`dispatch`, `sweep`, `lock` and `release` still take and drop their lock ref under `refs/locks/`.)

## Move a customization into the package

Upstream it when a second project would want it, or when it had to work around the package rather than through a rung
above. Leave it local when it names the project's own files, services or rules.

1. Clone the package, branch, and make the change so a project that sets nothing behaves exactly as before: a new
   setting with a default in the list at the top of `bin/autopilot.sh` (add it to `SETTINGS` so `env` exports it), a
   new input with a default, or new prompt text that is true for every project
2. Point the project at the branch: in its three callers, `@v1` → `@<branch>`. Run the flow once on a test issue; the
   `.autopilot` checkout follows the caller's ref, so script and prompts come from the branch too
3. Open a PR on `Leo486597/autopilot` with what changed, why, and the run that proves it
4. Once merged, release it: § Versions and updates
5. In the project: callers back to `@v1`, and delete the local version (the prompt addition, the hook, the setting it
   replaced) in the same PR

**Done when** the project's callers say `@v1`, its local customization is gone, and the flow still runs on a test issue.

## Migrate a hand-made flow

The project already runs its own triage / worker / judge workflows and script (this package started as one of those).

1. Map each of its parts to a rung of § Customize: settings into `.github/autopilot.env`, project checks and steps into
   `.github/autopilot/*.md`, scans and screenshot fetching into `JUDGE_PREPARE`, setup into `WORKER_SETUP` / inputs.
   Anything that maps to no rung goes to § Move a customization into the package first
2. Prove the plain steps agree before switching: from the project root, run the old script and
   `DRY=1 bin/autopilot.sh` side by side on `dispatch` and `board`, and diff what each would do. A difference is either
   a setting you missed or a real change; say which in the PR
3. Replace its workflows with the three callers (keep the file names), delete its own script and copied prompt text in
   the same PR, and point every doc that named them at this package
4. If the project's workflows run on a self-hosted mirror rather than GitHub Actions: the mirror may not fill
   `job.workflow_repository` / `job.workflow_sha`; the workflows then check out the package at `v1`. Check one run's
   `.autopilot` checkout step to see which ref it took

**Done when** the old workflows and script are deleted, the dry-run diff is explained in the PR, and one issue has gone
from opened to merged on the new flow.

## Versions and updates

- A project calls the package at a major tag, `@v1`
  - every `v1.x.y` release moves `v1`, so the project runs it on its next workflow run, with no change of its own
  - the script and prompts come from the same commit as the workflow (`job.workflow_sha`), so they never mix versions
  - a runner that doesn't fill `job.workflow_sha` (some self-hosted mirrors) checks out `v1`: same result for `@v1`
- A new major (`v2`) changes what a project must hold: a caller input, a setting, a label
  - the daily sweep compares the project's `uses:` lines with the package's latest release
    (`autopilot.sh update-check`), and opens the issue "Autopilot: move to v2"
  - the project's own worker builds that issue from the release notes; its judge checks it like any PR
  - one issue per major, ever: closing it declines the move, reopening it brings it back
- Releasing the package
  - patch: a fix; minor: something new that changes nothing for a project that sets nothing; major: anything else
  - push the tag: `git tag v1.4.0 && git push origin v1.4.0`. `release.yml` publishes the release with notes from the
    merged PRs and moves `v1` to it
  - a major's release notes say, step by step, what a project must change: that text is the worker's brief
