#!/usr/bin/env python3
"""Merge a composite image's local syft scan with the CycloneDX SBOMs pulled
from its base images into one CycloneDX 1.6 document.

A copy-only composite re-ships artifacts whose real provenance lives in the base
images it copies from. The action scans the pushed composite directly (catching
e.g. cargo-auditable dep trees or a shipped apk rootfs) and downloads each base's
CycloneDX attestation; this script stitches them into a single SBOM describing
what the composite actually ships.

Reads from the environment:
  COMPONENT        composite component name (-> metadata.component + output file)
  PROTECT_VERSION  composite version (the short-sha tag)
  LOCAL_SBOM       path to the syft scan of the pushed composite (may be absent
                   or contain zero components for FROM-scratch composites)
  EXTRA_SBOM       optional path to an extra local syft scan. Its components and 
                   inner dependencies are unioned, its metadata.component is ignored.
  BASES_DIR        directory of <base>.cdx.json predicates already extracted from
                   base attestations (may be empty/missing)

Always writes protect-<COMPONENT>.cdx.json (even with zero components, so the
caller can decide warn-vs-fail) and prints a JSON summary to stdout.
"""
import json
import os
import sys


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def dedup_key(comp):
    return (comp.get("purl")
            or comp.get("bom-ref")
            or "%s@%s" % (comp.get("name", "?"), comp.get("version", "?")))


def main():
    component = os.environ["COMPONENT"]
    version = os.environ.get("PROTECT_VERSION", "")
    local_path = os.environ.get("LOCAL_SBOM", "")
    extra_path = os.environ.get("EXTRA_SBOM", "")
    bases_dir = os.environ.get("BASES_DIR", "")

    components = []
    seen = set()
    raw_deps = []
    contributed = []

    def add(comp):
        if not isinstance(comp, dict):
            return
        key = dedup_key(comp)
        if key in seen:
            return
        seen.add(key)
        components.append(comp)

    # Local scan of the pushed composite first.
    local = load(local_path) if local_path else None
    if local:
        for c in local.get("components") or []:
            add(c)
        raw_deps.extend(local.get("dependencies") or [])

    extra = load(extra_path) if extra_path else None
    if extra:
        for c in extra.get("components") or []:
            add(c)
        raw_deps.extend(extra.get("dependencies") or [])

    # Then each base image's downloaded CycloneDX predicate.
    base_files = []
    if bases_dir and os.path.isdir(bases_dir):
        base_files = sorted(
            os.path.join(bases_dir, f)
            for f in os.listdir(bases_dir) if f.endswith(".cdx.json"))
    for bf in base_files:
        doc = load(bf)
        if not doc:
            continue
        primary = (doc.get("metadata") or {}).get("component")
        label = os.path.basename(bf)[:-len(".cdx.json")]
        if isinstance(primary, dict):
            label = (primary.get("purl")
                     or "%s@%s" % (primary.get("name", "?"),
                                   primary.get("version", "?")))
            add(primary)  # the base image itself is a shipped component
        for c in doc.get("components") or []:
            add(c)
        raw_deps.extend(doc.get("dependencies") or [])
        contributed.append(label)

    image_ref = ("protect-%s@%s" % (component, version) if version
                 else "protect-%s" % component)

    # Carry over and dedup the inner dependency graphs, then make the composite
    # depend on every top-level component we merged.
    dep_by_ref = {}
    order = []
    for d in raw_deps:
        ref = d.get("ref")
        if not ref or ref == image_ref:
            continue
        if ref not in dep_by_ref:
            dep_by_ref[ref] = set()
            order.append(ref)
        for dd in d.get("dependsOn") or []:
            dep_by_ref[ref].add(dd)

    top_refs = [c["bom-ref"] for c in components if c.get("bom-ref")]
    dependencies = [{"ref": image_ref, "dependsOn": top_refs}]
    for ref in order:
        dependencies.append({"ref": ref, "dependsOn": sorted(dep_by_ref[ref])})

    properties = [{"name": "dev.edera.sbom.bases", "value": str(len(contributed))}]
    for b in contributed:
        properties.append({"name": "dev.edera.sbom.base", "value": b})

    metadata_component = {
        "bom-ref": image_ref,
        "type": "container",
        "name": "protect-%s" % component,
    }
    if version:
        metadata_component["version"] = version

    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "component": metadata_component,
            "properties": properties,
        },
        "components": components,
        "dependencies": dependencies,
    }

    out = "protect-%s.cdx.json" % component
    with open(out, "w") as fh:
        json.dump(document, fh, indent=2)
        fh.write("\n")

    print(json.dumps({
        "component": component,
        "components": len(components),
        "bases_merged": len(contributed),
        "bases": contributed,
    }, indent=2))


if __name__ == "__main__":
    main()
