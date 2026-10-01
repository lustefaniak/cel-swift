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
// Ported from cel-go common/types/provider.go (Provider, FieldType), common/types/struct.go
// (StructTypeDescriptor) and common/types/ref/provider.go (TypeAdapter).

/// The type of a message field and how to read it (cel-go `types.FieldType`).
public struct StructFieldType: Sendable {
  /// The declared CEL type of the field.
  public var type: CELType
  /// Whether the field is set on an object, the `has()` test.
  public var isSet: @Sendable (any ObjectValue) -> Bool
  /// Reads the field from an object.
  public var getFrom: @Sendable (any ObjectValue) -> Value
  /// Whether the field was found by its JSON name rather than its proto name.
  public var isJSONField: Bool

  /// Creates a field type.
  ///
  /// By default the field is read with ``ObjectValue/field(_:)`` and tested with
  /// ``ObjectValue/isFieldSet(_:)`` using `name`.
  public init(
    name: String,
    type: CELType,
    isJSONField: Bool = false,
    isSet: (@Sendable (any ObjectValue) -> Bool)? = nil,
    getFrom: (@Sendable (any ObjectValue) -> Value)? = nil
  ) {
    self.type = type
    self.isJSONField = isJSONField
    self.isSet = isSet ?? { object in object.isFieldSet(name) == .bool(true) }
    self.getFrom = getFrom ?? { object in object.field(name) }
  }
}

/// Describes a message (struct) type to the type checker and to object construction
/// (`pkg.Message{field: value}`).
///
/// Implemented by `CELProtobuf` for generated message adapters and by native Swift types.
public protocol StructTypeDescriptor: Sendable {
  /// The fully qualified type name, such as `google.expr.proto3.test.TestAllTypes`.
  var typeName: String { get }
  /// The names of the fields.
  var fieldNames: [String] { get }
  /// The type of a field, or `nil` if the type has no such field.
  func fieldType(named name: String) -> StructFieldType?
  /// Creates an instance from field values, or an error value such as `no such field: x`.
  func newValue(fields: [String: Value]) -> Value
}

/// Resolves types, fields, enum values and identifiers for the checker and the interpreter, and
/// constructs objects.
///
/// ``TypeRegistry`` is the standard implementation; other providers can be composed underneath it
/// (``Environment/Option/typeProvider(_:)``). Every requirement has a default that reports a miss,
/// so such a provider implements only the lookups it answers.
public protocol TypeProvider: Sendable {
  /// The numeric value of a fully qualified enum value name, or an error value.
  func enumValue(_ enumName: String) -> Value

  /// The value of a qualified identifier: a type value such as `int`, or an enum constant.
  func findIdent(_ identName: String) -> Value?

  /// The type of a struct type name, wrapped as a type value: `type(pkg.Message)`.
  func findStructType(_ structType: String) -> CELType?

  /// The field names of a struct type.
  func findStructFieldNames(_ structType: String) -> [String]?

  /// The type of a struct field.
  func findStructFieldType(_ structType: String, fieldName: String) -> StructFieldType?

  /// Creates an object of a struct type from field values, or an error value.
  func newValue(_ structType: String, fields: [String: Value]) -> Value
}

/// Neutral answers, so a provider composed under a ``TypeRegistry`` implements only the lookups it
/// handles; each default is the miss ``TypeRegistry`` itself reports.
extension TypeProvider {
  /// Returns `unknown enum name 'x'`.
  public func enumValue(_ enumName: String) -> Value {
    .error(message: "unknown enum name '\(enumName)'")
  }

  /// Returns `nil`: no identifier is known.
  public func findIdent(_ identName: String) -> Value? {
    nil
  }

  /// Returns `nil`: no struct type is known.
  public func findStructType(_ structType: String) -> CELType? {
    nil
  }

  /// Returns `nil`: no struct type is known.
  public func findStructFieldNames(_ structType: String) -> [String]? {
    nil
  }

  /// Returns `nil`: no struct type is known.
  public func findStructFieldType(_ structType: String, fieldName: String) -> StructFieldType? {
    nil
  }

  /// Returns `unknown type 'x'`.
  public func newValue(_ structType: String, fields: [String: Value]) -> Value {
    .error(message: "unknown type '\(structType)'")
  }
}

/// Converts host values to CEL values.
public protocol TypeAdapter: Sendable {
  /// Converts a host value to a CEL value, or returns an error value if it cannot.
  func nativeToValue(_ value: Any) -> Value
}
