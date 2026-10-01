#!/usr/bin/env python3
"""Extracts the expression tables of cel-go's ext/*_test.go into JSON lines for CELExtensionsTests.

Each cel-go table is a `[]struct{...}{ {expr: ..., err: ..., ...}, ... }` literal. Entries whose fields are all
simple (string / bool literals) are kept; entries using Go values (`in`, `vars`, `dynArgs` with Go
expressions, cost hints, ...) are dropped, since they need hand porting. Each output line is

  {"table": "<file>:<line>", "env": "<env name>", "kind": "<kind>", "fields": {...}, "entry": "<file>:<line>"}

where `env` and `kind` come from the TABLES list below (the environment and the harness cel-go's test uses).

Usage (from the repository root):
  python3 tools/ext-fixtures/extract_go_tables.py > Tests/CELExtensionsTests/Resources/go-tables.jsonl
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = os.path.join(ROOT, "third_party", "cel-go", "ext")

# (file, line of the `[]struct {` table, env, kind)
#   kind "true":    parse (and check unless parseOnly), evaluate; true, or an error containing `err`
#   kind "static":  compiling fails with an error containing `err`
#   kind "runtime": compiles; evaluating fails with an error containing `err`
#   kind "format":  `format`.format([formatArgs]) == expectedOutput, or an error containing `err`
TABLES = [
    ("strings_test.go", 31, "strings", "true"),
    ("math_test.go", 28, "math", "true"),
    ("math_test.go", 238, "math", "static"),
    ("lists_test.go", 30, "lists", "true"),
    ("lists_test.go", 124, "lists-v1", "true"),
    ("encoders_test.go", 28, "encoders", "true"),
    ("comprehensions_test.go", 29, "comprehensions", "true"),
    ("comprehensions_test.go", 397, "comprehensions", "static"),
    ("comprehensions_test.go", 502, "comprehensions", "runtime"),
    ("regex_test.go", 27, "regex", "true"),
    ("regex_test.go", 128, "regex", "static"),
    ("regex_test.go", 170, "regex", "runtime"),
    ("formatting_v2_test.go", 47, "strings", "format"),
    ("formatting_test.go", 36, "strings-v3", "format"),
]


def tokenize_literal(src, i):
    """Returns the end index of the Go literal (string, raw string, rune) or comment starting at i."""
    c = src[i]
    if c == "`":
        return src.index("`", i + 1) + 1
    if c in "\"'":
        j = i + 1
        while src[j] != c:
            j += 2 if src[j] == "\\" else 1
        return j + 1
    if src.startswith("//", i):
        return src.index("\n", i)
    if src.startswith("/*", i):
        return src.index("*/", i) + 2
    return None


def matching_brace(src, i):
    depth = 0
    while i < len(src):
        end = tokenize_literal(src, i) if src[i] in "`\"'/" else None
        if end is not None:
            i = end
            continue
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced")


def go_unquote(lit):
    if lit[0] == "`":
        return lit[1:-1]
    body = lit[1:-1]
    out = []
    i = 0
    simple = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'"}
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        n = body[i + 1]
        if n in simple:
            out.append(simple[n])
            i += 2
        elif n == "u":
            out.append(chr(int(body[i + 2:i + 6], 16)))
            i += 6
        elif n == "U":
            out.append(chr(int(body[i + 2:i + 10], 16)))
            i += 10
        elif n == "x":
            out.append(chr(int(body[i + 2:i + 4], 16)))
            i += 4
        else:
            raise ValueError("escape " + n)
    return "".join(out)


FIELD = re.compile(r"\s*(\w+)\s*:\s*")


def parse_entry(text):
    """Parses `field: value, ...`; returns None when a value is not a string or bool literal."""
    fields = {}
    i = 0
    while i < len(text):
        while i < len(text) and text[i] in " \t\n,":
            i += 1
        if i >= len(text):
            break
        if text.startswith("//", i):
            i = text.index("\n", i) if "\n" in text[i:] else len(text)
            continue
        m = FIELD.match(text, i)
        if not m:
            return None
        name = m.group(1)
        i = m.end()
        if text[i] in "`\"":
            end = tokenize_literal(text, i)
            fields[name] = go_unquote(text[i:end])
            i = end
        elif text.startswith("true", i) or text.startswith("false", i):
            v = text.startswith("true", i)
            fields[name] = v
            i += 4 if v else 5
        else:
            # Any other value: keep the field name so the harness can drop it.
            j = i
            depth = 0
            while j < len(text):
                end = tokenize_literal(text, j) if text[j] in "`\"'" else None
                if end is not None:
                    j = end
                    continue
                if text[j] in "({[":
                    depth += 1
                elif text[j] in ")}]":
                    depth -= 1
                elif text[j] == "," and depth == 0:
                    break
                j += 1
            fields[name] = {"go": text[i:j].strip()}
            i = j
    return fields


def entries(path, line):
    src = open(path).read()
    offsets = [0]
    for l in src.splitlines(keepends=True):
        offsets.append(offsets[-1] + len(l))
    start = offsets[line - 1]
    struct = src.index("struct", start)
    type_open = src.index("{", struct)
    type_close = matching_brace(src, type_open)
    body_open = src.index("{", type_close + 1)
    body_close = matching_brace(src, body_open)
    i = body_open + 1
    while i < body_close:
        if src[i] == "{":
            end = matching_brace(src, i)
            entry_line = src.count("\n", 0, i) + 1
            yield entry_line, src[i + 1:end]
            i = end + 1
        elif src.startswith("//", i):
            i = src.index("\n", i)
        else:
            i += 1


def main():
    for name, line, env, kind in TABLES:
        path = os.path.join(EXT, name)
        for entry_line, text in entries(path, line):
            fields = parse_entry(text)
            if fields is None:
                continue
            print(json.dumps({"entry": "%s:%d" % (name, entry_line), "env": env, "kind": kind, "fields": fields},
                             ensure_ascii=False))


if __name__ == "__main__":
    main()
