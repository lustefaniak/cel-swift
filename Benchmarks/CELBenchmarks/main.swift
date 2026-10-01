// Interpreter benchmarks: a policy-sized expression and comprehension-heavy expressions, planned once
// and evaluated many times.
//
//   swift run -c release CELBenchmarks [iterations] [benchmark-name]
//
// Prints the mean time per evaluation. Not part of the test suite; numbers are for spotting
// pathological slowness, not for comparing machines.

import CEL

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

struct Benchmark {
  var name: String
  var expr: String
  var variables: [VariableDecl]
  var bindings: [String: Value]
}

let pr: Value = [
  "additions": 120, "deletions": 30, "author": "octocat", "draft": false,
  "labels": ["bug", "backend", "needs-review"],
  "files": .list(ArrayList((0..<40).map { i in ["path": .string("src/module\(i % 7)/file\(i).swift"), "changes": .int(Int64(i * 3))] as Value })),
]
let review: Value = ["confidence": 0.91, "risk": "low", "approvals": 2]

let benchmarks = [
  Benchmark(
    name: "policy",
    expr: """
      !pr.draft
        && pr.additions + pr.deletions <= 400
        && review.confidence >= 0.85
        && review.risk in ['low', 'medium']
        && (review.approvals >= 2 || pr.author in ['octocat', 'hubot'])
        && !('do-not-merge' in pr.labels)
        && pr.labels.exists(l, l == 'bug' || l.startsWith('feat'))
        && pr.files.all(f, !f.path.endsWith('.lock') && f.changes < 500)
      """,
    variables: [
      VariableDecl(name: "pr", type: .map(key: .string, value: .dyn)),
      VariableDecl(name: "review", type: .map(key: .string, value: .dyn)),
    ],
    bindings: ["pr": pr, "review": review]),
  Benchmark(
    name: "comprehension-map-filter",
    expr: "xs.map(x, x * 2).filter(y, y % 3 == 0).map(z, z + 1).size() > 0",
    variables: [VariableDecl(name: "xs", type: .list(.int))],
    bindings: ["xs": .list(ArrayList((0..<1000).map { Value.int(Int64($0)) }))]),
  Benchmark(
    name: "comprehension-nested",
    expr: "xs.all(x, ys.exists(y, y == x % 50))",
    variables: [VariableDecl(name: "xs", type: .list(.int)), VariableDecl(name: "ys", type: .list(.int))],
    bindings: [
      "xs": .list(ArrayList((0..<200).map { Value.int(Int64($0)) })),
      "ys": .list(ArrayList((0..<50).map { Value.int(Int64($0)) })),
    ]),
  Benchmark(
    name: "string-ops",
    expr: "pr.files.filter(f, f.path.contains('module3')).map(f, f.path.size()).size() >= 1",
    variables: [VariableDecl(name: "pr", type: .map(key: .string, value: .dyn))],
    bindings: ["pr": pr]),
]

func now() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

let iterations = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 2000 : 2000
let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
for benchmark in benchmarks where only == nil || benchmark.name == only {
  do {
    var env = ProgramEnvironment()
    try env.declare(benchmark.variables)
    let program = try env.program(try env.compile(benchmark.expr))
    let activation = MapActivation(benchmark.bindings)
    let warm = program.eval(activation).value
    guard case .bool(true) = warm else {
      print("\(benchmark.name): unexpected result \(warm)")
      continue
    }
    let start = now()
    for _ in 0..<iterations {
      _ = program.eval(activation)
    }
    let perEval = (now() - start) / Double(iterations)
    print("\(benchmark.name): \((perEval * 1e8).rounded() / 100) µs/eval over \(iterations) iterations")
  } catch {
    print("\(benchmark.name): \(error)")
  }
}
