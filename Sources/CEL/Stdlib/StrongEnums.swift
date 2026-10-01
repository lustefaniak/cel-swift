// The conversion functions of strong enum types, following the cel-spec language definition (enums) and the
// `enums/strong_*` conformance sections. Not a ported file: cel-go has no strong enums.

/// The functions ``Environment/Option/strongEnums`` declares for each enum type.
enum StrongEnums {
  /// `E(int)`, `E(string)` and the `int(E)` overload for the enum type named `enumType`.
  ///
  /// `E(int)` accepts any 32-bit number, declared or not, as open protobuf enums do; `E(string)` accepts
  /// only the declared value names.
  static func functions(enumType: String, values: [String: Int32]) throws -> [FunctionDecl] {
    let type = CELType.opaque(name: enumType, parameters: [])
    let conversion = try FunctionDecl(
      enumType,
      .documentation("convert a value to the enum \(enumType)"),
      .overload(
        "int_to_\(enumType)", argumentTypes: [.int], resultType: type,
        .unaryBinding { value in
          guard case .int(let i) = value else { return .error(.noSuchOverload) }
          guard let number = Int32(exactly: i) else {
            return .error(message: "range error converting \(i) to enum \(enumType)")
          }
          return .object(EnumValue(typeName: enumType, number: number))
        }),
      .overload(
        "string_to_\(enumType)", argumentTypes: [.string], resultType: type,
        .unaryBinding { value in
          guard case .string(let name) = value else { return .error(.noSuchOverload) }
          guard let number = values[name] else {
            return .error(message: "invalid enum value name '\(name)' for enum \(enumType)")
          }
          return .object(EnumValue(typeName: enumType, number: number))
        }))
    let toInt = try FunctionDecl(
      Overloads.typeConvertInt,
      .overload(
        "\(enumType)_to_int", argumentTypes: [type], resultType: .int,
        .unaryBinding { value in value.convert(to: .int) }))
    return [conversion, toInt]
  }
}
