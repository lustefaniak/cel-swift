#!/usr/bin/env python3
"""Compare cel-swift with cel-go on the expressions in tools/bench/cases.json.

Builds and runs Benchmarks/CELBenchmarks (release, through tools/build-guard/swiftlock) and the cel-go driver in
tools/bench/go, then prints a markdown table of ns/op per case and phase (parse, check, plan, eval) with the
Swift/Go ratio.

  tools/bench/bench.py                       # both drivers, full table
  tools/bench/bench.py --swift-only --save before.tsv
  tools/bench/bench.py --swift-only --baseline before.tsv   # Swift now vs a saved Swift run
  tools/bench/bench.py --go-results go.tsv   # reuse a saved cel-go run
  tools/bench/bench.py --swift-results a.tsv --baseline b.tsv   # compare two saved Swift runs

Options --rounds, --round-ms, --filter and --phase are passed to both drivers.
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
PHASES = ["parse", "check", "plan", "eval"]


def parse_tsv(text):
    results = {}
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) >= 3:
            results[(fields[0], fields[1])] = float(fields[2])
    return results


def driver_args(args):
    return ["--rounds", str(args.rounds), "--round-ms", str(args.round_ms)] + (
        ["--filter", args.filter] if args.filter else [])


def run_swift(args):
    if not args.no_build:
        subprocess.run([os.path.join(ROOT, "tools/build-guard/swiftlock"), "swift", "build", "-c", "release",
                        "--product", "CELBenchmarks", "-j", "4"], cwd=ROOT, check=True, stdout=sys.stderr)
    cmd = [os.path.join(ROOT, ".build/release/CELBenchmarks"), "--cases", "tools/bench/cases.json"] + driver_args(args)
    if args.phase:
        cmd += ["--phase", args.phase]
    return subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout


def run_go(args):
    cmd = ["go", "run", ".", "-cases", "../cases.json", "-rounds", str(args.rounds), "-round-ms", str(args.round_ms)]
    if args.filter:
        cmd += ["-filter", args.filter]
    out = subprocess.run(cmd, cwd=os.path.join(ROOT, "tools/bench/go"), check=True, capture_output=True,
                         text=True).stdout
    if args.phase:
        out = "\n".join(l for l in out.splitlines() if l.split("\t")[1:2] == [args.phase])
    return out


def fmt(ns):
    if ns is None:
        return "-"
    if ns >= 1e6:
        return f"{ns / 1e6:.2f} ms"
    if ns >= 1e3:
        return f"{ns / 1e3:.1f} µs"
    return f"{ns:.0f} ns"


def table(left, right, left_name, right_name):
    names = []
    for name, _ in list(left) + list(right):
        if name not in names:
            names.append(name)
    print(f"| case | phase | {left_name} | {right_name} | {left_name}/{right_name} |")
    print("|---|---|---:|---:|---:|")
    for name in names:
        for phase in PHASES:
            a, b = left.get((name, phase)), right.get((name, phase))
            if a is None:
                continue
            ratio = f"{a / b:.2f}×" if a and b else "-"
            print(f"| {name} | {phase} | {fmt(a)} | {fmt(b)} | {ratio} |")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--round-ms", type=int, default=100)
    p.add_argument("--filter")
    p.add_argument("--phase", help="only this phase; a unique prefix is enough (pa, ch, pl, ev)")
    p.add_argument("--swift-only", action="store_true")
    p.add_argument("--no-build", action="store_true", help="use the existing release build")
    p.add_argument("--save", help="write the Swift results to this TSV file")
    p.add_argument("--baseline", help="compare against a saved Swift TSV instead of cel-go")
    p.add_argument("--go-results", help="use a saved cel-go TSV instead of running the Go driver")
    p.add_argument("--swift-results", help="use a saved Swift TSV instead of building and running CELBenchmarks")
    args = p.parse_args()
    if args.phase:
        matches = [phase for phase in PHASES if phase.startswith(args.phase)]
        if len(matches) != 1:
            p.error(f"--phase {args.phase}: expected one of {', '.join(PHASES)}")
        args.phase = matches[0]

    if args.swift_results:
        with open(args.swift_results) as f:
            swift_out = f.read()
    else:
        swift_out = run_swift(args)
    if args.save:
        with open(args.save, "w") as f:
            f.write(swift_out)
    swift = parse_tsv(swift_out)
    if args.baseline:
        with open(args.baseline) as f:
            table(swift, parse_tsv(f.read()), "after", "before")
        return
    if args.swift_only:
        table(swift, {}, "cel-swift", "-")
        return
    if args.go_results:
        with open(args.go_results) as f:
            go = parse_tsv(f.read())
    else:
        go = parse_tsv(run_go(args))
    table(swift, go, "cel-swift", "cel-go")


if __name__ == "__main__":
    main()
