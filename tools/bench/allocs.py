#!/usr/bin/env python3
"""Allocations per operation of each benchmark case and phase (macOS only).

Builds tools/bench/malloc-count into a dylib that counts malloc calls, then runs the release benchmark driver
under it twice per case and phase, with --iterations 0 and --iterations n, and prints the difference divided
by n as tab-separated lines: name, phase, allocations per operation. Unlike times, these counts do not depend
on the load on the machine. cel-go's driver (tools/bench/go) reports its allocations per operation as the
fourth column of its output.

  tools/bench/allocs.py                         # all cases, built driver in .build/release
  tools/bench/allocs.py --filter policy --phase eval -n 500
  tools/bench/allocs.py --driver other-checkout/.build/release/CELBenchmarks
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
PHASES = ["parse", "check", "plan", "eval"]


def build_counter():
    src = os.path.join(ROOT, "tools/bench/malloc-count/count.c")
    out = os.path.join(ROOT, ".build/libmalloccount.dylib")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run(["clang", "-O2", "-dynamiclib", "-o", out, src], check=True)
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--driver", default=os.path.join(ROOT, ".build/release/CELBenchmarks"))
    p.add_argument("--cases", default=os.path.join(ROOT, "tools/bench/cases.json"))
    p.add_argument("--filter")
    p.add_argument("--phase", help="a phase name or prefix")
    p.add_argument("-n", type=int, default=200, help="iterations per measurement")
    args = p.parse_args()
    if sys.platform != "darwin":
        sys.exit("allocs.py: needs dyld interposing (macOS)")
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=build_counter())

    def count(name, phase, n):
        r = subprocess.run([args.driver, "--cases", args.cases, "--filter", name, "--phase", phase,
                            "--iterations", str(n)], env=env, capture_output=True, text=True, check=True)
        lines = [l for l in r.stderr.splitlines() if l.startswith("malloc-count\t")]
        if not lines:
            sys.exit("allocs.py: the counter did not report; is the driver built without hardened runtime?")
        return int(lines[-1].split("\t")[1])

    import json
    with open(args.cases) as f:
        names = [c["name"] for c in json.load(f) if not args.filter or c["name"] == args.filter]
    for name in names:
        for phase in PHASES:
            if args.phase and not phase.startswith(args.phase):
                continue
            per_op = (count(name, phase, args.n) - count(name, phase, 0)) / args.n
            print(f"{name}\t{phase}\t{per_op:.1f}", flush=True)


if __name__ == "__main__":
    main()
