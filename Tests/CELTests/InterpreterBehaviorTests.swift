// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from the TestInterpreter_* functions of cel-go interpreter/interpreter_test.go, plus
// cost-limit, deep-nesting and comprehension accumulator checks.

import Testing

@testable import CEL

struct InterpreterBehaviorTests {
  private func env(container: String = "") throws -> ProgramEnvironment {
    var env = ProgramEnvironment(container: container.isEmpty ? .default : try Container(.name(container)))
    env.checkerOptions = [.crossTypeNumericComparisons(true)]
    return env
  }

  @Test func logicalAndMissingType() throws {
    let env = try env()
    let ast = try env.parse("a && TestProto{c: true}.c")
    #expect(throws: (any Error).self) { try env.program(ast) }
  }

  @Test func exhaustiveConditionalExpr() throws {
    let env = try env()
    let ast = try env.parse("a ? b < 1.0 : c == ['hello']")
    let program = try env.program(ast, options: ProgramOptions(evalOptions: [.exhaustiveEval]))
    let result = program.eval(["a": true, "b": 0.999, "c": ["hello"]])
    #expect(result.value == .bool(true))
    // `==` (id 7) is evaluated in exhaustive mode although `a` is true.
    #expect(result.state?.value(7) == .bool(true))
  }

  @Test func exhaustiveLogicalOrEquals() throws {
    let env = try env(container: "test")
    let ast = try env.parse(#"a || b == "b""#)
    let program = try env.program(ast, options: ProgramOptions(evalOptions: [.exhaustiveEval]))
    let result = program.eval(["a": true, "b": "b"])
    #expect(result.value == .bool(true))
    #expect(result.state?.value(3) == .bool(true))
  }

  @Test func interruptableEval() throws {
    var env = try env()
    try env.declare([VariableDecl(name: "items", type: .list(.int))])
    let ast = try env.compile("items.map(i, i).map(i, i).size() != 0")
    let program = try env.program(ast, options: ProgramOptions(interruptCheckFrequency: 100))
    let items = Value.list(ArrayList((0..<5000).map { Value.int(Int64($0)) }))
    let result = program.eval(MapActivation(["items": items]), interrupt: { true })
    #expect(result.value == .error(EvalError("operation interrupted")))
    // Without an interrupt the program completes.
    #expect(program.eval(MapActivation(["items": items])).value == .bool(true))
  }

  @Test func missingIdentInSelect() throws {
    var env = try env(container: "test")
    try env.declare([VariableDecl(name: "a.b", type: .dyn)])
    let ast = try env.compile("a.b.c")
    let program = try env.program(ast, options: ProgramOptions(evalOptions: [.partialEval]))
    let vars = PartialActivationWrapper(
      MapActivation(["a.b": ["d": "hello"]]), unknowns: [AttributePattern("a.b").qualString("c")])
    #expect(program.eval(vars).value.isUnknown)
    #expect(program.eval(EmptyActivation()).value.isError)
  }

  @Test(arguments: [
    ("bool('tru')", nil),
    ("bool(\"true\")", Value.bool(true)),
    ("bytes(\"hello\")", .bytes(Array("hello".utf8))),
    ("double(\"_123\")", nil),
    ("double(\"123.0\")", .double(123)),
    ("duration('12hh3')", nil),
    ("duration('12s')", .duration(CELDuration(nanoseconds: 12_000_000_000))),
    ("dyn(1u)", .uint(1)),
    ("int('11l')", nil),
    ("int('11')", .int(11)),
    ("string('11')", .string("11")),
    ("timestamp('123')", nil),
    ("timestamp(123)", .timestamp(CELTimestamp(secondsSinceEpoch: 123))),
    ("type(null)", .type(.null)),
    ("type(timestamp(int('123')))", .type(.timestamp)),
    ("uint(-1)", nil),
    ("uint(1)", .uint(1)),
  ] as [(String, Value?)])
  func typeConversionOpt(_ expr: String, _ out: Value?) throws {
    let env = try env()
    let ast = try env.compile(expr)
    let optimized = Result { try env.program(ast, options: ProgramOptions(evalOptions: [.optimize])) }
    guard let out else {
      // Planning reports the same error the evaluation would.
      guard case .failure(let planError) = optimized else {
        Issue.record("\(expr): expected a planning error")
        return
      }
      let runtime = try env.program(ast).eval([:]).value
      guard case .error(let err) = runtime else {
        Issue.record("\(expr): expected a runtime error, got \(runtime)")
        return
      }
      #expect("\(planError)" == err.message)
      return
    }
    let program = try optimized.get()
    let constant = try #require(program.interpretable as? any InterpretableConst, "\(expr) is not a constant")
    #expect(constant.value.celEquals(out) == .bool(true), "\(expr): \(constant.value)")
  }

  @Test func planOptionalElements() throws {
    let env = try env()
    let badA = Expr.list(id: 1, elements: [.ident(id: 2, "a")], optionalIndices: [-1])
    let badB = Expr.list(id: 1, elements: [.ident(id: 2, "b")], optionalIndices: [24])
    for expr in [badA, badB] {
      let ast = AST(expr: expr, sourceInfo: SourceInfo(source: nil))
      #expect(throws: (any Error).self) {
        try env.program(ast, options: ProgramOptions(evalOptions: [.optimize]))
      }
    }
  }

