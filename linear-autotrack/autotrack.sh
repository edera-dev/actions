#!/usr/bin/env bash
# Files a Linear issue for a pull request opened without one, and moves that
# issue to Done when the pull request merges. action.yml describes the inputs.
#
# Runs no model. The pull request's title and body are copied into the issue
# as data and never reach a shell or a GraphQL document.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINEAR_URL=https://api.linear.app/graphql

# The marker stops a later run on the same pull request filing a second issue.
# The signature is how the merge step tells an issue this action filed from one
# a person linked to the pull request, which it leaves alone.
MARKER='<!-- linear-autotrack-marker -->'
SIGNATURE='Auto-created by linear-autotrack'

# An active cycle with less than this left is nearly over, so the issue goes
# into the next one.
CYCLE_CUTOFF_SECONDS=$((48 * 3600))

: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is not set}"
TEAM=${TEAM:-}
GRACE_MINUTES=${GRACE_MINUTES:-10}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

note() {
  echo "$*"
  echo "$*" >>"$SUMMARY"
}

linear() {
  # linear <operation> [variables-json]: sends graphql/<operation>.graphql and
  # prints the response. Fails on an HTTP error or a GraphQL error.
  local op=$1 vars=${2:-'{}'} status
  jq -n --rawfile q "$HERE/graphql/$op.graphql" --argjson v "$vars" \
    '{query: $q, variables: $v}' >"$WORK/request.json"
  # Read from a file so the key is not on curl's command line.
  printf 'Authorization: %s\n' "$LINEAR_API_KEY" >"$WORK/auth"
  if ! status=$(curl -sS -o "$WORK/response.json" -w '%{http_code}' \
    -H @"$WORK/auth" -H 'Content-Type: application/json' \
    --data-binary @"$WORK/request.json" "$LINEAR_URL"); then
    echo "Could not reach Linear for $op" >&2
    return 1
  fi
  case "$status" in
    2??) ;;
    *)
      echo "Linear returned HTTP $status for $op:" >&2
      cat "$WORK/response.json" >&2
      return 1
      ;;
  esac
  if jq -e '(.errors // []) | length > 0' "$WORK/response.json" >/dev/null; then
    echo "Linear returned errors for $op:" >&2
    cat "$WORK/response.json" >&2
    return 1
  fi
  cat "$WORK/response.json"
}

event=$(cat "$GITHUB_EVENT_PATH")
ev() { jq -r "$1" <<<"$event"; }

case "${GITHUB_EVENT_NAME:-}" in
  pull_request) ;;
  *)
    echo "::error::linear-autotrack runs on pull_request events, not '${GITHUB_EVENT_NAME:-}'"
    exit 1
    ;;
esac
[ -n "$TEAM" ] || {
  echo "::error::The team input is empty."
  exit 1
}
case "$GRACE_MINUTES" in
  '' | *[!0-9]*)
    echo "::error::grace-minutes must be a whole number of minutes, not '$GRACE_MINUTES'"
    exit 1
    ;;
esac
# A pull request from a fork gets no secrets, and a repository can call this
# before its key is set up. Neither is a fault in the pull request.
if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "::warning::No Linear API key reached this run, so the pull request was not checked."
  exit 0
fi

PR_URL=$(ev '.pull_request.html_url')
REPO=$(ev '.repository.full_name')
AUTHOR=$(ev '.pull_request.user.login')

load_teams() {
  # Every team key in the workspace. A key from any team counts as tracked,
  # but text that only looks like a key (edera-6, utf-8) does not.
  local teams
  teams=$(linear Teams | jq -c '[.data.teams.nodes[] | select(.key | test("^[A-Za-z0-9]+$"))]')
  TEAM_ID=$(jq -r --arg k "$TEAM" \
    'first(.[] | select((.key | ascii_upcase) == ($k | ascii_upcase)) | .id) // empty' <<<"$teams")
  if [ -z "$TEAM_ID" ]; then
    echo "::error::No Linear team has the key '$TEAM'."
    exit 1
  fi
  TEAM_KEY=$(jq -r --arg id "$TEAM_ID" '.[] | select(.id == $id) | .key' <<<"$teams")
  KEY_REGEX="(^|[^A-Za-z0-9])($(jq -r 'map(.key) | join("|")' <<<"$teams"))-[0-9]+([^0-9]|$)"
}

