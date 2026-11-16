#!/usr/bin/env bash
#
# Derives the version tags for an image built from the checked-out commit and
# writes them to GITHUB_OUTPUT as protect_version_tag_*. Every image also gets
# protect_version, from PROTECT_VERSION.
#
# The release is RELEASE_TAG when the caller has resolved one (v0.0.0 means
# none), so the image tags match the version stamped into the build. It must
# point at the checked-out commit. Without it, the release is picked from the
# commit's own tags: the highest final release, else the highest release
# candidate. Not git describe, which picks among several tags on one commit by
# tag type and creation time, so a final release can come out as its RC.
#
# A commit at a release tag (vX.Y.Z, optionally -rcN) gets vX.Y.Z and X.Y.Z.
# The moving tags (X.Y, X, stable, latest) go only to the highest final
# release in their range, judged by version rather than by which build
# finishes last. Without that, a patch to an older line published alongside a
# newer one (v1.12.10 with v1.13.4) takes latest whenever its build finishes
# second. A release candidate gets no moving tags.
#
# The ranges are read from the checkout's tags, so it needs them all
# (actions/checkout with fetch-depth: 0). A shallow checkout that has only the
# release's own tag treats that release as the highest.

set -euo pipefail

: "${PROTECT_VERSION:?}"
: "${GITHUB_OUTPUT:?}"

echo "protect_version=${PROTECT_VERSION}" >> "${GITHUB_OUTPUT}"

# The highest final release whose version starts with $1, a regex.
highest_final() {
  git tag -l 'v*' |
    sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' |
    { grep -E "^$1" || true; } |
    sort -V |
    tail -n 1
}

version_re='^v([0-9]+)(\.([0-9]+))?(\.([0-9]+))?(-rc[0-9]+)?$'

if [[ -n "${RELEASE_TAG:-}" && "${RELEASE_TAG}" != v0.0.0 ]]; then
  input="${RELEASE_TAG}"
  if [[ "$(git rev-parse -q --verify "refs/tags/${input}^{commit}" || true)" != "$(git rev-parse HEAD)" ]]; then
    echo "::error::RELEASE_TAG ${input} does not point at the checked-out commit"
    exit 1
  fi
else
  tags="$(git tag --points-at HEAD | { grep -E "${version_re}" || true; })"
  input="$(printf '%s\n' "${tags}" | { grep -v -- '-rc' || true; } | sort -V | tail -n 1)"
  if [[ -z "${input}" ]]; then
    input="$(printf '%s\n' "${tags}" | { grep -- '-rc' || true; } | sort -V | tail -n 1)"
  fi
fi

[[ "${input}" =~ ${version_re} ]] || exit 0

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[3]}"
patch="${BASH_REMATCH[5]}"
candidate="${BASH_REMATCH[6]}"

full="${major}${minor:+.${minor}}${patch:+.${patch}}${candidate}"
{
  echo "protect_version_tag_full_with_v=v${full}"
  echo "protect_version_tag_full_no_v=${full}"
} >> "${GITHUB_OUTPUT}"

if [[ -n "${candidate}" || -z "${minor}" || -z "${patch}" ]]; then
  exit 0
fi

if [[ "$(highest_final "${major}\.${minor}\.")" == "${full}" ]]; then
  echo "protect_version_tag_major_minor=${major}.${minor}" >> "${GITHUB_OUTPUT}"
else
  echo "::notice::${input} is not the highest ${major}.${minor} release; leaving ${major}.${minor} where it is"
fi

if [[ "$(highest_final "${major}\.")" == "${full}" ]]; then
  echo "protect_version_tag_major=${major}" >> "${GITHUB_OUTPUT}"
else
  echo "::notice::${input} is not the highest ${major}.x release; leaving ${major} where it is"
fi

if [[ "$(highest_final "")" == "${full}" ]]; then
  {
    echo "protect_version_tag_stable=stable"
    echo "protect_version_tag_latest=latest"
  } >> "${GITHUB_OUTPUT}"
else
  echo "::notice::${input} is not the highest release; leaving latest and stable where they are"
fi
