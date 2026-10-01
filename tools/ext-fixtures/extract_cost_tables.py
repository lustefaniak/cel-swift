#!/usr/bin/env python3
"""Extracts the cost tables of cel-go's ext/*_test.go into JSON lines for CELExtensionsTests.

Each table row has an expression, optional variables (`vars`), inputs (`in`), size hints (`hints`), the
static estimate (`estimatedCost`) and the actual runtime cost (`actualCost`). Go values are translated:
variable types to CEL type names (`list(int)`), inputs to CEL literal expressions the harness evaluates to
get the binding (`[1, 2]`, `b"hello"`), costs to decimal strings (UInt64.max does not survive a JSON
double). Each output line is

  {"entry": "<file>:<line>", "test": "<Go test>", "env": "<env name>", "version": <int or null>,
   "expr": ..., "vars": {"x": "list(int)"}, "in": {"x": "[1, 2]"}, "hints": {"x": 10},
   "estimate": ["min", "max"], "actual": "n"}

where `env` names the environment of the cel-go test (see CostTableTests.swift) and `version` the library
version, `null` for the latest.

Usage (from the repository root):
  python3 tools/ext-fixtures/extract_cost_tables.py > Tests/CELExtensionsTests/Resources/cost-tables.jsonl
  python3 tools/ext-fixtures/extract_cost_tables.py --verify /path/to/oracle   # compare with tools/oracle
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_go_tables import EXT, entries, go_unquote, tokenize_literal  # noqa: E402

# (file, line of the table, Go test, env, how version 0 is read: "latest" when the test's env factory
# treats 0 as the default, "zero" when it passes 0 through)
TABLES = [
    ("lists_test.go", 231, "TestListsCosts", "lists", "latest"),
    ("sets_test.go", 31, "TestSets", "sets", "latest"),
    ("regex_test.go", 277, "TestRegexCosts", "regex", "latest"),
    ("encoders_test.go", 129, "TestEncodersCosts", "encoders", "zero"),
    ("math_test.go", 691, "TestMathCosts", "math", "latest"),
    ("bindings_test.go", 33, "TestBindings", "bindings", "latest"),
    ("comprehensions_test.go", 218, "TestTwoVarComprehensionsCost", "comprehensions", "latest"),
    ("strings_test.go", 853, "TestStringCostTracking", "strings-v5", "latest"),
]

MAX_UINT64 = (1 << 64) - 1

# Go type expressions of cel-go types.
CEL_TYPES = {
    "cel.IntType": "int", "cel.UintType": "uint", "cel.DoubleType": "double", "cel.StringType": "string",
    "cel.BytesType": "bytes", "cel.BoolType": "bool", "cel.DynType": "dyn", "cel.NullType": "null_type",
    "cel.DurationType": "google.protobuf.Duration", "cel.TimestampType": "google.protobuf.Timestamp",
}


def split_top(text, sep=","):
    """Splits on `sep` outside brackets and literals."""
    parts, depth, start, i = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        if c in "`\"'":
            i = tokenize_literal(text, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == sep and depth == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    if text[start:].strip():
        parts.append(text[start:])
    return [p.strip() for p in parts if p.strip()]


def cel_type(go):
    go = go.strip()
    if go in CEL_TYPES:
        return CEL_TYPES[go]
    m = re.fullmatch(r"cel\.ListType\((.*)\)", go, re.S)
    if m:
        return "list(%s)" % cel_type(m.group(1))
    m = re.fullmatch(r"cel\.MapType\((.*)\)", go, re.S)
    if m:
        k, v = split_top(m.group(1))
        return "map(%s, %s)" % (cel_type(k), cel_type(v))
    raise ValueError("type " + go)


def parse_vars(go):
    out = {}
    m = re.fullmatch(r"\[\]cel\.EnvOption\{(.*)\}", go.strip(), re.S)
    if not m:
        raise ValueError("vars " + go)
    for item in split_top(m.group(1)):
        c = re.fullmatch(r"cel\.Container\((.*)\)", item, re.S)
        if c:
            out["@container"] = go_unquote(c.group(1).strip())
            continue
        v = re.fullmatch(r"cel\.Variable\((.*)\)", item, re.S)
        if not v:
            raise ValueError("var " + item)
        name, t = split_top(v.group(1))
        out[go_unquote(name)] = cel_type(t)
    return out


def go_type_prefix(text):
    """Splits a composite literal into (Go type, body) or returns (None, text) for an elided type."""
    if text.startswith("{"):
        return None, text
    i = text.index("{")
    return text[:i].strip(), text[i:]


def elem_type(go_type):
    if go_type.startswith("[]"):
        return go_type[2:]
    m = re.fullmatch(r"map\[(\w+)\](.*)", go_type)
    return m.group(2) if m else None


def key_type(go_type):
    m = re.fullmatch(r"map\[(\w+)\](.*)", go_type)
    return m.group(1) if m else None


def scalar(text, go_type):
    """A Go scalar literal as a CEL literal of the Go type's CEL counterpart."""
    text = text.strip()
    if text[0] in "`\"":
        return json.dumps(go_unquote(text), ensure_ascii=False)
    if go_type in ("uint", "uint32", "uint64"):
        return text + "u"
    if go_type in ("float32", "float64"):
        return text if any(c in text for c in ".eE") else text + ".0"
    if re.fullmatch(r"-?\d+", text):
        return text
    if re.fullmatch(r"-?\d+\.\d*", text):
        return text
    if text in ("true", "false"):
        return text
    raise ValueError("scalar " + text)


