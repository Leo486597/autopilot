#!/usr/bin/env bash
# The issue agents' plain steps, no model. Run from the project's root; settings come from .github/autopilot.env.
#   autopilot.sh dispatch           start workers on sorted issues, P0 first, while slots are free
#   autopilot.sh sweep              daily: let go of idle P3s, close finished parents, classify what has no kind, dispatch
#   autopilot.sh ping <n> <what>    @-mention the owner on issue or PR <n>; the details come on stdin
#   autopilot.sh settle <pr> <sha> <since>  after the judge: merge a PASS; print `vote` for an UNSURE the voters decide
#   autopilot.sh tally <pr> <sha>   merge on 2 of 3 MERGE votes, else hand the PR to the owner; ping them either way
#   autopilot.sh wait-checks <sha>  wait for CHECKS_WORKFLOW's run on <sha> to finish
#   autopilot.sh board              set every issue's Stage column on the project boards (BOARD_PROJECTS)
#   autopilot.sh unconflict         ask the worker to merge BASE into each ready PR that now conflicts with it
#   autopilot.sh review <pr>        add a merged PR to the review list by hand (REVIEW_LIST)
#   autopilot.sh lock <issue>       lock the release ticket's milestone: it takes every open PR with no milestone
#   autopilot.sh release            refresh each locked milestone's list on its ticket; once all are closed, fire `release`
#   autopilot.sh update-check       open an issue when PACKAGE has a newer major than the project's workflows call
#   autopilot.sh labels [--prune]   make GitHub's labels match .github/labels.yml; --prune deletes the ones not in it
#   autopilot.sh prompt <name> K=V  print prompts/<name>.md plus the project's .github/autopilot/<name>.md, {{K}} filled in
#   autopilot.sh env                print the settings as KEY=value lines, for $GITHUB_ENV
#   autopilot.sh init               copy the starter files into the current repo; never overwrites
# DRY=1 prints what it would change and changes nothing but the locks. gh acts as the agent's GitHub App; PROJECT_TOKEN (the
# owner's, with the `project` scope) edits the boards and starts workflows, which an app can't do for a user-owned project.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
[[ ! -f .github/autopilot.env ]] || { set -a; . .github/autopilot.env; set +a; }
REPO=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}
: "${OWNER:=${REPO%%/*}}"                 # the person the agents work for
: "${BASE:=main}"                         # the branch PRs go into
: "${NEEDS_LABEL:=needs: owner}"          # waits on the owner
: "${BUILDABLE:=^kind: (feature|bug|chore)$}"   # a label matching this gets a worker
: "${AT_ONCE:=3}"                         # workers running together
: "${CLASSIFY_PER_DAY:=5}"                # issues with no kind the sweep hands to the classifier
: "${IDLE_DAYS:=14}"                      # a P3 quiet this long is let go
: "${REVIEW_LIST:=}"                      # issue listing every PR merged without the owner; empty: none
: "${CHECKS_WORKFLOW:=}"                  # the judge waits for this workflow's run on the PR's commit; empty: none
: "${REQUIRED_CHECK:=}"                   # a check that must be green before a merge; empty: none
: "${BOARD_PROJECTS:=}"                   # project numbers whose Stage field `board` keeps; empty: no board
: "${BOARD_ROUTE:=}"                      # `<label regex> <project>`: issues with such a label go to that project
: "${MODEL:=claude-opus-5-5}"
: "${JUDGE_PREPARE:=}"                    # command run from BASE before the judge; it may write files the judge reads
: "${WORKER_SETUP:=}"                     # command run before the worker starts
: "${PACKAGE:=Leo486597/autopilot}"       # where the shared workflows come from; the sweep checks it for a newer major
export REPO OWNER BASE NEEDS_LABEL BUILDABLE
SETTINGS="OWNER BASE NEEDS_LABEL BUILDABLE AT_ONCE CLASSIFY_PER_DAY IDLE_DAYS REVIEW_LIST CHECKS_WORKFLOW REQUIRED_CHECK
  BOARD_PROJECTS BOARD_ROUTE MODEL JUDGE_PREPARE WORKER_SETUP PACKAGE"

