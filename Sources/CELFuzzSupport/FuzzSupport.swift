// Shared setup for the libFuzzer targets (Sources/cel-fuzz-*). Not a ported file.
//
// Built only when CEL_FUZZ=1 is set while evaluating Package.swift; see Fuzz/README.md.

import CEL
import CELProtobuf
import CELSpecProtos

/// The environment and bindings the checker and evaluator fuzzers run against.
package enum FuzzSupport {
  /// The standard library, optional types, the conformance `TestAllTypes` messages (proto2 and
  /// proto3, container `cel.expr.conformance.proto3`) and a few variables of different types.
  package static let environment: ProgramEnvironment = {
    let protos = CELSpecProtos.protobufTypes
    var registry = TypeRegistry(composing: protos, adapter: protos)
    try? registry.register(CELType.optionalOfDyn)
    var env = ProgramEnvironment(
      container: (try? Container(.name("cel.expr.conformance.proto3"))) ?? .default,
      functions: StandardLibrary.functions + OptionalLibrary.functions(),
      variables: OptionalLibrary.types + [
        VariableDecl(name: "i", type: .int),
        VariableDecl(name: "u", type: .uint),
        VariableDecl(name: "d", type: .double),
        VariableDecl(name: "s", type: .string),
        VariableDecl(name: "b", type: .bytes),
        VariableDecl(name: "l", type: .list(.int)),
        VariableDecl(name: "m", type: .map(key: .string, value: .dyn)),
        VariableDecl(name: "x", type: .dyn),
        VariableDecl(name: "o", type: .optional(.string)),
        VariableDecl(name: "t", type: .timestamp),
        VariableDecl(name: "dur", type: .duration),
      ],
      provider: registry,
      macros: Macro.allMacros + OptionalLibrary.macros(),
      parserOptions: [.enableOptionalSyntax(true), .enableIdentEscapeSyntax(true)],
      errorOnBadPresenceTest: true)
    env.decorators = [OptionalLibrary.decorator]
    return env
  }()

  /// Values for the variables of ``environment``.
  package static let bindings: [String: Value] = [
    "i": .int(-7),
    "u": .uint(42),
    "d": .double(2.5),
    "s": .string("héllo wörld"),
    "b": .bytes([0, 1, 0xff]),
    "l": .list(ArrayList([1, 2, 3, 4, 5])),
    "m": .map(OrderedMap([("a", 1), ("b", "two"), ("c", .list(ArrayList([.bool(true), .null])))])),
    "x": .map(OrderedMap([("k", .list(ArrayList(["v", 2.0])))])),
    "o": .optional(.string("opt")),
    "t": .timestamp(CELTimestamp(secondsSinceEpoch: 1_700_000_000, nanoseconds: 5)),
    "dur": .duration(CELDuration(nanoseconds: 90_000_000_000)),
  ]

  /// The input as an expression: UTF-8, invalid sequences repaired.
  package static func expression(_ data: UnsafePointer<UInt8>?, _ size: Int) -> String {
    guard let data, size > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: size), as: UTF8.self)
  }
}
