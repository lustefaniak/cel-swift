#!/usr/bin/env python3
"""Profile one benchmark phase with Instruments' Time Profiler and summarise where the time goes (macOS only).

Records the release benchmark driver with `xctrace` and prints, as percentages of all samples: the time
by runtime category of the leaf frame (retain/release, malloc/free, exclusivity checks, hashing, ...), the
functions with the most self time, the functions with the most inclusive time, and for samples whose leaf is
in the Swift runtime or the allocator, the first caller outside them (who causes the ARC and malloc work).

  tools/bench/profile.py --phase parse                      # all cases
  tools/bench/profile.py --phase eval --filter policy --top 40
  tools/bench/profile.py --phase check --focus resolveOverload   # only samples under that frame
  tools/bench/profile.py --phase parse --callers 'swift_beginAccess'   # who calls a leaf
  tools/bench/profile.py --xml .build/profile/parse.xml     # summarise an earlier recording again

The trace and its XML export are kept in .build/profile/ for Instruments or another pass.
"""
import argparse
import collections
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))

CATEGORIES = [
    ("retain/release", r"swift_(retain|release|bridgeObjectRe|unknownObjectRe|unownedRe|weak)|_swift_release_dealloc|"
                       r"swift_tryRetain|RefCounts|HeapObjectSideTable"),
    ("malloc/free", r"^(_?malloc|_?free|_xzm|xzm_|_nanov2|nanov2|szone|swift_allocObject|swift_deallocObject|"
                    r"swift_deallocClassInstance|swift::swift_slowAlloc|swift_slowAlloc|swift_slowDealloc|malloc_zone|"
                    r"_malloc_zone|_platform_memset|calloc|realloc)"),
    ("exclusivity", r"swift_beginAccess|swift_endAccess|SwiftTLSContext|AccessSet"),
    ("dynamic casts", r"swift_dynamicCast|swift_conformsToProtocol|tryCast|swift_getObjectType|ConformanceState"),
    ("metadata", r"swift_getGenericMetadata|swift_getWitnessTable|swift_getAssociated|instantiateConcreteType|"
                 r"swift_getTypeByMangledName|swift_checkMetadataState"),
    ("value witnesses", r"^(initializeWithCopy|assignWithCopy|destroy|initializeWithTake|assignWithTake|outlined) "),
    ("locks", r"pthread_rwlock|pthread_mutex|os_unfair|_os_lock"),
    ("hashing", r"Hasher|_hash|hashValue|_rawHashValue"),
]
RUNTIME = re.compile(r"^(swift_|_swift|swift::|bool swift::|outlined|_?malloc|_?free|_xzm|xzm|nanov2|_platform|"
                     r"DYLD-STUB|__swift|objc_|<deduplicated)")


def record(args):
    out = os.path.join(ROOT, ".build/profile")
    os.makedirs(out, exist_ok=True)
    name = args.phase + (f"-{args.filter}" if args.filter else "")
    trace, xml = os.path.join(out, name + ".trace"), os.path.join(out, name + ".xml")
    subprocess.run(["rm", "-rf", trace], check=True)
    cmd = [args.driver, "--cases", args.cases, "--phase", args.phase, "--rounds", "15", "--round-ms", "60"]
    if args.filter:
        cmd += ["--filter", args.filter]
    subprocess.run(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--output", trace, "--no-prompt",
                    "--launch", "--"] + cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(xml, "w") as f:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], check=True, stdout=f)
    print(f"trace: {trace}", file=sys.stderr)
    return xml


def samples(xml):
    """Yields (weight in ms, frames leaf first) per sample; the export refers back to earlier elements by id."""
    ids = {}

    def resolve(e):
        ref = e.get("ref")
        return ids[ref] if ref is not None else e

    for _, e in ET.iterparse(xml, events=("end",)):
        if e.get("id") is not None:
            ids[e.get("id")] = e
        if e.tag != "row":
            continue
        backtrace, weight = None, 1.0
        for child in e:
            if child.tag == "tagged-backtrace":
                bt = resolve(child).find("backtrace")
                backtrace = resolve(bt) if bt is not None else None
            elif child.tag == "weight":
                weight = int(resolve(child).text) / 1e6
        if backtrace is not None:
            frames = [resolve(f).get("name") or "?" for f in backtrace if f.tag == "frame"]
            if frames:
                yield weight, frames


def short(name):
    return name if len(name) <= 150 else name[:147] + "..."


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--phase", choices=["parse", "check", "plan", "eval"])
    p.add_argument("--filter", help="one case of the cases file")
    p.add_argument("--xml", help="summarise this export instead of recording")
    p.add_argument("--focus", help="only samples with a frame containing this text")
    p.add_argument("--callers", help="regex: break down samples whose leaf matches it by first non-runtime caller")
    p.add_argument("--top", type=int, default=30)
    p.add_argument("--driver", default=os.path.join(ROOT, ".build/release/CELBenchmarks"))
    p.add_argument("--cases", default=os.path.join(ROOT, "tools/bench/cases.json"))
    args = p.parse_args()
    if not args.xml and not args.phase:
        p.error("--phase or --xml is required")
    xml = args.xml or record(args)

    total = 0.0
    self_time, inclusive, categories, runtime_callers = (collections.Counter() for _ in range(4))
    for weight, frames in samples(xml):
        if args.focus and not any(args.focus in f for f in frames):
            continue
        if args.callers and not re.search(args.callers, frames[0]):
            total += weight
            continue
        total += weight
        self_time[frames[0]] += weight
        for f in set(frames):
            inclusive[f] += weight
        for category, rx in CATEGORIES:
            if re.search(rx, frames[0]):
                categories[category] += weight
                break
        else:
            categories["other"] += weight
        if RUNTIME.search(frames[0]):
            caller = next((f for f in frames[1:] if not RUNTIME.search(f)), None)
            if caller:
                runtime_callers[short(caller)] += weight
    if not total:
        sys.exit("profile.py: no samples")

    def table(title, counter):
        print(f"\n## {title}")
        for name, w in counter.most_common(args.top):
            print(f"{100 * w / total:5.1f}%  {short(name)}")

    print(f"{total:.0f} ms of samples" + (f" under {args.focus}" if args.focus else ""))
    if args.callers:
        table(f"callers of leaves matching {args.callers}", runtime_callers)
        return
    table("leaf category", categories)
    table("self time", self_time)
    table("inclusive time", inclusive)
    table("first non-runtime caller of runtime and allocator leaves", runtime_callers)


if __name__ == "__main__":
    main()