MARK='<!-- agent -->'
LOCK=locks/dispatch  # a ref only one dispatcher holds: the refs API refuses to create one that exists
STALE=600          # seconds; a lock older than this was left by a run that died
JQ_DEFS='
def labels: [.labels[].name];
def buildable: labels | any(test($ENV.BUILDABLE));
def starts: [.comments[] | select(.body | test("^\\s*@claude"))];   # each worker run on it, by dispatch or by the owner
def running: any(starts[]; (.createdAt | fromdateiso8601) > now - 3600);   # the worker stops a run after 50 min
# The owner wrote last on an issue whose worker stopped to ask them
def answered: (labels | index($ENV.NEEDS_LABEL)) and (starts | length > 0) and ((.comments | last) as $c
  | $c.author.login == $ENV.OWNER and ($c.body | test("^\\s*(@claude|<!-- agent -->)") | not));
def rank: [.labels[].name | select(startswith("priority: P")) | ltrimstr("priority: P") | tonumber] | first // 9;
'

run() { if [[ "${DRY:-}" == 1 ]]; then echo "DRY: $*" >&2; else "$@" >&2; fi; }   # stdout stays for results
days_ago() { date -u -d "$1 days ago" +%F 2>/dev/null || date -u -v-"$1"d +%F; }

# Ping the owner: a comment that @-mentions them lands in their GitHub notifications
ping() {
  local body; body=$(cat)
  run gh api "repos/$REPO/issues/$1/comments" --silent -f body="$MARK
@$OWNER **$2**

$body"
}
owner_gh() { GH_TOKEN="${PROJECT_TOKEN:-$GH_TOKEN}" gh "$@"; }   # gh as the owner: the boards, and starting a workflow

# Run "$@" holding the dispatch lock, so two dispatchers can't both see the same free slot. A newer one waits here;
# a job-level concurrency group would cancel it instead and mark its whole triage run cancelled.
locked() {
  local held at mine
  while :; do
    if held=$(gh api "repos/$REPO/git/ref/$LOCK" --jq .object.sha 2>/dev/null); then
      at=$(( $(date -u +%s) - $(gh api "repos/$REPO/git/blobs/$held" --jq .content | base64 -d | cut -d' ' -f1) ))
      # Only one waiter can create the -stale- ref for this lock, so only one drops it (and never a newer lock)
      if (( at > STALE )) && gh api "repos/$REPO/git/refs" -f "ref=refs/$LOCK-stale-$held" -f "sha=$held" --silent 2>/dev/null; then
        echo "lock: dropping a stale lock taken ${at}s ago" >&2
        gh api -X DELETE "repos/$REPO/git/refs/$LOCK" --silent || true
        continue
      fi
      echo "lock: another dispatcher has held it for ${at}s, waiting" >&2
    else
      mine=$(gh api "repos/$REPO/git/blobs" -f content="$(date -u +%s) ${GITHUB_RUN_ID:-local} $$" --jq .sha) &&
        gh api "repos/$REPO/git/refs" -f "ref=refs/$LOCK" -f "sha=$mine" --silent && break
    fi
    sleep $(( 5 + RANDOM % 5 ))
  done
  trap unlock EXIT
  echo "lock: taken at $(date -u +%T)" >&2
  local rc
  "$@"; rc=$?   # a failure gets here only under a caller's `||`; anywhere else set -e exits through the trap
  unlock; trap - EXIT   # release as soon as "$@" is done, not at exit
  return $rc
}
unlock() { gh api -X DELETE "repos/$REPO/git/refs/$LOCK" --silent || true; echo "lock: released at $(date -u +%T)" >&2; }
trap 'exit 1' INT TERM   # a cancelled run still goes through the EXIT trap and releases the lock

# An issue with sub-issues is a parent: its work is those, so it gets no worker, and the sweep closes it once they are all closed
open_issues() {
  gh issue list -R "$REPO" --state open --limit 200 --json number,title,url,labels,assignees,comments,updatedAt \
    | jq --argjson subs "$(gh api graphql -F owner="${REPO%%/*}" -F name="${REPO#*/}" -f query='query($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){issues(states:OPEN,first:100){nodes{number subIssuesSummary{total completed}}}}}' \
        --jq '.data.repository.issues.nodes | map({key: "\(.number)", value: .subIssuesSummary}) | from_entries')" \
      "$JQ_DEFS"' map(. + {rank: rank, subs: ($subs["\(.number)"] // {total: 0, completed: 0})}
        | . + {parent: (.subs.completed < .subs.total)}) | sort_by(.rank, .number)'
}

