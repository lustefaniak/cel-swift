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
// Ported from cel-go common/types/object.go (behaviour as a protocol), common/types/traits/
// field_tester.go and indexer.go.

/// A structured value with named fields, such as a protobuf message or a native Swift type, or
/// an abstract (opaque) value introduced by an extension.
///
/// Conforming types describe their CEL type, answer field selections (`msg.field`) and presence
/// tests (`has(msg.field)`), and define equality. Message types are additionally described to the
/// type checker and to object construction by a ``StructTypeDescriptor`` registered with a
/// ``TypeRegistry``.
public protocol ObjectValue: Sendable {
  /// The runtime type: ``CELType/object(_:)`` for messages, ``CELType/opaque(name:parameters:)``
  /// for abstract values.
  var celType: CELType { get }

  /// The capabilities of the value. Defaults to the traits of ``celType``.
  var traits: TypeTraits { get }

  /// Returns the value of a field, or an error value such as `no such field 'x'`.
  func field(_ name: String) -> Value

  /// Returns `.bool(true)` if the field is set to a non-default value, `.bool(false)` if it is
  /// defined but unset, or an error value if the field is not defined.
  func isFieldSet(_ name: String) -> Value

  /// Whether this object equals another under CEL equality.
  func isEqual(to other: any ObjectValue) -> Bool

  /// Whether the object is the zero value of its type (an empty message). Defaults to `false`.
  var isZeroValue: Bool { get }
}

extension ObjectValue {
  /// The traits of ``celType``.
  public var traits: TypeTraits { celType.traits }

  /// `false`.
  public var isZeroValue: Bool { false }

  /// Returns a `no such field` error for every field.
  public func field(_ name: String) -> Value {
    .error(EvalError("no such field '\(name)'"))
  }

  /// Returns a `no such field` error for every field.
  public func isFieldSet(_ name: String) -> Value {
    .error(EvalError("no such field '\(name)'"))
  }
}
