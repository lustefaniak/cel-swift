// Benchmarks: parse, check, plan and eval of the expressions in tools/bench/cases.json, timed the same way
// as the cel-go driver in tools/bench/go so the two can be compared (tools/bench/bench.py).
//
//   swift run -c release CELBenchmarks [--cases tools/bench/cases.json] [--rounds 5] [--round-ms 100]
//                                      [--filter name] [--phase eval] [--threads n]
//
// Each phase is calibrated to rounds of about --round-ms, run --rounds times, and the fastest round's time per
// operation is printed as one tab-separated line: name, phase, ns/op. Bindings are CEL expressions
// evaluated once with the lists extension, so both drivers build their inputs the same way.
// With --threads n every round runs the operation on n threads at once and ns/op is wall time divided
// by all operations, i.e. inverse throughput (shows contention on shared state; Swift driver only).

import CEL
import CELExtensions
import Foundation

struct BenchCase: Decodable {
  var name: String
  var expr: String
  var variables: [String: String]
  var bindings: [String: String]
}

struct Options {
  var casesPath = "tools/bench/cases.json"
  var rounds = 5
  var roundMilliseconds = 100
  var filter: String?
  var phase: String?
  var threads = 1

  init(_ arguments: [String]) {
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      let value = iterator.next() ?? ""
      switch argument {
      case "--cases": casesPath = value
      case "--rounds": rounds = Int(value) ?? rounds
      case "--round-ms": roundMilliseconds = Int(value) ?? roundMilliseconds
      case "--filter": filter = value
      case "--phase": phase = value
      case "--threads": threads = max(1, Int(value) ?? 1)
      default: fail("unknown argument \(argument)")
      }
    }
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("bench: \(message)\n".utf8))
  exit(1)
}

func celType(_ name: String) -> CELType {
  switch name {
  case "int": return .int
  case "string": return .string
  case "dyn": return .dyn
  case "list(int)": return .list(.int)
  case "map(string, dyn)": return .map(key: .string, value: .dyn)
  default: fail("unknown type \(name)")
  }
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// The nanoseconds per call of `body` in the fastest of `rounds` rounds of about `roundMilliseconds`
/// each: the round least disturbed by other load on the machine.
func measure(_ options: Options, _ body: () -> Void) -> Double {
  let target = UInt64(options.roundMilliseconds) * 1_000_000
  var n = 1
  while true {
    let start = now()
    for _ in 0..<n { body() }
    let elapsed = now() - start
    if elapsed >= target / 10 {
      n = max(1, Int(Double(n) * Double(target) / Double(max(elapsed, 1))))
      break
    }
    n *= 2
  }
  var perOp: [Double] = []
  for _ in 0..<options.rounds {
    let start = now()
    if options.threads > 1 {
      withoutActuallyEscaping(body) { body in
        DispatchQueue.concurrentPerform(iterations: options.threads) { _ in
          for _ in 0..<n { body() }
        }
      }
    } else {
      for _ in 0..<n { body() }
    }
    perOp.append(Double(now() - start) / Double(n * options.threads))
  }
  return perOp.min() ?? 0
}

let options = Options(CommandLine.arguments)
guard let data = FileManager.default.contents(atPath: options.casesPath) else {
  fail("cannot read \(options.casesPath)")
}
let cases: [BenchCase]
do {
  cases = try JSONDecoder().decode([BenchCase].self, from: data)
} catch {
  fail("\(options.casesPath): \(error)")
}

do {
  let bindingEnv = try Environment(.library(.lists))
  for benchCase in cases where options.filter == nil || benchCase.name == options.filter {
    let env = try Environment(.variables(benchCase.variables.mapValues(celType)))
    var bindings: [String: Value] = [:]
    for (name, expr) in benchCase.bindings {
      bindings[name] = try bindingEnv.program(bindingEnv.compile(expr)).evaluate().value
    }
    let variables = Variables(bindings)

    let parsed = try env.parse(benchCase.expr)
    let checked = try env.check(parsed)
    let program = try env.program(checked)
    let result = try program.evaluate(variables).value
    guard case .bool(true) = result else {
      fail("\(benchCase.name): unexpected result \(result)")
    }

    func report(_ phase: String, _ body: () -> Void) {
      guard options.phase == nil || options.phase == phase else { return }
      let ns = measure(options, body)
      print("\(benchCase.name)\t\(phase)\t\((ns * 10).rounded() / 10)")
    }
    report("parse") { _ = try? env.parse(benchCase.expr) }
    report("check") { _ = try? env.check(parsed) }
    report("plan") { _ = try? env.program(checked) }
    report("eval") { _ = try? program.evaluate(variables) }
  }
} catch {
  fail("\(error)")
}
