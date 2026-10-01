#!/usr/bin/env bash
# Tests for advisory-review/assemble.py.
#
# The fixture focus file is generated from the templates, so it always has
# exactly the sections the templates use. This repository's own focus file is
# assembled too, since it is a real one and nothing else checks it before a
# review runs.
#
# Run from anywhere: bash advisory-review/tests/assemble.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$DIR/.." && pwd)
ASSEMBLE="$DIR/assemble.py"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# True when some file under the directory has three newlines in a row.
has_blank_run() {
  python3 - "$1" <<'EOF'
import os, sys
for dp, _, names in os.walk(sys.argv[1]):
    for n in names:
        if "\n\n\n" in open(os.path.join(dp, n)).read():
            sys.exit(0)
sys.exit(1)
EOF
}
no_blank_run() { ! has_blank_run "$1"; }

run() {
  python3 "$ASSEMBLE" --focus "$1" --test-layers "$WORK/test-layers.md" --out "$2" \
    --var REPOSITORY=edera-dev/example --var DEFAULT_BRANCH=main
}

# Every placeholder the templates use, less the two the run supplies.
sections=$(grep -ohE '@@[A-Z_]+@@' "$DIR"/templates/*.md | tr -d '@' | sort -u \
  | grep -vxE 'REPOSITORY|DEFAULT_BRANCH')

write_focus() {
  # write_focus <file> [section to leave out]
  local s
  {
    echo "# Commentary before the first marker is ignored."
    echo "<!-- this line is not a marker -->"
    for s in $sections; do
      [ "$s" = "${2:-}" ] && continue
      printf '\n<!-- focus: %s -->\nvalue of %s\n' "$s" "$s"
    done
  } >"$1"
}

printf '# Test layers for the fixture\n' >"$WORK/test-layers.md"
write_focus "$WORK/focus.md"

echo "# a complete focus file assembles"
out="$WORK/out"
check "assembly succeeds" run "$WORK/focus.md" "$out"
for f in pr-review/SKILL.md test-coverage-review/SKILL.md \
  test-coverage-review/references/test-layers.md \
  references/review-writing.md references/finding-impact.md; do
  check "writes $f" test -s "$out/$f"
done
check "no placeholder is left in any output" bash -c "! grep -rqE '@@[A-Z_]+@@' '$out'"
check "every section lands somewhere" \
  bash -c "for s in $(echo "$sections" | tr '\n' ' '); do grep -rqF \"value of \$s\" '$out' || exit 1; done"
check "the run variables are filled" \
  bash -c "grep -qF 'git diff origin/main...HEAD' '$out/pr-review/SKILL.md' && grep -qF 'repos/edera-dev/example/pulls/' '$out/test-coverage-review/SKILL.md'"
check "commentary before the first marker stays out" bash -c "! grep -rqF 'Commentary before' '$out'"
check "the test-layers file is copied as given" cmp "$WORK/test-layers.md" "$out/test-coverage-review/references/test-layers.md"
check "review-writing.md is copied unchanged" cmp "$DIR/templates/review-writing.md" "$out/references/review-writing.md"
check "no run of blank lines is left behind" no_blank_run "$out"

echo "# the links between the skills resolve"
for skill in pr-review test-coverage-review; do
  # shellcheck disable=SC2016  # the backticks are literal Markdown in the pattern
  for link in $(grep -oE '`(\.\./)?references/[a-z-]+\.md`' "$out/$skill/SKILL.md" | tr -d '`' | sort -u); do
    check "$skill links to $link" test -f "$out/$skill/$link"
  done
done

echo "# FORK_SCOPE is optional and every other section is required"
write_focus "$WORK/no-fork.md" FORK_SCOPE
check "leaving out FORK_SCOPE assembles" run "$WORK/no-fork.md" "$WORK/out-no-fork"
check "and leaves no trace of it" bash -c "! grep -rqF 'value of FORK_SCOPE' '$WORK/out-no-fork'"
check "and no run of blank lines where it was" no_blank_run "$WORK/out-no-fork"
for s in INTRO SERIOUS GAP_EXAMPLE IMPACT_WORKED_EXAMPLE; do
  write_focus "$WORK/missing-$s.md" "$s"
  check "leaving out $s fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/missing-$s.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>/dev/null"
  check "and names $s" bash -c "python3 '$ASSEMBLE' --focus '$WORK/missing-$s.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>&1 | grep -qw '$s'"
done

echo "# mistakes in a focus file fail rather than dropping out of the review"
cp "$WORK/focus.md" "$WORK/typo.md"
printf '\n<!-- focus: SERIUOS -->\nmisspelt\n' >>"$WORK/typo.md"
check "a section no template uses fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/typo.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>/dev/null"
check "and names it" bash -c "python3 '$ASSEMBLE' --focus '$WORK/typo.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>&1 | grep -qw SERIUOS"
cp "$WORK/focus.md" "$WORK/dup.md"
printf '\n<!-- focus: INTRO -->\nagain\n' >>"$WORK/dup.md"
check "a section given twice fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/dup.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>/dev/null"
sed 's/^value of SERIOUS$//' "$WORK/focus.md" >"$WORK/empty.md"
check "an empty required section fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/empty.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>/dev/null"
check "a missing run variable fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/focus.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b 2>/dev/null"
check "an unknown run variable fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/focus.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main --var OTHER=x 2>/dev/null"
check "a missing focus file fails" bash -c "! python3 '$ASSEMBLE' --focus '$WORK/nope.md' --test-layers '$WORK/test-layers.md' --out '$WORK/x' --var REPOSITORY=a/b --var DEFAULT_BRANCH=main 2>/dev/null"

echo "# this repository's own focus file assembles"
check "the real focus file for this repository assembles" \
  python3 "$ASSEMBLE" --focus "$ROOT/.github/review/focus.md" \
  --test-layers "$ROOT/.github/review/test-layers.md" --out "$WORK/own" \
  --var REPOSITORY=edera-dev/actions --var DEFAULT_BRANCH=main

echo
if [ "$failures" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed" >&2
  exit 1
fi
