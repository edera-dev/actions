# Review focus

What the advisory review checks look for in this repository. The shared
workflow in `edera-dev/actions` supplies the review method; this file supplies
everything specific to this repository, and `test-layers.md` beside it says
where checks live and what runs on a pull request.

Each section starts at its `<!-- focus: NAME -->` line and runs to the next
one. The templates under `advisory-review/templates/` in `edera-dev/actions`
fix the names and show where each section lands. `FORK_SCOPE` is optional;
every other section is required, and a name no template uses fails the run.

<!-- focus: INTRO -->
These actions run inside other repositories' jobs, holding those jobs' credentials, and are consumed from the default branch. So does the shared review workflow under `advisory-review/`, which is these checks. A merge here is a deployment to every consumer at once, with no staging and no rollout. Two consequences shape the review: anything that can execute or exfiltrate is serious because it runs next to someone else's secrets, and anything that changes an input, output or default is a compatibility change even when it looks like a tidy-up.

<!-- focus: SERIOUS -->
## 1. Serious defects

Read the whole `action.yml`, not just the hunk, and then ask what a caller sees. The two questions that matter most are what this can execute and what a consumer has to change.

**An input that reaches a shell.** `${{ inputs.x }}` interpolated directly into a `run:` block is substituted before bash sees it, so the value is parsed as shell. Inside a composite action the value came from a caller in another repository, which may itself have taken it from a pull request title, a branch name, or a dispatch input. It must go through `env:` and be referenced as `"$X"`. This is the highest-value class in this repository and it is easy to introduce by accident when adding a new input to an existing script block.

**A secret reaching somewhere it can be read.** A credential echoed, written to `$GITHUB_OUTPUT`, `$GITHUB_ENV`, the step summary, or a file left in the workspace, or passed as a command-line argument where it shows in the process list. `configure-azure-sccache` deliberately returns a connection string as an output; anything of that shape needs `::add-mask::` before it is ever printed, and a reviewer should check the mask is applied before the first use, not after.

**An input renamed, removed, or made required.** A caller passing an input the action no longer declares gets a warning, not an error, and the run continues with the default. The step then succeeds while doing nothing, in every consumer, and the first sign is usually a missing artifact rather than a red check. A new required input fails every existing caller. Either way, say which callers have to change and what they see if they do not.

**A default changed.** Every caller that relied on the old default silently changes behaviour on their next run. This includes defaults that look cosmetic — a retry count, a path, a boolean that gates a removal. Name the new behaviour a caller gets without editing anything.

**An output renamed or removed.** Callers read outputs as `steps.x.outputs.y`, and a missing output evaluates to an empty string rather than failing. An empty string in a shell comparison or an `if:` expression usually takes the other branch quietly, so the failure appears as behaviour nobody asked for rather than as an error.

**A step that fails without failing the job.** `continue-on-error`, a trailing `|| true`, a pipeline whose real command is not last, or a missing `set -euo pipefail` in a multi-line `run:`. In a shared action this hides the failure from every consumer at once, and they will read the green check as proof the action did its job.

**Signing, attestation and SBOM correctness.** In `build-and-sign-image`, an image that publishes without being signed, a signature over the wrong digest, or an SBOM that describes a different build removes the link between what was published and what it contains. A conditional that skips signing under some input combination is worth tracing carefully, because the result is a published, unsigned image and a green run.

**A destructive step whose scope widens.** `reclaim-disk-space` removes things from the runner. A removal that starts matching more than it did — a broader glob, a new default of `true`, a path that now resolves somewhere else — deletes something a caller needed later in its own job, and the failure appears in their workflow, not here.

**Permissions and `uses:` inside the action.** A nested `uses:` pinned to a tag or branch rather than a digest runs third-party code inside a job that already has the caller's credentials. Flag any unpinned ref, and any action added that the step could do without.

**Python helpers.** `push.py`, `action.py` and the `sbom/` scripts run with whatever the job has. A new `subprocess` call built from a string, an unvalidated path, an HTTP call without a timeout, or an exception path that exits zero all behave as the shell cases above: quietly wrong rather than failed.

