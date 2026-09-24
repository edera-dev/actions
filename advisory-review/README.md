# Advisory review

Two advisory checks for pull requests, shared by every repository that opts in:

- **PR review** reads the diff for serious defects, supply-chain changes,
  work quietly skipped, and tests that do not test anything.
- **Test coverage** asks whether the checks that exist would fail if the change
  were wrong, and names the one that is missing if they would not.

Both post into a single comment-only review on the pull request, one section
each, updated in place on every push. Neither can approve a pull request,
request changes on one, or turn one red.

## How it runs

`.github/workflows/advisory-review.yml` is a reusable workflow. Each check runs
as two jobs:

- `review` runs the model. Its token can read the repository and the pull
  request and nothing else, and it passes that token to the action explicitly,
  because without one the action exchanges the identity token for an app token
  with contents, pull request and issue write. The model writes its section to
  a file, which is handed over as an artifact.
- `publish` runs no model. It takes the section as data and posts it through
  `post-pr-review.sh`, which fixes the review event to `COMMENT`, keeps the
  other check's section, stamps each section with the commit it reviewed, and
  refuses a body that contains review markers or anything shaped like a
  credential.

The split means text anyone can leave on a public pull request never reaches a
model that holds a token able to write to it. The model can still read its own
environment and has open network egress, so a repository whose cloud
federation trusts identity tokens from pull request runs should scope that
trust to specific workflows.

A reusable workflow gets none of its own repository's files, so both jobs read
`job_workflow_ref` from their identity token and fetch `advisory-review/` from
exactly the commit they were called at.

The review is skipped for fork pull requests, drafts, and events a bot
triggered. If the review was set up to run and produced nothing, the section
says so and links the run log; if the repository has not set the identifiers,
nothing is posted at all.

## Opting a repository in

1. Add `.github/workflows/pr-review.yml`:

   ```yaml
   name: PR review

   on:
     pull_request:
       types: [opened, synchronize, ready_for_review]
       branches: [main]

   permissions:
     contents: read

   concurrency:
     group: pr-review-${{ github.event.pull_request.number }}
     cancel-in-progress: true

   jobs:
     suggestions:
       uses: edera-dev/actions/.github/workflows/advisory-review.yml@<commit>
       permissions:
         contents: read
         pull-requests: write
         id-token: write
       with:
         check: pr-review-suggestions
         federation-rule-id: ${{ vars.PR_REVIEW_FEDERATION_RULE_ID }}
         organization-id: ${{ vars.PR_REVIEW_ORGANIZATION_ID }}
         service-account-id: ${{ vars.PR_REVIEW_SERVICE_ACCOUNT_ID }}
         workspace-id: ${{ vars.PR_REVIEW_WORKSPACE_ID }}

     coverage:
       # the same, with check: pr-test-coverage
   ```

   Pin the workflow to a commit, as for any other action here. Set `branches`
   to where pull requests in that repository actually land.

2. Add `.github/review/focus.md` and `.github/review/test-layers.md`, which say
   what matters in that repository. The easiest start is another repository's
   pair.

3. Set the four `PR_REVIEW_*` variables on the repository. The federation rule
   and service account are per repository; the organization and workspace are
   the same everywhere. Until all four are set, both checks skip quietly.

## The focus file

The review method is fixed and lives in `templates/`. Everything specific to a
repository goes in its focus file, as named sections:

```markdown
<!-- focus: INTRO -->
What this repository is and why a defect in it matters.

<!-- focus: SERIOUS -->
## 1. Serious defects
...
```

A section runs from its marker to the next one. The templates fix the names;
`FORK_SCOPE` is optional and every other section is required. A missing
section, an empty one, or one no template uses fails the run with its name,
rather than dropping out of the review unnoticed.

To see exactly what the model will be given for a repository:

```bash
python3 advisory-review/assemble.py \
  --focus ../other-repo/.github/review/focus.md \
  --test-layers ../other-repo/.github/review/test-layers.md \
  --out /tmp/skills --var REPOSITORY=edera-dev/other-repo --var DEFAULT_BRANCH=main
```

## Tests

`selftest.yml` runs everything in `tests/` on every pull request here:

- `post-pr-review.test.sh` drives the publisher against a fake `gh`.
- `assemble.test.sh` builds the skills from a fixture generated from the
  templates, and from this repository's own focus file.
- `workflow.test.sh` asserts the workflow's permissions, gates, tool
  allowlist and failure handling.
