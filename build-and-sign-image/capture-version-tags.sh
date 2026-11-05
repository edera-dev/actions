#!/usr/bin/env bash
# Decides which tags an image build publishes, and writes them to GITHUB_OUTPUT.
#
# Every build gets the short-sha tag. Version tags (vX.Y.Z, X.Y, X, stable, and
# latest by way of the metadata action's `latest=auto`) are reserved for release
# events: any other trigger that lands on an already-tagged commit would
# otherwise republish them onto a freshly built digest, and Docker builds are
# not bit-for-bit reproducible, so a released tag would end up pointing at an
# artifact that was never released.
#
# Reads EVENT and GITHUB_OUTPUT from the environment; runs in the checked-out
# repo.
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
EVENT="${EVENT:-}"

echo "protect_version=$(git rev-parse --short=7 HEAD)" >>"${GITHUB_OUTPUT}"

if [ "${EVENT}" != "release" ]; then
  echo "Event is '${EVENT}', not 'release': publishing only the short-sha tag."
  exit 0
fi

# This is gross, but it detects whether we're checked out into a tag
# and sets the version tags accordingly. This is for a case of
# rebuilding an image from a tag. The docker metadata action only version
# tags on the "tag" event, it doesn't version tag when we checkout a tag
# on a workflow_dispatch
# See https://github.com/edera-dev/protect/issues/1248
if ! git describe --exact-match --tags &>/dev/null; then
  echo "No tag points at HEAD; publishing only the short-sha tag."
  exit 0
fi

input="$(git describe --exact-match --tags)"
if [[ ! "$input" =~ ^v([0-9]+)(\.([0-9]+))?(\.([0-9]+))?(-rc[0-9]+)?$ ]]; then
  echo "Tag '${input}' is not a version tag; publishing only the short-sha tag."
  exit 0
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[3]}"
patch="${BASH_REMATCH[5]}"
candidate="${BASH_REMATCH[6]}"

# Build version strings
full_with_v="v${major}"
full_no_v="${major}"

if [[ -n "$minor" ]]; then
  full_with_v+=".${minor}"
  full_no_v+=".${minor}"
fi

if [[ -n "$patch" ]]; then
  full_with_v+=".${patch}"
  full_no_v+=".${patch}"
fi

if [[ -n "$candidate" ]]; then
  full_with_v+="${candidate}"
  full_no_v+="${candidate}"
fi

# Output full_with_v tag and descending specificity
echo "protect_version_tag_full_with_v=$full_with_v" >>"${GITHUB_OUTPUT}"
echo "protect_version_tag_full_no_v=$full_no_v" >>"${GITHUB_OUTPUT}"

# Do not output broader specificity when there is a release candidate
if [[ -z "$candidate" ]]; then
  echo "protect_version_tag_major_minor=${major}.${minor}" >>"${GITHUB_OUTPUT}"
  echo "protect_version_tag_major=${major}" >>"${GITHUB_OUTPUT}"
  echo "protect_version_tag_stable=stable" >>"${GITHUB_OUTPUT}"
  echo "protect_version_tag_latest=latest" >>"${GITHUB_OUTPUT}"
fi