has_linear_ref() {
  # has_linear_ref <branch> <title> <body>
  local number numbers
  grep -qiE "$KEY_REGEX" <<<"$1"$'\n'"$2"$'\n'"$3" && return 0
  grep -qiE 'linear\.app/[a-z0-9-]+/issue/' <<<"$3" && return 0
  # A GitHub issue the body closes may be the mirror of a Linear issue, in
  # which case Linear's linkback comment on it carries the key.
  numbers=$(grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?|part[- ]of):?[[:space:]]+#[0-9]+' <<<"$3" |
    grep -oE '[0-9]+$' | sort -un | head -n 5) || true
  for number in $numbers; do
    # The issues endpoint answers for a pull request number too, and another
    # pull request's linkback names that pull request's issue, not this one's.
    if [ -n "$(gh api "repos/$REPO/issues/$number" --jq 'select(.pull_request == null) | .number')" ] &&
      gh api "repos/$REPO/issues/$number/comments" --paginate \
        --jq '.[].body | select(contains("<!-- linear-linkback -->"))' >"$WORK/linkbacks" &&
      grep -qiE "$KEY_REGEX" "$WORK/linkbacks"; then
      return 0
    fi
  done
  return 1
}

assignee_for_author() {
  # Prints the Linear user id for the pull request's author, or nothing. Only
  # emails GitHub has tied to the author's account count, because a commit can
  # claim any email. edera.dev and edera.io addresses compare by local part.
  local emails users='[]' after=null page
  # shellcheck disable=SC2016  # a jq variable, not a shell expansion.
  emails=$(gh pr view "$PR_URL" --json author,commits --jq '.author.login as $me
    | [.commits[].authors[] | select(.login == $me) | .email | ascii_downcase] | unique')
  while :; do
    page=$(linear Users "$(jq -nc --argjson a "$after" '{after: $a}')") || return 1
    users=$(jq -c --argjson acc "$users" '$acc + .data.users.nodes' <<<"$page")
    [ "$(jq -r '.data.users.pageInfo.hasNextPage' <<<"$page")" = true ] || break
    after=$(jq -c '.data.users.pageInfo.endCursor' <<<"$page")
  done
  jq -rn --argjson emails "$emails" --argjson users "$users" '
    def key: ascii_downcase | capture("^(?<local>[^@]+)@(?<domain>.+)$")
      | if .domain == "edera.dev" or .domain == "edera.io"
        then "edera:" + .local else .local + "@" + .domain end;
    ($emails | map(key)) as $want
    | [$users[] | select(.email != null)
        | select((.email | key) as $k | any($want[]; . == $k)) | .id]
    | unique | if length == 1 then .[0] else empty end'
}

track() {
  if [ "$(ev '.pull_request.draft')" = true ]; then
    note "Draft pull request. Marking it ready for review runs this again."
    return 0
  fi
  if [ "$(ev '.pull_request.user.type')" = Bot ] || [[ "$AUTHOR" == *'[bot]' ]]; then
    note "Opened by a bot, so not tracked."
    return 0
  fi

  load_teams
  if has_linear_ref "$(ev '.pull_request.head.ref')" "$(ev '.pull_request.title // ""')" \
    "$(ev '.pull_request.body // ""')"; then
    note "The pull request names a Linear issue."
    return 0
  fi
  gh pr view "$PR_URL" --json comments --jq '.comments[].body' >"$WORK/comments"
  if grep -qF "$MARKER" "$WORK/comments"; then
    note "An issue was already filed for this pull request."
    return 0
  fi

  # The author may be about to add the key. Wait, then check the pull request
  # as it is now rather than as it was opened.
  if [ "$GRACE_MINUTES" -gt 0 ]; then
    echo "No Linear issue named. Checking again in $GRACE_MINUTES minutes."
    sleep "$((GRACE_MINUTES * 60))"
  fi
  local pr
  pr=$(gh pr view "$PR_URL" --json headRefName,title,body,state,isDraft)
  if [ "$(jq -r '.state' <<<"$pr")" != OPEN ] || [ "$(jq -r '.isDraft' <<<"$pr")" = true ]; then
    note "The pull request was closed or turned back into a draft while waiting."
    return 0
  fi
  if has_linear_ref "$(jq -r '.headRefName' <<<"$pr")" "$(jq -r '.title // ""' <<<"$pr")" \
    "$(jq -r '.body // ""' <<<"$pr")"; then
    note "A Linear issue was named while waiting."
    return 0
  fi

  # An issue created in Linear can link the pull request from that side.
  local linked
  linked=$(linear PrIssues "$(jq -n --arg url "$PR_URL" '{url: $url}')" |
    jq -r '[.data.attachmentsForURL.nodes[].issue.identifier // empty] | unique | join(", ")')
  if [ -n "$linked" ]; then
    note "Linked from Linear already: $linked."
    return 0
  fi

  local setup label_ids state_id cycle cycle_id cycle_name assignee_id title description
  setup=$(linear TeamSetup "$(jq -n --arg t "$TEAM_ID" '{teamId: $t}')")
  label_ids=$(jq -c '[.data.team.labels.nodes[] | select(.name == "auto-tracked") | .id]' <<<"$setup")
  [ "$label_ids" != '[]' ] ||
    echo "::warning::Linear team $TEAM_KEY has no auto-tracked label, so the issue is filed without it."
  state_id=$(jq -r '[.data.team.states.nodes[] | select(.type == "started")]
    | sort_by(.position) | first | .id // empty' <<<"$setup")
  cycle=$(jq -c --argjson now "$(date +%s)" --argjson cutoff "$CYCLE_CUTOFF_SECONDS" '
    .data.team.cycles.nodes as $c
    | (first($c[] | select(.isActive)) // null) as $active
    | (first($c[] | select(.isNext)) // null) as $next
    | def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    if $active != null and (($active.endsAt | secs) - $now) >= $cutoff then $active
    else $next // $active end' <<<"$setup")
  cycle_id=$(jq -r '.id // empty' <<<"$cycle")
  cycle_name=$(jq -r 'if . == null then "" else .name // "\(.number)" end' <<<"$cycle")

  if ! assignee_id=$(assignee_for_author); then
    echo "::warning::The Linear user lookup failed, so the issue is unassigned."
    assignee_id=''
  fi

  title=$(jq -r '.title' <<<"$pr")
  description=$(jq -r --arg url "$PR_URL" --arg author "$AUTHOR" --arg sig "$SIGNATURE" \
    --arg key "$TEAM_KEY" '
    (.body // "")
    | gsub("<!--[\\s\\S]*?-->"; "") | gsub("\r"; "") | sub("^\\s+"; "") | sub("\\s+$"; "")
    | if length > 2000
      then (.[0:2000] | sub("\\n[^\\n]*$"; "")) + "\n\n(Cut short. The pull request has the full description.)"
      else . end
    | (if . == "" then "" else . + "\n\n" end)
      + "## Source\n\n* PR: \($url)\n* Author: [\($author)](https://github.com/\($author))\n\n"
      + "_\($sig) because this pull request had no Linear issue. To skip this next time,"
      + " put the issue key (for example \($key)-123) in the branch name or PR title._"' <<<"$pr")

  local input created issue_id identifier issue_url
  input=$(jq -n --arg teamId "$TEAM_ID" --arg title "$title" --arg description "$description" \
    --argjson labelIds "$label_ids" --arg stateId "$state_id" --arg cycleId "$cycle_id" \
    --arg assigneeId "$assignee_id" '
    {teamId: $teamId, title: $title, description: $description, labelIds: $labelIds}
    + (if $stateId == "" then {} else {stateId: $stateId} end)
    + (if $cycleId == "" then {} else {cycleId: $cycleId} end)
    + (if $assigneeId == "" then {} else {assigneeId: $assigneeId} end)')
  created=$(linear CreateIssue "$(jq -n --argjson i "$input" '{input: $i}')")
  issue_id=$(jq -r '.data.issueCreate.issue.id' <<<"$created")
  identifier=$(jq -r '.data.issueCreate.issue.identifier' <<<"$created")
  issue_url=$(jq -r '.data.issueCreate.issue.url' <<<"$created")

  # The link is what the merge step follows, so it goes on before the comment.
  local link_vars linked_ok=true
  link_vars=$(jq -n --arg i "$issue_id" --arg url "$PR_URL" --arg t "$title" \
    '{issueId: $i, url: $url, title: $t}')
  if ! linear LinkPr "$(jq -c '{issueId, url}' <<<"$link_vars")" >/dev/null; then
    echo "Linear's GitHub integration could not link the pull request. Linking it as a URL."
    linear LinkUrl "$link_vars" >/dev/null || linked_ok=false
  fi

  local who where=''
  [ -z "$cycle_name" ] || where=", in cycle $cycle_name"
  if [ -n "$assignee_id" ]; then
    who="Assigned to the PR author."
  else
    who="No Linear user matched the PR author's commit emails, so it is unassigned."
  fi
  {
    echo "$MARKER"
    echo "Tracked in Linear as [$identifier]($issue_url)$where. $who"
    echo
    echo "If this is the wrong issue, edit or close it in Linear. To skip this next time, put the issue key in the branch name or PR title."
  } >"$WORK/comment.md"
  gh pr comment "$PR_URL" --body-file "$WORK/comment.md" >/dev/null
  note "Filed $identifier for $PR_URL$where."

  if [ "$linked_ok" != true ]; then
    echo "::warning::$identifier is not linked to the pull request, so it will not close when the pull request merges."
  fi
}

complete() {
  local found pending issue id key team states done_state
  found=$(linear PrIssues "$(jq -n --arg url "$PR_URL" '{url: $url}')")
  # Only an open issue this action filed for exactly this pull request. One a
  # person linked, or one filed for another pull request, stays as it is. Only
  # the Source section counts, since the copied body can name other PRs.
  pending=$(jq -c --arg url "$PR_URL" --arg sig "$SIGNATURE" '
    [.data.attachmentsForURL.nodes[].issue // empty
      | select(.state.type as $t | any("triage", "backlog", "unstarted", "started"; . == $t))
      | select((.description // "") | contains($sig))
      | select([(.description // "") | split("## Source") | last
          | scan("https://github\\.com/[^/]+/[^/]+/pull/[0-9]+")] | any(. == $url))]
    | unique_by(.id) | .[]' <<<"$found")
  if [ -z "$pending" ]; then
    note "No open issue that linear-autotrack filed for $PR_URL."
    return 0
  fi
  while read -r issue; do
    id=$(jq -r '.id' <<<"$issue")
    key=$(jq -r '.identifier' <<<"$issue")
    team=$(jq -r '.team.id' <<<"$issue")
    states=$(linear TeamSetup "$(jq -n --arg t "$team" '{teamId: $t}')")
    done_state=$(jq -r '[.data.team.states.nodes[] | select(.type == "completed")]
      | sort_by(.position) | first | .id // empty' <<<"$states")
    if [ -z "$done_state" ]; then
      echo "::error::The team $key belongs to has no completed state."
      exit 1
    fi
    linear SetIssueState "$(jq -n --arg id "$id" --arg s "$done_state" '{id: $id, stateId: $s}')" >/dev/null
    note "Moved $key to Done because $PR_URL merged."
  done <<<"$pending"
}

case "$(ev '.action')" in
  opened | reopened | ready_for_review) track ;;
  closed)
    if [ "$(ev '.pull_request.merged')" = true ]; then complete; fi
    ;;
  *) echo "Nothing to do for a '$(ev '.action')' event." ;;
esac