def cel_value(text, go_type=None):
    text = text.strip()
    m = re.fullmatch(r"\[\]byte\((.*)\)", text, re.S)
    if m:
        return "b" + json.dumps(go_unquote(m.group(1).strip()))
    if text.startswith("[]") or text.startswith("map[") or text.startswith("{"):
        t, body = go_type_prefix(text)
        t = t or go_type
        items = split_top(body[1:-1])
        if t.startswith("[]"):
            return "[" + ", ".join(cel_value(i, elem_type(t)) for i in items) + "]"
        entries_ = []
        for item in items:
            k, v = split_top(item, ":")
            entries_.append("%s: %s" % (cel_value(k, key_type(t)), cel_value(v, elem_type(t))))
        return "{" + ", ".join(entries_) + "}"
    return scalar(text, go_type)


def parse_in(go):
    t, body = go_type_prefix(go.strip())
    if t != "map[string]any":
        raise ValueError("in " + go)
    out = {}
    for item in split_top(body[1:-1]):
        k, v = split_top(item, ":")
        out[go_unquote(k)] = cel_value(v)
    return out


def parse_hints(go):
    t, body = go_type_prefix(go.strip())
    if t != "map[string]uint64":
        raise ValueError("hints " + go)
    out = {}
    for item in split_top(body[1:-1]):
        k, v = split_top(item, ":")
        out[go_unquote(k)] = int(v)
    return out


def uint(text):
    text = text.strip()
    if text in ("math.MaxUint64", "18446744073709551615"):
        return MAX_UINT64
    return int(text)


def parse_estimate(go):
    go = go.strip()
    m = re.fullmatch(r"checker\.FixedCostEstimate\((.*)\)", go)
    if m:
        v = uint(m.group(1))
        return v, v
    m = re.fullmatch(r"checker\.CostEstimate\{\s*Min:\s*([\w.]+),\s*Max:\s*([\w.]+),?\s*\}", go)
    if m:
        return uint(m.group(1)), uint(m.group(2))
    raise ValueError("estimate " + go)


FIELD = re.compile(r"(\w+)\s*:\s*")


def strip_comments(text):
    out, i = [], 0
    while i < len(text):
        if text[i] in "`\"'" or text.startswith("//", i) or text.startswith("/*", i):
            end = tokenize_literal(text, i) if text.find("\n", i) >= 0 or text[i] != "/" else len(text)
            if text[i] != "/":
                out.append(text[i:end])
            i = end
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def raw_fields(text):
    """`field: <Go source>` pairs of a composite literal body, comments dropped."""
    fields = {}
    for part in split_top(strip_comments(text)):
        m = FIELD.match(part)
        if m:
            fields[m.group(1)] = part[m.end():].strip()
    return fields