# List issues an open PR says it closes, or that already have a worker's claude/<n>- branch
claimed() {
  { gh pr list -R "$REPO" --state open --json body \
      --jq '.[].body // "" | scan("(?i)(?:close[sd]?|fix(?:e[sd])?) #([0-9]+)\\b") | .[0]'
    gh api "repos/$REPO/git/matching-refs/heads/claude/" --jq '.[].ref | capture("^refs/heads/claude/(?<n>[0-9]+)-")? | .n'
  } | jq -s 'map(tonumber) | unique'
}

dispatch() {
  local open=${1:-$(open_issues)} free n waiting=()
  free=$(( AT_ONCE - $(gh run list -R "$REPO" --workflow claude.yml --limit 100 --json status --jq '[.[] | select(.status != "completed")] | length') ))
  echo "dispatch: $free of $AT_ONCE free now" >&2
  # Resume a worker the owner answered; start one on an unassigned buildable issue with no sub-issues, not waiting on the
  # owner, unclaimed, not running, and tried fewer than twice
  for n in $(jq -r --argjson claimed "$(claimed)" "$JQ_DEFS"'.[] | select((.assignees | length == 0) and buildable and (running | not))
      | if answered then "\(.number):answered"
        elif (.subs.total == 0) and (labels | index($ENV.NEEDS_LABEL) | not) and (starts | length < 2)
          and (.number as $n | $claimed | index($n) | not) then "\(.number)"
        else empty end' <<<"$open"); do
    (( free > 0 )) || { waiting+=("#${n%:answered}"); continue; }
    if [[ "$n" == *:answered ]]; then
      n=${n%:answered}
      run gh issue edit "$n" -R "$REPO" --remove-label "$NEEDS_LABEL"
      run gh issue comment "$n" -R "$REPO" --body "@claude $OWNER answered above: take the answer and carry on, in your open PR for #$n if there is one."
      echo "resumed #$n" >&2
      free=$((free - 1))
      continue
    fi
    run gh issue comment "$n" -R "$REPO" --body "$(prompt fix N="$n")"
    echo "dispatched #$n" >&2
    free=$((free - 1))
    [[ "${DRY:-}" == 1 ]] || sleep 10   # let the worker run register before the next count, ours or the next dispatcher's
  done
  # Show which issues wait for a free worker, in the log and on the run's summary page
  echo "dispatch: waiting for a free worker: ${waiting[*]:-none}" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >&2
}

sweep() {
  local open n
  open=$(open_issues)

  for n in $(jq -r --arg d "$(days_ago "$IDLE_DAYS")" '.[] | select(.rank == 3 and (.assignees | length == 0) and .updatedAt < $d) | .number' <<<"$open"); do
    run gh issue close "$n" -R "$REPO" --reason "not planned" \
      --comment "$MARK
Let go: a P3 with no activity for $IDLE_DAYS days. Reopen it if it still matters."
  done

  for n in $(jq -r '.[] | select(.subs.total > 0 and .subs.completed == .subs.total) | .number' <<<"$open"); do
    run gh issue close "$n" -R "$REPO" --reason completed --comment "$MARK
Closed: all its sub-issues are done. Reopen it if something is left."
  done

  for n in $(jq -r --argjson claimed "$(claimed)" --argjson k "$CLASSIFY_PER_DAY" '[.[] | select((any(.labels[].name; startswith("kind: ")) | not)
             and (.assignees | length == 0) and (.number as $n | $claimed | index($n) | not)) | .number][:$k][]' <<<"$open"); do
    run owner_gh workflow run triage.yml -R "$REPO" -f issue="$n"
  done

  update_check
  locked dispatch   # reads the issues again inside the lock: another dispatcher may have started one since
}

