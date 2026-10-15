#!/usr/bin/env python3
"""Build the two review skills for one repository.

The templates under templates/ hold the review method, which is the same
everywhere. A repository's focus file supplies everything specific to it, as
named sections, and its test-layers file is copied in beside the coverage
skill. The output keeps the layout the skills link to each other by:

    OUT/pr-review/SKILL.md
    OUT/test-coverage-review/SKILL.md
    OUT/test-coverage-review/references/test-layers.md
    OUT/references/review-writing.md
    OUT/references/finding-impact.md

A focus file is Markdown in which each section starts at a line of the form
`<!-- focus: NAME -->` and runs to the next such line. Anything before the
first one is commentary for whoever edits the file. A name no template uses
is an error, so a misspelt section fails here rather than silently dropping
out of the review.

Usage:
    assemble.py --focus FILE --test-layers FILE --out DIR
                [--var NAME=VALUE ...]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = os.path.join(HERE, "templates")

# Output path -> template. review-writing.md has no placeholders and is copied.
DOCUMENTS = {
    "pr-review/SKILL.md": "pr-review.md",
    "test-coverage-review/SKILL.md": "test-coverage-review.md",
    "references/finding-impact.md": "finding-impact.md",
    "references/review-writing.md": "review-writing.md",
}

# Sections a repository may leave out. Only the forks have anything to say
# about the upstream branch they sit on.
OPTIONAL = {"FORK_SCOPE"}

# Filled from the run rather than from the focus file.
RUN_VARIABLES = {"REPOSITORY", "DEFAULT_BRANCH"}

MARKER = re.compile(r"^<!-- focus: ([A-Z][A-Z_]*) -->$")
PLACEHOLDER = re.compile(r"@@([A-Z][A-Z_]*)@@")


class FocusError(Exception):
    pass


def parse_focus(text):
    sections = {}
    name = None
    lines = []
    for line in text.splitlines():
        match = MARKER.match(line)
        if match:
            if name is not None:
                sections[name] = "\n".join(lines).strip("\n")
            name = match.group(1)
            if name in sections:
                raise FocusError(f"section {name} appears more than once")
            lines = []
        elif name is not None:
            lines.append(line)
    if name is not None:
        sections[name] = "\n".join(lines).strip("\n")
    return sections


def placeholders():
    used = set()
    for template in DOCUMENTS.values():
        with open(os.path.join(TEMPLATES, template)) as f:
            used |= set(PLACEHOLDER.findall(f.read()))
    return used


def fill(template, values):
    def substitute(match):
        return values[match.group(1)]
    text = PLACEHOLDER.sub(substitute, template)
    # An empty optional section leaves a run of blank lines behind.
    return re.sub(r"\n{3,}", "\n\n", text)


def assemble(focus_text, test_layers_text, out, variables):
    sections = parse_focus(focus_text)
    used = placeholders()
    wanted = used - RUN_VARIABLES

    unknown = sorted(set(sections) - wanted)
    if unknown:
        raise FocusError("no template uses section " + ", ".join(unknown))
    missing = sorted(wanted - set(sections) - OPTIONAL)
    if missing:
        raise FocusError("missing section " + ", ".join(missing))
    empty = sorted(k for k, v in sections.items() if not v and k not in OPTIONAL)
    if empty:
        raise FocusError("empty section " + ", ".join(empty))
    unset = sorted(RUN_VARIABLES & used - set(variables))
    if unset:
        raise FocusError("no value given for " + ", ".join(unset))

    values = {k: "" for k in OPTIONAL}
    values.update(sections)
    values.update(variables)

    for path, template in DOCUMENTS.items():
        with open(os.path.join(TEMPLATES, template)) as f:
            text = fill(f.read(), values)
        target = os.path.join(out, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            f.write(text)

    target = os.path.join(out, "test-coverage-review/references/test-layers.md")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w") as f:
        f.write(test_layers_text)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--focus", required=True)
    parser.add_argument("--test-layers", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--var", action="append", default=[], metavar="NAME=VALUE")
    args = parser.parse_args(argv)

    variables = {}
    for item in args.var:
        name, sep, value = item.partition("=")
        if not sep or name not in RUN_VARIABLES:
            parser.error(f"--var takes one of {', '.join(sorted(RUN_VARIABLES))} as NAME=VALUE: {item}")
        variables[name] = value

    try:
        with open(args.focus) as f:
            focus_text = f.read()
        with open(args.test_layers) as f:
            test_layers_text = f.read()
    except OSError as error:
        print(f"assemble.py: {error.filename}: {error.strerror}", file=sys.stderr)
        return 1
    try:
        assemble(focus_text, test_layers_text, args.out, variables)
    except FocusError as error:
        print(f"assemble.py: {args.focus}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