def rows():
    for name, line, test, env, zero in TABLES:
        for entry_line, text in entries(os.path.join(EXT, name), line):
            f = raw_fields(text)
            entry = "%s:%d" % (name, entry_line)
            try:
                est = parse_estimate(f["estimatedCost"]) if "estimatedCost" in f else (0, 0)
                version = int(f["version"]) if "version" in f else 0
                row = {
                    "entry": entry, "test": test, "env": env,
                    "version": None if (version == 0 and zero == "latest") else version,
                    "expr": go_unquote(f["expr"]),
                    "vars": parse_vars(f["vars"]) if "vars" in f else {},
                    "in": parse_in(f["in"]) if "in" in f else {},
                    "hints": parse_hints(f["hints"]) if "hints" in f else {},
                    "estimate": [str(est[0]), str(est[1])],
                    "actual": str(uint(f["actualCost"])),
                }
            except (KeyError, ValueError) as e:
                print("skipping %s: %s" % (entry, e), file=sys.stderr)
                continue
            container = row["vars"].pop("@container", None)
            if container:
                row["container"] = container
            yield row


# Oracle configs for the environments above (tools/oracle, cel-go env.Config).
def oracle_config(row):
    def ext(n, v="latest"):
        return {"name": n, "version": v}
    v = "latest" if row["version"] is None else row["version"]
    env = row["env"]
    exts = {
        "lists": [ext("lists", v)],
        "sets": [ext("sets", v)],
        "regex": [ext("optional"), ext("regex", v)],
        "encoders": [ext("encoders", v)],
        "math": [ext("math", v)],
        "bindings": [ext("bindings", 0), ext("strings")],
        "comprehensions": [ext("two-var-comprehensions"), ext("bindings"), ext("lists"), ext("strings"),
                           ext("optional")],
        "strings-v5": [ext("strings", 5)],
    }[env]
    variables = [type_desc(n, t) for n, t in row["vars"].items()]
    config = {"extensions": exts, "variables": variables}
    if "container" in row:
        config["container"] = row["container"]
    return config


def type_desc(name, t):
    def desc(t):
        m = re.fullmatch(r"(\w+)\((.*)\)", t)
        if not m:
            return {"type_name": t}
        return {"type_name": m.group(1), "params": [desc(p) for p in split_top(m.group(2))]}
    d = desc(t)
    d["name"] = name
    return d


def verify(oracle):
    proc = subprocess.Popen([oracle], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def ask(req):
        proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    failures = 0
    for row in rows():
        config = oracle_config(row)
        bindings = {}
        for name, lit in row["in"].items():
            cfg = dict(config, variables=[])
            r = ask({"kind": "eval", "expr": lit, "config": cfg})
            bindings[name] = r["result"]["value"]
        hints = {k: {"min": 0, "max": v} for k, v in row["hints"].items()}
        r = ask({"kind": "eval", "expr": row["expr"], "config": config, "bindings": bindings, "size_hints": hints})
        got_est = [str(r.get("cost_estimate", {}).get("min")), str(r.get("cost_estimate", {}).get("max"))]
        ok = r.get("result", {}).get("value") == {"bool": True} or row["test"] == "TestStringCostTracking"
        if not ok or got_est != row["estimate"] or str(r.get("cost")) != row["actual"]:
            failures += 1
            print("MISMATCH %s %s: oracle %s est %s cost %s; table est %s cost %s" % (
                row["entry"], row["expr"], r.get("result"), got_est, r.get("cost"), row["estimate"], row["actual"]))
    print("%d mismatches" % failures, file=sys.stderr)
    return 1 if failures else 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        sys.exit(verify(sys.argv[2]))
    for row in rows():
        print(json.dumps(row, ensure_ascii=False))


if __name__ == "__main__":
    main()
