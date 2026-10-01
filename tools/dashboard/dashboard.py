#!/usr/bin/env python3
"""Per-file cel-spec conformance table: cel-swift next to cel-go, cel-rust and cel-cpp.

Reads the results file written by the conformance tests (`swift test --filter CELConformanceTests`, default
.build/conformance-results.json) and the skip lists of the other implementations:

- cel-go:   third_party/cel-go/conformance/BUILD.bazel (submodule, v0.32.0)
- cel-rust: tools/dashboard/data/cel-rust-ignored.txt (snapshot, see its header)
- cel-cpp:  tools/dashboard/data/cel-cpp-conformance.BUILD (snapshot, see its header)

Works offline. Python 3 standard library only.

Columns: tests in the file; cel-swift passes in checked mode and in parse-only mode (passes / tests the mode
applies to); tests each other implementation skips (cel-cpp separately for its checked and parse-only runs).
"n/r" means that implementation does not run the file at all.
"""

import argparse
import ast
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "tools", "dashboard", "data")
CEL_GO_BUILD = os.path.join(ROOT, "third_party", "cel-go", "conformance", "BUILD.bazel")
CEL_CPP_BUILD = os.path.join(DATA, "cel-cpp-conformance.BUILD")
CEL_RUST_IGNORED = os.path.join(DATA, "cel-rust-ignored.txt")

# Keywords for which check_keyword's into_safe() (used by cel-rust's generate.rs) emits a raw identifier.
RUST_KEYWORDS = {
    "as", "break", "const", "continue", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
    "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "static", "struct", "trait", "true",
    "type", "unsafe", "use", "where", "while", "async", "await", "dyn", "abstract", "become", "box", "do",
    "final", "macro", "override", "priv", "typeof", "unsized", "virtual", "yield", "try",
}
# Keywords that cannot be raw identifiers; check_keyword appends an underscore instead.
RUST_NON_RAW_KEYWORDS = {"self", "super", "crate", "Self"}


def default_results_path():
    path = os.environ.get("CEL_CONFORMANCE_RESULTS")
    if path:
        return path if os.path.isabs(path) else os.path.join(ROOT, path)
    return os.path.join(ROOT, ".build", "conformance-results.json")


def bazel_lists(path):
    """Evaluates the top-level `_NAME = [...]` / `_A + [...]` / `_A` assignments of a BUILD file.

    Starlark list literals with comments are valid Python, so the file is parsed with `ast` and only those
    assignments are evaluated; calls such as cc_library(...) are ignored.
    """
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=path)
    env = {}

    def evaluate(node):
        if isinstance(node, ast.List):
            return [ast.literal_eval(e) for e in node.elts]
        if isinstance(node, ast.Name):
            return list(env[node.id])
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return evaluate(node.left) + evaluate(node.right)
        raise ValueError(f"{path}:{node.lineno}: unsupported expression")

    for stmt in tree.body:
        if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
            name = stmt.targets[0].id
            if name.startswith("_"):
                env[name] = evaluate(stmt.value)
    return env


def expand_cel_go_skips(skips):
    """cel-go conformance_test.bzl _expand_tests_to_skip: `a/b/c,d` means `a/b/c` and `a/b/d`."""
    out = []
    for skip in skips:
        comma = skip.find(",")
        if comma == -1:
            out.append(skip)
            continue
        slash = skip.rfind("/", 0, comma)
        slash = 0 if slash == -1 else slash + 1
        out.extend(skip[:slash] + part for part in skip[slash:].split(","))
    return out


def files_of(all_tests):
    """`@repo//tests/simple:testdata/basic.textproto` -> `basic`."""
    return {t.rsplit("/", 1)[-1].removesuffix(".textproto") for t in all_tests}


def prefix_matches(name, prefix):
    return name == prefix or name.startswith(prefix + "/")


def rust_sanitize(name):
    """cel-rust generate.rs sanitize_identifier."""
    out = "".join(ch.lower() if ch.isascii() and ch.isalnum() else "_" for ch in name)
    while "__" in out:
        out = out.replace("__", "_")
    out = out.strip("_") or "unnamed"
    if out[0].isdigit():
        out = "_" + out
    if out in RUST_KEYWORDS:
        return "r#" + out
    if out in RUST_NON_RAW_KEYWORDS:
        return out + "_"
    return out


def rust_keys(tests):
    """Maps each test name to cel-rust's `stem::section::test` identifier (generate.rs, per-section dedupe)."""
    keys = {}
    counts = {}
    for t in tests:
        section = rust_sanitize(t["section"])
        scope = (t["file"], t["section"])
        ident = rust_sanitize(t["test"])
        seen = counts.setdefault(scope, {})
        n = seen.get(ident, 0)
        seen[ident] = n + 1
        if n > 0:
            ident = f"{ident}_{n}"
        keys[t["name"]] = f"{t['file']}::{section}::{ident}"
    return keys


def load_rust_ignored():
    with open(CEL_RUST_IGNORED, encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip() and not line.startswith("#")}


class SkipColumn:
    """One implementation's skip list, evaluated against our test inventory."""

    def __init__(self, label, files_run, matcher, entries):
        self.label = label
        self.files_run = files_run  # None: every file
        self.matcher = matcher  # (test) -> bool
        self.entries = entries  # [(entry, (test) -> bool)] for stale-entry reporting

    def runs(self, file_name):
        return self.files_run is None or file_name in self.files_run


