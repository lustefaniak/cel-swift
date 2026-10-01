// Strong enum values, following the cel-spec language definition (enums are distinct types) and the
// `enums/strong_*` conformance sections. Not a ported file: cel-go represents every enum value as an int.

/// A value of a protobuf enum type, when the environment enables ``Environment/Option/strongEnums``.
///
/// With strong enums, `pkg.Color.RED` and enum fields of messages evaluate to enum values instead of
/// `int`s: their type is the enum, `type(pkg.Color.RED) == pkg.Color`, and they equal only values of
/// the same enum with the same number. `int(e)` gives the number; `pkg.Color(1)` and
/// `pkg.Color('RED')` create one. An enum value's ``celType`` is the abstract type named after the
/// enum, `.opaque(name: "pkg.Color", parameters: [])`.
///
/// Values outside the declared ones are allowed, as protobuf open enums hold any 32-bit number.
public struct EnumValue: ObjectValue, Hashable, CustomStringConvertible {
  /// The fully qualified enum type name, such as `google.type.DayOfWeek`.
  public let typeName: String
  /// The numeric value.
  public let number: Int32

  /// Creates a value of the enum type named `typeName`.
  ///
  /// - Parameters:
  ///   - typeName: The fully qualified enum type name.
  ///   - number: The numeric value, declared by the enum or not.
  public init(typeName: String, number: Int32) {
    self.typeName = typeName
    self.number = number
  }

  /// The enum type: ``CELType/opaque(name:parameters:)`` named ``typeName``.
  public var celType: CELType {
    .opaque(name: typeName, parameters: [])
  }

  /// Whether `other` is a value of the same enum type with the same number.
  public func isEqual(to other: any ObjectValue) -> Bool {
    guard let other = other as? EnumValue else { return false }
    return self == other
  }

  /// Whether the number is 0, the default value of every enum field.
  public var isZeroValue: Bool {
    number == 0
  }

  /// The type name and number, such as `google.type.DayOfWeek(1)`.
  public var description: String {
    "\(typeName)(\(number))"
  }
}

/// A type provider that can represent its enum values as ``EnumValue``s, so that
/// ``Environment/Option/strongEnums`` can switch it over and declare the enum conversion functions.
///
/// ``TypeRegistry`` conforms and passes the switch on to a composed provider that conforms too, such as
/// the `CELProtobuf` types.
package protocol StrongEnumProvider: TypeProvider {
  /// The enum types the provider knows that become strong enums when enabled, by fully qualified
  /// name, with the numbers of their value names.
  var strongEnumTypes: [String: [String: Int32]] { get }

  /// The provider with strong enums enabled or disabled.
  func settingStrongEnums(_ enabled: Bool) -> Self
}
