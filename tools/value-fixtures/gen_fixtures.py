#!/usr/bin/env python3
"""Generates Tests/CELTests/Fixtures/GoValueFixtures.swift from cel-go via tools/oracle.

The fixtures pin the Go formatting and parsing behaviour the Swift value layer ports:
  - string(double): Go strconv.FormatFloat(f, 'g', -1, 64), for edge cases and random bit patterns
  - double(string): Go strconv.ParseFloat(s, 64) acceptance and results
  - duration(string) / string(duration): Go time.ParseDuration and cel-go's formatting
  - timestamp(string) / string(timestamp): RFC 3339 parsing and formatting

Usage (from the repository root):
  (cd tools/oracle && go build -o /tmp/cel-oracle .)
  python3 tools/value-fixtures/gen_fixtures.py /tmp/cel-oracle > Tests/CELTests/Fixtures/GoValueFixtures.swift
"""
import json
import random
import struct
import subprocess
import sys

random.seed(20261001)


def run(oracle, exprs):
    inp = "".join(
        json.dumps({"id": str(i), "kind": "eval", "check": False, "expr": e}) + "\n"
        for i, e in enumerate(exprs)
    )
    out = subprocess.run([oracle], input=inp, capture_output=True, text=True, check=True).stdout
    results = {}
    for line in out.splitlines():
        r = json.loads(line)
        results[int(r["id"])] = r["result"]
    return [results[i] for i in range(len(exprs))]


def cel_double_literal(d):
    lit = repr(d)
    if "e" not in lit and "." not in lit:
        lit += ".0"
    return lit.replace("e+", "e")


def swift_string(s):
    out = '"'
    for ch in s:
        if ch == "\\":
            out += "\\\\"
        elif ch == '"':
            out += '\\"'
        elif ord(ch) < 0x20 or ord(ch) > 0x7E:
            out += "\\u{%x}" % ord(ch)
        else:
            out += ch
    return out + '"'


def double_cases():
    vals = [
        0.0, -0.0, 1.0, -1.0, 0.1, 0.5, 1.5, 2.5, 100.0, 1e5, 1e6, 123456.0, 1234567.0, 1e20,
        1e21, 1e22, 1e-4, 1e-5, 0.0001234, 0.00001234, 5e-324, 2.2250738585072014e-308,
        1.7976931348623157e308, 9007199254740993.0, 3.141592653589793, 2.718281828459045, 1 / 3,
        2 / 3, 1e15, 1e16, 1e17, 123456789012345680.0, 0.3, 0.7, -1.23e4, 1e100, 1e-100, 4.35,
        0.1 + 0.2, 9.999999999999999e22, 1e23, 5e-310, 1.0000000000000002, 0.9999999999999999,
        255.0, 65535.0, 4294967295.0, 18446744073709551615.0, 9223372036854775807.0, 999999.0,
        999999.5, 0.000099999, 0.00009999999999999999,
    ]
    while len(vals) < 1500:
        d = struct.unpack("<d", struct.pack("<Q", random.getrandbits(64)))[0]
        if d != d or d in (float("inf"), float("-inf")):
            continue
        vals.append(d)
    for _ in range(500):
        vals.append(round(random.uniform(-1e6, 1e6), random.randint(0, 8)))
    return vals


PARSE_DOUBLE = [
    "0", "1", "-1", "+1", "1.5", ".5", "5.", "-.5", "1e10", "1E10", "1e+10", "1e-10", "1e", "e1",
    "1_000", "1__0", "_1", "1_", "1_000.5", "0x1p3", "0x1P-2", "0x1.8p1", "0x10", "0x_1p0",
    "0x1p", "inf", "+inf", "-Inf", "infinity", "+Infinity", "-INFINITY", "infin", "nan", "NaN",
    "-nan", "+nan", "nanx", "1e999", "-1e999", "1e-999", "4.9e-324", "2.5e-324",
    "1.7976931348623157e308", "1.7976931348623159e308", "", " 1", "1 ", "1.2.3", "0.1",
    "123456789012345678901234567890", "1e1_0", "00012", "0x", "0b101", "0o17", "1d", "١",
]