# A newer minor reaches the project by itself (its workflows call @v<major>, which each release moves); a newer major
# changes what the project must hold, so it becomes an issue the worker builds from the release notes
update_check() {
  local used latest title
  used=$(grep -ho "$PACKAGE/\.github/workflows/[a-z-]*\.yml@v[0-9]*" .github/workflows/*.yml | sed 's/.*@v//' | sort -n | head -1 || true)
  [[ -n "$used" ]] || return 0
  latest=$(gh api "repos/$PACKAGE/releases/latest" --jq .tag_name | sed -E 's/^v([0-9]+).*/\1/') || return 0   # no release yet
  (( latest > used )) || return 0
  title="Autopilot: move to v$latest"
  [[ -z $(gh issue list -R "$REPO" --state all --search "in:title \"$title\"" --json number --jq '.[].number') ]] || return 0
  run gh issue create -R "$REPO" --title "$title" --body "This project's workflows call $PACKAGE v$used; v$latest is out.
Move the project to it: the \`uses:\` lines in \`.github/workflows/\`, and whatever the release notes say a project must change.
Release notes: https://github.com/$PACKAGE/releases"
  echo "update-check: v$used → v$latest, issue opened" >&2
}

# The project an issue's card belongs on: BOARD_ROUTE's when a label matches it, else the first of BOARD_PROJECTS
board_for() {
  local labels=$1 route=${BOARD_ROUTE% *} to=${BOARD_ROUTE##* }
  [[ -n "$BOARD_ROUTE" ]] && grep -qE "$route" <<<"$labels" && echo "$to" || echo "${BOARD_PROJECTS%% *}"
}

# Set each issue's Stage on the project boards from what GitHub shows: its state, labels, PR and worker
board() {
  [[ -n "$BOARD_PROJECTS" ]] || return 0
  local wanted p proj open board_owner=${REPO%%/*}
  open=$(open_issues)
  # ponytail: first 100 items per project and 100 open PRs; page when a board outgrows that
  wanted=$(jq -n --slurpfile o <(printf '%s' "$open") \
      --slurpfile p <(gh pr list -R "$REPO" --base "$BASE" --state open --limit 100 --json body,isDraft,labels) "$JQ_DEFS"'
    $o[0] as $open | ($p[0] | map((.body // "") as $b | {draft: .isDraft, owner: ([.labels[].name] | index($ENV.NEEDS_LABEL) != null),
        n: [$b | scan("(?i)(?:close[sd]?|fix(?:e[sd])?) #([0-9]+)\\b") | .[0] | tonumber]}) ) as $p
    | $open | map(.number as $n | ([$p[] | select(.n | index($n))] | first) as $pr | {key: "\($n)", value:
        (if (.assignees | length) > 0 then "Local"
         elif .parent then "Working"
         elif labels | index($ENV.NEEDS_LABEL) then "Needs you"
         elif $pr and $pr.owner then "Needs you"
         elif $pr and ($pr.draft | not) then "In review"
         elif $pr then "Working"
         elif running then "Working"
         elif buildable then "Ready"
         else "New" end)}) | from_entries')
  # Add each labelled open issue to the project it belongs on, if it isn't on one yet
  local have n url labels
  have=$(for p in $BOARD_PROJECTS; do owner_gh api graphql -F owner="$board_owner" -F n="$p" -f query='query($owner:String!,$n:Int!){
    repositoryOwner(login:$owner){... on ProjectV2Owner{projectV2(number:$n){items(first:100){nodes{content{... on Issue{number}}}}}}}}' \
    --jq '.data.repositoryOwner.projectV2.items.nodes[].content.number // empty'; done | jq -s .)
  jq -r --argjson have "$have" '.[] | select((.number as $n | $have | index($n) | not) and any(.labels[].name; startswith("kind: ")))
      | [.number, .url, ([.labels[].name] | join(","))] | @tsv' <<<"$open" \
  | while IFS=$'\t' read -r n url labels; do
      p=$(board_for "$labels")
      run owner_gh project item-add "$p" --owner "$board_owner" --url "$url"; echo "board: #$n added to project $p" >&2
    done
  for p in $BOARD_PROJECTS; do
    # Read each issue's state here, at write time, so a just-closed issue is archived and the board stays under 100 items
    proj=$(owner_gh api graphql -F owner="$board_owner" -F n="$p" -f query='query($owner:String!,$n:Int!){
      repositoryOwner(login:$owner){... on ProjectV2Owner{projectV2(number:$n){id
      field(name:"Stage"){... on ProjectV2SingleSelectField{id options{id name}}}
      items(first:100){nodes{id content{... on Issue{number state}} fieldValueByName(name:"Stage"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}}' \
      --jq '.data.repositoryOwner.projectV2')
    jq -r --argjson w "$wanted" '.id as $pid | .field as $f | select($f) | .items.nodes[] | select(.content.number)
        | if .content.state == "CLOSED" then [$pid, .id, "archive", "-", "#\(.content.number) archived"]
          else $w["\(.content.number)"] as $s | select($s and $s != .fieldValueByName.name)
            | ([$f.options[] | select(.name == $s) | .id] | first) as $o | select($o)
            | [$pid, .id, $f.id, $o, "#\(.content.number) → \($s)"] end | @tsv' <<<"$proj" \
    | while IFS=$'\t' read -r pid item field option what; do
        if [[ "$field" == archive ]]; then run owner_gh project item-archive "$p" --owner "$board_owner" --id "$item"
        else run owner_gh project item-edit --project-id "$pid" --id "$item" --field-id "$field" --single-select-option-id "$option"; fi
        echo "board: $what" >&2
      done
  done
}

MARKED='^\s*<!-- agent -->'

to_owner() {
  run gh pr edit "$1" -R "$REPO" --add-label "$NEEDS_LABEL"
  ping "$1" "$2" <<<"$3"
}

# Wait for CHECKS_WORKFLOW's run on <sha>: up to 5 min for it to register; a run skipped while the PR was a draft doesn't count
wait_checks() {
  [[ -n "$CHECKS_WORKFLOW" ]] || return 0
  local id
  for _ in $(seq 20); do
    id=$(gh run list -R "$REPO" --workflow "$CHECKS_WORKFLOW" --commit "$1" --limit 5 --json databaseId,conclusion \
      --jq 'map(select(.conclusion | IN("skipped", "cancelled") | not))[0].databaseId // empty')
    if [[ -n "$id" ]]; then   # a red run is the judge's to report
      gh run watch "$id" -R "$REPO" > /dev/null || true
      gh run view "$id" -R "$REPO" --json conclusion --jq .conclusion | grep -qvxE 'skipped|cancelled' && return 0
    fi
    sleep 15
  done
}

# The judge's verdict on <sha>, from its own comment posted since <since>: marked, or its FAIL hand-back to the worker
verdict() {
  gh pr view "$1" -R "$REPO" --json comments | jq -r --arg sha "$2" --arg since "$3" --arg m "$MARKED|^\\s*@claude fix the judge's findings" \
    '[.comments[] | select(.createdAt >= $since and (.body | test($m))) | .body
      | capture("### Judge: (?<v>PASS|UNSURE|FAIL) · " + $sha)? | .v] | last // "none"'
}

# After the judge: merge a PASS, send an UNSURE to the vote. Prints `vote` or `done`.
settle() {
  local pr=$1 sha=$2
  case $(verdict "$pr" "$sha" "$3") in
    PASS) merge "$pr" "$sha" ;;
    UNSURE) echo vote; return ;;
    FAIL) ;;   # the judge already handed it back or to the owner
    none) to_owner "$pr" "has no verdict" "The judge ended without a readable card on ${sha:0:7}. Its run is under Actions → judge." ;;
  esac
  echo done
}

merge() {
  local pr=$1 sha=$2 why=${3:-} red
  # Every check but the judge's own must have passed, from every run; pending counts as not green. A CANCELLED check
  # whose workflow has a newer run proves nothing, so it is left out. REQUIRED_CHECK must have run green: a draft's run
  # that skipped every job proves nothing.
  # A check is a check run (GitHub Actions) or a commit status named "<workflow> / <job> (<event>)" (a self-hosted mirror)
  red=$(gh pr view "$pr" -R "$REPO" --json statusCheckRollup | jq -r --arg req "$REQUIRED_CHECK" 'def run: (.detailsUrl // .targetUrl // "") | capture("/runs/(?<r>[0-9]+)").r | tonumber;
        def wf: if (.workflowName // "") != "" then .workflowName else ((.context // "") | split(" / ")[0]) end;
        def nm: .name // ((.context // "") | capture("^.+? / (?<j>.+) \\([a-z_]+\\)$").j // .context);
        [.statusCheckRollup[] | select(wf != "judge")] as $c
        | [$c[] | select(.conclusion == "CANCELLED" and (run as $r | wf as $w | any($c[]; wf == $w and run > $r)) | not)
        | select((.conclusion // .state) | IN("SUCCESS", "SKIPPED", "NEUTRAL") | not)
        | nm]
        + (if $req == "" or any(.statusCheckRollup[]; nm == $req and (.conclusion // .state) == "SUCCESS") then [] else ["\($req) (never ran ready)"] end)
        | join(", ")') \
    || { to_owner "$pr" "didn't merge" "GitHub wouldn't show its checks."; return; }
  if [[ -n "$red" ]]; then
    to_owner "$pr" "didn't merge" "${why:+$why

}Not green: $red"
    return
  fi
  LOCK=locks/merge locked merge_current "$pr" "$sha" || return 0
  [[ -z "$why" ]] || ping "$pr" "merged by vote" <<<"$why"
  [[ -z "$REVIEW_LIST" ]] || LOCK=locks/review locked review_add "$pr" \
    || ping "$REVIEW_LIST" "missed #$pr" <<<"#$pr merged, but the review list couldn't be updated: add it by hand."
}

# Merge <pr> only if its checks ran on today's BASE; else bring the branch up to date, so the new commit gets fresh checks
# and a fresh judge. Held under a lock, so two merges can't both pass on the same old BASE. Returns 1 if not merged
merge_current() {
  local pr=$1 sha=$2 behind
  behind=$(gh api "repos/$REPO/compare/$BASE...$sha" --jq .behind_by) \
    || { to_owner "$pr" "didn't merge" "GitHub wouldn't compare it with $BASE."; return 1; }
  if (( behind > 0 )); then
    # Comment first: the push below starts a new judge run, which cancels this one
    run gh api "repos/$REPO/issues/$pr/comments" --silent -f body="$MARK
Not merged yet: \`$BASE\` has $behind commits that ${sha:0:7} lacks, so its checks never ran with them. Merging \`$BASE\` into the branch; fresh checks and a fresh judge follow."
    run gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" --silent -f expected_head_sha="$sha" \
      || to_owner "$pr" "didn't merge" "$BASE moved since its checks ran, and GitHub couldn't merge $BASE into the branch."
    return 1
  fi
  run gh pr merge "$pr" -R "$REPO" --merge --match-head-commit "$sha" \
    || { to_owner "$pr" "didn't merge" "GitHub refused the merge: a conflict, or a newer commit than the judged one."; return 1; }
}

# Put a merged PR at the top of the review list with its ### Deliverables, and drop the entries the owner has ticked
review_add() {
  local pr=$1 json body deliverables list
  json=$(gh pr view "$pr" -R "$REPO" --json title,body,mergedAt) || return 1
  deliverables=$(jq -r '.body // ""' <<<"$json" | tr -d '\r' | awk '/^#+ *Deliverables/ { on = 1; next } on && /^#/ { exit } on && NF { print "  " $0 }')
  body=$(gh issue view "$REVIEW_LIST" -R "$REPO" --json body --jq .body | tr -d '\r') || return 1
  [[ "$body" == *'<!-- review-list -->'* ]] || return 1
  list=$(mktemp)
  ENTRY="- [ ] #$pr $(jq -r '"\(.title) · merged \(.mergedAt[:10])"' <<<"$json")
${deliverables:-  - no Deliverables section in the PR}" awk '
    !added && /<!-- review-list -->/ { print; print ENVIRON["ENTRY"]; added = 1; next }
    /^- \[[xX]\]/ { ticked = 1; next }
    ticked && /^[[:space:]]/ { next }
    { ticked = 0; print }' <<<"$body" > "$list"
  run gh issue edit "$REVIEW_LIST" -R "$REPO" --body-file "$list"
}

# Count this round's votes: marked comments after the latest UNSURE on <sha>, the last one per voter
tally() {
  local pr=$1 sha=$2 votes yes
  votes=$(gh pr view "$pr" -R "$REPO" --json comments | jq -r --arg sha "$sha" --arg m "$MARKED" '
      .comments | (map((.body | test($m)) and (.body | test("### Judge: UNSURE · " + $sha))) | rindex(true)) as $u
      | if $u == null then [] else .[($u + 1):] end
      | map(select(.body | test($m)) | .body
            | capture("### Vote (?<n>[1-3]): (?<v>MERGE|OWNER) · " + $sha + "[^\\n]*\\n\\s*(?<why>[^\\n]*)")?)
      | group_by(.n) | map(last) | .[] | "Vote \(.n): \(.v) — \(.why)"') \
    || { to_owner "$pr" "needs you" "The judge was unsure, and GitHub wouldn't show the votes."; return; }
  yes=$(grep -c '^Vote [1-3]: MERGE' <<<"$votes" || true)
  if (( yes >= 2 )); then
    merge "$pr" "$sha" "The judge was unsure; the vote went $yes of 3 to merge.
$votes"
  else
    to_owner "$pr" "needs you: the vote went $yes of 3 to merge" "The judge was unsure, and fewer than 2 of 3 voters would merge it.
${votes:-No vote was posted.}"
  fi
}

# After a merge into BASE: a ready PR that now conflicts gets `@claude` to merge BASE in. Drafts are left alone: their
# worker or session is still on them, and rebases before marking them ready.
unconflict() {
  local prs n
  for _ in 1 2 3 4 5 6; do   # GitHub works out `mergeable` shortly after the push
    prs=$(gh pr list -R "$REPO" --base "$BASE" --state open --limit 100 --json number,mergeable,isDraft,comments)
    jq -e 'any(.[]; .isDraft == false and .mergeable == "UNKNOWN")' <<<"$prs" >/dev/null || break
    sleep 10
  done
  for n in $(jq -r '.[] | select(.isDraft == false and .mergeable == "CONFLICTING")
      | select(.comments | last | .body // "" | test("^\\s*@claude merge ") | not)   # its worker has not answered yet
      | .number' <<<"$prs"); do
    run gh pr comment "$n" -R "$REPO" --body "@claude merge $BASE into this PR's branch and resolve the conflicts, keeping what both sides meant, then push. Change nothing else."
    echo "unconflict: asked on #$n" >&2
  done
}

# Lock a release ticket's milestone: it takes every open PR no milestone tracks, and the ticket lists them with their status
lock() {
  local n desc pr
  read -r n desc < <(gh api "repos/$REPO/issues/$1" --jq '[.milestone.number, .milestone.description // ""] | @tsv')
  [[ -n $n ]] || { echo "lock: #$1 has no milestone: put it in the release's milestone first" >&2; exit 1; }
  [[ $desc == Locked* ]] || run gh api -X PATCH "repos/$REPO/milestones/$n" --silent -f description="Locked on $(date -u +%F) (#$1): \
the PRs in flight then. Once they all close, the release starts by itself and this milestone closes."
  for pr in $(gh pr list -R "$REPO" --state open --limit 100 --json number,milestone --jq '.[] | select(.milestone == null) | .number'); do
    run gh api -X PATCH "repos/$REPO/issues/$pr" --silent -F milestone="$n"
  done
  # Wait for the milestone's list to catch up: it lags the PRs just added by seconds, while its count doesn't
  for _ in 1 2 3 4 5 6; do
    (( $(gh api "repos/$REPO/issues?milestone=$n&state=all&per_page=100" --jq length) >= \
       $(gh api "repos/$REPO/milestones/$n" --jq '.open_issues + .closed_issues') )) && break
    sleep 5
  done
  release list
}

# One line per item a locked milestone holds: ticked once it is closed, and where an open PR stands
held() {
  gh api "repos/$REPO/issues?milestone=$1&state=all&per_page=100" --jq "sort_by(.number) | .[] | select(.number != $2) | [.number, .state, (.pull_request != null)] | @tsv" \
  | while IFS=$'\t' read -r i state is_pr; do
      if [[ $is_pr == false ]]; then
        [[ $state == closed ]] && echo "- [x] #$i: closed" || echo "- [ ] #$i: open"
        continue
      fi
      gh pr view "$i" -R "$REPO" --json state,isDraft,statusCheckRollup --jq '[.statusCheckRollup[] | .conclusion // .state] as $c
        | if .state == "MERGED" then "- [x] #'"$i"': merged"
          elif .state == "CLOSED" then "- [x] #'"$i"': closed without merging"
          else "- [ ] #'"$i"': \(if .isDraft then "draft" else "ready" end), " + (
            if any($c[]; . == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE" or . == "CANCELLED" or . == "STALE") then "checks red"
            elif any($c[]; . == null or . == "" or . == "PENDING" or . == "EXPECTED") then "checks running"
            elif ($c | length) == 0 then "no checks" else "checks green" end) end'
    done
}

# Each locked milestone: refresh the list on its ticket. Once all but the ticket are closed, fire the `release`
# repository_dispatch, then close the milestone so it ships once, and the ticket. `release list` only refreshes
release() {
  local n title open ticket items body head section tstate treason tmilestone waiting
  gh api "repos/$REPO/milestones?state=open" --jq '.[] | select(.description // "" | test("^Locked.*\\(#[0-9]+\\)"))
      | [.number, .title, .open_issues, (.description | capture("\\(#(?<n>[0-9]+)\\)").n)] | @tsv' \
  | while IFS=$'\t' read -r n title open ticket; do
      items=$(held "$n" "$ticket")
      IFS=$'\t' read -r tstate treason tmilestone < <(gh api "repos/$REPO/issues/$ticket" \
        --jq '[.state, .state_reason // "none", .milestone.number // 0] | @tsv')
      body=$(gh api "repos/$REPO/issues/$ticket" --jq '.body // ""')
      head=${body%%<!-- release-lock -->*}
      section="<!-- release-lock -->
### Locked in [$title](https://github.com/$REPO/milestone/$n)

The release starts by itself once every one below is closed.

$items"
      [[ $body == *"$section" ]] || run gh api -X PATCH "repos/$REPO/issues/$ticket" --silent \
        -f body="${head%"${head##*[![:space:]]}"}

$section"
      waiting=$open; [[ $tstate == open && $tmilestone == "$n" ]] && waiting=$(( open - 1 ))
      # Ship only when the count and the list agree: either can lag the other. A ticket closed as not planned ships nothing
      [[ ${1:-} != list && $treason != not_planned && $waiting == 0 && -n $items && $items != *"- [ ]"* ]] || continue
      run owner_gh api "repos/$REPO/dispatches" --silent -f event_type=release
      run gh api -X PATCH "repos/$REPO/milestones/$n" --silent -f state=closed
      [[ $tstate == closed ]] || run gh issue close "$ticket" -R "$REPO" --comment "$MARK
Everything in $title is closed: the release has started."
      echo "release: every issue in $title is closed, ship started" >&2
    done
}

labels() {
  local want have name color desc
  want=$(grep -E '^[[:space:]]*- \{' .github/labels.yml | sed -E 's/^[[:space:]]*- //' | jq -s .)
  have=$(gh label list -R "$REPO" --limit 200 --json name,color,description)
  jq -r --argjson have "$have" '.[] | . as $l | select($have | any(.name == $l.name and (.color | ascii_downcase) == ($l.color | ascii_downcase)
      and .description == $l.description) | not) | [.name, .color, .description] | @tsv' <<<"$want" \
  | while IFS=$'\t' read -r name color desc; do
      run gh label create "$name" -R "$REPO" --color "$color" --description "$desc" --force; echo "labels: set $name" >&2
    done
  jq -r --argjson want "$want" '.[].name | ascii_downcase as $n | select($want | any(.name | ascii_downcase == $n) | not)' <<<"$have" \
  | while read -r name; do
      if [[ ${1:-} == --prune ]]; then run gh label delete "$name" -R "$REPO" --yes; echo "labels: deleted $name" >&2
      else echo "labels: not in labels.yml: $name (--prune deletes it)" >&2; fi
    done
}

# Print the package's prompt <name>, then the project's own additions, with each {{KEY}} filled from the environment.
# `system` takes none: it goes inside a quoted argument, and the project's CLAUDE.md already reaches the worker
prompt() {
  local name=$1; shift
  (( $# == 0 )) || export "$@"
  { cat "$HERE/prompts/$name.md"; [[ $name == system || ! -f ".github/autopilot/$name.md" ]] || { echo; cat ".github/autopilot/$name.md"; }; } \
    | perl -pe 's/\{\{(\w+)\}\}/$ENV{$1} \/\/ $&/ge'
}

case "${1:-}" in
  dispatch) locked dispatch ;;
  sweep) sweep ;;
  ping) ping "$2" "$3" ;;
  settle) settle "$2" "$3" "$4" ;;
  tally) tally "$2" "$3" ;;
  wait-checks) wait_checks "$2" ;;
  board) board ;;
  unconflict) unconflict ;;
  review) LOCK=locks/review locked review_add "$2" ;;
  lock) LOCK=locks/release locked lock "$2" ;;
  release) LOCK=locks/release locked release ;;
  labels) labels "${2:-}" ;;
  update-check) update_check ;;
  prompt) shift; prompt "$@" ;;
  env) for k in $SETTINGS; do printf '%s=%s\n' "$k" "${!k}"; done ;;
  init) cp -Rn "$HERE/template/." . || true; echo "init: starter files copied; fill in .github/autopilot.env and the three workflows (AGENTS.md § Set up)" ;;
  *) sed -n '2,20p' "$0"; exit 64 ;;
esac
