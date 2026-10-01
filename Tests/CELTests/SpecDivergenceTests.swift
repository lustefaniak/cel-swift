// Behaviour where cel-swift follows the cel-spec conformance suite rather than cel-go; each case is
// listed in docs/divergences.md. The conformance tests cover the same cases; these pin them in the
// core test target, through the public API.

import CEL
import Testing

@Suite("Spec over cel-go")
struct SpecDivergenceTests {
  /// type_deductions/legacy_nullable_types: `null` joins into the nullable element type.
  @Test(arguments: [
    ("[d, null][0]", CELType.duration),
    ("[null, d][0]", .duration),
    ("[t, null][0]", .timestamp),
    ("[optional.of(1), null][0]", .optional(.int)),
  ] as [(String, CELType)])
  func nullJoinsIntoNullableType(_ expr: String, _ want: CELType) throws {
    let env = try Environment(.optionalTypes, .variable("d", .duration), .variable("t", .timestamp))
    #expect(try env.compile(expr).outputType == want)
  }

  /// type_deductions/wrappers/wrapper_promotion(_2): a primitive joins into its wrapper, in either order.
  @Test(arguments: ["[w, 1]", "[1, w]"])
  func primitiveJoinsIntoWrapper(_ expr: String) throws {
    let env = try Environment(.variable("w", .wrapper(.int)))
    #expect(try env.compile(expr).outputType == .list(.wrapper(.int)))
  }

  /// optionals/optionals/map_optional_select_has: an optional reached through a path is selected into.
  @Test(arguments: [
    ("has({'foo': optional.none()}.foo.bar)", Value.bool(false)),
    ("{'foo': optional.none()}.foo.bar == optional.none()", .bool(true)),
    ("{'foo': optional.of({'bar': 1})}.foo.bar == optional.of(1)", .bool(true)),
    ("has({'foo': optional.of({'bar': 1})}.foo.bar)", .bool(true)),
    ("has({'foo': optional.of({'bar': 1})}.foo.baz)", .bool(false)),
  ] as [(String, Value)])
  func optionalInsidePath(_ expr: String, _ want: Value) throws {
    let env = try Environment(.optionalTypes)
    let result = try env.program(try env.compile(expr)).evaluate()
    #expect(result.value == want)
  }

  /// timestamps/duration_converters/get_milliseconds: the milliseconds portion, not the conversion.
  @Test(arguments: [
    ("duration('1.234s').getMilliseconds()", Value.int(234)),
    ("duration('123.321s').getMilliseconds()", .int(321)),
    ("duration('-1.5s').getMilliseconds()", .int(-500)),
    ("duration('2h').getMilliseconds()", .int(0)),
  ] as [(String, Value)])
  func durationMilliseconds(_ expr: String, _ want: Value) throws {
    let env = try Environment()
    #expect(try env.program(try env.compile(expr)).evaluate().value == want)
  }
}
