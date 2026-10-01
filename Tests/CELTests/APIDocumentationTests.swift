// The examples of Sources/CEL/CEL.docc and README.md, so the documentation keeps compiling and
// stays true. Keep them in sync when either side changes.

import CEL
import CELExtensions
import Testing

@Suite("Documentation examples")
struct APIDocumentationTests {
  @Test func landingPage() throws {
    let env = try Environment(.variable("user", .map(key: .string, value: .dyn)))
    let checked = try env.compile("user.age >= 18 && user.country in ['PL', 'DK']")
    let program = try env.program(checked)
    let result = try program.evaluate(["user": ["age": 30, "country": "PL"]])
    #expect(result.value == true)
  }

  @Test func gettingStarted() throws {
    let env = try Environment(
      .variable("request", .map(key: .string, value: .dyn)),
      .variable("limit", .int),
      .constant("maxRetries", .int, value: 3)
    )
    #expect {
      _ = try env.compile("request.size > limt")
    } throws: { error in
      "\(error)" == """
        ERROR: <input>:1:16: undeclared reference to 'limt' (in container '')
         | request.size > limt
         | ...............^
        """
    }
    let checked = try env.compile("request.size > limit")
    #expect(checked.outputType == .bool)
    let program = try env.program(checked)
    let result = try program.evaluate(["request": ["size": 2048], "limit": 1024])
    #expect(result.value == true)
    #expect(result.value.asBool == true)

    var variables: Variables = ["limit": 1024]
    variables.bind("request") { ["size": 2048] }
    #expect(try program.evaluate(variables).value == true)
  }

  @Test func functionsAndLibraries() throws {
    let env = try Environment(
      .function(
        "shout",
        .memberOverload(
          "string_shout", argumentTypes: [.string], resultType: .string,
          .unaryBinding { value in
            guard let text = value.asString else { return .error(EvalError("expected a string")) }
            return Value(text.uppercased() + "!")
          }))
    )
    #expect(try env.program(env.compile("'hi'.shout()")).evaluate().value == "HI!")

    let extended = try Environment(.library(.strings), .library(.lists), .library(.math))
    #expect(try extended.program(extended.compile("'a,b'.split(',').size()")).evaluate().value == 2)

    let subset = Library.Subset(
      includedMacros: ["has"],
      includedFunctions: [.init("_==_"), .init("_&&_"), .init("size", overloadIDs: ["list_size"])])
    let small = try Environment.custom(.library(.standard(subset: subset)))
    #expect(try small.program(small.compile("[1].size() == 1 && has({'a': 1}.a)")).evaluate().value == true)
  }

  @Test func cost() throws {
    let env = try Environment(.variable("items", .list(.string)))
    let checked = try env.compile("items.all(i, i.size() < 100)")
    let range = env.estimateCost(checked, sizeHints: ["items": 0...1000, "items.@items": 0...100])
    #expect(range.upperBound < 10_000)
    let program = try env.program(checked, options: [.costLimit(10_000)])
    #expect(try program.evaluate(["items": ["a", "b"]]).value == true)
  }

  @Test func partialEvaluation() throws {
    let env = try Environment(.variable("user", .string), .variable("risk", .double))
    let program = try env.program(
      env.compile("user == 'admin' || risk < 0.5"), options: [.partialEvaluation])
    let decided = try program.evaluate(Variables(["user": "admin"], unknowns: [UnknownPattern("risk")]))
    #expect(decided.value == true)
  }

  @Test func optimize() throws {
    let env = try Environment(.variable("x", .int))
    let folded = try env.optimize(env.compile("x + 2 * 3 > 10"), .constantFolding())
    #expect(folded.description == "x + 6 > 10")
  }
}
