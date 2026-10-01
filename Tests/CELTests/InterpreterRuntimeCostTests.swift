// Runtime cost against cel-go: the fixtures (Fixtures/RuntimeCostFixtures.swift, generated with
// tools/cost-fixtures from cel-go via the oracle) pin the actual cost of each expression in checked and
// parse-only mode, the port of cel-go interpreter/runtimecost.go.

import Testing

@testable import CEL

struct InterpreterRuntimeCostTests {
  static let environment: ProgramEnvironment = {
    var registry = TypeRegistry()
    try? registry.register(CELType.optionalOfDyn)
    var env = ProgramEnvironment(
      functions: StandardLibrary.functions + OptionalLibrary.functions(),
      variables: OptionalLibrary.types, provider: registry,
      macros: Macro.allMacros + OptionalLibrary.macros(), parserOptions: [.enableOptionalSyntax(true)])
    env.decorators = [OptionalLibrary.decorator]
    return env
  }()

  @Test(arguments: runtimeCostFixtures.map(\.0))
  func actualCostMatchesCelGo(_ expr: String) throws {
    let fixture = try #require(runtimeCostFixtures.first { $0.0 == expr })
    let env = Self.environment
    let options = ProgramOptions(evalOptions: [.trackCost])
    let checked = try env.program(try env.compile(expr), options: options).eval([:])
    #expect(checked.actualCost == fixture.1, "checked cost of \(expr)")
    #expect(checked.value.isError == fixture.3, "checked result of \(expr): \(checked.value)")
    let parsed = try env.program(try env.parse(expr), options: options).eval([:])
    #expect(parsed.actualCost == fixture.2, "parse-only cost of \(expr)")
  }
}
