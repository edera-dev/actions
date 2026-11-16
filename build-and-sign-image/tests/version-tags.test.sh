#!/usr/bin/env bash
#
# Exercises version-tags.sh against scratch repositories with the release
# tags that motivated it. Run from anywhere; exits non-zero on a failure.

set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/version-tags.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

g() { git -c user.name=test -c user.email=test@example.invalid "$@"; }

# lines: one commit per tag, so each can be checked out on its own, and an
# untagged commit on top.
lines="${work}/lines"
g init -q "${lines}"
g -C "${lines}" commit -q --allow-empty -m base
for tag in v1.12.9 v1.12.10 v1.13.3 v1.13.4 v1.14.0-rc1 v2.0.0-rc1; do
  g -C "${lines}" commit -q --allow-empty -m "${tag}"
  g -C "${lines}" tag "${tag}"
done
g -C "${lines}" commit -q --allow-empty -m untagged
g -C "${lines}" tag untagged-head

# shared: several tags on one commit, where git describe would pick the RC.
# v1.15.0's commit has an annotated RC and a lightweight final; v1.16.0's has
# both annotated, the RC created after the final. v1.17.0's has only RCs.
shared="${work}/shared"
g init -q "${shared}"
g -C "${shared}" commit -q --allow-empty -m base
g -C "${shared}" commit -q --allow-empty -m 1.15
GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' g -C "${shared}" tag -a -m rc v1.15.0-rc1
g -C "${shared}" tag v1.15.0
g -C "${shared}" commit -q --allow-empty -m 1.16
GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' g -C "${shared}" tag -a -m final v1.16.0
GIT_COMMITTER_DATE='2026-01-03T00:00:00Z' g -C "${shared}" tag -a -m rc v1.16.0-rc2
g -C "${shared}" commit -q --allow-empty -m 1.17
g -C "${shared}" tag v1.17.0-rc9
g -C "${shared}" tag v1.17.0-rc10

failed=0

# $1: repository; $2: tag to check out; $3: RELEASE_TAG, or empty; $4:
# expected moving tags, sorted and space-separated; $5: expected full tag, or
# empty; $6: "fail" if the script should exit non-zero.
check() {
  local repo="$1" ref="$2" release="$3" want_moving="$4" want_full="$5" want_fail="${6:-}"
  local out status got_moving got_full label
  label="${ref}${release:+ RELEASE_TAG=${release}}"
  git -C "${repo}" checkout -q --detach "${ref}"
  out="$(mktemp)"
  status=0
  (cd "${repo}" && GITHUB_OUTPUT="${out}" PROTECT_VERSION=abc1234 RELEASE_TAG="${release}" \
    bash "${script}" >/dev/null) || status=$?
  got_moving="$({ grep -E '^protect_version_tag_(major_minor|major|stable|latest)=' "${out}" || true; } | cut -d= -f2 | sort | xargs)"
  got_full="$(sed -n 's/^protect_version_tag_full_with_v=//p' "${out}")"
  if [[ -n "${want_fail}" ]]; then
    if [[ "${status}" -ne 0 ]]; then
      echo "ok   ${label}: refused"
    else
      echo "FAIL ${label}: exited 0, want a failure"
      failed=1
    fi
  elif [[ "${status}" -eq 0 && "${got_moving}" == "${want_moving}" && "${got_full}" == "${want_full}" ]] &&
    grep -qx 'protect_version=abc1234' "${out}"; then
    echo "ok   ${label}: [${got_moving}] ${got_full}"
  else
    echo "FAIL ${label}: exit ${status}; moving [${got_moving}], want [${want_moving}]; full '${got_full}', want '${want_full}'"
    failed=1
  fi
  rm -f "${out}"
}

check "${lines}" v1.13.4       ""          "1 1.13 latest stable" v1.13.4
check "${lines}" v1.12.10      ""          "1.12"                 v1.12.10
check "${lines}" v1.13.3       ""          ""                     v1.13.3
check "${lines}" v1.12.9       ""          ""                     v1.12.9
check "${lines}" v1.14.0-rc1   ""          ""                     v1.14.0-rc1
check "${lines}" v2.0.0-rc1    ""          ""                     v2.0.0-rc1
check "${lines}" untagged-head ""          ""                     ""
check "${lines}" v1.13.4       v1.13.4     "1 1.13 latest stable" v1.13.4
check "${lines}" untagged-head v0.0.0      ""                     ""
check "${lines}" v1.13.4       v1.12.10    ""                     ""          fail

check "${shared}" v1.15.0      ""          "1.15"                 v1.15.0
check "${shared}" v1.16.0      ""          "1 1.16 latest stable" v1.16.0
check "${shared}" v1.17.0-rc9  ""          ""                     v1.17.0-rc10
check "${shared}" v1.16.0      v1.16.0-rc2 ""                     v1.16.0-rc2
check "${shared}" v1.16.0      v0.0.0      "1 1.16 latest stable" v1.16.0

exit "${failed}"
