#!/usr/bin/env python3
"""Generates Tests/CELTests/PartialFixtures/partial_eval.json from cel-go via tools/oracle.

Every case below is evaluated by cel-go with partial evaluation and state tracking (the oracle's
`residual` flag), in checked and parse-only mode, and the result is recorded: the value, error or
unknown set (expression ids and attribute trails), and `Env.ResidualAst` printed with `AstToString`.
`PartialEvaluationFixtureTests` replays them through cel-swift's public API (`partialEvaluation`,
`trackState`, `Environment.residual(of:state:)`).

Environment: standard library, optional types and macro call tracking, plus the case's variables.

Usage (from the repository root):
  (cd tools/oracle && go build -o /tmp/cel-oracle .)
  python3 tools/partial-fixtures/gen_partial_fixtures.py /tmp/cel-oracle > Tests/CELTests/PartialFixtures/partial_eval.json
"""
import json
import re
import subprocess
import sys

I, S, B, D, U = "int", "string", "bool", "double", "uint"
DYN = "dyn"


def L(t):
    return f"list({t})"


def M(k, v):
    return f"map({k}, {v})"


def O(t):
    return f"optional({t})"


def uint(v):
    return ("uint", v)


def opt(v=None):
    return ("optional", v)


def ts(s):
    return ("timestamp", s)


def dur(s):
    return ("duration", s)