def build_columns(tests):
    go = bazel_lists(CEL_GO_BUILD)
    go_skips = expand_cel_go_skips(go["_TESTS_TO_SKIP"])
    cpp = bazel_lists(CEL_CPP_BUILD)
    cpp_checked = cpp["_TESTS_TO_SKIP_MODERN"]
    cpp_parse_only = cpp["_TESTS_TO_SKIP_MODERN"] + cpp["_TESTS_TO_SKIP_PARSE_ONLY"]
    rust_ignored = load_rust_ignored()
    rust = rust_keys(tests)

    def prefix_column(label, files_run, prefixes):
        entries = [(p, lambda t, p=p: prefix_matches(t["name"], p)) for p in prefixes]
        return SkipColumn(label, files_run, lambda t: any(prefix_matches(t["name"], p) for p in prefixes), entries)

    rust_entries = [(key, lambda t, key=key: rust.get(t["name"]) == key) for key in sorted(rust_ignored)]
    return [
        prefix_column("cel-go", files_of(go["_ALL_TESTS"]), go_skips),
        SkipColumn("cel-rust", None, lambda t: rust.get(t["name"]) in rust_ignored, rust_entries),
        prefix_column("cpp chk", files_of(cpp["_ALL_TESTS"]), cpp_checked),
        prefix_column("cpp p-o", files_of(cpp["_ALL_TESTS"]), cpp_parse_only),
    ]


def render(rows, header, markdown):
    if markdown:
        lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---:" if i else "---" for i in range(len(header))) + "|"]
        lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
        return "\n".join(lines)
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    fmt = lambda row: "  ".join(
        str(c).ljust(widths[i]) if i == 0 else str(c).rjust(widths[i]) for i, c in enumerate(row)
    )
    return "\n".join([fmt(header), "  ".join("-" * w for w in widths)] + [fmt(r) for r in rows])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results", default=default_results_path(), help="conformance results JSON")
    parser.add_argument("--run", action="store_true", help="run `swift test --filter CELConformanceTests` first")
    parser.add_argument("--markdown", action="store_true", help="print a Markdown table")
    parser.add_argument("--stale", action="store_true", help="list skip entries that match no test")
    args = parser.parse_args()

    if args.run:
        env = dict(os.environ, CEL_CONFORMANCE_RESULTS=args.results)
        subprocess.run(["swift", "test", "--filter", "CELConformanceTests"], cwd=ROOT, env=env, check=False)
    if not os.path.exists(args.results):
        sys.exit(f"{args.results} not found: run `swift test --filter CELConformanceTests` (or pass --run)")
    with open(args.results, encoding="utf-8") as f:
        results = json.load(f)
    tests = results["tests"]
    columns = build_columns(tests)

    by_file = {}
    for t in tests:
        by_file.setdefault(t["file"], []).append(t)

    header = ["file", "tests", "swift chk", "swift p-o"] + [c.label for c in columns]
    rows = []
    totals = [0, 0, 0, 0] + [0] * len(columns)
    file_names = [f["file"] for f in results["files"]]
    for name in file_names:
        ts = by_file.get(name, [])
        checked = sum(t["checked"]["status"] == "pass" for t in ts)
        po_applicable = sum(t["parse_only"]["status"] != "n/a" for t in ts)
        parse_only = sum(t["parse_only"]["status"] == "pass" for t in ts)
        row = [name, len(ts), checked, f"{parse_only}/{po_applicable}"]
        totals[1] += len(ts)
        totals[2] += checked
        totals[3] += parse_only
        totals[0] += po_applicable
        for i, column in enumerate(columns):
            if not column.runs(name):
                row.append("n/r")
                continue
            n = sum(column.matcher(t) for t in ts)
            row.append(n)
            totals[4 + i] += n
        rows.append(row)
    rows.append(["total", totals[1], totals[2], f"{totals[3]}/{totals[0]}"] + totals[4:])

    print(f"cel-spec {results.get('spec_version', '?')} conformance, cel-swift runner: {results.get('runner', '?')}")
    print()
    print(render(rows, header, args.markdown))
    print()

    # Milestone measures (docs/plan.md, Conformance targets).
    passed_checked = {t["name"] for t in tests if t["checked"]["status"] == "pass"}
    rust, cpp_checked = columns[1], columns[2]
    rust_gap = [t["name"] for t in tests if not rust.matcher(t) and t["name"] not in passed_checked]
    cpp_gap = [
        t["name"] for t in tests
        if cpp_checked.runs(t["file"]) and not cpp_checked.matcher(t) and t["name"] not in passed_checked
    ]
    swift_skipped = sum(
        t["checked"]["status"] == "skip" or t["parse_only"]["status"] == "skip" for t in tests
    )
    print(f"rust parity: {len(rust_gap)} tests cel-rust passes that cel-swift does not (checked mode)")
    print(f"cpp parity:  {len(cpp_gap)} tests cel-cpp passes (checked) that cel-swift does not; "
          f"cel-swift skip.txt covers {swift_skipped} tests")

    if args.stale:
        print()
        for column in columns:
            stale = [entry for entry, match in column.entries if not any(match(t) for t in tests)]
            for entry in stale:
                print(f"stale {column.label} entry: {entry}")


if __name__ == "__main__":
    main()
