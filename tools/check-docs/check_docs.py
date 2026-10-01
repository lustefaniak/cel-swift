#!/usr/bin/env python3
"""Lists public declarations without a doc comment, from the package's symbol graphs.

CLAUDE.md asks for a DocC doc comment on every `public` declaration. Generate the symbol graphs
first (the command builds the package; locally run it through tools/build-guard/swiftlock):

    swift package --jobs 4 dump-symbol-graph --skip-synthesized-members --skip-inherited-docs
    tools/check-docs/check_docs.py              # reads .build/<triple>/symbolgraph

`--skip-inherited-docs` matters: without it a conformance's members inherit the protocol's
comment and look documented. Exits 1 and lists the symbols when any public one is undocumented.
"""

import glob
import json
import os
import sys

# Generated or internal-only modules: their public surface is not part of the product API.
IGNORED_MODULES = {"CELSpecProtos", "CELGoTestProtos", "cel_swiftPackageTests"}


def main():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
    dirs = sys.argv[1:] or glob.glob(os.path.join(root, ".build/*/symbolgraph"))
    files = sorted(f for d in dirs for f in glob.glob(os.path.join(d, "*.symbols.json")))
    if not files:
        print("no symbol graphs found; run swift package dump-symbol-graph first", file=sys.stderr)
        return 2

    missing = []
    total = 0
    for path in files:
        module = os.path.basename(path).split(".")[0].split("@")[0]
        if module in IGNORED_MODULES:
            continue
        with open(path, encoding="utf-8") as f:
            graph = json.load(f)
        for symbol in graph["symbols"]:
            if symbol["accessLevel"] not in ("public", "open"):
                continue
            # Extension blocks (`--emit-extension-block-symbols`) group members of extended types
            # from other modules; their members carry the documentation.
            if symbol["kind"]["identifier"] == "swift.extension":
                continue
            total += 1
            lines = (symbol.get("docComment") or {}).get("lines") or []
            if not any(line["text"].strip() for line in lines):
                where = symbol.get("location", {}).get("uri", "").replace("file://" + root + "/", "")
                line = symbol.get("location", {}).get("position", {}).get("line", -1) + 1
                name = ".".join(symbol["pathComponents"])
                missing.append(f"{where}:{line}: {module} {symbol['kind']['identifier']} {name}")
    for entry in sorted(set(missing)):
        print(entry)
    if missing:
        print(f"{len(set(missing))} of {total} public symbols have no doc comment", file=sys.stderr)
        return 1
    print(f"{total} public symbols, all documented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