PARSE_DURATION = [
    "0", "-0", "+0", "", "1s", "1.5s", "-1.5s", "+1.5s", "1h2m3s", "1h2m3.5s", "300ms",
    "1us", "1µs", "1μs", "1ns", "2h45m", ".5s", "5.s", ".s", "1", "1x", "1.5.5s",
    "9223372036s", "9223372037s", "2562047h", "2562048h", "-2562047h47m16.854775808s",
    "2562047h47m16.854775807s", "2562047h47m16.854775808s", "1.000000001s", "0.0000000001s",
    "1.23456789123s", "-1m", "3m30s", "1h1h", "100000000000000000000ns", "1e3s",
]

FORMAT_DURATION = [
    "0s", "1s", "1.5s", "-1.5s", "1h", "-1ns", "1ns", "1us", "1ms", "123456789ns",
    "2562047h47m16.854775807s", "-2562047h47m16.854775808s", "86400s", "0.000001s", "1.1s",
    "100.001s",
]

PARSE_TIMESTAMP = [
    "2009-02-13T23:31:30Z", "2009-02-13t23:31:30Z", "2009-02-13T23:31:30z",
    "2009-02-13T23:31:60Z", "2009-02-30T23:31:30Z", "2008-02-29T00:00:00Z",
    "2009-02-29T00:00:00Z", "2009-02-13T23:31:30.123Z", "2009-02-13T23:31:30.123456789Z",
    "2009-02-13T23:31:30.1234567891Z", "2009-02-13T23:31:30.Z", "2009-02-13T23:31:30+01:00",
    "2009-02-13T23:31:30-08:30", "2009-02-13T23:31:30+00:00", "2009-02-13T23:31:30-00:00",
    "2009-02-13T23:31:30+24:00", "2009-02-13T23:31:30+23:59", "0001-01-01T00:00:00Z",
    "0000-12-31T23:59:59Z", "9999-12-31T23:59:59.999999999Z", "9999-12-31T23:59:59-01:00",
    "0001-01-01T00:00:00+01:00", "2009-02-13 23:31:30Z", "2009-2-13T23:31:30Z",
    "2009-02-13T23:31:30", "2009-02-13T23:31:30+0100", "1970-01-01T00:00:00Z",
    "1969-12-31T23:59:59.999999999Z", "2000-01-01T00:00:00.000Z", "2000-01-01T00:00:00.100Z",
]

TIMESTAMP_ACCESSORS = [
    "getFullYear", "getMonth", "getDayOfYear", "getDayOfMonth", "getDate", "getDayOfWeek",
    "getHours", "getMinutes", "getSeconds", "getMilliseconds",
]

TIMESTAMPS_FOR_ACCESSORS = [
    "2009-02-13T23:31:30.123456789Z", "1970-01-01T00:00:00Z", "0001-01-01T00:00:00Z",
    "9999-12-31T23:59:59.999Z", "2000-02-29T12:00:00Z", "1969-12-31T23:59:59.5Z",
    "2023-07-14T10:30:45.123Z",
]

TIME_ZONES = [
    None, "UTC", "+01:00", "-08:00", "+05:30", "-0:30", "+23:59", "-23:59", "02:00", "America/Los_Angeles",
    "Europe/Warsaw", "Asia/Kolkata", "Australia/Lord_Howe",
]


