#!/usr/bin/env bash
# Tests for linear-autotrack/autotrack.sh.
#
# Runs the script against a fake gh and a fake Linear API (tests/fake-bin),
# which serve fixtures from a scratch directory and log every call, then checks
# what the script sent to Linear and posted on the pull request.
#
# Run from anywhere: bash linear-autotrack/tests/autotrack.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../autotrack.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Copied rather than used in place: a file committed through the GitHub API
# loses its executable bit.
mkdir -p "$WORK/bin"
cp "$HERE/fake-bin/gh" "$HERE/fake-bin/curl" "$WORK/bin/"
chmod +x "$WORK/bin/gh" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export FAKE="$WORK/fake"

failures=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
check() {
  # check <description> <command...>; the command's exit status is the verdict.
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

PR_URL=https://github.com/edera-dev/example/pull/8
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
NOW=$(date +%s)

reset() {
  rm -rf "$FAKE"
  mkdir -p "$FAKE/linear" "$FAKE/issues"
  : >"$FAKE/linear.log"
  : >"$FAKE/gh.log"
  : >"$FAKE/comments.log"
  export GITHUB_EVENT_NAME=pull_request
  export GITHUB_EVENT_PATH="$FAKE/event.json"
  export GITHUB_STEP_SUMMARY="$FAKE/summary.md"
  export LINEAR_API_KEY=lin_test_key
  export TEAM=cor
  export GRACE_MINUTES=0
  event opened
  pr
  linear_fixture Teams '{"data":{"teams":{"nodes":[
    {"id":"team-cor","key":"COR"},{"id":"team-inf","key":"ENGINFR"},{"id":"team-prt","key":"PRT"}]}}}'
  linear_fixture PrIssues '{"data":{"attachmentsForURL":{"nodes":[]}}}'
  team_setup "$((NOW + 7 * 86400))"
  linear_fixture Users '{"data":{"users":{"nodes":[
    {"id":"user-alice","name":"Alice","email":"alice@edera.dev"},
    {"id":"user-bob","name":"Bob","email":"bob@edera.dev"}],
    "pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
  linear_fixture CreateIssue '{"data":{"issueCreate":{"success":true,
    "issue":{"id":"issue-new","identifier":"COR-500","url":"https://linear.app/edera/issue/COR-500/x"}}}}'
  linear_fixture LinkPr '{"data":{"attachmentLinkGitHubPR":{"success":true}}}'
  linear_fixture LinkUrl '{"data":{"attachmentCreate":{"success":true}}}'
  linear_fixture SetIssueState '{"data":{"issueUpdate":{"success":true,"issue":{"identifier":"COR-1"}}}}'
}

linear_fixture() { printf '%s\n' "$2" >"$FAKE/linear/$1.json"; }

