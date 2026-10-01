// Strong enums (Environment.Option.strongEnums) through the public API, with the cel-go test protos. Not a
// ported file: cel-go has no strong enums; the semantics follow the cel-spec `enums/strong_*` sections, which
// the conformance suite runs against the cel-spec protos.

import CEL
import CELGoTestProtos
import CELProtobuf
import Testing

struct StrongEnumTests {
  static let globalEnum = "google.expr.proto3.test.GlobalEnum"
  static let nestedEnum = "google.expr.proto3.test.TestAllTypes.NestedEnum"

  static func environment(_ options: Environment.Option...) throws -> Environment {
    try Environment(options: [.typeProvider(testTypes()), .container("google.expr.proto3.test")] + options)
  }

  func evaluate(_ expression: String, in env: Environment, _ variables: [String: Value] = [:]) throws -> Value {
    try env.program(env.compile(expression)).evaluate(variables).value
  }

  func evaluateUnchecked(_ expression: String, in env: Environment, _ variables: [String: Value] = [:]) throws
    -> Value
  {
    try env.program(env.parse(expression)).evaluate(variables).value
  }

  @Test func constantsAreEnumValues() throws {
    let env = try Self.environment(.strongEnums)
    #expect(try evaluate("GlobalEnum.GAZ", in: env) == .object(EnumValue(typeName: Self.globalEnum, number: 2)))
    #expect(try evaluate("TestAllTypes.NestedEnum.BAR", in: env) == .object(EnumValue(typeName: Self.nestedEnum, number: 1)))
    #expect(try env.compile("GlobalEnum.GAZ").outputType == .opaque(name: Self.globalEnum, parameters: []))
    #expect(try evaluateUnchecked("GlobalEnum.GAZ", in: env) == .object(EnumValue(typeName: Self.globalEnum, number: 2)))
  }

  @Test func withoutTheOptionEnumsAreInts() throws {
    let env = try Self.environment()
    #expect(try evaluate("GlobalEnum.GAZ", in: env) == 2)
    #expect(try evaluate("TestAllTypes{}.standalone_enum", in: env) == 0)
    #expect(throws: CompileError.self) { try env.compile("GlobalEnum(1)") }
  }

  @Test func typesAndEquality() throws {
    let env = try Self.environment(.strongEnums)
    #expect(try evaluate("type(GlobalEnum.GOO) == GlobalEnum", in: env) == true)
    #expect(try evaluate("type(GlobalEnum.GOO)", in: env) == .type(.opaque(name: Self.globalEnum, parameters: [])))
    #expect(try evaluate("GlobalEnum.GAR == GlobalEnum.GAR", in: env) == true)
    #expect(try evaluate("GlobalEnum.GAR != GlobalEnum.GAZ", in: env) == true)
    // Only values of the same enum compare: an int does not type-check, and is unequal at runtime.
    #expect(throws: CompileError.self) { try env.compile("GlobalEnum.GAR == 1") }
    #expect(try evaluateUnchecked("GlobalEnum.GAR == 1", in: env) == false)
    #expect(try evaluateUnchecked("GlobalEnum.GOO == TestAllTypes.NestedEnum.FOO", in: env) == false)
  }

  @Test func conversions() throws {
    let env = try Self.environment(.strongEnums)
    #expect(try evaluate("int(GlobalEnum.GAZ)", in: env) == 2)
    #expect(try evaluate("GlobalEnum(1) == GlobalEnum.GAR", in: env) == true)
    #expect(try evaluate("TestAllTypes.NestedEnum(-7)", in: env) == .object(EnumValue(typeName: Self.nestedEnum, number: -7)))
    #expect(try evaluate("GlobalEnum('GAZ')", in: env) == .object(EnumValue(typeName: Self.globalEnum, number: 2)))
    #expect(try evaluateUnchecked("TestAllTypes.NestedEnum('BAZ')", in: env) == .object(EnumValue(typeName: Self.nestedEnum, number: 2)))
    // `#expect(throws:)` returns the error only from Swift 6.1 on.
    #expect(evaluationError("GlobalEnum(2147483648)", in: env)?.contains("range") == true)
    #expect(evaluationError("GlobalEnum('NOPE')", in: env) == "invalid enum value name 'NOPE' for enum \(Self.globalEnum)")
  }

