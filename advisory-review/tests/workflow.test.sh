#!/usr/bin/env bash
# Static checks on .github/workflows/advisory-review.yml and on the caller
# this repository uses for its own pull requests.
#
# These hold the boundary the whole design rests on: the job that runs the
# model has a token that cannot write and never gets an app token, the job
# that can write runs no model, and nothing either job does can approve a pull
# request, request changes on one, or turn one red.
#
# Run from anywhere: bash advisory-review/tests/workflow.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$DIR/.." && pwd)
WF=${ADVISORY_REVIEW_WORKFLOW:-"$ROOT/.github/workflows/advisory-review.yml"}
CALLER="$ROOT/.github/workflows/pr-review.yml"
PUBLISHER="$DIR/post-pr-review.sh"

failures=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
# check <description> <command...>: the command runs in this shell, so it can
# be one of the predicates below.
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# The extractors read the whole file and never exit early, and every
# predicate captures their output before matching. Piping an extractor into
# `grep -q` under pipefail fails whenever grep finds its match and exits while
# the extractor is still writing, which happens on some platforms and not
# others.

# job <name>: the lines of one job, up to the next job at the same indent.
job() {
  awk -v head="  $1:" '
    $0 == head { on = 1; print; next }
    on && /^  [a-z]/ { on = 0 }
    on { print }
  ' "$WF"
}
# step <job> <step name>: the lines of one step of that job.
step() {
  awk -v jhead="  $1:" -v shead="      - name: $2" '
    $0 == jhead { injob = 1; next }
    injob && /^  [a-z]/ { injob = 0; on = 0 }
    injob && $0 == shead { on = 1; print; next }
    on && /^      - name: / { on = 0 }
    on { print }
  ' "$WF"
}
# permissions <job>: that job's permission lines, sorted and joined.
permissions() {
  local text
  text=$(job "$1")
  printf '%s\n' "$text" | awk '
    /^    permissions:/ { on = 1; next }
    on && /^      [a-z-]+: / { sub(/^ +/, ""); print; next }
    on { on = 0 }
  ' | sort | tr '\n' ' '
}
steps_of() {
  local text
  text=$(job "$1")
  printf '%s\n' "$text" | sed -n 's/^      - name: //p'
}

job_has() { local t; t=$(job "$1"); grep -qF -- "$2" <<<"$t"; }
job_lacks() { local t; t=$(job "$1"); ! grep -qF -- "$2" <<<"$t"; }
step_has() { local t; t=$(step "$1" "$2"); grep -qF -- "$3" <<<"$t"; }
step_lacks() { local t; t=$(step "$1" "$2"); ! grep -qF -- "$3" <<<"$t"; }
step_matches() { local t; t=$(step "$1" "$2"); grep -qE -- "$3" <<<"$t"; }
step_exists() { [ -n "$(step "$1" "$2")" ]; }
permissions_are() { [ "$(permissions "$1")" = "$2" ]; }
tools_lack() {
  local text tools
  text=$(step review 'Build the prompt')
  tools=$(grep -o "tools='[^']*'" <<<"$text")
  [ -n "$tools" ] && ! grep -qE -- "$1" <<<"$tools"
}
fetch_steps_match() {
  local a b
  a=$(step review 'Fetch the review files' | sed -n '/run: |/,$p')
  b=$(step publish 'Fetch the review files' | sed -n '/run: |/,$p')
  [ -n "$a" ] && [ "$a" = "$b" ]
}
only_trigger_is_workflow_call() {
  [ "$(sed -n '/^on:$/,/^[a-z]/p' "$WF" | grep -cE '^  [a-z_]+:$')" = 1 ] \
    && grep -qE '^  workflow_call:$' "$WF"
}
no_forbidden_names() {
  # The action being called and its own input names are the one exception.
  ! grep -rniE 'protect|anthropic|claude' "$WF" "$CALLER" "$DIR" \
    | grep -viE 'protects|protection|protected|uses: anthropics/claude-code-action@|anthropic_[a-z_]+_id:|claude_args:|tests/workflow\.test\.sh'
}

echo "# the workflow is only ever called"
check "it triggers on workflow_call and nothing else" only_trigger_is_workflow_call
check "no pull_request_target in the workflow" bash -c "! grep -q pull_request_target '$WF'"
check "or in the caller" bash -c "! grep -q pull_request_target '$CALLER'"
check "no secret is read" bash -c "! grep -qE 'secrets\\.' '$WF'"
check "top-level permissions are empty" grep -qE '^permissions: \{\}$' "$WF"