team_setup() {
  # team_setup <active cycle end, epoch seconds or "none">
  local active=''
  if [ "$1" != none ]; then
    active="{\"id\":\"cycle-active\",\"name\":\"27K\",\"number\":4,\"isActive\":true,\"isNext\":false,\"endsAt\":\"$(iso "$1")\"},"
  fi
  linear_fixture TeamSetup "{\"data\":{\"team\":{
    \"labels\":{\"nodes\":[{\"id\":\"label-auto\",\"name\":\"auto-tracked\"}]},
    \"states\":{\"nodes\":[
      {\"id\":\"state-review\",\"name\":\"In Review\",\"type\":\"started\",\"position\":5},
      {\"id\":\"state-progress\",\"name\":\"In Progress\",\"type\":\"started\",\"position\":2},
      {\"id\":\"state-todo\",\"name\":\"Todo\",\"type\":\"unstarted\",\"position\":1},
      {\"id\":\"state-released\",\"name\":\"Released\",\"type\":\"completed\",\"position\":9},
      {\"id\":\"state-done\",\"name\":\"Done\",\"type\":\"completed\",\"position\":3}]},
    \"cycles\":{\"nodes\":[$active
      {\"id\":\"cycle-next\",\"name\":null,\"number\":5,\"isActive\":false,\"isNext\":true,
       \"endsAt\":\"$(iso "$((NOW + 21 * 86400))")\"}]}}}}"
}

event() {
  # event <action> [jq edits applied to the pull request]
  jq -n --arg action "$1" --arg url "$PR_URL" '{
    action: $action,
    repository: {full_name: "edera-dev/example"},
    pull_request: {
      html_url: $url, draft: false, merged: false,
      title: "vtd: restore an assignment check", body: "The check was lost in a rework.",
      head: {ref: "alice/vtd-assign"}, user: {login: "alice", type: "User"}
    }}' | jq "${2:-.}" >"$FAKE/event.json"
}

pr() {
  # pr [jq edits]: what gh pr view prints, as opened.
  jq -n '{
    headRefName: "alice/vtd-assign", title: "vtd: restore an assignment check",
    body: "The check was lost in a rework.\n\nSigned-off-by: Alice <alice@edera.io>",
    state: "OPEN", isDraft: false, author: {login: "alice"}, comments: [],
    commits: [
      {authors: [{login: "alice", email: "Alice@edera.io"}]},
      {authors: [{login: "mallory", email: "bob@edera.dev"}]}]}' |
    jq "${1:-.}" >"$FAKE/pr.json"
}

run() { bash "$SCRIPT" >"$FAKE/out" 2>&1; }
called() { grep -q "^$1 " "$FAKE/linear.log"; }
not_called() { ! called "$1"; }
sent() {
  # sent <operation> <jq predicate over the variables>
  grep -m 1 "^$1 " "$FAKE/linear.log" | cut -d" " -f2- | jq -e "$2"
}
commented() { grep -qF -- "$1" "$FAKE/comments.log"; }
no_comment() { [ ! -s "$FAKE/comments.log" ]; }
output_has() { grep -qF -- "$1" "$FAKE/out"; }

echo "# an untracked pull request gets an issue, a link and one comment"
reset
check "exits 0" run
check "files in the configured team" sent CreateIssue '.input.teamId == "team-cor"'
check "uses the pull request title" sent CreateIssue '.input.title == "vtd: restore an assignment check"'
check "applies the auto-tracked label" sent CreateIssue '.input.labelIds == ["label-auto"]'
check "uses the first started state" sent CreateIssue '.input.stateId == "state-progress"'
check "uses the active cycle" sent CreateIssue '.input.cycleId == "cycle-active"'
check "assigns the author through an edera.io commit email" sent CreateIssue '.input.assigneeId == "user-alice"'
check "copies the body into the description" sent CreateIssue \
  '.input.description | startswith("The check was lost in a rework.")'
check "names the pull request in Source" sent CreateIssue \
  ".input.description | contains(\"* PR: $PR_URL\")"
check "links the author without a mention" sent CreateIssue \
  '.input.description | contains("* Author: [alice](https://github.com/alice)")'
check "signs the description" sent CreateIssue \
  '.input.description | contains("Auto-created by linear-autotrack")'
check "links the pull request to the new issue" sent LinkPr \
  ".issueId == \"issue-new\" and .url == \"$PR_URL\""
check "does not fall back to a URL link" not_called LinkUrl
check "comments with the marker" commented '<!-- linear-autotrack-marker -->'
check "comments with the issue and cycle" commented \
  'Tracked in Linear as [COR-500](https://linear.app/edera/issue/COR-500/x), in cycle 27K.'
check "names no GitHub user in the comment" bash -c "! grep -q '@' \"\$FAKE/comments.log\""
check "comments exactly once" test "$(grep -c 'linear-autotrack-marker' "$FAKE/comments.log")" = 1
check "writes a step summary" grep -q 'Filed COR-500' "$FAKE/summary.md"

echo "# a key from any team, anywhere in the pull request, counts as tracked"
for edit in '.head.ref = "kavi/cor-185-linear-autotrack"' \
  '.title = "PRT-12: fix the thing"' '.body = "Part of engInfr-77."'; do
  reset
  event opened "$(printf '.pull_request |= (%s)' "$edit")"
  check "skips when $edit" run
  check "files nothing when $edit" not_called CreateIssue
  check "leaves no comment when $edit" no_comment
done

echo "# text that only looks like a key does not"
reset
event opened '.pull_request.head.ref = "fix/edera-6.18-utf-8" | .pull_request.body = "See CVE-2026-1234 and x86-64."'
pr '.headRefName = "fix/edera-6.18-utf-8" | .body = "See CVE-2026-1234 and x86-64."'
check "exits 0" run
check "files an issue" called CreateIssue

echo "# a linear.app link counts as tracked"
reset
event opened '.pull_request.body = "Tracked at https://linear.app/edera/issue/SOME-1/x"'
check "exits 0" run
check "files nothing" not_called CreateIssue

echo "# a closed GitHub issue that mirrors a Linear issue counts as tracked"
reset
event opened '.pull_request.body = "Fixes #12"'
echo '{"number":12,"pull_request":null}' >"$FAKE/issues/12.json"
printf '%s\n' '[{"body":"<!-- linear-linkback -->\nPRT-9"}]' >"$FAKE/issues/12-comments.json"
check "exits 0" run
check "files nothing" not_called CreateIssue

echo "# a linkback on a pull request rather than an issue does not count"
reset
event opened '.pull_request.body = "Fixes #13"'
pr '.body = "Fixes #13"'
echo '{"number":13,"pull_request":{"url":"x"}}' >"$FAKE/issues/13.json"
printf '%s\n' '[{"body":"<!-- linear-linkback -->\nPRT-9"}]' >"$FAKE/issues/13-comments.json"
check "exits 0" run
check "files an issue" called CreateIssue

echo "# drafts and bots are left alone, without calling Linear"
reset
event opened '.pull_request.draft = true'
check "draft exits 0" run
check "draft makes no Linear call" test ! -s "$FAKE/linear.log"
reset
event opened '.pull_request.user = {login: "edera-rebase-app[bot]", type: "Bot"}'
check "bot exits 0" run
check "bot makes no Linear call" test ! -s "$FAKE/linear.log"
reset
event ready_for_review
check "ready_for_review files an issue" run
check "ready_for_review called CreateIssue" called CreateIssue

echo "# a pull request this already commented on is not filed again"
reset
pr '.comments = [{body: "<!-- linear-autotrack-marker -->\nTracked in Linear as COR-1."}]'
check "exits 0" run
check "files nothing" not_called CreateIssue

echo "# a key added during the wait counts"
reset
pr
jq '.title = "COR-77: vtd: restore an assignment check"' "$FAKE/pr.json" >"$FAKE/pr-fresh.json"
check "exits 0" run
check "files nothing" not_called CreateIssue
check "says why" output_has 'named while waiting'

echo "# a pull request closed during the wait is not filed"
reset
jq '.state = "CLOSED"' "$FAKE/pr.json" >"$FAKE/pr-fresh.json"
check "exits 0" run
check "files nothing" not_called CreateIssue

echo "# an issue that links the pull request from Linear counts as tracked"
reset
linear_fixture PrIssues '{"data":{"attachmentsForURL":{"nodes":[{"issue":{"identifier":"COR-9"}}]}}}'
check "exits 0" run
check "files nothing" not_called CreateIssue
check "names the linked issue" output_has 'COR-9'

echo "# cycle choice"
reset
team_setup "$((NOW + 24 * 3600))"
check "exits 0 with a nearly finished cycle" run
check "uses the next cycle when the active one ends within 48h" sent CreateIssue '.input.cycleId == "cycle-next"'
check "names an unnamed cycle by number" commented 'in cycle 5.'
reset
team_setup none
check "exits 0 between cycles" run
check "uses the next cycle when none is active" sent CreateIssue '.input.cycleId == "cycle-next"'
reset
linear_fixture TeamSetup '{"data":{"team":{"labels":{"nodes":[]},"states":{"nodes":[]},"cycles":{"nodes":[]}}}}'
check "exits 0 for a team without cycles, states or the label" run
check "omits cycle and state, sends no labels" sent CreateIssue \
  '(.input | has("cycleId") | not) and (.input | has("stateId") | not) and .input.labelIds == []'
check "warns about the missing label" output_has 'no auto-tracked label'

echo "# assignee"
reset
pr '.commits = [{authors: [{login: "alice", email: "alice@example.com"}]}]'
check "exits 0 with no matching user" run
check "leaves the issue unassigned" sent CreateIssue '.input | has("assigneeId") | not'
check "says so on the pull request" commented 'so it is unassigned'
reset
echo 500 >"$FAKE/linear/Users.status"
check "exits 0 when the user lookup fails" run
check "still files the issue, unassigned" sent CreateIssue '.input | has("assigneeId") | not'

echo "# description"
reset
long=$(printf 'line %04d of a long description\n' $(seq 1 200))
pr ".body = \"<!-- template: describe the change -->\\n\" + $(jq -Rs . <<<"$long")"
check "exits 0" run
check "drops HTML comments" sent CreateIssue '.input.description | contains("template:") | not'
check "cuts a long body at a line boundary" sent CreateIssue \
  '.input.description | test("of a long description\n\n\\(Cut short\\. The pull request has the full description\\.\\)")'
check "keeps the description under the cap plus Source" sent CreateIssue '.input.description | length < 2600'
reset
pr '.body = null'
check "exits 0 with an empty body" run
check "starts the description at Source" sent CreateIssue '.input.description | startswith("## Source")'

echo "# linking falls back to a URL attachment"
reset
linear_fixture LinkPr '{"errors":[{"message":"repository not connected"}]}'
check "exits 0" run
check "attaches the pull request URL" sent LinkUrl \
  ".issueId == \"issue-new\" and .url == \"$PR_URL\" and .title == \"vtd: restore an assignment check\""
check "still comments" commented 'COR-500'
reset
linear_fixture LinkPr '{"errors":[{"message":"no"}]}'
echo 400 >"$FAKE/linear/LinkUrl.status"
check "exits 0 when both links fail" run
check "warns that it will not close on merge" output_has 'will not close when the pull request merges'
check "still comments, so a rerun files nothing" commented 'linear-autotrack-marker'

echo "# a failed create leaves no comment and fails the run"
reset
echo 400 >"$FAKE/linear/CreateIssue.status"
check "exits non-zero" bash -c "! bash '$SCRIPT'"
check "leaves no comment" no_comment

echo "# merge moves only this action's open issue for this exact PR to Done"
reset
event closed '.pull_request.merged = true'
sig='_Auto-created by linear-autotrack because this pull request had no Linear issue._'
linear_fixture PrIssues "$(jq -n --arg url "$PR_URL" --arg sig "$sig" '
  def issue($id; $type; $desc): {issue: {id: $id, identifier: $id, team: {id: "team-cor"},
    state: {type: $type}, description: $desc}};
  {data: {attachmentsForURL: {nodes: [
    issue("ours"; "started"; "Body\n\n## Source\n\n* PR: [\($url)](<\($url)>)\n\n\($sig)"),
    issue("other-pr"; "started"; "* PR: \($url)3\n\n\($sig)"),
    issue("by-hand"; "started"; "Linked by a person to \($url)"),
    issue("finished"; "completed"; "* PR: \($url)\n\n\($sig)"),
    issue("body-names-us"; "started";
      "Companion to \($url)\n\n## Source\n\n* PR: \($url)3\n\n\($sig)"),
    issue("ours"; "started"; "Body\n\n## Source\n\n* PR: [\($url)](<\($url)>)\n\n\($sig)")]}}}')"
check "exits 0" run
check "updates exactly one issue" test "$(grep -c '^SetIssueState ' "$FAKE/linear.log")" = 1
check "updates the auto-filed issue" sent SetIssueState '.id == "ours"'
check "moves it to the first completed state" sent SetIssueState '.stateId == "state-done"'
check "does not comment" no_comment

echo "# a merge with nothing filed, and a close without merge, change nothing"
reset
event closed '.pull_request.merged = true'
check "exits 0 with nothing to close" run
check "updates nothing" not_called SetIssueState
reset
event closed
check "exits 0 when closed unmerged" run
check "makes no Linear call" test ! -s "$FAKE/linear.log"

echo "# configuration"
reset
export LINEAR_API_KEY=''
check "no key exits 0" run
check "no key warns" output_has '::warning::No Linear API key'
check "no key makes no call" test ! -s "$FAKE/linear.log"
reset
export TEAM=NOPE
check "an unknown team fails" bash -c "! bash '$SCRIPT'"
reset
export GRACE_MINUTES=ten
check "a bad grace period fails" bash -c "! bash '$SCRIPT'"
reset
export GITHUB_EVENT_NAME=push
check "a non pull_request event fails" bash -c "! bash '$SCRIPT'"
reset
export GITHUB_EVENT_NAME=pull_request_target
check "pull_request_target is refused" bash -c "! bash '$SCRIPT'"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