  func evaluationError(_ expression: String, in env: Environment) -> String? {
    do {
      _ = try evaluate(expression, in: env)
      return nil
    } catch let error as EvalError {
      return error.message
    } catch {
      return "\(error)"
    }
  }

  @Test func messageFields() throws {
    let env = try Self.environment(.strongEnums, .variable("x", .object("google.expr.proto3.test.TestAllTypes")))
    #expect(try evaluate("TestAllTypes{}.standalone_enum", in: env) == .object(EnumValue(typeName: Self.nestedEnum, number: 0)))
    #expect(try evaluate("type(TestAllTypes{}.standalone_enum) == TestAllTypes.NestedEnum", in: env) == true)
    #expect(try evaluate("TestAllTypes{standalone_enum: TestAllTypes.NestedEnum.BAZ}.standalone_enum == TestAllTypes.NestedEnum.BAZ", in: env) == true)
    #expect(try evaluate("TestAllTypes{repeated_nested_enum: [TestAllTypes.NestedEnum(9)]}.repeated_nested_enum[0]", in: env) == .object(EnumValue(typeName: Self.nestedEnum, number: 9)))
    // Assigning an int type-checks only without strong enums, but the field still accepts one.
    #expect(throws: CompileError.self) { try env.compile("TestAllTypes{standalone_enum: 1}") }
    #expect(try evaluateUnchecked("TestAllTypes{standalone_enum: 1}.standalone_enum", in: env) == .object(EnumValue(typeName: Self.nestedEnum, number: 1)))
    // A value of another enum is not converted.
    #expect(throws: EvalError.self) { try evaluateUnchecked("TestAllTypes{standalone_enum: GlobalEnum.GAZ}", in: env) }

    let message = Proto3.with { $0.standaloneEnum = .baz }
    // Messages from types with strong enums read enum values in both modes.
    let strong = ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile], strongEnums: true)
    #expect(try evaluateUnchecked("x.standalone_enum", in: env, ["x": strong.value(of: message)]) == .object(EnumValue(typeName: Self.nestedEnum, number: 2)))
    // Messages from types without them follow the checked type when checked, and read ints otherwise.
    let legacy = testTypes()
    #expect(try evaluate("x.standalone_enum", in: env, ["x": legacy.value(of: message)]) == .object(EnumValue(typeName: Self.nestedEnum, number: 2)))
    #expect(try evaluateUnchecked("x.standalone_enum", in: env, ["x": legacy.value(of: message)]) == 2)
  }

  @Test func optionPositionDoesNotMatter() throws {
    let env = try Environment(options: [.strongEnums, .typeProvider(testTypes()), .container("google.expr.proto3.test")])
    #expect(try evaluate("GlobalEnum(2) == GlobalEnum.GAZ", in: env) == true)
    let extended = try env.extending(.variable("y", .int))
    #expect(try evaluate("int(GlobalEnum.GAZ) + y", in: extended, ["y": 1]) == 3)
  }

  @Test func registeredEnumValues() throws {
    var registry = TypeRegistry()
    registry.registerEnumValue("my.Color.RED", number: 1)
    registry.registerEnumValue("my.Color.GREEN", number: 2)
    let env = try Environment(.typeProvider(registry), .strongEnums)
    #expect(try evaluate("my.Color.GREEN", in: env) == .object(EnumValue(typeName: "my.Color", number: 2)))
    #expect(try evaluate("my.Color('RED') == my.Color.RED && type(my.Color.RED) == my.Color", in: env) == true)
  }

  /// Enum numbers are 32-bit (protobuf, cel-go's `EnumValueDescription.Value() int32`), so
  /// `registerEnumValue` takes an `Int32`: a strong enum value cannot hold a different number
  /// than the one registered.
  @Test func registeredEnumValuesAtInt32Bounds() throws {
    var registry = TypeRegistry()
    registry.registerEnumValue("my.Size.HUGE", number: .max)
    registry.registerEnumValue("my.Size.TINY", number: .min)
    let env = try Environment(.typeProvider(registry), .strongEnums)
    #expect(try evaluate("int(my.Size.HUGE)", in: env) == 2_147_483_647)
    #expect(try evaluate("int(my.Size.TINY)", in: env) == -2_147_483_648)
    #expect(try evaluate("my.Size(2147483647) == my.Size.HUGE", in: env) == true)
    let legacy = try Environment(.typeProvider(registry))
    #expect(try evaluate("my.Size.TINY", in: legacy) == -2_147_483_648)
  }
}