echo "# the review job runs the model and cannot write"
check "exactly contents read, pull requests read, identity token" \
  permissions_are review "contents: read id-token: write pull-requests: read "
check "fork pull requests are skipped" job_has review 'github.event.pull_request.head.repo.full_name == github.repository'
check "drafts are skipped" job_has review 'github.event.pull_request.draft == false'
check "events a bot triggered are skipped" job_has review "!endsWith(github.actor, '[bot]')"
check "the model step exists" step_exists review Review
check "it passes this job's own token, so no app token is minted" \
  step_matches review Review '^ +github_token: \$\{\{ github\.token \}\}$'
check "nothing is posted from the model step" step_has review Review "classify_inline_comments: 'false'"
check "the model step is continue-on-error" step_has review Review 'continue-on-error: true'
check "the review job never runs the publisher" job_lacks review 'post-pr-review.sh'
check "the model's tools include no unrestricted git" tools_lack 'Bash\(git:\*\)'
check "or anything that runs the publisher" tools_lack 'post-pr-review'
check "or a pull request write command" tools_lack 'gh pr (comment|review|edit|merge|close)'
check "the prompt tells the model it cannot post" step_has review 'Build the prompt' 'You cannot post to the pull request'
check "the section is handed over only when one was written" \
  step_has review 'Hand the section over' "steps.state.outputs.state == 'section'"
check "the outcome is recorded on every end of the job" step_has review 'Record the outcome' 'if: always()'

# Everything that can fail for a reason other than a broken caller must not
# turn the job red. The input check is the one step allowed to.
while IFS= read -r name; do
  case "$name" in
    'Harden runner' | 'Check the inputs' | 'Record the outcome') continue ;;
  esac
  check "review step '$name' is continue-on-error" step_has review "$name" 'continue-on-error: true'
done < <(steps_of review)

echo "# the publish job can write and runs no model"
check "exactly pull requests write and the identity token" \
  permissions_are publish "id-token: write pull-requests: write "
check "it runs no model" job_lacks publish 'claude-code-action'
check "it waits for the review" job_has publish 'needs: review'
check "it is skipped when a newer push cancelled the run" job_has publish '!cancelled()'
check "and when the review job was skipped" job_has publish "needs.review.result != 'skipped'"
check "it posts through the publisher" step_has publish Publish 'post-pr-review.sh'
check "the unfinished note never overwrites a section this head has" \
  step_has publish Publish '--only-if-unstamped'
while IFS= read -r name; do
  case "$name" in
    'Harden runner' | 'Decide what to post') continue ;;
  esac
  check "publish step '$name' is continue-on-error" step_has publish "$name" 'continue-on-error: true'
done < <(steps_of publish)

echo "# both jobs fetch the review files the same way"
check "the two fetch steps run the same script" fetch_steps_match
check "and fetch the commit the identity token names" step_has review 'Fetch the review files' 'job_workflow_ref'

echo "# the names agree across the publisher, the workflow and the caller"
for name in pr-review-suggestions pr-test-coverage; do
  check "the publisher knows section $name" grep -qE "^SECTIONS=\\(.*\\b$name\\b" "$PUBLISHER"
  check "the workflow accepts check $name" step_has review 'Check the inputs' "$name)"
  check "the caller runs check $name" grep -qE "^      check: $name$" "$CALLER"
done
for skill in pr-review test-coverage-review; do
  check "the workflow's skill $skill has a template" test -f "$DIR/templates/$skill.md"
  check "and the workflow names it" step_has review 'Check the inputs' "skill=$skill"
done

echo "# this repository's caller"
check "it calls the workflow on its own branch, once per check" \
  test "$(grep -c 'uses: ./.github/workflows/advisory-review.yml' "$CALLER")" = 2
check "it runs on pull requests to main" grep -qE "^    branches: \\[main\\]$" "$CALLER"
check "it grants each check exactly what the jobs need" \
  test "$(grep -cE '^      (contents: read|pull-requests: write|id-token: write)$' "$CALLER")" = 6
check "a newer push cancels the older run" grep -qE '^  cancel-in-progress: true$' "$CALLER"

echo "# the names this code must not carry"
check "no internal product or vendor name outside the action's interface" no_forbidden_names

echo
if [ "$failures" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed" >&2
  exit 1
fi
