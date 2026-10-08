# Working on autopilot itself

This repo is the package, and it runs its own issue flow (`.github/workflows/{triage,claude,judge}.yml` call the
`autopilot-*.yml` workflows here at `@main`). `AGENTS.md` is the guide for setting it up in *other* projects; read it to
know what a change must keep working, not as steps to run here.

- A change keeps every existing project working as before: a new setting or input gets a default that does nothing new.
- A new setting goes in the list at the top of `bin/autopilot.sh` and in its `SETTINGS` line, and `AGENTS.md` says which
  rung of § Customize it belongs to.
- Prove a script change with `bash -n bin/autopilot.sh` and a `DRY=1` run of the command you touched; a workflow change
  with `actionlint` if you have it.
- Docs are nested bullets in plain words; each line one fact.
