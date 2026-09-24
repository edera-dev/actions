# What checks this repo has, and what runs on a PR

One workflow checks the actions themselves: `.github/workflows/selftest.yml`,
and it reaches three of the seven. The actions have no unit tests, and there
is no formatter and no linter in CI; the shared review workflow is the one
thing here with tests of its own, described under The review checks
themselves. Knowing which actions that workflow touches, and what it asserts
about them, is the whole job.

## The self-test

`selftest.yml` runs on every pull request and on pushes to `main`. It does two
things, and the second is easy to overlook:

1. It loads an action through a local `uses: ./<action>`. That is what runs the
   runner's own manifest parser, which is the only thing that catches
   `action.yml` template errors — an expression evaluated inside a description
   string, for instance. No offline linter checks this.
2. It then asserts that action's contract: the outputs it emits and the
   environment it sets, using fake credentials where one is needed.

**It covers three of the seven actions**: `report-disk-space`,
`reclaim-disk-space` and `configure-azure-sccache`. `build-and-sign-image`,
`notify-slack`, `push-metrics` and `setup-cargo-make` are loaded by nothing in
CI — not even the manifest parser runs over them, so a template error in one of
those `action.yml` files reaches consumers. Check which side of that line a
change falls on before calling it covered; for the four unexercised actions the
honest answer is that nothing here sees the change.

For the three that are exercised, an input, output or environment effect is
covered if and only if the assertion block mentions it. An action that stops
emitting an output nothing asserts will pass every check here.

## What cannot be checked here

Anything needing a real registry, a real credential, or a real endpoint: the
actual push, the actual signature, the real sccache backend. Those only fail in
a consuming repository. When a change touches one of them, the useful review
comment names what a consumer would see, not a test this repository cannot run.

## The review checks themselves

This repository hosts the shared review workflow that every consuming
repository runs: `.github/workflows/advisory-review.yml` and the files under
`advisory-review/`. `.github/workflows/pr-review.yml` runs it against this
repository's own pull requests. The review checks exercise none of the
actions. Never count them as coverage for a change to an action.

The shared workflow does have tests of its own. `selftest.yml` runs everything
under `advisory-review/tests/` on every pull request: the publisher against a
fake `gh`, the skill assembly against fixture focus files, and the workflow's
permission, allowlist and gating contract. A change under `advisory-review/`
or to `advisory-review.yml` is covered if one of those asserts the behaviour
that changed.

## What has no check at all

- Whether a caller still passes an input this action declares. The runner warns
  on an unknown input and continues, so a rename is invisible from both sides
  until someone notices a missing artifact.
- Whether a default change alters behaviour for existing callers.
- Whether a Python helper handles its failure path.

## Where a gap usually is

- A new output or environment variable that `selftest.yml` does not assert.
- A renamed input or output, where the compatible move is to keep the old one
  working for a release rather than to add a check.
- A step that can succeed having done nothing, with no assertion that it did
  something.
- A failure path in a Python helper that exits zero.
