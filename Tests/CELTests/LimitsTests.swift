// End-to-end tests of the termination guarantees for untrusted expressions: the runtime cost
// limit, interrupts (time limit, task cancellation), parser limits on deep or large inputs, the
// comprehension nesting validator and the regex program size limit (cel-go cel/program.go,
// interpreter/decorators.go, cel/validator.go, parser/options.go).

import Testing

@testable import CEL

/// `[0, 1, ..., 9]` nested `depth` times with `all`, about 10^depth iterations unbounded.
private func nestedComprehension(depth: Int) -> String {
  let range = "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]"
  var expr = "true"
  for level in (0..<depth).reversed() {
    expr = "\(range).all(v\(level), v\(level) >= 0 && \(expr))"
  }
  return expr
}

private func elapsedSeconds(_ body: () throws -> Void) rethrows -> Double {
  let clock = ContinuousClock()
  let start = clock.now
  try body()
  let d = clock.now - start
  return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Suite struct LimitsTests {
  @Test func costLimitStopsDeepComprehensionQuickly() throws {
    let env = try Environment()
    let expr = try env.compile(nestedComprehension(depth: 9))
    let program = try env.program(expr, options: [.costLimit(10_000), .errorsAsValues])
    var result: EvaluationResult?
    let seconds = try elapsedSeconds { result = try program.evaluate() }
    let r = try #require(result)
    guard case .error(let e) = r.value else {
      Issue.record("expected a cost limit error, got \(r.value)")
      return
    }
    #expect(e.message == costLimitExceededMessage)
    #expect((r.cost ?? 0) > 10_000)
    // The cost observer stops counting at the limit; the evaluation stops at the next iteration.
    #expect((r.cost ?? 0) < 10_100)
    #expect(seconds < 5)
  }

  @Test func costLimitWithoutComprehensionsReportsError() throws {
    let env = try Environment(.variable("s", .string))
    let expr = try env.compile("s + s + s + s")
    let program = try env.program(expr, options: [.costLimit(10)])
    #expect(throws: EvalError.self) {
      try program.evaluate(["s": .string(String(repeating: "x", count: 100))])
    }
  }

  @Test func estimateBoundsDeepComprehension() throws {
    let env = try Environment()
    let expr = try env.compile(nestedComprehension(depth: 3))
    let estimate = env.estimateCost(expr)
    let result = try env.program(expr, options: [.trackCost]).evaluate()
    let cost = try #require(result.cost)
    #expect(estimate.min <= cost && cost <= estimate.max)
  }

  @Test func timeLimitInterruptsLongEvaluation() throws {
    let env = try Environment()
    let expr = try env.compile(nestedComprehension(depth: 9))
    let program = try env.program(expr, options: [.timeLimit(.milliseconds(50)), .errorsAsValues])
    var result: EvaluationResult?
    let seconds = try elapsedSeconds { result = try program.evaluate() }
    guard case .error(let e) = try #require(result).value else {
      Issue.record("expected an interrupt error")
      return
    }
    #expect(e.message == interruptErrorMessage)
    #expect(seconds < 5)
  }

  @Test func cancelledTaskInterruptsNestedComprehension() async throws {
    let env = try Environment()
    let expr = try env.compile(nestedComprehension(depth: 9))
    let program = try env.program(expr, options: [.interruptCheckFrequency(10), .errorsAsValues])
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try program.evaluate().value
    }
    let value = try await task.value
    guard case .error(let e) = value else {
      Issue.record("expected an interrupt error, got \(value)")
      return
    }
    #expect(e.message == interruptErrorMessage)
  }

  // Deeply nested or very long inputs must produce an error or a value, never a crash.
  @Test(arguments: [
    String(repeating: "(", count: 50_000) + "1" + String(repeating: ")", count: 50_000),
    String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000),
    String(repeating: "-", count: 50_000) + "1",
    String(repeating: "!", count: 50_000) + "true",
    "a" + String(repeating: ".b", count: 50_000),
    "a" + String(repeating: "[0]", count: 30_000),
    Array(repeating: "1", count: 30_000).joined(separator: " + "),
    Array(repeating: "true", count: 30_000).joined(separator: " && "),
    Array(repeating: "x", count: 20_000).joined(separator: " ? x : "),
    String(repeating: "{1: ", count: 20_000) + "1" + String(repeating: "}", count: 20_000),
    String(repeating: "[1].map(x, ", count: 5_000) + "x" + String(repeating: ")", count: 5_000),
  ])
  func deepInputsDoNotCrash(_ text: String) throws {
    let env = try Environment(.variable("a", .dyn), .variable("x", .bool))
    do {
      let expr = try env.compile(text)
      _ = env.estimateCost(expr)
      let program = try env.program(expr, options: [.costLimit(1_000_000), .errorsAsValues])
      _ = try program.evaluate(["a": .null, "x": true])
    } catch {
      // A compile error (recursion, size or node limit) is the expected outcome for most inputs.
    }
  }

  @Test func recursionLimitIsEnforced() throws {
    let env = try Environment(.parserRecursionLimit(10))
    let deep = String(repeating: "[", count: 20) + String(repeating: "]", count: 20)
    #expect(throws: CompileError.self) { try env.compile(deep) }
    _ = try env.compile("[[1]]")
  }

  @Test func expressionSizeLimitIsEnforced() throws {
    let env = try Environment(.expressionSizeLimit(10))
    #expect(throws: CompileError.self) { try env.compile("1 + 2 + 3 + 4 + 5") }
    _ = try env.compile("1 + 2")
  }

  @Test func expressionNodeLimitIsEnforced() throws {
    let env = try Environment(.expressionNodeLimit(5))
    #expect(throws: CompileError.self) { try env.compile("[1, 2, 3].map(x, x * 2)") }
    _ = try env.compile("1 + 2")
  }

  @Test func comprehensionNestingLimitIsEnforced() throws {
    let env = try Environment(.validators(.comprehensionNestingLimit(2)))
    #expect(throws: CompileError.self) { try env.compile(nestedComprehension(depth: 3)) }
    _ = try env.compile(nestedComprehension(depth: 2))
  }

  @Test func regexProgramSizeLimitRejectsLiteralPatterns() throws {
    let env = try Environment(.regexProgramSizeLimit(10))
    #expect(throws: CompileError.self) { try env.compile("'aaa'.matches('(a|b|c|d){10}')") }
    _ = try env.compile("'aaa'.matches('a')")
  }

  @Test func regexProgramSizeLimitRejectsComputedPatterns() throws {
    let env = try Environment(.variable("p", .string), .regexProgramSizeLimit(10))
    let program = try env.program(try env.compile("'aaa'.matches(p)"), options: [.errorsAsValues])
    let big = try program.evaluate(["p": "(a|b|c|d){10}"]).value
    guard case .error(let e) = big else {
      Issue.record("expected a regex size error, got \(big)")
      return
    }
    #expect(e.message.hasPrefix("regex program size "))
    #expect(e.message.hasSuffix(" exceeds limit of 10"))
    #expect(try program.evaluate(["p": "a"]).value == .bool(true))
  }
}