**The shared review workflow.** `.github/workflows/advisory-review.yml` and `advisory-review/` are the review checks every consuming repository runs, pinned by commit. The model's job holds a read-only token and the publishing job runs no model; that split is the only thing standing between text a stranger can write on a public pull request and a token that can write to it. A change that gives the model's job `pull-requests: write` or `contents: write`, stops passing the job's own token to the action (which then mints an app token with contents, pull request and issue write), lets the publishing job run anything other than `post-pr-review.sh` on the model's text, or removes the `COMMENT`-only event from the publisher changes what every consumer's review can do. Say which boundary moves.

<!-- focus: SUPPLY -->
## 2. Supply chain

Real, but rarely "it runs arbitrary shell in a job holding secrets" serious — label these **Supply chain** so severity reads honestly.

A nested `uses:` moved off a digest, a new third-party action, a Python dependency added without obvious need, a tool downloaded inside a step without a checksum.

**On a version bump, check the call sites still match the new interface.** This repository is both a producer and a consumer of that problem: a bump here can drop an input a nested action still receives, and the runner will warn rather than fail. Read the bumped action's manifest at the new ref and compare it to what the step passes.

<!-- focus: SKIPPED_TEST_FORMS -->
An action removed from the self-test, an assertion deleted from its contract block, a step made `continue-on-error`, or a `|| true` appended.

<!-- focus: SUPPRESSION_FORMS -->
An error swallowed (`|| true`, `2>/dev/null`, `continue-on-error`, a bare `except:`), or a condition widened so a step stops running rather than stops failing.

<!-- focus: RIGHT_LEVEL -->
The self-test loads each action and asserts its contract. A new input or output belongs there; a change in what a script computes internally usually does not need more than that.

<!-- focus: NO_TEST_LAYER -->
Some things genuinely cannot be exercised here — anything that needs real credentials or a real registry. Say so plainly and name what a caller would see if it were wrong, rather than proposing a test that would need the credential.

<!-- focus: OUT_OF_SCOPE -->
Style, naming, formatting, and comment wording. Do not restate what a step does.

<!-- focus: CALIBRATION_COST -->
an input that reaches a shell inside a job holding another repository's credentials, or a rename that silently disables a step in every consumer, costs a lot more.

<!-- focus: CANNOT_CHECK_EXAMPLE -->
I could not run the action to see what the step actually emits, so I am reading the manifest

<!-- focus: IMPLICATION_EXAMPLE -->
"the input is renamed, so every caller still passing the old name gets the default instead and Actions only warns, which means the step keeps succeeding while doing nothing" does.

<!-- focus: SERIOUS_DEFINITION -->
a value that can execute inside a job holding a caller's credentials, a secret that can be read, a change that silently disables or alters a step in consuming repositories, a published artifact that loses its signature or its provenance, or a destructive step whose scope widens

<!-- focus: SAY_WHAT_HAPPENS -->
the input value is parsed by bash; the connection string appears unmasked in the log; every caller passing the old name now gets the default; the image publishes unsigned; the tool cache is deleted for callers who never asked

<!-- focus: WRITE_BAD -->
The `remove-toolcache` input's default is declared in `action.yml` as a string, and the condition compares it with `== 'true'`, and this change alters the declared default from `'false'` to `'true'`, which means the comparison...

<!-- focus: WRITE_GOOD -->
Every caller that does not set `remove-toolcache` starts having the tool cache deleted on their next run. The default in `reclaim-disk-space/action.yml` changes from `'false'` to `'true'`, and the removal is gated on that value alone, so a job that later expects a cached toolchain fails in its own repository with no change on its side.

<!-- focus: CLEAN_EXAMPLE -->
A new optional input with a default that preserves current behaviour, and the self-test asserts it. Nothing concerning.

<!-- focus: OUTPUT_EXAMPLE -->
One problem I think should be fixed before merge: the input reaches a shell. The output rename can follow.

**Serious: the `image` input is executed as shell.**

Any caller that passes a value derived from a branch name, a PR title, or a dispatch input hands this action arbitrary commands, running inside their job with their credentials. `build-and-sign-image/action.yml` interpolates `${{ inputs.image }}` directly into the `run:` block, so bash parses it before the script starts.

Passing it through `env:` and using `"$IMAGE"` fixes it; the step two lines above already does it that way.

**Renaming the `digest` output silently breaks callers.**

A caller reading `steps.build.outputs.digest` gets an empty string rather than an error, and an empty string in their `if:` takes the other branch, so their signing step stops running and their run stays green. Keeping the old output as well, set to the same value, makes the rename safe to land before consumers are updated.