def main():
    oracle = sys.argv[1]
    lines = []
    w = lines.append
    w("// Generated by tools/value-fixtures/gen_fixtures.py from cel-go v0.32.0 via tools/oracle.")
    w("// Do not edit by hand; regenerate instead.")
    w("")
    w("enum GoValueFixtures {")

    # string(double)
    vals = double_cases()
    results = run(oracle, ["string(%s)" % cel_double_literal(d) for d in vals])
    w("  /// (IEEE 754 bits, Go strconv.FormatFloat(f, 'g', -1, 64)).")
    w("  static let doubleToString: [(UInt64, String)] = [")
    for d, r in zip(vals, results):
        bits = struct.unpack("<Q", struct.pack("<d", d))[0]
        w("    (0x%016x, %s)," % (bits, swift_string(r["value"]["string"])))
    w("  ]")
    w("")

    # double(string)
    results = run(oracle, ["double(%s)" % json.dumps(s) for s in PARSE_DOUBLE])
    w("  /// (input, IEEE 754 bits or nil when Go strconv.ParseFloat fails).")
    w("  static let stringToDouble: [(String, UInt64?)] = [")
    for s, r in zip(PARSE_DOUBLE, results):
        if "value" in r:
            v = r["value"]["double"]
            if isinstance(v, str):
                d = {"NaN": float("nan"), "Infinity": float("inf"), "-Infinity": float("-inf")}[v]
            else:
                d = float(v)
            bits = "0x%016x" % struct.unpack("<Q", struct.pack("<d", d))[0]
        else:
            bits = "nil"
        w("    (%s, %s)," % (swift_string(s), bits))
    w("  ]")
    w("")

    # duration(string) -> int nanos
    results = run(oracle, ["int(duration(%s))" % json.dumps(s) for s in PARSE_DURATION])
    w("  /// (input, nanoseconds or nil when Go time.ParseDuration fails).")
    w("  static let stringToDuration: [(String, Int64?)] = [")
    for s, r in zip(PARSE_DURATION, results):
        v = r["value"]["int"] if "value" in r else None
        w("    (%s, %s)," % (swift_string(s), "nil" if v is None else str(int(v))))
    w("  ]")
    w("")

    # string(duration)
    results = run(oracle, ["string(duration(%s))" % json.dumps(s) for s in FORMAT_DURATION])
    nanos = run(oracle, ["int(duration(%s))" % json.dumps(s) for s in FORMAT_DURATION])
    w("  /// (nanoseconds, string(duration)).")
    w("  static let durationToString: [(Int64, String)] = [")
    for r, n in zip(results, nanos):
        w("    (%s, %s)," % (int(n["value"]["int"]), swift_string(r["value"]["string"])))
    w("  ]")
    w("")

    # timestamp(string) -> (seconds, nanos, string(ts)) or error
    secs = run(oracle, ["int(timestamp(%s))" % json.dumps(s) for s in PARSE_TIMESTAMP])
    strs = run(oracle, ["string(timestamp(%s))" % json.dumps(s) for s in PARSE_TIMESTAMP])
    ms = run(oracle, ["timestamp(%s).getMilliseconds()" % json.dumps(s) for s in PARSE_TIMESTAMP])
    w("  /// (input, (unix seconds, milliseconds, string(timestamp)) or the error message).")
    w("  static let stringToTimestamp: [(String, Result<(Int64, Int64, String), FixtureError>)] = [")
    for s, a, b, c in zip(PARSE_TIMESTAMP, secs, strs, ms):
        if "value" in a:
            w("    (%s, .success((%s, %s, %s)))," % (
                swift_string(s), int(a["value"]["int"]), int(c["value"]["int"]),
                swift_string(b["value"]["string"])))
        else:
            w("    (%s, .failure(FixtureError(%s)))," % (swift_string(s), swift_string(a["error"])))
    w("  ]")
    w("")

    # timestamp accessors with time zones
    exprs = []
    keys = []
    for ts in TIMESTAMPS_FOR_ACCESSORS:
        for acc in TIMESTAMP_ACCESSORS:
            for tz in TIME_ZONES:
                arg = "" if tz is None else json.dumps(tz)
                exprs.append("timestamp(%s).%s(%s)" % (json.dumps(ts), acc, arg))
                keys.append((ts, acc, tz))
    results = run(oracle, exprs)
    w("  /// (timestamp, accessor, time zone or nil, result or error message).")
    w("  static let timestampAccessors: [(String, String, String?, Result<Int64, FixtureError>)] = [")
    for (ts, acc, tz), r in zip(keys, results):
        tzs = "nil" if tz is None else swift_string(tz)
        if "value" in r:
            res = ".success(%s)" % int(r["value"]["int"])
        else:
            res = ".failure(FixtureError(%s))" % swift_string(r["error"])
        w("    (%s, %s, %s, %s)," % (swift_string(ts), swift_string(acc), tzs, res))
    w("  ]")
    w("}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
