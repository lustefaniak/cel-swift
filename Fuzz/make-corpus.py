#!/usr/bin/env python3
"""Writes the seed corpora Fuzz/corpus/<target>/ from the parser fixtures.

Deterministic: the same fixtures give the same files. Each target gets at most LIMIT expressions,
spread over the fixture files (sampled by hash, so a rerun after a fixture change moves few files).

    python3 Fuzz/make-corpus.py
"""

import hashlib
import json
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Tests", "CELTests", "ParserFixtures")
CORPUS = os.path.join(ROOT, "Fuzz", "corpus")
LIMIT = 300

# Expressions over the fuzz environment's variables (Sources/CELFuzzSupport), so the checker and
# evaluator corpora start with well-typed inputs that reach comprehensions and the bindings.
ENV_SEEDS = [
    "i + 1 > 0 && s.startsWith('h')",
    "l.map(e, e * i).filter(e, e % 2 == 0).size()",
    "l.all(e, e > 0) || l.exists_one(e, e == 3)",
    "m.a + 1 == 2 ? m.b : string(m.c)",
    "has(m.c) && m.c[0] == true",
    "x.k[1] / 2.0",
    "o.orValue('none') + s",
    "o.hasValue() ? o.value() : ''",
    "t + dur > timestamp('2023-01-01T00:00:00Z')",
    "t.getHours('America/New_York') + dur.getMinutes()",
    "b + b'\\x00' == bytes(s)",
    "u * 2u - uint(i * i)",
    "d.ceil() == 3.0 || double(i) < d",
    "s.matches('^h.*d$') && size(s) == 11",
    "[1, 2, 3].map(a, [a, a]).map(p, p[0] + p[1])",
    "{'k': l, 'n': {'x': m}}.n.x.b",
    "TestAllTypes{single_int64: i, repeated_string: [s]}.repeated_string[0]",
    "TestAllTypes{}.?single_nested_message.bb.orValue(0)",
    "cel.expr.conformance.proto2.TestAllTypes{single_int32: 1}.single_int32",
    "[?o, ?optional.none(), optional.of(1)]",
    "m.?a.optMap(v, v + 1)",
    "l.map(a, l.map(b, l.map(c, a + b + c))).size()",
    "type(x) == map && dyn(l)[0] == 1",
    "int(s.size()) + i in l",
    "duration('1h2m3.5s') + dur < duration('2h')",
]


def sample(exprs):
    unique = sorted(set(e for e in exprs if e))
    unique.sort(key=lambda e: hashlib.sha256(e.encode()).hexdigest())
    return unique


def load():
    with open(os.path.join(FIXTURES, "parse_conformance.json")) as f:
        conformance = [c["expr"] for c in json.load(f)]
    with open(os.path.join(FIXTURES, "parse_fuzz.json")) as f:
        fuzz = [c["expr"] for c in json.load(f)]
    with open(os.path.join(FIXTURES, "parser_test_cases.json")) as f:
        tables = json.load(f)
    parser_tests = []
    for table in tables.values():
        for case in table:
            for key in ("in", "expr", "i"):
                if isinstance(case, dict) and isinstance(case.get(key), str):
                    parser_tests.append(case[key])
    return conformance, fuzz, parser_tests


def write(target, exprs):
    path = os.path.join(CORPUS, target)
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.makedirs(path)
    for e in exprs:
        data = e.encode()
        name = hashlib.sha1(data).hexdigest()
        with open(os.path.join(path, name), "wb") as f:
            f.write(data)


def main():
    conformance, fuzz, parser_tests = load()
    conf = sample(conformance)
    write("parser", sample(ENV_SEEDS + conf[:120] + sample(fuzz)[:90] + sample(parser_tests)[:90])[:LIMIT])
    semantic = sample(ENV_SEEDS + conf[: LIMIT - len(ENV_SEEDS)])
    write("checker", semantic)
    write("evaluator", semantic)


if __name__ == "__main__":
    main()
