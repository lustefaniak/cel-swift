// Tests of the public Environment / Program API, written against the public surface only (no
// @testable import), so they fail when something a client needs is not public.

import CEL
import Testing

@Suite("Public API")
struct APITests {
  @Test func compileAndEvaluate() throws {
    let env = try Environment(.variable("x", .int), .variable("name", .string))
    let checked = try env.compile("x * 2 + size(name)")
    #expect(checked.outputType == .int)
    let program = try env.program(checked)
    let result = try program.evaluate(["x": 20, "name": "ab"])
    #expect(result.value == 42)
    #expect(result.value.asInt == 42)
  }

  @Test func parseOnlyEvaluation() throws {
    let env = try Environment()
    let parsed = try env.parse("[1, 2, 3].map(x, x * x)")
    let result = try env.program(parsed).evaluate()
    #expect(result.value.asList == [1, 4, 9])
  }

  @Test func compileErrorRendersLikeCelGo() {
    let env = try! Environment(.variable("x", .int))
    #expect {
      _ = try env.compile("x + y")
    } throws: { error in
      guard let error = error as? CompileError else { return false }
      return error.description == """
        ERROR: <input>:1:5: undeclared reference to 'y' (in container '')
         | x + y
         | ....^
        """
        && error.issues.count == 1
        && error.issues[0].line == 1 && error.issues[0].column == 5
    }
  }

  @Test func syntaxError() {
    let env = try! Environment()
    #expect(throws: CompileError.self) {
      _ = try env.parse("1 +")
    }
  }

  @Test func evaluationErrorIsThrownByDefault() throws {
    let env = try Environment()
    let program = try env.program(env.compile("1 / 0"))
    #expect(throws: EvalError.self) {
      _ = try program.evaluate()
    }
  }

  @Test func evaluationErrorAsValue() throws {
    let env = try Environment()
    let program = try env.program(env.compile("1 / 0"), options: [.errorsAsValues])
    let result = try program.evaluate()
    #expect(result.value.asError?.message == "division by zero")
  }

  @Test func customFunctionWithSwiftBinding() throws {
    let env = try Environment(
      .function(
        "shout",
        .memberOverload(
          "string_shout", argTypes: [.string], resultType: .string,
          .unaryBinding { value in
            guard let s = value.asString else { return .error(EvalError("bad")) }
            return Value(s.uppercased() + "!")
          })))
    let result = try env.program(env.compile("'hi'.shout()")).evaluate()
    #expect(result.value == "HI!")
  }

  @Test func extendingAddsDeclarationsWithoutChangingParent() throws {
    let parent = try Environment(.variable("a", .int))
    let child = try parent.extending(.variable("b", .int))
    #expect(throws: CompileError.self) { _ = try parent.compile("a + b") }
    let result = try child.program(child.compile("a + b")).evaluate(["a": 1, "b": 2])
    #expect(result.value == 3)
  }

  @Test func conflictingDeclarationsThrow() {
    #expect(throws: DeclarationError.self) {
      _ = try Environment(.variable("a", .int), .variable("a", .string))
    }
  }

  @Test func container() throws {
    let env = try Environment(.container("pkg"), .variable("pkg.x", .int))
    let result = try env.program(env.compile("x + 1")).evaluate(["pkg.x": 1])
    #expect(result.value == 2)
  }

  @Test func costTrackingAndLimit() throws {
    let env = try Environment(.variable("l", .list(.int)))
    let expression = try env.compile("l.map(x, x * 2).size() > 1")
    let tracked = try env.program(expression, options: [.trackCost])
    let result = try tracked.evaluate(["l": [1, 2, 3]])
    #expect(result.cost != nil)
    #expect((result.cost ?? 0) > 0)

    let limited = try env.program(expression, options: [.costLimit(2)])
    #expect {
      _ = try limited.evaluate(["l": [1, 2, 3]])
    } throws: { error in
      (error as? EvalError)?.message == "operation cancelled: actual cost limit exceeded"
    }
  }

  @Test func stateTracking() throws {
    let env = try Environment(.variable("x", .int))
    let expression = try env.compile("x > 1 && x < 10")
    let result = try env.program(expression, options: [.trackState]).evaluate(["x": 5])
    let state = try #require(result.state)
    #expect(!state.expressionIDs.isEmpty)
    #expect(state.value(ofExpressionID: state.expressionIDs[0]) != nil)
  }

  @Test func lazyVariablesAreComputedOnDemand() throws {
    let env = try Environment(.variable("a", .bool), .variable("b", .bool))
    let program = try env.program(env.compile("a || b"))
    var variables: Variables = ["a": true]
    variables.bind("b") { .error(EvalError("must not be computed")) }
    #expect(try program.evaluate(variables).value == true)
  }

  @Test func resolverVariables() throws {
    let env = try Environment(.variable("a.b", .int))
    let program = try env.program(env.compile("a.b + 1"))
    let result = try program.evaluate(Variables { name in name == "a.b" ? 41 : nil })
    #expect(result.value == 42)
  }

  @Test func optionalTypes() throws {
    let env = try Environment(.optionalTypes, .variable("m", .map(key: .string, value: .int)))
    let program = try env.program(env.compile("m.?a.orValue(7)"))
    #expect(try program.evaluate(["m": Value(["b": 1])]).value == 7)
  }

  @Test func customEnvironmentHasNoStandardLibrary() throws {
    let env = try Environment.custom(.variable("x", .int))
    #expect(throws: CompileError.self) { _ = try env.compile("x + 1") }
    #expect(!env.hasLibrary(named: "cel.lib.std"))
    #expect(try Environment().hasLibrary(named: "cel.lib.std"))
  }

  @Test func cancelledTaskInterruptsEvaluation() async throws {
    let env = try Environment()
    let program = try env.program(
      env.compile("[1, 2, 3, 4, 5, 6, 7, 8, 9].all(x, [1, 2, 3, 4, 5, 6, 7, 8, 9].all(y, true))"),
      options: [.interruptCheckFrequency(1)])
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return Result { try program.evaluate() }
    }
    let outcome = await task.value
    #expect(throws: EvalError.self) { try outcome.get() }
  }

  @Test func partialEvaluation() throws {
    let env = try Environment(.variable("a", .bool), .variable("b", .map(key: .string, value: .bool)))
    let program = try env.program(env.compile("a && b.x"), options: [.partialEvaluation])
    let unknown = try program.evaluate(Variables(["a": true], unknowns: [UnknownPattern("b").qualified(by: "x")]))
    #expect(unknown.value.isUnknown)
    let decided = try program.evaluate(Variables(["a": false], unknowns: [UnknownPattern("b")]))
    #expect(decided.value == false)
    let partial = env.partialVariables(["a": true])
    #expect(partial.unknowns.map(\.description) == ["b"])
    #expect(try program.evaluate(partial).value.isUnknown)
    #expect(UnknownPattern("a").qualified(by: .int(1)).wildcard().description == "a[1].*")
  }

  @Test func costEstimate() throws {
    let env = try Environment(.variable("s", .string), .variable("l", .list(.string)))
    let constant = try env.compile("1 + 2 == 3")
    #expect(env.estimateCost(constant) == 2...2)
    let unbounded = try env.compile("l.all(x, x.startsWith(s))")
    #expect(env.estimateCost(unbounded).upperBound == UInt64.max)
    let bounded = env.estimateCost(unbounded, sizeHints: ["l": 0...10, "l.@items": 0...20, "s": 0...5])
    #expect(bounded.upperBound < 1000)
  }

  @Test func extendingWithoutFunctionsReusesDeclarations() throws {
    let parent = try Environment(.function("f", .overload("f_int", argTypes: [.int], resultType: .int)))
    let child = try parent.extending(.variable("x", .int), .container("c"))
    #expect(child.hasFunction(named: "f"))
    #expect(try child.compile("f(x)").outputType == .int)
  }

  @Test func unparse() throws {
    let env = try Environment()
    #expect(try env.parse("a+b*2").description == "a + b * 2")
  }

  @Test func valueConversions() {
    #expect(Value(3) == .int(3))
    #expect(Value(UInt(3)) == .uint(3))
    #expect(Value(bytes: [1]) == .bytes([1]))
    #expect(Value(Duration.seconds(2))?.asDuration?.nanoseconds == 2_000_000_000)
    #expect(Value(["k": 1]).asMap?[.string("k")] == 1)
    #expect(Value.null.isNull)
    #expect(Value(1.5).asDouble == 1.5)
  }
}
