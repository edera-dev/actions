#!/usr/bin/env python3
"""List the external base images a composite's target stage copies artifacts from.

Many protect images are copy-only composites (`FROM scratch` + `COPY --from=...`)
that re-ship artifacts built in sibling repos. Scanning such an image directly
finds nothing, so instead we merge in the CycloneDX attestations the base images
already carry. This script discovers which bases to pull.

It parses a Dockerfile, finds the target build stage (or the last stage when no
target is given), and prints -- one registry ref per line -- the images that the
target stage pulls shipped artifacts from via `COPY --from=`. Stage aliases /
indexes are resolved transitively back to their `FROM` image; `scratch` is
dropped. Build args (e.g. ${PROTECT_VERSION}) are expanded from the environment,
falling back to Dockerfile `ARG` defaults; a ref left with an unresolved `$VAR`
is dropped with a warning (it can't be pulled).

Toolchain/builder bases need no special-casing here: they are emitted like any
other base, and simply have no CycloneDX attestation to download later.

Usage: list_bases.py <dockerfile> [<target-stage>]
"""
import os
import re
import sys

_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def expand(value, variables):
    """Expand ${VAR} / $VAR from `variables`; leave unknown refs untouched."""
    def repl(m):
        name = m.group(1) or m.group(2)
        return variables.get(name, m.group(0))
    return _VAR.sub(repl, value)


def parse(dockerfile):
    """Return (global ARG defaults, [stage,...]) where a stage is a dict with
    keys: alias (or None), ref (the FROM image/alias), copies (list of
    --from values)."""
    with open(dockerfile) as fh:
        raw = fh.read()
    # Collapse line continuations so each instruction is one logical line.
    raw = re.sub(r"\\\r?\n", " ", raw)

    global_args = {}
    stages = []
    seen_from = False
    cur = None
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        kw = s.split(None, 1)[0].upper()

        if kw == "ARG" and not seen_from:
            body = s.split(None, 1)[1] if len(s.split(None, 1)) > 1 else ""
            if "=" in body:
                k, v = body.split("=", 1)
                global_args[k.strip()] = v.strip().strip('"\'')
            elif body.strip():
                global_args.setdefault(body.strip(), "")
            continue

        if kw == "FROM":
            seen_from = True
            parts = s.split()
            idx = 1
            while idx < len(parts) and parts[idx].startswith("--"):
                idx += 1  # skip flags such as --platform=$BUILDPLATFORM
            ref = parts[idx] if idx < len(parts) else ""
            alias = None
            if idx + 2 < len(parts) and parts[idx + 1].upper() == "AS":
                alias = parts[idx + 2]
            cur = {"alias": alias, "ref": ref, "copies": []}
            stages.append(cur)
            continue

        if kw == "COPY" and cur is not None:
            m = re.search(r"--from=(\S+)", s)
            if m:
                cur["copies"].append(m.group(1).strip('"\''))
            continue

    return global_args, stages


def main():
    if len(sys.argv) < 2:
        print("usage: list_bases.py <dockerfile> [target]", file=sys.stderr)
        sys.exit(2)
    dockerfile = sys.argv[1]
    target = sys.argv[2].strip() if len(sys.argv) > 2 and sys.argv[2].strip() else None

    global_args, stages = parse(dockerfile)
    if not stages:
        return

    variables = dict(global_args)
    variables.update(os.environ)  # build-args from the env win over ARG defaults

    by_alias = {}
    for i, st in enumerate(stages):
        by_alias[str(i)] = st  # numeric stage index, e.g. COPY --from=0
        if st["alias"]:
            by_alias[st["alias"].lower()] = st

    tstage = None
    if target:
        tstage = by_alias.get(target.lower())
        if tstage is None:
            print("::warning::target stage %r not found in %s; using last stage"
                  % (target, dockerfile), file=sys.stderr)
    if tstage is None:
        tstage = stages[-1]

    def resolve(value, depth=0):
        """Resolve a --from value to a concrete image ref, following stage
        aliases/indexes that themselves `FROM` another stage."""
        if depth > 16:
            return None
        st = by_alias.get(value.lower())
        if st is not None:
            return resolve(st["ref"], depth + 1)
        return value  # not a stage -> an image ref (or 'scratch')

    out = []
    for raw_from in tstage["copies"]:
        ref = resolve(raw_from)
        if not ref:
            continue
        ref = expand(ref, variables)
        if ref.lower() == "scratch":
            continue
        if "$" in ref:
            print("::warning::skipping base with unresolved build-arg: %s" % ref,
                  file=sys.stderr)
            continue
        if ref not in out:
            out.append(ref)

    for ref in out:
        print(ref)


if __name__ == "__main__":
    main()