# (expression, declarations, bindings, unknown patterns). A pattern is a list: the variable name, then
# qualifiers (str, int, bool, uint(n) or "*" for a wildcard).
CASES = [
    # Logical operators and short-circuiting around unknowns.
    ("x < 10 && (y == 0 || 'hello' != 'goodbye')", {"x": I, "y": I}, {}, [["x"], ["y"]]),
    ("x < 10 && y == 0", {"x": I, "y": I}, {"y": 0}, [["x"]]),
    ("x < 10 && y == 0", {"x": I, "y": I}, {"y": 1}, [["x"]]),
    ("x < 10 || y == 0", {"x": I, "y": I}, {"y": 0}, [["x"]]),
    ("x < 10 || y == 0", {"x": I, "y": I}, {"y": 1}, [["x"]]),
    ("x || y", {"x": B, "y": B}, {}, [["x"], ["y"]]),
    ("x && y", {"x": B, "y": B}, {}, [["x"], ["y"]]),
    ("x && !y", {"x": B, "y": B}, {"y": False}, [["x"]]),
    ("!(x || y)", {"x": B, "y": B}, {"y": False}, [["x"]]),
    ("x && (1/0 > 0)", {"x": B}, {}, [["x"]]),
    ("(1/0 > 0) || x", {"x": B}, {}, [["x"]]),
    ("x || (1/0 > 0)", {"x": B}, {}, [["x"]]),
    ("x && y && z", {"x": B, "y": B, "z": B}, {"y": True}, [["x"], ["z"]]),
    ("x || y || z", {"x": B, "y": B, "z": B}, {"y": False}, [["x"], ["z"]]),
    ("x || y || z", {"x": B, "y": B, "z": B}, {"y": True}, [["x"], ["z"]]),
    # Conditionals.
    ("c ? a : b", {"a": I, "b": I, "c": B}, {"a": 1, "b": 2}, [["c"]]),
    ("c ? a : b", {"a": I, "b": I, "c": B}, {"c": True, "b": 2}, [["a"]]),
    ("c ? a : b", {"a": I, "b": I, "c": B}, {"c": False, "a": 1}, [["b"]]),
    ("(c ? a : b) + 1 > 3", {"a": I, "b": I, "c": B}, {"c": True}, [["a"], ["b"]]),
    ("c ? a.f : b.f", {"a": M(S, I), "b": M(S, I), "c": B}, {"c": True, "b": {"f": 1}}, [["a"]]),
    # Arithmetic, comparison and functions with unknown arguments.
    ("x + 1 == y", {"x": I, "y": I}, {"y": 3}, [["x"]]),
    ("x + y * 2", {"x": I, "y": I}, {"y": 3}, [["x"]]),
    ("size(s) > n && s.startsWith('a')", {"s": S, "n": I}, {"s": "abc"}, [["n"]]),
    ("s.startsWith(p) && s.endsWith(q)", {"s": S, "p": S, "q": S}, {"s": "abc", "p": "a"}, [["q"]]),
    ("string(x) + '!' == s", {"x": I, "s": S}, {"x": 5}, [["s"]]),
    ("x == string(y)", {"x": S, "y": I}, {}, [["x"], ["y"]]),
    ("x == string(y)", {"x": S, "y": I}, {"y": 10}, [["x"]]),
    ("int(d) + 1 > i", {"d": D, "i": I}, {"d": 2.5}, [["i"]]),
    ("u + 1u == v", {"u": U, "v": U}, {"u": uint(2)}, [["v"]]),
    ("t + duration('1h') < now", {"t": "timestamp", "now": "timestamp"},
     {"t": ts("2020-01-01T00:00:00Z")}, [["now"]]),
    ("d > duration('1m') && d < limit", {"d": "duration", "limit": "duration"}, {"d": dur("90s")}, [["limit"]]),
    ("type(x) == int && x > y", {"x": DYN, "y": I}, {"x": 3}, [["y"]]),
    ("x in [1, 2, 3]", {"x": I}, {}, [["x"]]),
    ("1 in l", {"l": L(I)}, {}, [["l"]]),
    ("x in l", {"x": I, "l": L(I)}, {"l": [1, 2]}, [["x"]]),
    ("x in l", {"x": I, "l": L(I)}, {"l": []}, [["x"]]),
    ("k in m", {"k": S, "m": M(S, I)}, {"m": {"a": 1}}, [["k"]]),
    ("x in {}", {"x": S}, {}, [["x"]]),
    ("[x, y, 1 + 2]", {"x": I, "y": I}, {"y": 2}, [["x"]]),
    ("{'a': x, 'b': 1 + 1}", {"x": I}, {}, [["x"]]),
    ("[x, y] == [1, 2]", {"x": I, "y": I}, {"y": 2}, [["x"]]),
    # Attribute qualifiers and patterns.
    ("a.b.c == 1", {"a": M(S, M(S, I))}, {"a": {"b": {"c": 1}}}, [["a", "b"]]),
    ("a.b.c == 1 && a.d == 2", {"a": M(S, DYN)}, {"a": {"b": {"c": 1}, "d": 2}}, [["a", "b", "c"]]),
    ("a.b.c == 1 && a.d == 2", {"a": M(S, DYN)}, {"a": {"b": {"c": 1}, "d": 3}}, [["a", "b", "c"]]),
    ("a['b'] == 1", {"a": M(S, I)}, {"a": {"b": 1}}, [["a", "b"]]),
    ("a[0] + a[1]", {"a": L(I)}, {"a": [1, 2]}, [["a", 0]]),
    ("a[0] + a[1]", {"a": L(I)}, {"a": [1, 2]}, [["a", "*"]]),
    ("a[1u]", {"a": M(U, I)}, {"a": {}}, [["a", uint(1)]]),
    ("a[true]", {"a": M(B, I)}, {"a": {}}, [["a", True]]),
    ("a[i]", {"a": L(I), "i": I}, {"a": [10, 20]}, [["i"]]),
    ("a[i] == 20", {"a": L(I), "i": I}, {"i": 1}, [["a"]]),
    ("a[a.size() - 1]", {"a": L(I)}, {}, [["a"]]),
    ("m[k].f", {"m": M(S, M(S, I)), "k": S}, {"m": {"x": {"f": 1}}}, [["k"]]),
    ("m[k].f", {"m": M(S, M(S, I)), "k": S}, {"k": "x"}, [["m", "x"]]),
    ("m[k].f", {"m": M(S, M(S, I)), "k": S}, {"k": "x", "m": {"x": {"f": 1}}}, [["m", "*", "f"]]),
    ("m[k].f", {"m": M(S, M(S, I)), "k": S}, {"k": "x", "m": {"x": {"f": 1}}}, [["m", "y", "f"]]),
    ("request.auth.claims.email == 'a@b.c' && request.time > timestamp(0)",
     {"request.auth.claims": M(S, S), "request.time": "timestamp"},
     {"request.time": ts("2020-01-01T00:00:00Z")}, [["request.auth.claims", "email"]]),
    ("has(a.b)", {"a": M(S, I)}, {}, [["a"]]),
    ("has(a.b)", {"a": M(S, I)}, {"a": {"b": 1}}, [["a", "b"]]),
    ("has(a.b.c)", {"a": M(S, M(S, I))}, {"a": {"b": {}}}, [["a", "b"]]),
    ("has(a.b) || has(a.c)", {"a": M(S, I)}, {"a": {"c": 1}}, [["a", "b"]]),
    ("has(a.b) && has(a.c)", {"a": M(S, I)}, {"a": {"c": 1}}, [["a", "b"]]),
    ("(true ? x : y).abc == u", {"x": M(S, I), "y": M(S, I), "u": I}, {"x": {"abc": 1}, "y": {}}, [["u"]]),
    ("(c ? x : y).abc", {"x": M(S, I), "y": M(S, I), "c": B}, {"x": {"abc": 1}, "y": {"abc": 2}}, [["c"]]),
    # Comprehensions and macros.
    ("x.exists(i, i < 10)", {"x": L(I)}, {}, [["x"]]),
    ("x.exists(i, i < 10) && [11, 12, 13].all(i, i in [y, 12, 13])", {"x": L(I), "y": I}, {"y": 11}, [["x"]]),
    ("l.all(i, i > y)", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("l.all(i, i > y)", {"l": L(I), "y": I}, {"l": []}, [["y"]]),
    ("l.exists(i, i == y)", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("l.exists_one(i, i == y)", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("l.map(i, i * y)", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("l.filter(i, i > y)", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("l.map(i, i * 2).filter(i, i > y).size() > 0", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("l.map(i, i > 1, i * y)", {"l": L(I), "y": I}, {"l": [1, 2]}, [["y"]]),
    ("foo.exists(t, t == bar.baz.x)", {"foo": M(S, DYN), "bar": M(S, DYN)}, {"foo": {"a": "b"}},
     [["bar", "baz", "*"]]),
    ("users.filter(u, u.startsWith(r.attr.prefix))", {"users": L(S), "r": M(S, DYN)},
     {"users": ["alice", "bob"]}, [["r", "attr", "*"]]),
    ("[1, 2, 3].exists(i, i == x) || y", {"x": I, "y": B}, {"x": 2}, [["y"]]),
    ("[1, 2, 3].all(i, i != x) && y", {"x": I, "y": B}, {"x": 2}, [["y"]]),
    ("[x, 2].exists(i, i == 2)", {"x": I}, {}, [["x"]]),
    ("[x, 3].exists(i, i == 2)", {"x": I}, {}, [["x"]]),
    ("[x, 3].all(i, i == 3)", {"x": I}, {}, [["x"]]),
    ("[x, 2].all(i, i == 3)", {"x": I}, {}, [["x"]]),
    ("m.all(k, m[k] > y)", {"m": M(S, I), "y": I}, {"m": {"a": 1}}, [["y"]]),
    ("[has(a.b), has(c.d)].exists(x, x == true)", {"a": M(S, I), "c": M(S, I)}, {"a": {}}, [["c"]]),
    # Optionals.
    ("x.or(y).orValue(z)", {"x": O(I), "y": O(I), "z": I}, {"y": opt(), "z": 42}, [["x"]]),
    ("x.or(y).orValue(z)", {"x": O(I), "y": O(I), "z": I}, {"x": opt(), "y": opt()}, [["z"]]),
    ("x.or(y).orValue(z)", {"x": O(I), "y": O(I), "z": I}, {"x": opt(1)}, [["y"], ["z"]]),
    ("a.?b.orValue(0) + 1", {"a": M(S, I)}, {}, [["a"]]),
    ("a.?b.orValue(0) + c", {"a": M(S, I), "c": I}, {"a": {"b": 2}}, [["c"]]),
    ("a[?'b'].hasValue() || c", {"a": M(S, I), "c": B}, {"a": {}}, [["c"]]),
    ("[?a.?b, 1]", {"a": M(S, I)}, {}, [["a"]]),
    ("{?'k': a.?b}", {"a": M(S, I)}, {}, [["a"]]),
    ("{?'k': a.?b, 'j': c}", {"a": M(S, I), "c": I}, {"a": {"b": 1}}, [["c"]]),
    ("optional.of(x).value() + 1", {"x": I}, {}, [["x"]]),
    ("optional.ofNonZeroValue(x).hasValue()", {"x": I}, {}, [["x"]]),
    # Errors next to unknowns.
    ("x == (1/0)", {"x": I}, {}, [["x"]]),
    ("x != (1/0)", {"x": I}, {}, [["x"]]),
    ("x + [1][5]", {"x": I}, {}, [["x"]]),
    ("[x, 1/0]", {"x": I}, {}, [["x"]]),
    ("{'a': x, 'b': 1/0}", {"x": I}, {}, [["x"]]),
    ("x / y", {"x": I, "y": I}, {"y": 0}, [["x"]]),
    ("m.missing == x", {"m": M(S, I), "x": I}, {"m": {}}, [["x"]]),
    # Nothing unknown.
    ("x + 1", {"x": I}, {"x": 1}, []),
    ("x.exists(i, i > 1)", {"x": L(I)}, {"x": [1, 2]}, []),
]


def type_desc(t):
    t = t.strip()
    m = re.fullmatch(r"(\w+)\((.*)\)", t)
    if not m:
        return {"type_name": t}
    name, inner = m.group(1), m.group(2)
    params, depth, cur = [], 0, ""
    for ch in inner:
        if ch == "," and depth == 0:
            params.append(cur)
            cur = ""
            continue
        depth += ch == "("
        depth -= ch == ")"
        cur += ch
    params.append(cur)
    name = "optional_type" if name == "optional" else name
    return {"type_name": name, "params": [type_desc(p) for p in params]}


def encode(v):
    if v is None:
        return {"null": None}
    if isinstance(v, bool):
        return {"bool": v}
    if isinstance(v, int):
        return {"int": str(v)}
    if isinstance(v, float):
        return {"double": v}
    if isinstance(v, str):
        return {"string": v}
    if isinstance(v, list):
        return {"list": [encode(e) for e in v]}
    if isinstance(v, dict):
        return {"map": [{"key": encode(k), "value": encode(e)} for k, e in sorted(v.items())]}
    tag, payload = v
    if tag == "uint":
        return {"uint": str(payload)}
    if tag == "optional":
        return {"optional": None if payload is None else encode(payload)}
    return {tag: payload}


def qualifier(q):
    if q == "*":
        return "*"
    return encode(q)


def main():
    oracle = sys.argv[1]
    requests = []
    for n, (expr, decls, bindings, unknowns) in enumerate(CASES):
        for checked in (True, False):
            config = {
                "extensions": [{"name": "optional"}],
                "features": [{"name": "cel.feature.macro_call_tracking", "enabled": True}],
                "variables": [dict(name=k, **type_desc(t)) for k, t in decls.items()],
            }
            req = {
                "id": f"{n}-{'checked' if checked else 'parsed'}",
                "kind": "eval",
                "expr": expr,
                "config": config,
                "bindings": {k: encode(v) for k, v in bindings.items()},
                "unknowns": [{"variable": u[0], "path": [qualifier(q) for q in u[1:]]} for u in unknowns],
                "residual": True,
            }
            if not checked:
                req["check"] = False
            requests.append((req, decls, unknowns))
    proc = subprocess.run(
        [oracle], input="\n".join(json.dumps(r) for r, _, _ in requests) + "\n", capture_output=True,
        text=True, check=True)
    records = []
    for (req, decls, unknowns), line in zip(requests, proc.stdout.splitlines()):
        resp = json.loads(line)
        if resp.get("oracle_error"):
            sys.exit(f"{req['id']} {req['expr']}: {resp['oracle_error']}")
        if resp.get("error"):
            sys.exit(f"{req['id']} {req['expr']}: {resp['error']}")
        records.append({
            "id": req["id"],
            "expr": req["expr"],
            "checked": "check" not in req,
            "variables": [[k, t] for k, t in decls.items()],
            "bindings": req["bindings"],
            "unknowns": req["unknowns"],
            "result": resp["result"],
            "residual": resp.get("residual"),
            "residual_error": resp.get("residual_error"),
        })
    json.dump(records, sys.stdout, indent=1, sort_keys=True, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
