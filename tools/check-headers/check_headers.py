#!/usr/bin/env python3
"""Checks the license headers and provenance notes of every Swift file under Sources.

Rules (CLAUDE.md "Porting rules", docs/plan.md "Licensing"):

- A file ported from cel-go starts with cel-go's Apache-2.0 header (`Copyright <year> Google LLC`),
  names the cel-go source file(s) it ports (`cel-go parser/parser.go`), every named cel-go file
  exists in third_party/cel-go, and the year is the copyright year of one of them.
- A file ported from Go's standard library keeps the Go Authors' BSD notice; one ported from the
  ANTLR Go runtime keeps the ANTLR BSD notice; one ported from go-yaml keeps its Apache header with
  the Canonical copyright. Each of these names its source and is covered by an entry in NOTICE.
- A file that is not a port says so in its leading comment (`Not a ported file`).
- Generated files (`DO NOT EDIT`) live in the generated-proto targets or name their generator.

Usage: tools/check-headers/check_headers.py [--root DIR]. Exits 1 and lists the problems when any
file breaks a rule.
"""

import argparse
import os
import re
import sys

# protoc output; generated files elsewhere must say what generated them.
GENERATED_DIRS = ("Sources/CELSpecProtos/", "Sources/CELGoTestProtos/")
APACHE = "Licensed under the Apache License, Version 2.0"
GO_BSD = "Use of this source code is governed by a BSD-style"
BSD_TEXT = "Redistribution and use in source and binary forms"
ANTLR_BSD = "The ANTLR Project. All rights reserved."
NOT_PORTED = "Not a ported file"

# Top-level directories of cel-go: a path starting with one of them names a cel-go file.
CEL_GO_DIRS = ("cel", "checker", "common", "ext", "interpreter", "parser", "policy", "repl", "server", "test", "tools")
PATH_RE = re.compile(r"(?<![\w./-])((?:[a-z0-9_]+/)+[\w{},.-]+\.(?:go|g4))\b")


def leading_comment(text):
    """The lines of the comment block at the top of the file, up to the first code line."""
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            lines.append(stripped.lstrip("/").strip())
        elif stripped == "" and len(lines) < 60:
            lines.append("")
        else:
            break
    return "\n".join(lines)


def expand_braces(path):
    """Expands one `{a,b}` group: `common/types/{bool,int}.go` -> two paths."""
    m = re.search(r"\{([^{}]*)\}", path)
    if not m:
        return [path]
    out = []
    for part in m.group(1).split(","):
        out.extend(expand_braces(path[: m.start()] + part.strip() + path[m.end():]))
    return out


def cel_go_paths(header):
    paths = []
    # A brace list may wrap onto the next comment line: `common/types/{bool,...,\nuint}.go`.
    joined = re.sub(r",\n\s*", ",", header)
    for raw in PATH_RE.findall(joined):
        for p in expand_braces(raw):
            if p.split("/", 1)[0] in CEL_GO_DIRS:
                paths.append(p)
    return paths


def copyright_year(path):
    try:
        with open(path, encoding="utf-8") as f:
            m = re.search(r"Copyright (\d{4})", f.read(400))
    except OSError:
        return None
    return m.group(1) if m else None


def notice_covers(notice, rel):
    """NOTICE mentions the file, its name, a directory containing it, or its target."""
    if rel in notice or os.path.basename(rel) in notice:
        return True
    parts = rel.split("/")
    # Sources/<Target>/<dir>/...: a mentioned directory below the target covers its files.
    for i in range(3, len(parts)):
        if re.search(re.escape("/".join(parts[:i])) + r"(?![\w/])", notice):
            return True
    return bool(re.search(rf"\b{re.escape(parts[1])} target\b", notice))


def check_file(root, rel, notice):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        text = f.read()
    head = text[:400]
    header = leading_comment(text)
    problems = []

    if "DO NOT EDIT" in head:
        if not rel.startswith(GENERATED_DIRS) and not re.search(r"(Code g|G)enerated by \S", head):
            problems.append("generated file outside the generated-proto targets that does not name its generator")
        if "The Go Authors" in head and not notice_covers(notice, rel):
            problems.append("Go-derived generated file not covered by NOTICE")
        return problems

    google = re.match(r"// Copyright (\d{4}) Google LLC", text)
    go_authors = re.match(r"// Copyright \d{4} The Go Authors", text)
    antlr = re.match(r"// Copyright \(c\) [\d-]+ The ANTLR Project", text)
    go_yaml = "Canonical Ltd" in header and "go.yaml.in/yaml" in header

    if google:
        if APACHE not in header:
            problems.append("Google LLC copyright without the Apache-2.0 notice")
        if "cel-go" not in header:
            problems.append("cel-go header but the leading comment does not name cel-go")
        paths = cel_go_paths(header)
        if not paths:
            problems.append("does not name the cel-go source file(s) it ports")
        years = set()
        for p in paths:
            full = os.path.join(root, "third_party/cel-go", p)
            if not os.path.exists(full):
                problems.append(f"names {p}, which is not in third_party/cel-go")
                continue
            y = copyright_year(full)
            if y:
                years.add(y)
        if years and google.group(1) not in years:
            want = ", ".join(sorted(years))
            problems.append(f"copyright year {google.group(1)} is not that of a named cel-go file ({want})")
    elif go_authors:
        if GO_BSD not in header and BSD_TEXT not in header:
            problems.append("Go Authors copyright without the BSD notice")
        if not re.search(r"\.go\b|Go's|Go standard library", header):
            problems.append("does not name the Go source file(s) it ports")
        if not notice_covers(notice, rel):
            problems.append("Go-derived file not covered by NOTICE")
    elif antlr:
        if ANTLR_BSD not in header:
            problems.append("ANTLR copyright without the BSD notice")
        if not notice_covers(notice, rel):
            problems.append("ANTLR-derived file not covered by NOTICE")
    elif go_yaml:
        if APACHE not in header:
            problems.append("go-yaml copyright without the Apache-2.0 notice")
        if not notice_covers(notice, rel):
            problems.append("go-yaml-derived file not covered by NOTICE")
    elif "Copyright" in header:
        problems.append("unrecognised copyright notice")
    elif NOT_PORTED not in header:
        problems.append(f"no license header and no '{NOT_PORTED}' note")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.path.join(os.path.dirname(__file__), "../.."))
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    if not os.listdir(os.path.join(root, "third_party/cel-go")):
        print("third_party/cel-go is empty: run git submodule update --init", file=sys.stderr)
        return 2
    with open(os.path.join(root, "NOTICE"), encoding="utf-8") as f:
        notice = f.read()

    failures = 0
    count = 0
    for dirpath, _, files in os.walk(os.path.join(root, "Sources")):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            count += 1
            for problem in check_file(root, rel, notice):
                print(f"{rel}: {problem}")
                failures += 1
    if failures:
        print(f"{failures} problem(s) in {count} files", file=sys.stderr)
        return 1
    print(f"{count} files OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
