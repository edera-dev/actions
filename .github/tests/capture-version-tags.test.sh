#!/usr/bin/env bash
# Tests for build-and-sign-image/capture-version-tags.sh.
#
# The case with teeth is a non-release event on a commit that already carries a
# release tag. Emitting version tags there republishes vX.Y.Z/stable/latest onto
# a freshly built digest, which silently moves a released tag off the artifact
# that was released. Nothing else in this repo exercises the action - it needs
# registry credentials and a real build - so this is the only thing standing
# between that regression and protect's release workflow.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="$ROOT/build-and-sign-image/capture-version-tags.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

# A repo whose HEAD carries a release tag: the shape that drifts.
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m released
git -C "$REPO" tag v1.12.0

# Runs the script and echoes the GITHUB_OUTPUT it produced. Errors are surfaced,
# not swallowed - a non-zero exit must not look like a wrong value.
tags_for() {
  local event="$1" out="$WORK/out"
  : >"$out"
  if ! (cd "$REPO" && EVENT="$event" GITHUB_OUTPUT="$out" bash "$SCRIPT") >"$WORK/log" 2>&1; then
    echo "script exited non-zero for event '$event':" >&2
    cat "$WORK/log" >&2
    return 1
  fi
  cat "$out"
}

echo "# a release event tags the release"

out=$(tags_for release) || out=""
for expected in \
  "protect_version_tag_full_with_v=v1.12.0" \
  "protect_version_tag_full_no_v=1.12.0" \
  "protect_version_tag_major_minor=1.12" \
  "protect_version_tag_major=1" \
  "protect_version_tag_stable=stable" \
  "protect_version_tag_latest=latest"; do
  if printf '%s\n' "$out" | grep -qx "$expected"; then
    pass "release emits ${expected%%=*}"
  else
    fail "release did not emit $expected"
  fi
done

echo
echo "# no other event may touch the release tags"

# push, schedule and workflow_dispatch all reach this on an already-tagged
# commit: a release branch sitting at its tag, the nightly, a manual rebuild.
for event in push schedule workflow_dispatch ""; do
  label=${event:-<empty>}
  out=$(tags_for "$event") || out="SCRIPT-FAILED"
  if printf '%s\n' "$out" | grep -q "protect_version_tag_"; then
    fail "event '$label' emitted version tags on an already-tagged commit"
  else
    pass "event '$label' emits no version tags"
  fi
  # The short-sha tag is the one every build must still get.
  if printf '%s\n' "$out" | grep -q "^protect_version="; then
    pass "event '$label' still emits the short-sha tag"
  else
    fail "event '$label' did not emit the short-sha tag"
  fi
done

echo
echo "# release candidates stay narrow"

git -C "$REPO" tag -d v1.12.0 >/dev/null
git -C "$REPO" tag v1.13.0-rc1
out=$(tags_for release) || out=""
if printf '%s\n' "$out" | grep -qx "protect_version_tag_full_with_v=v1.13.0-rc1"; then
  pass "an rc tags its own version"
else
  fail "an rc did not tag its own version"
fi
if printf '%s\n' "$out" | grep -qE "protect_version_tag_(stable|latest|major)="; then
  fail "an rc moved stable/latest/major"
else
  pass "an rc does not move stable/latest/major"
fi

echo
echo "# an untagged commit gets only the short sha"

git -C "$REPO" tag -d v1.13.0-rc1 >/dev/null
git -C "$REPO" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m untagged
out=$(tags_for release) || out=""
if printf '%s\n' "$out" | grep -q "protect_version_tag_"; then
  fail "an untagged commit emitted version tags"
else
  pass "an untagged commit emits no version tags"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$FAILURES check(s) failed"
  exit 1
fi