  @Test func planListComprehensionTwoVar() throws {
    let accu = "@result"
    let expr = Expr.comprehension(
      id: 1, iterRange: .list(id: 2, elements: [.literal(id: 3, .int(2)), .literal(id: 4, .int(3))]),
      iterVar: "i", iterVar2: "v", accuVar: accu, accuInit: .list(id: 5, elements: []),
      loopCondition: .literal(id: 6, .bool(true)),
      loopStep: .call(
        id: 7, function: Operators.add,
        args: [.ident(id: 8, accu), .list(id: 9, elements: [.ident(id: 10, "i"), .ident(id: 11, "v")])]),
      result: .ident(id: 12, accu))
    let program = try env().program(
      AST(expr: expr, sourceInfo: SourceInfo(source: nil)), options: ProgramOptions(evalOptions: [.optimize]))
    #expect(program.eval([:]).value == [0, 2, 1, 3])
  }

  @Test func planMapComprehensionTwoVar() throws {
    let accu = "@result"
    let expr = Expr.comprehension(
      id: 1,
      iterRange: .map(
        id: 2,
        entries: [
          Expr.MapEntry(id: 3, key: .literal(id: 4, .int(0)), value: .literal(id: 5, .string("first"))),
          Expr.MapEntry(id: 6, key: .literal(id: 7, .int(1)), value: .literal(id: 8, .string("second"))),
        ]),
      iterVar: "k", iterVar2: "v", accuVar: accu, accuInit: .map(id: 9, entries: []),
      loopCondition: .literal(id: 10, .bool(true)),
      loopStep: .call(
        id: 11, function: "cel.@mapInsert",
        args: [
          .ident(id: 12, accu),
          .call(id: 13, function: Operators.add, args: [.ident(id: 14, "k"), .literal(id: 15, .int(1))]),
          .ident(id: 16, "v"),
        ]),
      result: .ident(id: 17, accu))
    var env = try env()
    let mapInsert = try FunctionDecl(
      "cel.@mapInsert",
      .overload(
        "cel.@mapInsert", argTypes: [.map(key: .int, value: .string), .int, .string],
        resultType: .map(key: .int, value: .string)),
      .singletonFunctionBinding { args in
        guard case .map(let m) = args[0], let mutable = m as? MutableMap else { return .noSuchOverload }
        return mutable.insert(args[1], args[2])
      })
    try env.declare(functions: [mapInsert])
    let program = try env.program(
      AST(expr: expr, sourceInfo: SourceInfo(source: nil)), options: ProgramOptions(evalOptions: [.optimize]))
    let result = program.eval([:]).value
    #expect(result == [1: "first", 2: "second"])
    // The mutable accumulator is converted back to an immutable map.
    if case .map(let m) = result {
      #expect(!(m is MutableMap))
    }
  }

  @Test func costLimitCancelsEvaluation() throws {
    let env = try env()
    let ast = try env.compile("[1, 2, 3, 4, 5].map(x, x * 2).map(y, y + 1).size() > 0")
    let tracked = try env.program(ast, options: ProgramOptions(evalOptions: [.trackCost]))
    let full = tracked.eval([:])
    #expect(full.value == .bool(true))
    let cost = try #require(full.actualCost)
    #expect(cost > 10)
    let limited = try env.program(ast, options: ProgramOptions(costLimit: cost - 1))
    let result = limited.eval([:])
    #expect(result.value == .error(EvalError("operation cancelled: actual cost limit exceeded")))
    let exact = try env.program(ast, options: ProgramOptions(costLimit: cost))
    #expect(exact.eval([:]).value == .bool(true))
  }

  @Test func comprehensionAccumulatorIsNotShared() throws {
    let env = try env()
    let program = try env.program(try env.compile("[1, 2].map(x, [x].map(y, y * 10))"))
    #expect(program.eval([:]).value == [[10], [20]])
    // Repeated evaluations start from fresh accumulators.
    #expect(program.eval([:]).value == [[10], [20]])
  }

  /// Planning and evaluation must not overflow the stack of a secondary thread at the parser's
  /// default maximum recursion depth.
  @Test func deepExpressionOnSecondaryThread() async throws {
    let depth = 240
    let expr = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
    let nested = Array(repeating: "(", count: depth).joined() + "x" + Array(repeating: " + 1)", count: depth).joined()
    let value = try await Task.detached {
      let env = ProgramEnvironment()
      let a = try env.program(try env.compile(expr)).eval([:]).value
      var envX = ProgramEnvironment()
      try envX.declare([VariableDecl(name: "x", type: .int)])
      let b = try envX.program(try envX.compile(nested)).eval(["x": 0]).value
      return (a, b)
    }.value
    #expect(value.1 == .int(Int64(depth)))
    if case .list = value.0 {} else { Issue.record("expected a list, got \(value.0)") }
  }
}
