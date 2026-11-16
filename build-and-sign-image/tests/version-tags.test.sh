#!/usr/bin/env bash
#
# Exercises version-tags.sh against a scratch repository with the release
# tags that motivated it. Run from anywhere; exits non-zero on a failure.

set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/version-tags.sh"
repo="$(mktemp -d)"
trap 'rm -rf "${repo}"' EXIT

git -C "${repo}" init -q
git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m base

# One commit per tag, so each can be checked out on its own.
for tag in v1.12.9 v1.12.10 v1.13.3 v1.13.4 v1.14.0-rc1 v2.0.0-rc1; do
  git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m "${tag}"
  git -C "${repo}" tag "${tag}"
done

failed=0

# $1: tag to check out (or "untagged"); $2: expected moving tags, sorted and
# space-separated; $3: expected full tag, or empty.
check() {
  local ref="$1" want_moving="$2" want_full="$3" out got_moving got_full
  if [[ "${ref}" == untagged ]]; then
    git -C "${repo}" checkout -q --detach HEAD~0
    git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m untagged
  else
    git -C "${repo}" checkout -q --detach "${ref}"
  fi
  out="$(mktemp)"
  (cd "${repo}" && GITHUB_OUTPUT="${out}" PROTECT_VERSION=abc1234 bash "${script}" >/dev/null)
  got_moving="$({ grep -E '^protect_version_tag_(major_minor|major|stable|latest)=' "${out}" || true; } | cut -d= -f2 | sort | xargs)"
  got_full="$(sed -n 's/^protect_version_tag_full_with_v=//p' "${out}")"
  if [[ "${got_moving}" == "${want_moving}" && "${got_full}" == "${want_full}" ]] &&
    grep -qx 'protect_version=abc1234' "${out}"; then
    echo "ok   ${ref}: [${got_moving}] ${got_full}"
  else
    echo "FAIL ${ref}: moving [${got_moving}], want [${want_moving}]; full '${got_full}', want '${want_full}'"
    failed=1
  fi
  rm -f "${out}"
}

check v1.13.4     "1 1.13 latest stable" v1.13.4
check v1.12.10    "1.12"                 v1.12.10
check v1.13.3     ""                     v1.13.3
check v1.12.9     ""                     v1.12.9
check v1.14.0-rc1 ""                     v1.14.0-rc1
check v2.0.0-rc1  ""                     v2.0.0-rc1
check untagged    ""                     ""

exit "${failed}"