<!-- focus: UNKNOWN_EXAMPLE -->
The new step writes the resolved tag to `$GITHUB_ENV`, which makes it visible to every later step in the caller's job. I could not find a caller that treats the tag as sensitive, so I could not establish an exposure. No change requested.

<!-- focus: IMPACT_WORKED_EXAMPLE -->
The input is renamed, so every caller still passing the old name gets the default instead. The runner warns rather than failing, so the step keeps reporting success in each consuming repository while doing nothing, and the first sign is a missing artifact rather than a red check.

<!-- focus: HOW_WRONG -->
- What does a caller that does not change anything see after this merge? Every consumer picks the change up on its next run.
- Is an input, output or default being added, renamed, removed, or changed? Each of those is a compatibility change even when the diff looks like a tidy-up.
- Where does the value come from? A caller's input may itself originate in a branch name, a PR title, or a dispatch field, none of which are trusted.
- What happens on the failure path: the API error, the missing file, the registry rejection, the empty output?
- If this is a bug fix, what exactly was the bug, and what would have failed before the fix?
- Can the step succeed while doing nothing? That is the failure mode this repository produces most often.

<!-- focus: WHERE_TO_LOOK -->
- `.github/workflows/selftest.yml`. It loads an action through a local `uses:`, which is what exercises the runner's manifest parser, and then asserts that action's output and environment contract. It reaches three of the seven actions — `report-disk-space`, `reclaim-disk-space` and `configure-azure-sccache`. The other four are loaded by nothing, so not even the manifest parser runs over them. Check which side of that line the change falls on first; for the three that are covered, a new input or output is covered only if the assertion block mentions it;
- the action's own `action.yml`, for declared inputs, defaults and outputs — the contract a caller depends on;
- the Python helpers next to the action, which sometimes validate their own arguments;
- `advisory-review/tests/`, for a change to the shared review workflow or its files, which `selftest.yml` also runs.

The actions themselves have no unit tests. For a change to one, do not look for a test file; look at whether `selftest.yml` asserts the thing that changed.

<!-- focus: PROPORTIONATE -->
Adding an assertion to the self-test is usually proportionate. Asking for a test that needs a real registry, real credentials, or a real Azure endpoint is not.

<!-- focus: CONDITIONAL_EXAMPLE -->
"A caller that does not set the input picks up the new default on its next run and has its tool cache deleted" names the condition and the result. "This could affect consumers" names neither.

<!-- focus: TWO_SHAPES -->
- **The new contract is not asserted.** The self-test is where an action's inputs, outputs and environment effects are pinned. A new output that nothing reads in `selftest.yml` can stop being emitted and every check here stays green while callers silently receive an empty string.
- **The failure only exists in the caller.** Most of what goes wrong with a shared action goes wrong somewhere else: a renamed input, a changed default, a missing output. Nothing in this repository can observe that. Say which consumer behaviour changes and what they would see, rather than proposing a check this repository cannot run.

<!-- focus: SMALLEST_LAYER -->
Pick the smallest thing that would catch the failure. An assertion in `selftest.yml`, for a new or changed input, output or environment variable. A validation inside the step itself, for an argument the step can check. Keeping an old output alongside a new one, where a rename would otherwise be silent. Do not propose a harness with real credentials.

<!-- focus: COVER_BAD -->
The self-test covers this. It loads the action with fake credentials, asserts the configured output, the rw-mode output and the connection string, and exercises both the safe-defaults and the all-removals paths...

<!-- focus: COVER_GOOD -->
The self-test asserts the new output alongside the existing ones, so an action that stops emitting it fails here.

<!-- focus: CLEAN_NOTHING -->
Nothing here needs a check. It's a comment fix in a manifest.

<!-- focus: GAP_EXAMPLE -->
One gap. I'd add it with this PR, since the output is what callers branch on.

**Nothing asserts the new `digest` output, so it can stop being emitted without failing anything here.**

A caller reading `steps.build.outputs.digest` gets an empty string rather than an error, takes the other branch of its `if:`, and skips signing with a green run. The action can lose the output through any change to the step that sets it, and every check in this repository still passes.

`selftest.yml` already asserts the `configured` and `rw-mode` outputs in its contract block. Adding `digest` there, asserting it is non-empty and looks like a digest, is the assertion that protects against it.
